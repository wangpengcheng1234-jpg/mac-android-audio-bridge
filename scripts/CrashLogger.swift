import Cocoa
import Darwin

// MARK: - Crash Logger（低内存崩溃日志）
//
// 设计要点：
// 1. 启动时在 ~/Library/Logs/TransAudio/crashes/ 预打开一个崩溃文件，保存 fd。
//    这样崩溃时无需在 signal handler 里做文件打开（open 不是 100% 信号安全）。
// 2. signal handler / NSException handler 中只调用 async-signal-safe 函数：
//    write / backtrace / getpid / fsync，绝不分配内存，保证崩溃时也能写出调用栈。
// 3. 崩溃文件只写原始信号与返回地址（hex），启动时再用 atos 符号化并分析。
// 4. 启动时扫描目录，超过 30 个则删除最旧的（按文件名时间戳排序）。
// 5. 写完后 re-raise 信号，让系统照常生成 CrashReporter 报告。

private let kCrashDir = NSHomeDirectory() + "/Library/Logs/TransAudio/crashes"
private let kMaxCrashLogs = 30

/// 预打开的崩溃文件 fd（信号处理器中使用）
private var crashFD: Int32 = -1
private var crashPID: pid_t = 0
/// 预写入的版本串（C 字符串，信号处理器中安全）
private var crashVersionCStr: [CChar] = []
/// 主二进制加载地址（ASLR slide 后），用于 atos 符号化
private var crashLoadAddr: UInt = 0

private let kCrashSignals: [Int32] = [
    SIGABRT, SIGBUS, SIGSEGV, SIGILL, SIGTRAP, SIGFPE, SIGSYS
]

// MARK: - 公共接口

enum CrashLogger {

    /// 在 applicationDidFinishLaunching 最早调用：轮转旧日志、打开新崩溃文件、安装处理器。
    static func install(version: String) {
        crashPID = getpid()
        crashVersionCStr = Array(version.utf8CString) // 含结尾 \0
        crashLoadAddr = UInt(bitPattern: _dyld_get_image_header(0))
        rotateCrashLogs()
        openCrashFile()
        installSignalHandlers()
        NSSetUncaughtExceptionHandler { exception in
            handleUncaughtException(exception)
        }
    }

    /// 启动后分析历史崩溃日志，返回聚合摘要（按 信号+栈顶函数 分组）。
    static func analyze() -> CrashAnalysis {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: kCrashDir) else {
            return CrashAnalysis(total: 0, groups: [])
        }
        let crashFiles = files.filter { $0.hasPrefix("crash_") && $0.hasSuffix(".log") }
            .sorted(by: >) // 新→旧
        var entries: [CrashEntry] = []
        for f in crashFiles.prefix(kMaxCrashLogs) {
            if let entry = parseCrashFile(kCrashDir + "/" + f) {
                entries.append(entry)
            }
        }
        return groupEntries(entries)
    }

    /// 打开崩溃日志目录（Finder）
    static func revealInFinder() {
        let url = URL(fileURLWithPath: kCrashDir, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 清空所有崩溃日志
    static func clearAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: kCrashDir) else { return }
        for f in files where f.hasPrefix("crash_") {
            try? fm.removeItem(atPath: kCrashDir + "/" + f)
        }
    }
}

// MARK: - 崩溃条目结构

struct CrashEntry {
    let date: Date
    let signalName: String
    let signalNumber: Int
    let version: String
    let frames: [UInt]       // 原始返回地址
    let symbols: [String]    // atos 符号化后的函数名
    var topSymbol: String { symbols.first ?? "0x\(String(frames.first ?? 0, radix: 16))" }
}

struct CrashGroup {
    let key: String          // signal + topSymbol
    let count: Int
    let latest: Date
    let sample: CrashEntry
}

struct CrashAnalysis {
    let total: Int
    let groups: [CrashGroup]
}

// MARK: - 启动：轮转 + 打开文件

private func rotateCrashLogs() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: kCrashDir, withIntermediateDirectories: true)
    guard let files = try? fm.contentsOfDirectory(atPath: kCrashDir) else { return }
    // 每次启动都会预建一个空文件供信号处理器写入；若上次没有崩溃，这个文件会留成 0 字节。
    // 必须先清掉，否则空文件会占满 30 条上限，把真正的崩溃记录挤掉。
    for f in files where f.hasPrefix("crash_") && f.hasSuffix(".log") {
        let p = kCrashDir + "/" + f
        if let size = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int, size == 0 {
            try? fm.removeItem(atPath: p)
        }
    }
    guard let remaining = try? fm.contentsOfDirectory(atPath: kCrashDir) else { return }
    let crashFiles = remaining.filter { $0.hasPrefix("crash_") && $0.hasSuffix(".log") }
        .sorted(by: <) // 旧→新
    if crashFiles.count >= kMaxCrashLogs {
        let toDelete = crashFiles.count - kMaxCrashLogs + 1 // 多删一个给新文件腾位
        for f in crashFiles.prefix(toDelete) {
            try? fm.removeItem(atPath: kCrashDir + "/" + f)
        }
    }
}

