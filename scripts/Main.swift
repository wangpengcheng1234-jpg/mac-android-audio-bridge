import Cocoa
import CoreAudio

/// scrcpy 目录查找顺序：用户设置 → App 内置 Resources/scrcpy → ~/scrcpy → ~/Downloads
func findScrcpyDir() -> String? {
    var candidates: [String] = []
    if let saved = UserDefaults.standard.string(forKey: "scrcpyDir"), !saved.isEmpty {
        candidates.append(saved)
    }
    if let res = Bundle.main.resourceURL?.appendingPathComponent("scrcpy").path {
        candidates.append(res)
        candidates.append(res + "/scrcpy-macos-aarch64-v5.0.1")
    }
    candidates.append(NSHomeDirectory() + "/scrcpy/scrcpy-macos-aarch64-v5.0.1")
    candidates.append(NSHomeDirectory() + "/Downloads/scrcpy-macos-aarch64-v5.0.1")
    for c in candidates where FileManager.default.isExecutableFile(atPath: c + "/scrcpy") {
        return c
    }
    return nil
}

let scrcpyDir: String? = findScrcpyDir()

/// adb 查找顺序：环境变量 ADB → Android SDK → scrcpy 自带 adb → PATH
let adbPath: String = {
    if let env = ProcessInfo.processInfo.environment["ADB"], !env.isEmpty { return env }
    let sdk = NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
    if FileManager.default.isExecutableFile(atPath: sdk) { return sdk }
    if let dir = scrcpyDir, FileManager.default.isExecutableFile(atPath: dir + "/adb") { return dir + "/adb" }
    return "adb"
}()

/// 手机 IP（无线调试用），首次使用由用户输入，成功后自动记住
var lastIP: String {
    get { UserDefaults.standard.string(forKey: "lastIP") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "lastIP") }
}

// spyblue 配色
let C_BG      = NSColor(calibratedRed: 0.039, green: 0.043, blue: 0.059, alpha: 1)
let C_CYAN    = NSColor(calibratedRed: 0.00,  green: 0.84,  blue: 1.00, alpha: 1)
let C_BORDER  = NSColor(calibratedWhite: 0.42, alpha: 1)
let C_DIM     = NSColor(calibratedWhite: 0.58, alpha: 1)
let C_WHITE   = NSColor(calibratedWhite: 0.95, alpha: 1)
let C_MAGENTA = NSColor(calibratedRed: 1.00, green: 0.35, blue: 0.85, alpha: 1)
let C_GREEN   = NSColor(calibratedRed: 0.25, green: 0.95, blue: 0.42, alpha: 1)
let C_YELLOW  = NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.25, alpha: 1)
let C_RED     = NSColor(calibratedRed: 1.00, green: 0.33, blue: 0.33, alpha: 1)
let C_BLUE    = NSColor(calibratedRed: 0.42, green: 0.62, blue: 1.00, alpha: 1)

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

// MARK: - 面板（仿 rich.Panel 的描边）

final class PanelView: NSView {
    var title: String = ""
    var borderColor: NSColor = C_BORDER

    init(title: String, borderColor: NSColor = C_BORDER) {
        self.title = title
        self.borderColor = borderColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()

        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        if !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: mono(11, .medium),
                .foregroundColor: borderColor
            ]
            let size = title.size(withAttributes: attrs)
            let titleRect = NSRect(x: 12, y: bounds.height - size.height - 8,
                                   width: size.width, height: size.height)
            C_BG.setFill()
            titleRect.insetBy(dx: -4, dy: 0).fill()
            title.draw(at: titleRect.origin, withAttributes: attrs)

            let line = NSBezierPath()
            line.move(to: NSPoint(x: 12 + size.width + 8, y: bounds.height - 14))
            line.line(to: NSPoint(x: bounds.width - 12, y: bounds.height - 14))
            borderColor.withAlphaComponent(0.45).setStroke()
            line.lineWidth = 1
            line.stroke()
        }
    }
}

// MARK: - 文字行

