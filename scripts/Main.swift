import Cocoa
import CoreAudio
import Network

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

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    var window: NSWindow!

    let deviceValue   = textLabel("—", color: C_MAGENTA, size: 12, bold: true)
    let statusValue   = textLabel("IDLE", color: C_YELLOW, size: 12, bold: true)
    let transportValue = textLabel("手机需与 Mac 同一 Wi-Fi", color: C_DIM, size: 12)
    let codecValue    = textLabel("OPUS · 48 kHz · 16bit · 立体声（系统固定）", color: C_WHITE, size: 12)
    let dataValue     = textLabel("0.0 MB", color: C_BLUE, size: 12, bold: true)
    let uptimeValue   = textLabel("00:00", color: C_WHITE, size: 12)

    let volBar   = textLabel("[░░░░░░░░░░░░░░]", color: C_GREEN, size: 12, bold: true)
    let volValue = textLabel("— %", color: C_GREEN, size: 12, bold: true)
    let outValue = textLabel("检测中…", color: C_WHITE, size: 12)
    let outHint  = textLabel("Mac 音频输出", color: C_DIM, size: 11)
    let rttValue = textLabel("— ms", color: C_BLUE, size: 13, bold: true)
    let rttHint  = textLabel("实测 WiFi 往返耗时", color: C_DIM, size: 11)
    let awdlValue = textLabel("检测中…", color: C_DIM, size: 12)
    let awdlButton: NSButton = {
        let b = NSButton(title: "—", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }()
    var awdlIsUp = true

    let actionButton = NSButton()
    let bufferPopup = NSPopUpButton()
    let bitratePopup = NSPopUpButton()
    let codecPopup = NSPopUpButton()
    let enginePopup = NSPopUpButton()

    var process: Process?
    var coreAudioPlayer: CoreAudioPlayer?
    var sessionActive = false
    var stopping = false
    var sessionID: UInt64 = 0
    var activeEngine = "Native"
    /// 当前传输使用的 adb 序列号（含 ":" 为 Wi-Fi，否则为 USB）；nil 表示未在传输
    var activeDevice: String?
    var uiTimer: Timer?
    var startTime: Date?
    var savedPhoneVolume: Int?
    var logHandle: FileHandle?
    var stopCompletions: [() -> Void] = []

    // MARK: 建窗

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        refreshOutputDevice()
        refreshVolume()
        refreshRTT()
        refreshAWDL()
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
        let rect = NSRect(x: 0, y: 0, width: 660, height: 504)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "TransAudio"
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

        awdlButton.target = self
        awdlButton.action = #selector(awdlClicked)
        let awdlRow = NSStackView(views: [textLabel("AWDL:", color: C_DIM, size: 12), awdlValue, awdlButton])
        awdlRow.orientation = .horizontal
        awdlRow.spacing = 8
        awdlRow.alignment = .centerY

        let rightRows: [NSView] = [
            textLabel("Mac Volume:", color: C_DIM, size: 12),
            volRow,
            textLabel("Output Device:", color: C_DIM, size: 12),
            outValue,
            outHint,
            textLabel("Network Latency:", color: C_DIM, size: 12),
            rttRow,
            awdlRow
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
        // Auto：启动前实测网络抖动，自动选最低可用缓冲（推荐）
        let bufferOptions = ["Auto", "50 ms", "100 ms", "200 ms", "350 ms", "500 ms"]
        let bitrateOptions = ["96K", "128K", "192K", "256K", "320K"]
        let codecOptions = ["opus", "aac", "flac", "raw"]
        let engineOptions = ["Native", "Legacy"]

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
        setupPopup(bufferPopup, bufferOptions, savedIndex("audioBuffer", bufferOptions, fallback: 0))
        setupPopup(bitratePopup, bitrateOptions, savedIndex("audioBitrate", bitrateOptions, fallback: 1))
        setupPopup(codecPopup, codecOptions, savedIndex("audioCodec", codecOptions, fallback: 0))
        setupPopup(enginePopup, engineOptions, savedIndex("audioEngine", engineOptions, fallback: 0))
        codecPopup.target = self
        codecPopup.action = #selector(codecChanged)
        codecChanged()

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
            settingGroup("Codec:", codecPopup),
            settingGroup("Engine:", enginePopup)
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
            panelsRow.heightAnchor.constraint(equalToConstant: 240),

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

    /// 读取 awdl0 接口当前状态并刷新 UI（flags 里含 UP 即运行中）
    func refreshAWDL() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            p.arguments = ["awdl0"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch {}
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var exists = false
            var isUp = false
            if let l = out.range(of: "<"), let r = out.range(of: ">", range: l.upperBound..<out.endIndex) {
                exists = true
                isUp = out[l.upperBound..<r.lowerBound].split(separator: ",").contains("UP")
            }
            DispatchQueue.main.async {
                self.awdlIsUp = isUp
                if !exists {
                    self.awdlValue.stringValue = "不可用"
                    self.awdlValue.textColor = C_DIM
                    self.awdlButton.isEnabled = false
                } else {
                    self.awdlValue.stringValue = isUp ? "运行中（抖动尖峰风险）" : "已关闭 · 低抖动"
                    self.awdlValue.textColor = isUp ? C_YELLOW : C_GREEN
                    self.awdlButton.title = isUp ? "关闭" : "恢复"
                    self.awdlButton.isEnabled = true
                }
            }
        }
    }

    /// AWDL 开关：关闭前确认代价；通过 osascript 管理员授权执行 ifconfig（系统弹密码框）
    @objc func awdlClicked() {
        if awdlIsUp {
            let alert = NSAlert()
            alert.messageText = "关闭 AWDL（AirDrop 无线直连）？"
            alert.informativeText = "关闭可降低 Wi-Fi 延迟尖峰，但「隔空投送 / 接力 / 通用剪贴板」将不可用。\n\n随时可点「恢复」还原；重启 Mac 也会自动恢复。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "关闭 AWDL")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setAWDL(up: !awdlIsUp)
    }

    func setAWDL(up: Bool) {
        awdlButton.isEnabled = false
        awdlValue.stringValue = "处理中…（系统会弹密码框）"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/sbin/ifconfig awdl0 \(up ? "up" : "down")\" with administrator privileges"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch {}
            // 取消授权或密码错误时状态不变，refreshAWDL 会把 UI 刷回真实状态
            DispatchQueue.main.async { self.refreshAWDL() }
        }
    }

    /// 实测 WiFi 往返延迟（ping 手机 IP）
    func refreshRTT() {
        // USB 直连：音频不走网络，ping Wi-Fi IP 没有意义（用户反馈过这个困惑）
        if let dev = activeDevice, !dev.contains(":") {
            rttValue.stringValue = "USB 直连"
            rttValue.textColor = C_GREEN
            rttHint.stringValue = "无网络传输 · 抖动≈0 · 缓冲按最低档 50ms"
            rttHint.textColor = C_DIM
            return
        }
        let ip = activeDevice.flatMap { $0.contains(":") ? String($0.split(separator: ":")[0]) : nil } ?? lastIP
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
            var minRtt: Double?
            var maxRtt: Double?
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let r = out.range(of: "round-trip"),
                   let eq = out[r.upperBound...].firstIndex(of: "=") {
                    let parts = out[out.index(after: eq)...].split(separator: "/")
                    if parts.count >= 3 {
                        minRtt = Double(parts[0].trimmingCharacters(in: .whitespaces))
                        avg = Double(parts[1].trimmingCharacters(in: .whitespaces))
                        maxRtt = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                avg = nil
            }

            DispatchQueue.main.async {
                if let ms = avg {
                    self.rttValue.stringValue = String(format: "%.1f ms", ms)
                    self.rttValue.textColor = ms < 30 ? C_GREEN : (ms < 80 ? C_YELLOW : C_RED)
                    // 抖动 = 最坏 - 最好，直接决定缓冲要多大才不卡；越大网络越不稳
                    if let lo = minRtt, let hi = maxRtt {
                        self.rttHint.stringValue = String(format: "抖动 %.0f ms · 建议缓冲 ≥ %.0f ms", hi - lo, max(100, hi + 20))
                    } else {
                        self.rttHint.stringValue = "往返/2 ≈ 单向"
                    }
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

    /// Auto 缓冲：启动前快速 ping 手机 8 包，按「最坏 RTT + 20ms 余量」选缓冲（Wi-Fi 钳制 100~500ms）。
    /// 缓冲要对抗的是网络抖动，最坏 RTT 就是必须囤住的水位；USB 无网络传输，直接用最小值。
    func measureAutoBuffer(device: String) -> Int {
        guard device.contains(":") else { return 50 }
        let ip = String(device.split(separator: ":")[0])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "8", "-i", "0.2", "-q", ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let r = out.range(of: "round-trip"),
               let eq = out[r.upperBound...].firstIndex(of: "=") {
                let parts = out[out.index(after: eq)...].split(separator: "/")
                if parts.count >= 3,
                   let maxRtt = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    // 实测 RTT 最高 29ms、0% 丢包时，50ms 仍频繁 underflow；
                    // Wi-Fi Auto 至少保留 100ms，手动模式与 USB 的 50ms 不受影响
                    let chosen = min(500, max(100, Int(maxRtt.rounded()) + 20))
                    DispatchQueue.main.async {
                        self.rttHint.stringValue = "Auto 缓冲 → \(chosen) ms（最坏 RTT \(Int(maxRtt)) ms）"
                        self.rttHint.textColor = C_CYAN
                    }
                    return chosen
                }
            }
        } catch {}
        // 测量失败（手机 ICMP 被拦等）→ 取保守中间值
        DispatchQueue.main.async {
            self.rttHint.stringValue = "Auto 测量失败 → 200 ms"
            self.rttHint.textColor = C_YELLOW
        }
        return 200
    }

    /// 传输中禁用参数下拉（改动需重新 START 才生效）
    func setSettingsEnabled(_ on: Bool) {
        bufferPopup.isEnabled = on
        codecPopup.isEnabled = on
        enginePopup.isEnabled = on
        if on { codecChanged() } else { bitratePopup.isEnabled = false }
    }

    /// 无损编码（raw/flac）的码率由 48kHz×16bit×2 声道决定，不可调：
    /// Bitrate 下拉此时只显示固定值并禁用；切回有损编码时恢复完整列表
    @objc func codecChanged() {
        let codec = codecPopup.titleOfSelectedItem ?? "opus"
        let losslessFixed: [String: String] = ["raw": "1536K", "flac": "≈800K"]
        if let fixed = losslessFixed[codec] {
            bitratePopup.removeAllItems()
            bitratePopup.addItem(withTitle: fixed)
            bitratePopup.selectItem(at: 0)
            bitratePopup.isEnabled = false
        } else if bitratePopup.numberOfItems <= 1 {
            let opts = ["96K", "128K", "192K", "256K", "320K"]
            let saved = UserDefaults.standard.string(forKey: "audioBitrate") ?? "192K"
            bitratePopup.removeAllItems()
            bitratePopup.addItems(withTitles: opts)
            bitratePopup.selectItem(at: opts.firstIndex(of: saved) ?? 2)
            bitratePopup.isEnabled = true
        }
        codecValue.stringValue = codec.uppercased() + " · 48 kHz · 16bit · 立体声（系统固定）"
    }

    @objc func actionTapped() {
        if sessionActive {
            stopStream()
        } else {
            startStream()
        }
    }

    private func isCurrentSession(_ id: UInt64) -> Bool {
        sessionID == id && sessionActive
    }

    func startStream() {
        guard !sessionActive, process == nil, coreAudioPlayer == nil else { return }
        guard let dir = scrcpyDir else {
            let alert = NSAlert()
            alert.messageText = "未找到 scrcpy"
            alert.informativeText = "请把 scrcpy 放在 ~/scrcpy/scrcpy-macos-aarch64-v5.0.1，或放进 App 的 Contents/Resources/scrcpy。"
            alert.runModal()
            return
        }

        let engine = enginePopup.titleOfSelectedItem ?? "Native"
        let executable = dir + (engine == "Native" ? "/scrcpy-coreaudio" : "/scrcpy")
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            let alert = NSAlert()
            alert.messageText = "未找到 \(engine) 客户端"
            alert.informativeText = engine == "Native"
                ? "请先运行 scripts/build-scrcpy-coreaudio.sh，或明确选择 Legacy。"
                : "请恢复官方 scrcpy 5.0.1 客户端。"
            alert.runModal()
            return
        }

        let bufferChoice = bufferPopup.titleOfSelectedItem ?? "Auto"
        let bitrateK = (bitratePopup.titleOfSelectedItem ?? "128K").replacingOccurrences(of: "K", with: "")
        let codec = codecPopup.titleOfSelectedItem ?? "opus"
        UserDefaults.standard.set(bufferChoice.hasPrefix("Auto") ? "Auto" : bufferChoice, forKey: "audioBuffer")
        if bitratePopup.isEnabled {
            UserDefaults.standard.set(bitratePopup.titleOfSelectedItem, forKey: "audioBitrate")
        }
        UserDefaults.standard.set(codec, forKey: "audioCodec")
        UserDefaults.standard.set(engine, forKey: "audioEngine")

        sessionID += 1
        let id = sessionID
        sessionActive = true
        stopping = false
        activeEngine = engine
        actionButton.isEnabled = false
        actionButton.title = "… CONNECTING"
        statusValue.stringValue = "CONNECTING…"
        statusValue.textColor = C_YELLOW

        DispatchQueue.global().async { [self] in
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
                let (hint, steps) = lastIP.isEmpty ? ("", "") : self.diagnoseConnection(ip: lastIP)
                DispatchQueue.main.async {
                    guard self.isCurrentSession(id) else { return }
                    self.stopStream {
                        if lastIP.isEmpty {
                            self.askForPhoneIP()
                        } else {
                            self.statusValue.stringValue = "NO DEVICE"
                            self.statusValue.textColor = C_RED
                            self.deviceValue.stringValue = hint
                            self.transportValue.stringValue = "详见弹窗排查步骤"
                            self.showConnectionFailureAlert(hint: hint, steps: steps, ip: lastIP)
                        }
                    }
                }
                return
            }
            guard self.isCurrentSession(id), !self.stopping else { return }

            let isWireless = device.contains(":")
            if isWireless { lastIP = String(device.split(separator: ":")[0]) }
            self.activeDevice = device
            DispatchQueue.main.async {
                guard self.isCurrentSession(id) else { return }
                self.deviceValue.stringValue = device
                self.transportValue.stringValue = isWireless ? "Wi-Fi (adb tcpip)" : "USB (adb)"
                self.statusValue.stringValue = "STARTING…"
            }

            let bufferMs: Int
            if bufferChoice.hasPrefix("Auto") {
                DispatchQueue.main.async {
                    guard self.isCurrentSession(id), !self.stopping else { return }
                    self.statusValue.stringValue = "MEASURING…"
                }
                bufferMs = self.measureAutoBuffer(device: device)
            } else {
                bufferMs = Int(bufferChoice.replacingOccurrences(of: " ms", with: "")) ?? 100
            }

            var args = ["-s", device, "--no-video", "--no-control", "--no-window",
                        "--audio-source=playback", "--audio-codec=\(codec)"]
            if engine == "Legacy" {
                args.append(contentsOf: ["--audio-buffer=\(bufferMs)", "--audio-output-buffer=10"])
            }
            if codec == "opus" || codec == "aac" {
                args.append("--audio-bit-rate=\(bitrateK)K")
            }

            var env = ProcessInfo.processInfo.environment
            env["ADB"] = adbPath
            env.removeValue(forKey: "ITRAE_PCM_SOCKET")

            guard self.isCurrentSession(id), !self.stopping else { return }
            self.cleanupPhoneServer()
            self.savedPhoneVolume = self.phoneMediaVolume()

            if engine == "Native" {
                var nativeSocket: String?
                var nativeStartError: Error?
                // 播放器和会话属性在主线程同一临界段内设置，Stop 不会漏掉启动中的 player。
                DispatchQueue.main.sync {
                    guard self.isCurrentSession(id), !self.stopping else { return }
                    do {
                        let player = try CoreAudioPlayer(targetBufferMs: bufferMs,
                                                         autoBuffer: bufferChoice.hasPrefix("Auto"))
                        player.onFirstPCM = { [weak self] in
                            self?.markStreaming(session: id, engine: engine, codec: codec)
                        }
                        player.onFailure = { [weak self] message in
                            self?.failSession(message, session: id)
                        }
                        player.onTargetBufferChange = { [weak self] target in
                            guard let self, self.isCurrentSession(id) else { return }
                            self.updateAutoBufferDisplay(target)
                            self.rttHint.stringValue = "Native Auto 缓冲已调整至 \(target) ms"
                        }
                        nativeSocket = try player.start()
                        self.coreAudioPlayer = player
                    } catch {
                        nativeStartError = error
                    }
                }
                guard self.isCurrentSession(id), !self.stopping else { return }
                if let nativeStartError {
                    DispatchQueue.main.async {
                        self.failSession(nativeStartError.localizedDescription, session: id)
                    }
                    return
                }
                env["ITRAE_PCM_SOCKET"] = nativeSocket
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            p.environment = env
            p.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.isCurrentSession(id), !self.stopping else { return }
                    self.failSession("scrcpy 已退出（状态码 \(process.terminationStatus)）", session: id)
                }
            }

            var launchError: Error?
            // run() 与 process 赋值不可被 Stop 插入，避免遗留未被管理的 client。
            DispatchQueue.main.sync {
                guard self.isCurrentSession(id), !self.stopping else { return }
                if env["ITRAE_AUDIO_DEBUG"] == "1" {
                    args.append("--verbosity=verbose")
                    let logURL = URL(fileURLWithPath: "/tmp/phone-audio-scrcpy.log")
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        try? handle.truncate(atOffset: 0)
                        self.logHandle = handle
                        p.standardOutput = handle
                        p.standardError = handle
                    }
                }
                if self.logHandle == nil {
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                }
                p.arguments = args
                do {
                    try p.run()
                    self.process = p
                } catch {
                    launchError = error
                }
            }
            guard self.isCurrentSession(id), !self.stopping else { return }
            if let launchError {
                DispatchQueue.main.async {
                    self.failSession("启动 scrcpy 失败：\(launchError.localizedDescription)", session: id)
                }
                return
            }

            DispatchQueue.main.async {
                guard self.isCurrentSession(id), !self.stopping else { return }
                self.actionButton.title = "■  STOP BRIDGE"
                self.actionButton.bezelColor = NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.16, alpha: 1)
                self.actionButton.isEnabled = true
                self.setSettingsEnabled(false)
                self.updateAutoBufferDisplay(bufferMs)
                if engine == "Legacy" {
                    self.markStreaming(session: id, engine: engine, codec: codec)
                } else {
                    self.statusValue.stringValue = "WAITING PCM…"
                    self.statusValue.textColor = C_YELLOW
                    self.codecValue.stringValue = codec.uppercased() + " · Native CoreAudio"
                }
            }
        }
    }

    private func markStreaming(session id: UInt64, engine: String, codec: String) {
        guard isCurrentSession(id), !stopping, startTime == nil else { return }
        statusValue.stringValue = "STREAMING · \(engine.uppercased())"
        statusValue.textColor = C_GREEN
        codecValue.stringValue = engine == "Native"
            ? codec.uppercased() + " · 48 kHz · Float32 · 立体声"
            : codec.uppercased() + " · 48 kHz · 16bit · 立体声（Legacy）"
        actionButton.title = "■  STOP BRIDGE"
        actionButton.bezelColor = NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.16, alpha: 1)
        actionButton.isEnabled = true
        setSettingsEnabled(false)
        startTime = Date()
        startTimers()
        refreshVolume()
        refreshRTT()
        refreshOutputDevice()
    }

    private func updateAutoBufferDisplay(_ target: Int) {
        guard bufferPopup.titleOfSelectedItem?.hasPrefix("Auto") == true else { return }
        // 菜单项保留完整说明，收起时只显示 Auto，避免窄下拉截断成「Auto ·…」
        bufferPopup.item(at: 0)?.title = "Auto · \(target) ms"
        bufferPopup.title = "Auto"
    }

    private func failSession(_ message: String, session id: UInt64) {
        guard isCurrentSession(id), !stopping else { return }
        stopStream {
            self.statusValue.stringValue = "ERROR"
            self.statusValue.textColor = C_RED
            let alert = NSAlert()
            alert.messageText = "音频会话已停止"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// 连不上手机时自动诊断，返回（一句话原因，排查步骤）。
    /// 先 ping：不通说明手机根本不在局域网；通但 5555 关说明手机重启过、adb tcpip 已失效。
    func diagnoseConnection(ip: String) -> (String, String) {
        if !pingReachable(ip) {
            return ("手机不在局域网",
                    "手机可能没连 Wi-Fi、换了网络，或 IP 已变化。\n\n" +
                    "排查：\n" +
                    "1. 手机「设置 → WLAN」确认已连接，且和 Mac 是同一个 Wi-Fi\n" +
                    "2. 查看手机当前 IP，可能已不是 \(ip)（DHCP 重启后可能换 IP）\n" +
                    "3. 确认路由器没有开「AP 隔离/客户端隔离」")
        }
        if !tcpReachable(ip, port: 5555, timeout: 2) {
            return ("无线调试已关闭（手机可能重启过）",
                    "adb tcpip 模式在手机重启后自动失效，这是正常现象。\n\n" +
                    "恢复方法（任选其一）：\n" +
                    "1. 用 USB 线把手机连上 Mac，App 会自动检测到并恢复\n" +
                    "2. 或在手机「开发者选项」里重新打开「无线调试」")
        }
        return ("手机在线但 adb 无法连接",
                "手机和端口都正常，但 adb 握手失败。\n\n" +
                "排查：\n" +
                "1. 再点一次 START BRIDGE 重试（Mac 的 adb 服务偶尔卡死，App 已自动重启过它）\n" +
                "2. 手机「开发者选项」里重新开关一次「USB 调试」\n" +
                "3. 若手机弹过「是否允许这台电脑调试」，勾选一律允许并确认")
    }

    /// ping 一次判断是否可达（2 个包，任意一个回包即算通）
    func pingReachable(_ ip: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "2", "-W", "1000", "-q", ip]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// TCP 端口探测（NWConnection 同步化，最多等 timeout 秒）
    func tcpReachable(_ host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        guard let ep = NWEndpoint.Port(rawValue: port) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let conn = NWConnection(host: NWEndpoint.Host(host), port: ep, using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        return ok
    }

    /// 连接失败弹窗：给出诊断结果与排查步骤，并允许直接重填 IP
    func showConnectionFailureAlert(hint: String, steps: String, ip: String) {
        let alert = NSAlert()
        alert.messageText = "连不上手机（\(ip)）"
        alert.informativeText = steps
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "重新输入手机 IP")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            self.askForPhoneIP()
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
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            let sec = Int(Date().timeIntervalSince(start))
            self.uptimeValue.stringValue = String(format: "%02d:%02d", sec / 60, sec % 60)
            if self.activeEngine == "Native" {
                let bytes = self.coreAudioPlayer?.snapshot().receivedPCMBytes ?? 0
                self.dataValue.stringValue = String(format: "PCM %.2f MB", Double(bytes) / 1_048_576.0)
            } else {
                // Legacy 没有 PCM 回传，只保留原官方路径的时间估算值。
                self.dataValue.stringValue = String(format: "≈ %.2f MB", Double(sec) * 16.0 / 1024.0)
            }
            if sec % 3 == 0 { self.refreshVolume() }
            if sec % 5 == 0 { self.refreshRTT() }
            if sec % 8 == 0 { self.refreshOutputDevice() }
        }
    }

    /// 所有退出路径共用：先停 Native 播放和 socket，再停 client、手机 server 与日志。
    func stopStream(completion: @escaping () -> Void = {}) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopStream(completion: completion) }
            return
        }
        if stopping {
            stopCompletions.append(completion)
            return
        }
        guard sessionActive || process != nil || coreAudioPlayer != nil else {
            completion()
            return
        }

        stopping = true
        stopCompletions.append(completion)
        statusValue.stringValue = "STOPPING…"
        statusValue.textColor = C_YELLOW
        actionButton.isEnabled = false
        uiTimer?.invalidate()
        uiTimer = nil

        let client = process
        let player = coreAudioPlayer
        let log = logHandle
        logHandle = nil

        let stopClientAndSession = {
            DispatchQueue.global().async {
                if let client, client.isRunning {
                    client.terminate()
                    var waited = 0
                    while client.isRunning && waited < 30 {
                        usleep(100_000)
                        waited += 1
                    }
                    if client.isRunning {
                        kill(client.processIdentifier, SIGKILL)
                    }
                }
                try? log?.close()

                self.cleanupPhoneServer()
                if let saved = self.savedPhoneVolume, self.phoneMediaVolume() == 0 {
                    self.setPhoneMediaVolume(saved)
                }
                self.savedPhoneVolume = nil

                DispatchQueue.main.async {
                    self.resetToIdle()
                    let completions = self.stopCompletions
                    self.stopCompletions.removeAll()
                    completions.forEach { $0() }
                }
            }
        }

        if let player {
            player.stop(completion: stopClientAndSession)
        } else {
            stopClientAndSession()
        }
    }

    func resetToIdle() {
        uiTimer?.invalidate()
        uiTimer = nil
        sessionActive = false
        stopping = false
        process = nil
        coreAudioPlayer = nil
        startTime = nil
        activeDevice = nil
        statusValue.stringValue = "IDLE"
        statusValue.textColor = C_YELLOW
        transportValue.stringValue = "手机需与 Mac 同一 Wi-Fi"
        transportValue.textColor = C_DIM
        uptimeValue.stringValue = "00:00"
        dataValue.stringValue = "0.0 MB"
        actionButton.title = "▶  START BRIDGE"
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.isEnabled = true
        setSettingsEnabled(true)
        // 会话结束后 Auto 档恢复简短显示，实际目标值仍在下次 Start 时写入
        bufferPopup.item(at: 0)?.title = "Auto"
        bufferPopup.title = "Auto"
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if sessionActive || process != nil || coreAudioPlayer != nil {
            stopStream { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }
}