private func openCrashFile() {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd_HHmmss"
    let name = "crash_\(fmt.string(from: Date())).log"
    let path = kCrashDir + "/" + name
    // O_CREAT|O_WRONLY|O_TRUNC，权限 0644
    crashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
}

// MARK: - 信号处理器安装

private func installSignalHandlers() {
    for sig in kCrashSignals {
        var act = sigaction()
        act.__sigaction_u.__sa_handler = { sig in
            handleSignal(sig)
        }
        sigemptyset(&act.sa_mask)
        act.sa_flags = SA_RESETHAND // 触发后恢复默认处理器，写完 re-raise 让系统生成报告
        sigaction(sig, &act, nil)
    }
}

// MARK: - signal handler（async-signal-safe）

private func handleSignal(_ sig: Int32) {
    guard crashFD >= 0 else { return }

    // 头部
    writeCStr(crashFD, "signal=")
    writeIntDec(crashFD, sig)
    // 上一行 writeIntDec 已写换行，这里写 name 行
    writeCStr(crashFD, "name=")
    writeCStr(crashFD, signalCName(sig))
    writeCStr(crashFD, "\npid=")
    writeIntDec(crashFD, crashPID)
    writeCStr(crashFD, "version=")
    if !crashVersionCStr.isEmpty {
        _ = crashVersionCStr.withUnsafeBufferPointer { ptr in
            write(crashFD, ptr.baseAddress, strlen(ptr.baseAddress!))
        }
    }
    writeCStr(crashFD, "\nframes=\n")

    // 主二进制加载地址（用于 atos 符号化）
    writeCStr(crashFD, "loadaddr=")
    writeUIntHex(crashFD, crashLoadAddr)

    // 调用栈（只写原始地址，符号化留给启动时）
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let count = Int(backtrace(&frames, 128))
    for i in 0..<count {
        if let addr = frames[i] {
            writeUIntHex(crashFD, UInt(bitPattern: addr))
        }
    }

    fsync(crashFD)
    close(crashFD)
    crashFD = -1

    // re-raise 让系统生成 CrashReporter 报告
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - NSException handler

private func handleUncaughtException(_ exception: NSException) {
    guard crashFD >= 0 else { return }
    let name = exception.name.rawValue
    let reason = exception.reason ?? "(no reason)"
    let callStack = exception.callStackSymbols

    let text = """
    signal=NSException
    name=\(name)
    pid=\(crashPID)
    version=\(crashVersionCStr.isEmpty ? "" : String(cString: crashVersionCStr))
    reason=\(reason)
    frames=
    \(callStack.joined(separator: "\n"))
    """
    if let data = text.data(using: .utf8) {
        _ = data.withUnsafeBytes { buf in
            write(crashFD, buf.baseAddress, buf.count)
        }
    }
    fsync(crashFD)
    close(crashFD)
    crashFD = -1
}

// MARK: - 信号安全的写辅助（纯栈缓冲，无 malloc）

private func writeCStr(_ fd: Int32, _ s: UnsafePointer<CChar>) {
    _ = write(fd, s, strlen(s))
}

private func writeIntDec(_ fd: Int32, _ v: Int32) {
    var buf = [CChar](repeating: 0, count: 16)
    var n = v
    var pos = 14
    buf[15] = 0x0a // '\n'
    if n == 0 {
        buf[pos] = 0x30; pos -= 1
    } else {
        var neg = false
        if n < 0 { neg = true; n = -n }
        while n > 0 && pos >= 1 {
            buf[pos] = CChar(0x30 + (n % 10))
            n /= 10
            pos -= 1
        }
        if neg { buf[pos] = 0x2d; pos -= 1 } // '-'
    }
    buf.withUnsafeBufferPointer { ptr in
        _ = write(fd, ptr.baseAddress!.advanced(by: pos + 1), 15 - pos)
    }
}

private func writeUIntHex(_ fd: Int32, _ v: UInt) {
    // "0x" + hex(v) + "\n"
    var buf = [CChar](repeating: 0, count: 24)
    let hex: [CChar] = [0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,
                        0x38,0x39,0x61,0x62,0x63,0x64,0x65,0x66]
    var n = v
    var pos = 22
    buf[23] = 0x0a // '\n'
    if n == 0 {
        buf[pos] = hex[0]; pos -= 1
    } else {
        while n > 0 && pos >= 2 {
            buf[pos] = hex[Int(n & 0xf)]
            n >>= 4
            pos -= 1
        }
    }
    buf[pos] = 0x78 // 'x'
    pos -= 1
    buf[pos] = 0x30 // '0'
    buf.withUnsafeBufferPointer { ptr in
        _ = write(fd, ptr.baseAddress!.advanced(by: pos), 24 - pos)
    }
}

private func signalCName(_ sig: Int32) -> UnsafePointer<CChar> {
    let s: StaticString
    switch sig {
    case SIGABRT: s = "SIGABRT"
    case SIGBUS:  s = "SIGBUS"
    case SIGSEGV: s = "SIGSEGV"
    case SIGILL:  s = "SIGILL"
    case SIGTRAP: s = "SIGTRAP"
    case SIGFPE:  s = "SIGFPE"
    case SIGSYS:  s = "SIGSYS"
    default:      s = "UNKNOWN"
    }
    // StaticString 存储在静态区，rebound 后指针长期有效
    return s.utf8Start.withMemoryRebound(to: CChar.self, capacity: s.utf8CodeUnitCount + 1) { $0 }
}

// MARK: - 解析崩溃文件 + atos 符号化

private func parseCrashFile(_ path: String) -> CrashEntry? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var signalName = "UNKNOWN", version = "", signalNumber = 0
    var frames: [UInt] = []
    var loadAddr: UInt? = nil
    var inFrames = false
    for line in lines {
        let s = String(line)
        if s.hasPrefix("signal=") {
            let v = String(s.dropFirst(7))
            if v == "NSException" { signalName = "NSException"; signalNumber = -1 }
            else if let n = Int(v) { signalNumber = n; signalName = nameOfSignal(n) }
        } else if s.hasPrefix("name=") {
            signalName = String(s.dropFirst(5))
        } else if s.hasPrefix("version=") {
            version = String(s.dropFirst(8))
        } else if s.hasPrefix("loadaddr=") {
            let a = String(s.dropFirst(9))
            if a.hasPrefix("0x"), let addr = UInt(a.dropFirst(2), radix: 16) {
                loadAddr = addr
            }
        } else if s == "frames=" {
            inFrames = true
        } else if inFrames {
            if s.hasPrefix("0x"), let addr = UInt(s.dropFirst(2), radix: 16) {
                frames.append(addr)
            } else if !s.isEmpty && signalName == "NSException" {
                // NSException 的 callStackSymbols 是已符号化的文本
                frames.append(0)
            }
        }
    }
    // 文件名时间戳
    let base = (path as NSString).lastPathComponent
    let fmt = DateFormatter()
    fmt.dateFormat = "'crash_'yyyyMMdd_HHmmss'.log'"
    let date = fmt.date(from: base) ?? Date()

    let symbols = symbolicate(frames: frames, loadAddr: loadAddr,
                              isException: signalName == "NSException", content: content)
    return CrashEntry(date: date, signalName: signalName, signalNumber: signalNumber,
                      version: version, frames: frames, symbols: symbols)
}