func textLabel(_ s: String, color: NSColor, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = mono(size, bold ? .bold : .regular)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

func keyRow(_ key: String, _ value: NSTextField) -> NSStackView {
    let k = textLabel(key, color: C_DIM, size: 12)
    k.widthAnchor.constraint(equalToConstant: 132).isActive = true
    let row = NSStackView(views: [k, value])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
}

func blockBar(_ pct: Double, width: Int = 14) -> String {
    let filled = max(0, min(width, Int((pct / 100.0) * Double(width))))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

// 原生读默认输出设备。
// 之前用 python+sounddevice 轮询会初始化 PortAudio/CoreAudio，触发设备变更通知，
// 网易云音乐等播放器会因此误判“耳机切换”而自动续播，这里改成纯只读属性查询。
func defaultOutputDeviceName() -> String {
    var devAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &devAddr, 0, nil, &devSize, &dev) == noErr, dev != 0 else {
        return ""
    }

    var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var unmanagedName: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, &unmanagedName) == noErr,
          let cfName = unmanagedName else {
        return ""
    }
    return cfName.takeUnretainedValue() as String
}

// MARK: - 主程序

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    let deviceValue   = textLabel("—", color: C_MAGENTA, size: 12, bold: true)
    let statusValue   = textLabel("IDLE", color: C_YELLOW, size: 12, bold: true)
    let transportValue = textLabel("—", color: C_WHITE, size: 12)
    let codecValue    = textLabel("OPUS · 48 kHz · 16bit · 立体声（系统固定）", color: C_WHITE, size: 12)
    let dataValue     = textLabel("0.0 MB", color: C_BLUE, size: 12, bold: true)
    let uptimeValue   = textLabel("00:00", color: C_WHITE, size: 12)

    let volBar   = textLabel("[░░░░░░░░░░░░░░]", color: C_GREEN, size: 12, bold: true)
    let volValue = textLabel("— %", color: C_GREEN, size: 12, bold: true)
    let outValue = textLabel("检测中…", color: C_WHITE, size: 12)
    let outHint  = textLabel("Mac 音频输出", color: C_DIM, size: 11)
    let rttValue = textLabel("— ms", color: C_BLUE, size: 13, bold: true)
    let rttHint  = textLabel("实测 WiFi 往返耗时", color: C_DIM, size: 11)

    let actionButton = NSButton()
    let bufferPopup = NSPopUpButton()
    let bitratePopup = NSPopUpButton()
    let codecPopup = NSPopUpButton()

    var process: Process?
    var pollTimer: Timer?
    var uiTimer: Timer?
    var startTime: Date?
    var savedPhoneVolume: Int?
    var logHandle: FileHandle?

    // MARK: 建窗

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        refreshOutputDevice()
        refreshVolume()
        refreshRTT()
        // 上一次若异常退出，手机上可能留着 scrcpy 采集进程（会让手机一直没声音），启动时先清掉
        DispatchQueue.global().async { self.cleanupPhoneServer() }
    }

    func panelContent(_ rows: [NSView]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        return stack
    }

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 660, height: 486)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "iTrae 手机音频接收"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = C_BG
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = C_BG.cgColor
        window.contentView = root

        // —— 顶部标题面板
        let header = PanelView(title: "", borderColor: C_CYAN)
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerLabel = textLabel("SpyBlue  ·  MAC AUDIO BRIDGE", color: C_CYAN, size: 15, bold: true)
        headerLabel.alignment = .center
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 52),
            headerLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            headerLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        // —— 左面板：System Info
        let leftRows = [
            keyRow("Target Device: ", deviceValue),
            keyRow("Bridge Status: ", statusValue),
            keyRow("Transport:     ", transportValue),
            keyRow("Codec:         ", codecValue),
            keyRow("Uptime:        ", uptimeValue),
            keyRow("Data Received: ", dataValue)
        ]
        let leftPanel = PanelView(title: " System Info ", borderColor: C_BORDER)
        let leftInner = panelContent(leftRows)
        leftInner.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(leftInner)
        NSLayoutConstraint.activate([
            leftInner.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 16),
            leftInner.trailingAnchor.constraint(lessThanOrEqualTo: leftPanel.trailingAnchor, constant: -16),
            leftInner.topAnchor.constraint(equalTo: leftPanel.topAnchor, constant: 46),
            leftInner.bottomAnchor.constraint(lessThanOrEqualTo: leftPanel.bottomAnchor, constant: -16)
        ])

        // —— 右面板：Performance & Levels
        let volRow = NSStackView(views: [volBar, volValue])
        volRow.orientation = .horizontal
        volRow.spacing = 8
        volRow.alignment = .centerY

        let rttRow = NSStackView(views: [rttValue, rttHint])
        rttRow.orientation = .horizontal
        rttRow.spacing = 8
        rttRow.alignment = .centerY

        let rightRows: [NSView] = [
            textLabel("Mac Volume:", color: C_DIM, size: 12),
            volRow,
            textLabel("Output Device:", color: C_DIM, size: 12),
            outValue,
            outHint,
            textLabel("Network Latency:", color: C_DIM, size: 12),
            rttRow
        ]
        let rightPanel = PanelView(title: " Performance & Levels ", borderColor: C_BORDER)
        let rightInner = panelContent(rightRows)
        rightInner.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(rightInner)
        NSLayoutConstraint.activate([
            rightInner.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 16),
            rightInner.trailingAnchor.constraint(lessThanOrEqualTo: rightPanel.trailingAnchor, constant: -16),
            rightInner.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 46),
            rightInner.bottomAnchor.constraint(lessThanOrEqualTo: rightPanel.bottomAnchor, constant: -16)
        ])

        let panelsRow = NSStackView(views: [leftPanel, rightPanel])
        panelsRow.orientation = .horizontal
        panelsRow.spacing = 12
        panelsRow.distribution = .fillEqually
        panelsRow.translatesAutoresizingMaskIntoConstraints = false

        // —— 音频参数（卡顿 / 电流声调这里，改动后重新 START 生效）
        let bufferOptions = ["50 ms", "100 ms", "200 ms", "350 ms", "500 ms"]
        let bitrateOptions = ["96K", "128K", "192K", "256K", "320K"]
        let codecOptions = ["opus", "aac", "flac", "raw"]

        func savedIndex(_ key: String, _ options: [String], fallback: Int) -> Int {
            if let s = UserDefaults.standard.string(forKey: key), let i = options.firstIndex(of: s) { return i }
            return fallback
        }
        func setupPopup(_ popup: NSPopUpButton, _ options: [String], _ index: Int) {
            popup.addItems(withTitles: options)
            popup.selectItem(at: index)
            popup.font = mono(11)
            popup.controlSize = .small
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }
        setupPopup(bufferPopup, bufferOptions, savedIndex("audioBuffer", bufferOptions, fallback: 2))
        setupPopup(bitratePopup, bitrateOptions, savedIndex("audioBitrate", bitrateOptions, fallback: 1))
        setupPopup(codecPopup, codecOptions, savedIndex("audioCodec", codecOptions, fallback: 0))
        codecValue.stringValue = (codecPopup.titleOfSelectedItem ?? "opus").uppercased() + " · 48 kHz · 16bit · 立体声（系统固定）"

        func settingGroup(_ title: String, _ popup: NSPopUpButton) -> NSStackView {
            let label = textLabel(title, color: C_DIM, size: 11)
            let s = NSStackView(views: [label, popup])
            s.orientation = .horizontal
            s.spacing = 6
            s.alignment = .centerY
            return s
        }

        let settingsRow = NSStackView(views: [
            settingGroup("Buffer:", bufferPopup),
            settingGroup("Bitrate:", bitratePopup),
            settingGroup("Codec:", codecPopup)
        ])
        settingsRow.orientation = .horizontal
        settingsRow.spacing = 14
        settingsRow.alignment = .centerY
        settingsRow.translatesAutoresizingMaskIntoConstraints = false

        // —— 主按钮
        actionButton.title = "▶  START BRIDGE"
        actionButton.bezelStyle = .rounded
        actionButton.font = mono(13, .bold)
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.contentTintColor = .white
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.heightAnchor.constraint(equalToConstant: 38).isActive = true

        // —— 底部提示面板
        let footer = PanelView(title: "", borderColor: C_YELLOW)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerLabel = textLabel("关闭窗口即安全断开（自动恢复手机声音） · 手机与 Mac 需同一 Wi-Fi", color: C_YELLOW, size: 11)
        footerLabel.alignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            footer.heightAnchor.constraint(equalToConstant: 40),
            footerLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            footerLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        root.addSubview(header)
        root.addSubview(panelsRow)
        root.addSubview(settingsRow)
        root.addSubview(actionButton)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            panelsRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            panelsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            panelsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            panelsRow.heightAnchor.constraint(equalToConstant: 222),

            settingsRow.topAnchor.constraint(equalTo: panelsRow.bottomAnchor, constant: 12),
            settingsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            settingsRow.heightAnchor.constraint(equalToConstant: 24),

            actionButton.topAnchor.constraint(equalTo: settingsRow.bottomAnchor, constant: 12),
            actionButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            actionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            footer.topAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 数据刷新

    private func runADB(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8) ?? ""
    }

    private func findDevice() -> String? {
        let out = runADB(["devices"])
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2 && parts[1] == "device" { return String(parts[0]) }
        }
        return nil
    }

    /// 读手机媒体音量（STREAM_MUSIC）
    private func phoneMediaVolume() -> Int? {
        let out = runADB(["shell", "cmd", "media_session", "volume", "--stream", "3", "--get"])
        guard let r = out.range(of: "volume is ") else { return nil }
        let digits = out[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func setPhoneMediaVolume(_ v: Int) {
        _ = runADB(["shell", "cmd", "media_session", "volume", "--stream", "3", "--set", "\(v)"])
    }

    /// 杀掉手机端遗留的 scrcpy 采集进程。
    /// scrcpy 被异常终止时，设备端的 server 会活着继续占用音频路由（remote_submix），
    /// 表现就是「关掉电脑上的程序后手机没声音」。
    private func cleanupPhoneServer() {
        let out = runADB(["shell", "ps", "-A", "-o", "PID,ARGS"])
        for line in out.split(separator: "\n")
            where line.contains("com.genymobile.scrcpy.Server") && line.contains("video=false") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if let pid = parts.first, pid.allSatisfy(\.isNumber) {
                _ = runADB(["shell", "kill", "-9", String(pid)])
            }
        }
    }

    func refreshVolume() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "output volume of (get volume settings)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var vol = -1
            do {
                try p.run(); p.waitUntilExit()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                vol = Int((String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            } catch { vol = -1 }

            DispatchQueue.main.async {
                guard vol >= 0 else { return }
                self.volBar.stringValue = "[\(blockBar(Double(vol)))]"
                self.volValue.stringValue = "\(vol)%"
                let color = vol >= 80 ? C_RED : C_GREEN
                self.volBar.textColor = color
                self.volValue.textColor = color
            }
        }
    }

    func refreshOutputDevice() {
        DispatchQueue.global().async {
            let name = defaultOutputDeviceName()

            // 输出看起来像蓝牙音箱时给个提示（名字里不含 "MacBook" 的 "Speaker" 也算）
            let lower = name.lowercased()
            let looksLikeSpeaker = lower.contains("bluetooth") || name.contains("蓝牙") || name.contains("音箱")
                || (lower.contains("speaker") && !lower.contains("macbook"))
            let ok = !looksLikeSpeaker

            DispatchQueue.main.async {
                self.outValue.stringValue = name.isEmpty ? "未知" : name
                if name.isEmpty {
                    self.outHint.stringValue = "无法读取输出设备"
                    self.outHint.textColor = C_RED
                } else if ok {
                    self.outValue.textColor = C_WHITE
                    self.outHint.stringValue = "OK · 声音将送到这里"
                    self.outHint.textColor = C_GREEN
                } else {
                    self.outValue.textColor = C_YELLOW
                    self.outHint.stringValue = "⚠ 输出像是蓝牙音箱，建议换回耳机/内置"
                    self.outHint.textColor = C_YELLOW
                }
            }
        }
    }

    // MARK: 操作

    /// 实测 WiFi 往返延迟（ping 手机 IP）
    func refreshRTT() {
        let ip = lastIP
        guard !ip.isEmpty else {
            rttValue.stringValue = "— ms"
            rttValue.textColor = C_DIM
            rttHint.stringValue = "未设置手机 IP"
            return
        }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/ping")
            p.arguments = ["-c", "2", "-q", ip]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            var avg: Double?
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let r = out.range(of: "round-trip"),
                   let eq = out[r.upperBound...].firstIndex(of: "=") {
                    let parts = out[out.index(after: eq)...].split(separator: "/")
                    if parts.count >= 2 {
                        avg = Double(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }
            } catch {
                avg = nil
            }

            DispatchQueue.main.async {
                if let ms = avg {
                    self.rttValue.stringValue = String(format: "%.1f ms", ms)
                    self.rttValue.textColor = ms < 30 ? C_GREEN : (ms < 80 ? C_YELLOW : C_RED)
                    self.rttHint.stringValue = "往返/2 ≈ 单向"
                    self.rttHint.textColor = C_DIM
                } else {
                    self.rttValue.stringValue = "不可达"
                    self.rttValue.textColor = C_RED
                    self.rttHint.stringValue = "手机不在线或 ICMP 被拦"
                    self.rttHint.textColor = C_DIM
                }
            }
        }
    }

    /// 传输中禁用参数下拉（改动需重新 START 才生效）
    func setSettingsEnabled(_ on: Bool) {
        bufferPopup.isEnabled = on
        bitratePopup.isEnabled = on
        codecPopup.isEnabled = on
    }

    @objc func actionTapped() {
        if let p = process, p.isRunning {
            stopStream()
        } else {
            startStream()
        }
    }

    func startStream() {
        if process != nil { return }

        guard let dir = scrcpyDir else {
            let alert = NSAlert()
            alert.messageText = "未找到 scrcpy"
            alert.informativeText = "请把 scrcpy 放在 ~/scrcpy/scrcpy-macos-aarch64-v5.0.1，或放进 App 的 Contents/Resources/scrcpy。"
            alert.runModal()
            return
        }

        actionButton.isEnabled = false
        actionButton.title = "… CONNECTING"
        statusValue.stringValue = "CONNECTING…"
        statusValue.textColor = C_YELLOW

        DispatchQueue.global().async {
            var dev = self.findDevice()
            if dev == nil, !lastIP.isEmpty {
                _ = self.runADB(["connect", "\(lastIP):5555"])
                usleep(1_200_000)
                dev = self.findDevice()
            }
            if dev == nil, !lastIP.isEmpty {
                _ = self.runADB(["kill-server"])
                usleep(500_000)
                _ = self.runADB(["start-server"])
                usleep(800_000)
                _ = self.runADB(["connect", "\(lastIP):5555"])
                usleep(1_500_000)
                dev = self.findDevice()
            }
            guard let device = dev else {
                DispatchQueue.main.async {
                    if lastIP.isEmpty {
                        self.askForPhoneIP()
                    } else {
                        self.statusValue.stringValue = "NO DEVICE"
                        self.statusValue.textColor = C_RED
                        self.deviceValue.stringValue = "未找到手机"
                        self.transportValue.stringValue = "检查 Wi-Fi / 无线调试"
                        self.actionButton.title = "▶  START BRIDGE"
                        self.actionButton.isEnabled = true
                    }
                }
                return
            }

            let isWireless = device.contains(":")
            if isWireless { lastIP = String(device.split(separator: ":")[0]) }
            DispatchQueue.main.async {
                self.deviceValue.stringValue = device
                self.transportValue.stringValue = isWireless ? "Wi-Fi (adb tcpip)" : "USB (adb)"
                self.statusValue.stringValue = "STARTING…"
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: dir + "/scrcpy")

            // 音频参数：缓冲越大越抗卡顿（延迟也越高）；码率越高越清晰；flac/raw 无损但更吃带宽
            let bufferMs = (self.bufferPopup.titleOfSelectedItem ?? "100 ms").replacingOccurrences(of: " ms", with: "")
            let bitrateK = (self.bitratePopup.titleOfSelectedItem ?? "128K").replacingOccurrences(of: "K", with: "")
            let codec = self.codecPopup.titleOfSelectedItem ?? "opus"
            UserDefaults.standard.set(self.bufferPopup.titleOfSelectedItem, forKey: "audioBuffer")
            UserDefaults.standard.set(self.bitratePopup.titleOfSelectedItem, forKey: "audioBitrate")
            UserDefaults.standard.set(codec, forKey: "audioCodec")

            // --no-window：scrcpy 即使只放音频，也会新建一个以设备名为标题的窗口，这里彻底关掉
            // 码率只对 opus/aac 有效，flac/raw 是无损，scrcpy 不接受 --audio-bit-rate
            var args = ["-s", device, "--no-video", "--no-control", "--no-window",
                        "--audio-buffer=\(bufferMs)", "--audio-codec=\(codec)"]
            if codec == "opus" || codec == "aac" {
                args.append("--audio-bit-rate=\(bitrateK)K")
            }
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: dir)

            // scrcpy 自带一份 adb，会抢 5037 端口导致找不到设备；强制指定用 SDK 里的 adb
            var env = ProcessInfo.processInfo.environment
            env["ADB"] = adbPath
            p.environment = env

            let logURL = URL(fileURLWithPath: "/tmp/phone-audio-scrcpy.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: logURL) {
                try? h.truncate(atOffset: 0)
                self.logHandle = h
                p.standardOutput = h
                p.standardError = h
            } else {
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
            }

            // 清掉上次可能的残留，并记下手机当前音量，停止时好恢复
            self.cleanupPhoneServer()
            self.savedPhoneVolume = self.phoneMediaVolume()

            do {
                try p.run()
            } catch {
                DispatchQueue.main.async {
                    self.statusValue.stringValue = "LAUNCH FAILED"
                    self.statusValue.textColor = C_RED
                    self.actionButton.title = "▶  START BRIDGE"
                    self.actionButton.isEnabled = true
                }
                return
            }
            self.process = p

            DispatchQueue.main.async {
                self.statusValue.stringValue = "STREAMING"
                self.statusValue.textColor = C_GREEN
                self.codecValue.stringValue = codec.uppercased() + " · 48 kHz · 16bit · 立体声（系统固定）"
                self.actionButton.title = "■  STOP BRIDGE"
                self.actionButton.bezelColor = NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.16, alpha: 1)
                self.actionButton.isEnabled = true
                self.setSettingsEnabled(false)
                self.startTime = Date()
                self.startTimers()
                self.refreshVolume()
                self.refreshRTT()
                self.refreshOutputDevice()
            }
        }
    }

    /// 首次使用（没有 USB 设备、也没记过 IP）时，让用户填手机 IP
    func askForPhoneIP() {
        let alert = NSAlert()
        alert.messageText = "请输入手机 IP"
        alert.informativeText = "无线调试需要手机与 Mac 在同一个 Wi-Fi。也可以先用 USB 连接，点 START 直接走 USB。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "192.168.1.20"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)

        let resp = alert.runModal()

        statusValue.stringValue = "IDLE"
        statusValue.textColor = C_DIM
        actionButton.title = "▶  START BRIDGE"
        actionButton.isEnabled = true

        if resp == .alertFirstButtonReturn {
            let ip = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty {
                lastIP = ip
                startStream()
            }
        }
    }

    func startTimers() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard let p = self.process else { return }
            if !p.isRunning { self.resetToIdle() }
        }

        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard let start = self.startTime else { return }
            let sec = Int(Date().timeIntervalSince(start))
            self.uptimeValue.stringValue = String(format: "%02d:%02d", sec / 60, sec % 60)
            // 按 scrcpy 默认音频码率（Opus 128 kbps ≈ 16 KB/s）估算已接收量
            let mb = Double(sec) * 16.0 / 1024.0
            self.dataValue.stringValue = String(format: "%.2f MB", mb)
            if sec % 3 == 0 { self.refreshVolume() }
            if sec % 5 == 0 { self.refreshRTT() }
            if sec % 8 == 0 { self.refreshOutputDevice() }
        }
    }

    func stopStream() {
        guard let p = process else { return }
        statusValue.stringValue = "STOPPING…"
        statusValue.textColor = C_YELLOW
        actionButton.isEnabled = false

        DispatchQueue.global().async {
            p.terminate() // SIGTERM：scrcpy 会自己走清理流程
            var waited = 0
            while p.isRunning && waited < 30 {
                usleep(100_000)
                waited += 1
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }

            // 双保险：清掉设备端 server，手机声音立刻回来
            self.cleanupPhoneServer()
            if let saved = self.savedPhoneVolume, self.phoneMediaVolume() == 0 {
                self.setPhoneMediaVolume(saved)
            }
            self.savedPhoneVolume = nil

            DispatchQueue.main.async { self.resetToIdle() }
        }
    }

    func resetToIdle() {
        pollTimer?.invalidate(); pollTimer = nil
        uiTimer?.invalidate(); uiTimer = nil
        process = nil
        startTime = nil
        statusValue.stringValue = "IDLE"
        statusValue.textColor = C_YELLOW
        uptimeValue.stringValue = "00:00"
        dataValue.stringValue = "0.0 MB"
        actionButton.title = "▶  START BRIDGE"
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.isEnabled = true
        setSettingsEnabled(true)

        // 异常退出兜底：确保手机上不残留采集进程，声音能回来
        if savedPhoneVolume != nil {
            DispatchQueue.global().async {
                self.cleanupPhoneServer()
                self.savedPhoneVolume = nil
            }
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 关窗口即断开：先把设备端清理干净再退出，否则手机会一直没声音
        if let p = process, p.isRunning { p.terminate() }
        cleanupPhoneServer()
        if let saved = savedPhoneVolume, phoneMediaVolume() == 0 {
            setPhoneMediaVolume(saved)
        }
        savedPhoneVolume = nil
        process = nil
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