private func nameOfSignal(_ n: Int) -> String {
    switch Int32(n) {
    case SIGABRT: return "SIGABRT"
    case SIGBUS:  return "SIGBUS"
    case SIGSEGV: return "SIGSEGV"
    case SIGILL:  return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    case SIGFPE:  return "SIGFPE"
    case SIGSYS:  return "SIGSYS"
    default:      return "SIG\(n)"
    }
}

/// 用 atos 符号化返回地址（仅主二进制内的地址）
private func symbolicate(frames: [UInt], loadAddr: UInt?, isException: Bool, content: String) -> [String] {
    if isException {
        // NSException 已带符号化栈，直接提取 frames= 之后的行
        if let range = content.range(of: "frames=") {
            let tail = content[range.upperBound...]
            return tail.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        return []
    }
    guard !frames.isEmpty, let exec = Bundle.main.executablePath else {
        return frames.map { "0x\(String($0, radix: 16))" }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
    var args = ["-o", exec, "-arch", "arm64"]
    if let la = loadAddr {
        args += ["-l", "0x\(String(la, radix: 16))"]
    }
    args += frames.map { "0x\(String($0, radix: 16))" }
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    do {
        try p.run()
    } catch {
        return frames.map { "0x\(String($0, radix: 16))" }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    let syms = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
    return syms.isEmpty ? frames.map { "0x\(String($0, radix: 16))" } : syms
}

// MARK: - 聚合分析

private func groupEntries(_ entries: [CrashEntry]) -> CrashAnalysis {
    var dict: [String: (count: Int, latest: Date, sample: CrashEntry)] = [:]
    for e in entries {
        let key = "\(e.signalName) | \(e.topSymbol)"
        if var existing = dict[key] {
            existing.count += 1
            if e.date > existing.latest { existing.latest = e.date }
            dict[key] = existing
        } else {
            dict[key] = (1, e.date, e)
        }
    }
    let groups = dict.map { (key, val) in
        CrashGroup(key: key, count: val.count, latest: val.latest, sample: val.sample)
    }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.latest > $1.latest) }
    return CrashAnalysis(total: entries.count, groups: groups)
}
