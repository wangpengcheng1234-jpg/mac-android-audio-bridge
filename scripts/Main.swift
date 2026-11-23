import Cocoa
import CoreAudio
import Network
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

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

class PanelView: NSView {
    var title: String = ""
    var borderColor: NSColor = C_BORDER
    /// 标题右侧的延伸分隔线。标题同一行右侧放有文字（如设备条的状态提示）时必须关闭，
    /// 否则这条线会正好从文字中间穿过。
    var showsTitleRule: Bool = true

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

            if showsTitleRule {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 12 + size.width + 8, y: bounds.height - 14))
                line.line(to: NSPoint(x: bounds.width - 12, y: bounds.height - 14))
                borderColor.withAlphaComponent(0.45).setStroke()
                line.lineWidth = 1
                line.stroke()
            }
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
    /// 手机媒体音量（跟随用），与 Mac 音量独立
    let phoneVolValue = textLabel("手机 —", color: C_DIM, size: 10)
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
    /// 免密码授权只需安装一次，之后切换不再弹系统密码框
    private var awdlAuthorizationCache: Bool?

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
    /// 自动重连：当前会话已自动恢复次数 / 是否正在恢复（恢复期间不弹窗、不展开设备条）
    var autoRecoverAttempts = 0
    var isAutoRecovering = false
    /// 断联且找不到设备时进入的「暂停等待」态：不弹模态窗，主按钮变为「重试」
    var isPausedOffline = false
    /// 手机音量跟随
    var phoneVolTimer: Timer?
    /// 音量推送通道：server 端 VolumeWatcher 经 abstract socket 推送，桌面端 adb forward 接入。
    /// 正常路径零 adb 调用；仅在推送未就绪时才回退到 phoneVolTimer 轮询。
    var volumeWatchPort = -1
    var volumeWatchActive = false
    var volumeWatchFallbackTimer: Timer?
    var volumeQueryInFlight = false
    /// 连续读不到手机音量时的计数：用于兜底恢复满增益，避免默认增益 0 导致永久无声
    var volumeQueryFailures = 0
    /// 心跳（与 RTT 探测共用 5 秒节拍）
    var heartbeatInFlight = false
    var heartbeatFailures = 0
    var lastHeartbeatMs = 0
    /// 音频流探针：上一次观测到的 PCM 字节数 / 时间 / 最近一次 adb RTT 采样
    var lastPCMBytes: UInt64 = 0
    var lastPCMAt = Date.distantPast
    var lastRTTSampleAt = Date.distantPast
    var stopCompletions: [() -> Void] = []
    var onboardingController: OnboardingWindowController?

    // 设备选择条
    let deviceStrip = DeviceStripView(title: " 选择设备 ")
    var deviceStripHeight: NSLayoutConstraint?
    /// 设备条展开 / 收起时的窗口高度
    let windowExpandedHeight: CGFloat = 618
    let windowCollapsedHeight: CGFloat = 526
    let stripExpandedHeight: CGFloat = 92
    var isDeviceStripVisible = true
    /// 本次选中的设备（用于自动连接）
    var pendingDevice: FoundDevice?
    /// 自动刷新设备列表（插拔 USB / 手机开热点后无需手动点重新扫描）
    var deviceRefreshTimer: Timer?
    var isDiscovering = false
    var lastDeepScan = Date.distantPast
    /// 最近一次看到某设备的时间，用于让卡片短暂“粘住”，避免扫描抖动导致闪烁
    var lastSeenDevices: [String: (device: FoundDevice, time: Date)] = [:]
    /// 每个 USB 序列号上次尝试开通无线调试的时间（限制重试频率）
    var wirelessAttemptAt: [String: Date] = [:]
    /// 由 App 托管的 adb server（nodaemon 模式，保证拥有本地网络权限）
    var adbServerProcess: Process?
    let adbServerLock = NSLock()
    /// 无线连接因缺少“本地网络”权限失败（No route to host）
    var lastConnectNoRoute = false
    /// App 正在退出（退出时不再展开设备条/做动画）
    var isTerminating = false
    /// 充电+桥接时阻止空闲休眠的 IOPM 断言 ID（0 表示无断言）
    private var noSleepAssertionID: IOPMAssertionID = 0
    /// 电源状态变化监听
    private var powerSourceObserver: NSObjectProtocol?

    // MARK: 建窗

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 最先安装崩溃日志处理器（预打开崩溃文件 fd，保证崩溃时能写出调用栈）
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        CrashLogger.install(version: ver)

        buildMenu()
        buildWindow()
        refreshOutputDevice()
        refreshVolume()
        refreshRTT()
        refreshAWDL()
        // 先由 App 托管 adb server（nodaemon），否则无线连接会因权限问题失败
        DispatchQueue.global().async { self.ensureADBServer() }

        // 上一次若异常退出，手机上可能留着 scrcpy 采集进程（会让手机一直没声音），启动时先清掉
        DispatchQueue.global().async { self.cleanupPhoneServer() }

        // 充电时不休眠：监听电源状态变化
        self.startPowerSourceMonitoring()

        // 首次启动显示新手引导（延迟到下一个 runloop，确保 App 已完全激活、主窗口就绪）
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if noSleepAssertionID != 0 {
            IOPMAssertionRelease(noSleepAssertionID)
            noSleepAssertionID = 0
        }
        adbServerProcess?.terminate()
    }

    /// 构建菜单栏（含「帮助 → 新手引导」入口）
    func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 TransAudio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 TransAudio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "新手引导", action: #selector(showOnboarding), keyEquivalent: "?")
        helpMenu.addItem(withTitle: "查看 GitHub", action: #selector(openGitHub), keyEquivalent: "")
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(withTitle: "崩溃日志分析…", action: #selector(showCrashAnalysis), keyEquivalent: "")
    }

    @objc func showOnboarding() {
        let controller = OnboardingWindowController { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        onboardingController = controller
        // 模态运行：独占事件焦点，直到引导完成
        controller.runModal()
        onboardingController = nil
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/wangpengcheng1234-jpg/mac-android-audio-bridge") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 崩溃日志分析窗口

    @objc func showCrashAnalysis() {
        let analysis = CrashLogger.analyze()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "崩溃日志分析"
        win.center()

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = C_BG.cgColor

        // 汇总标签
        let summary = textLabel(
            analysis.total == 0
                ? "✓ 暂无崩溃记录"
                : "共 \(analysis.total) 次崩溃，归为 \(analysis.groups.count) 类",
            color: analysis.total == 0 ? C_GREEN : C_YELLOW, size: 13, bold: true)
        summary.translatesAutoresizingMaskIntoConstraints = false

        // 详情文本
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = mono(11)
        tv.textColor = C_WHITE
        tv.backgroundColor = .clear
        tv.string = formatCrashAnalysis(analysis)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tv
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 按钮
        let revealBtn = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
        revealBtn.bezelStyle = .rounded
        revealBtn.target = self
        revealBtn.action = #selector(revealCrashLogs)
        let clearBtn = NSButton(title: "清空全部", target: nil, action: nil)
        clearBtn.bezelStyle = .rounded
        clearBtn.target = self
        clearBtn.action = #selector(clearCrashLogs)
        let btnRow = NSStackView(views: [revealBtn, clearBtn, NSView()])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(summary)
        root.addSubview(scroll)
        root.addSubview(btnRow)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            btnRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            btnRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            btnRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            btnRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            btnRow.heightAnchor.constraint(equalToConstant: 28),
        ])

        win.contentView = root
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func formatCrashAnalysis(_ a: CrashAnalysis) -> String {
        guard a.total > 0 else { return "暂无崩溃记录。" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = ""
        for (i, g) in a.groups.enumerated() {
            out += "[\(i + 1)] \(g.key)\n"
            out += "    次数: \(g.count)   最近: \(fmt.string(from: g.latest))   版本: \(g.sample.version)\n"
            out += "    调用栈:\n"
            for (j, sym) in g.sample.symbols.prefix(12).enumerated() {
                out += "      \(j). \(sym)\n"
            }
            out += "\n"
        }
        return out
    }

    @objc func revealCrashLogs() {
        CrashLogger.revealInFinder()
    }

    @objc func clearCrashLogs() {
        let alert = NSAlert()
        alert.messageText = "确认清空全部崩溃日志？"
        alert.informativeText = "此操作不可撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            CrashLogger.clearAll()
        }
    }

    // MARK: 充电时不休眠（IOPMAssertion + IOPS）

    /// 是否处于交流电（充电）状态
    private func isOnACPower() -> Bool {
        // IOPS 的 Copy 函数返回 +1 的 CF 对象。
        // 若用 takeRetainedValue + 桥接到 Swift Array/Dictionary，
        // 桥接会 retain 元素，而 CF 对象释放时也会 release 元素 → 过度释放崩溃。
        // 改用 takeUnretainedValue（不转移所有权，+1 交给 autorelease pool 平衡）。
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeUnretainedValue() as? [Any] else { return false }
        for ps in list {
            let psRef = ps as CFTypeRef
            if let desc = IOPSGetPowerSourceDescription(info, psRef)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                if state == kIOPSACPowerValue as String { return true }
            }
        }
        return false
    }

    /// 充电中 + 音频桥接运行中 + 用户开启 → 阻止系统空闲休眠；否则释放断言
    private func updateSleepAssertion() {
        let enabled = UserDefaults.standard.bool(forKey: "noSleepWhenCharging")
        let shouldHold = enabled && sessionActive && isOnACPower()

        if shouldHold, noSleepAssertionID == 0 {
            let reason = "TransAudio 音频桥接中（充电时不休眠）" as CFString
            let ret = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &noSleepAssertionID)
            if ret == kIOReturnSuccess {
                appendDiagnostic("已阻止空闲休眠（充电 + 桥接中）")
            } else {
                noSleepAssertionID = 0
            }
        } else if !shouldHold, noSleepAssertionID != 0 {
            IOPMAssertionRelease(noSleepAssertionID)
            noSleepAssertionID = 0
            appendDiagnostic("已解除空闲休眠阻止")
        }
    }

    /// 监听电源状态变化（插/拔电源），实时更新断言
    private func startPowerSourceMonitoring() {
        let center = NotificationCenter.default
        powerSourceObserver = center.addObserver(
            forName: NSNotification.Name(kIOPSTimeRemainingNotificationKey as String),
            object: nil, queue: .main) { [weak self] _ in
            self?.updateSleepAssertion()
        }
    }

    func panelContent(_ rows: [NSView]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        return stack
    }

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 660, height: 618)
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
        // 限制 value 标签的水平压缩阻力：文本过长时截断（…）而非撑大窗口
        for v in [deviceValue, statusValue, transportValue, codecValue, uptimeValue, dataValue] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
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
        let volRow = NSStackView(views: [volBar, volValue, phoneVolValue])
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

        // —— 充电时不休眠（仅在桥接运行中生效）
        let noSleepBtn = NSButton(checkboxWithTitle: "充电中桥接时阻止 Mac 休眠", target: self, action: #selector(noSleepToggled))
        noSleepBtn.font = .systemFont(ofSize: 11)
        noSleepBtn.contentTintColor = C_DIM
        noSleepBtn.state = UserDefaults.standard.bool(forKey: "noSleepWhenCharging") ? .on : .off
        noSleepBtn.translatesAutoresizingMaskIntoConstraints = false

        // —— 设备选择条
        deviceStrip.translatesAutoresizingMaskIntoConstraints = false
        deviceStrip.onSelect = { [weak self] dev in self?.handleDeviceSelect(dev) }
        deviceStrip.onManualConnect = { [weak self] ip in self?.handleManualIP(ip) }
        deviceStrip.onRescan = { [weak self] in self?.refreshDeviceList() }

        // —— 主按钮（空闲时禁用，由设备条选中后自动连接）
        actionButton.title = "请先在上方选择设备"
        actionButton.bezelStyle = .rounded
        actionButton.font = mono(13, .bold)
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.contentTintColor = .white
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.heightAnchor.constraint(equalToConstant: 38).isActive = true
        actionButton.isEnabled = false

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
        root.addSubview(noSleepBtn)
        root.addSubview(deviceStrip)
        root.addSubview(actionButton)
        root.addSubview(footer)

        let stripHeight = deviceStrip.heightAnchor.constraint(equalToConstant: stripExpandedHeight)
        stripHeight.isActive = true
        deviceStripHeight = stripHeight

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

            noSleepBtn.topAnchor.constraint(equalTo: settingsRow.bottomAnchor, constant: 8),
            noSleepBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            noSleepBtn.heightAnchor.constraint(equalToConstant: 18),

            deviceStrip.topAnchor.constraint(equalTo: noSleepBtn.bottomAnchor, constant: 8),
            deviceStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            deviceStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            actionButton.topAnchor.constraint(equalTo: deviceStrip.bottomAnchor, constant: 0),
            actionButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            actionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            footer.topAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 首次扫描设备，并开启自动刷新（插拔 USB / 开热点无需手动点）
        refreshDeviceList()
        startDeviceAutoRefresh()
    }

    // MARK: 数据刷新

    /// macOS 上 adb 守护进程（fork-server）会被系统判定为“无本地网络权限”，
    /// 导致 adb connect 一律返回 No route to host。这里改成由本 App 托管
    /// `adb -L tcp:5037 nodaemon server` 子进程，权限随 App 一起生效。
    private func ensureADBServer() {
        adbServerLock.lock()
        defer { adbServerLock.unlock() }
        if let p = adbServerProcess, p.isRunning { return }

        // 先关掉可能存在的守护进程，否则 5037 被占用，nodaemon 起不来
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: adbPath)
        kill.arguments = ["kill-server"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        if (try? kill.run()) != nil { kill.waitUntilExit() }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: adbPath)
        server.arguments = ["-L", "tcp:5037", "nodaemon", "server"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        guard (try? server.run()) != nil else { return }
        adbServerProcess = server

        // 等 5037 端口就绪，最多 2 秒
        for _ in 0..<40 {
            if tcpReachable("127.0.0.1", port: 5037, timeout: 0.1) { break }
            usleep(50_000)
        }
    }

    private func runADB(_ args: [String], timeout: TimeInterval = 8) -> String {
        ensureADBServer()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        // adb 对不可达地址可能长时间不返回，超过时限直接终止，避免整个扫描卡死
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            usleep(150_000)
        }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8) ?? ""
    }

    private func findDevice() -> String? {
        adbDeviceSerials().first
    }

    /// 列出 adb devices 中状态为 device 的所有序列号
    private func adbDeviceSerials() -> [String] {
        adbDeviceStates().filter { $0.state == "device" }.map { $0.serial }
    }

    /// 列出 adb devices 的全部条目与状态（device / unauthorized / offline）
    private func adbDeviceStates() -> [(serial: String, state: String)] {
        let out = runADB(["devices"], timeout: 5)
        var list: [(serial: String, state: String)] = []
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2 {
                list.append((String(parts[0]), String(parts[1])))
            }
        }
        return list
    }

    /// 读取手机自身的 Wi-Fi IP：USB 连着时直接问手机，比扫描局域网可靠得多
    private func phoneWlanIP(serial: String) -> String? {
        let route = runADB(["-s", serial, "shell", "ip", "route"], timeout: 5)
        for line in route.split(separator: "\n") where line.contains("wlan0") {
            if let range = line.range(of: "src \\d+\\.\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
                return String(line[range]).replacingOccurrences(of: "src ", with: "")
            }
        }
        let addr = runADB(["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"], timeout: 5)
        if let range = addr.range(of: "inet \\d+\\.\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
            return String(addr[range]).replacingOccurrences(of: "inet ", with: "")
        }
        return nil
    }

    /// USB 在线时自动执行 adb tcpip 5555 并 connect，返回手机 Wi-Fi IP。
    /// 手机重启后 adb tcpip 会失效，这一步就是“插过 USB 点一下就能无线”的关键。
    @discardableResult
    private func enableWirelessOverUSB(usbSerial: String) -> String? {
        guard let ip = phoneWlanIP(serial: usbSerial) else { return nil }
        let target = "\(ip):5555"
        if adbDeviceSerials().contains(target) { return ip }

        _ = runADB(["-s", usbSerial, "tcpip", "5555"], timeout: 6)
        // adbd 切到 TCP 模式会重启并短暂掉线。原先固定等 1.5 s 经常不够，
        // 首次 connect 直接被拒（Connection refused），于是无线桥接永远开不起来。
        // 改为轮询：每 0.8 s 试一次，最多约 8 秒，一旦连上立即返回。
        for _ in 0..<10 {
            usleep(800_000)
            if adbDeviceSerials().contains(target) { return ip }
            _ = runADB(["connect", target], timeout: 4)
        }
        return nil
    }

    /// mDNS 发现：Android 11+ 的无线调试会广播 _adb-tls-connect._tcp。
    /// 返回 "ip:端口" 形式（无线调试端口是随机的，不能假定 5555）。
    private func mdnsWirelessSerials() -> [String] {
        let out = runADB(["mdns", "services"], timeout: 3)
        var serials: [String] = []
        for line in out.split(separator: "\n") where line.contains("_adb") {
            if let range = line.range(of: "\\d+\\.\\d+\\.\\d+\\.\\d+:\\d+", options: .regularExpression) {
                let serial = String(line[range])
                if !serials.contains(serial) { serials.append(serial) }
            } else if let range = line.range(of: "\\d+\\.\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
                let serial = String(line[range]) + ":5555"
                if !serials.contains(serial) { serials.append(serial) }
            }
        }
        return serials
    }

    /// 局域网 5555 端口的候选地址：网关 + 常见热点段 + 本机所在 /24 全段
    private func wirelessScanCandidates() -> [String] {
        var candidates = Set<String>()
        let local = currentWiFiIP()
        if let gw = defaultGateway() { candidates.insert(gw) }
        ["192.168.43.1", "192.168.1.1", "192.168.0.1",
         "172.20.10.1", "192.168.137.1", "192.168.100.1"].forEach { candidates.insert($0) }
        if let local,
           let prefix = local.split(separator: ".").dropLast().joined(separator: ".") as String? {
            for i in 1...254 where "\(prefix).\(i)" != local { candidates.insert("\(prefix).\(i)") }
        }
        return Array(candidates)
    }

    /// 热点/IP 变化时自动发现手机：先试常见网关，再扫描本地子网的 5555 端口。
    /// 手机开热点时 IP 通常是网关地址（如 192.168.43.1），且不同手机热点 IP 不同，
    /// 保存的 lastIP 容易失效。这里自动探测，避免用户手动改 IP。
    /// 策略（由快到慢）：默认网关 → 常见热点网关 → 本地子网受限并行扫描。
    private func autoFindWirelessDevice() -> String? {
        // 1) 默认网关：手机开热点时，手机本身就是 Mac 的默认网关，这是最准的一条
        if let gw = defaultGateway(), tryConnectADB(gw), let dev = findDevice() {
            return dev
        }

        // 2) 常见 Android / iOS 热点网关 IP
        let commonGateways = ["192.168.43.1", "192.168.1.1", "192.168.0.1",
                               "172.20.10.1", "192.168.137.1", "192.168.100.1"]
        for ip in commonGateways {
            if ip == defaultGateway() { continue } // 已试过
            if tryConnectADB(ip), let dev = findDevice() { return dev }
        }

        // 3) 全 /24 并行扫描（DHCP 常把手机分到 .100 之后，不能只扫 .1~.30）
        let reachableIPs = parallelTcpScan(wirelessScanCandidates(), port: 5555,
                                           timeout: 0.45, concurrency: 64)
        for ip in reachableIPs {
            if tryConnectADB(ip), let dev = findDevice() { return dev }
        }
        return nil
    }

    /// 读取 Mac 的默认网关 IP（手机热点场景下即手机自身 IP）
    private func defaultGateway() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 并行 TCP 端口扫描，返回端口可连通的 IP 列表
    private func parallelTcpScan(_ hosts: [String], port: UInt16, timeout: TimeInterval, concurrency: Int) -> [String] {
        guard !hosts.isEmpty else { return [] }
        let lock = NSLock()
        var result: [String] = []
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.transaudio.scan", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: concurrency)

        for host in hosts {
            semaphore.wait()
            group.enter()
            queue.async {
                defer { semaphore.signal(); group.leave() }
                if self.tcpReachable(host, port: port, timeout: timeout) {
                    lock.lock()
                    result.append(host)
                    lock.unlock()
                }
            }
        }
        group.wait()
        return result
    }

    /// 尝试 adb connect 指定 IP，成功返回 true
    private func tryConnectADB(_ ip: String) -> Bool {
        let out = runADB(["connect", "\(ip):5555"])
        // macOS 本地网络权限缺失时 adb 会报 No route to host（端口其实是通的）
        lastConnectNoRoute = out.contains("No route to host")
        usleep(600_000)
        return findDevice() != nil
    }

    /// 获取 Mac 当前 Wi-Fi 接口的 IP 地址
    private func currentWiFiIP() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["en0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // 匹配 inet 192.168.x.x
        if let range = out.range(of: "inet \\d+\\.\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
            let match = String(out[range])
            return match.replacingOccurrences(of: "inet ", with: "")
        }
        return nil
    }

    /// 读手机媒体音量（STREAM_MUSIC）。多设备连接时必须指定 serial，否则 adb 会报
    /// 「more than one device/emulator」而读不到值。
    private func phoneMediaVolume(serial: String? = nil) -> Int? {
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        args += ["shell", "cmd", "media_session", "volume", "--stream", "3", "--get"]
        let out = runADB(args)
        guard let r = out.range(of: "volume is ") else { return nil }
        let digits = out[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func setPhoneMediaVolume(_ v: Int, serial: String? = nil) {
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        args += ["shell", "cmd", "media_session", "volume", "--stream", "3", "--set", "\(v)"]
        _ = runADB(args)
    }

    /// 杀掉手机端遗留的 scrcpy 采集进程。
    /// scrcpy 被异常终止时，设备端的 server 会活着继续占用音频路由（remote_submix），
    /// 表现就是「关掉电脑上的程序后手机没声音」。
    ///
    /// 注意：多台设备同时连接（如手机 + 平板）时，`adb shell` 不带 `-s` 会直接返回
    /// 「more than one device/emulator」，清理会静默失效 —— 残留的旧 server 会一直
    /// 占用音频采集，导致新会话拿不到声音。因此这里必须逐台设备带上 `-s` 执行。
    private func cleanupPhoneServer(serial: String? = nil, endingSession: UInt64? = nil) {
        // 旧会话的收尾可能晚于新会话启动，此时不能杀掉新会话刚拉起的采集进程
        if let endingSession {
            let current: UInt64 = Thread.isMainThread ? sessionID : DispatchQueue.main.sync { self.sessionID }
            if current != endingSession { return }
        }
        let targets: [String]
        if let serial {
            targets = [serial]
        } else {
            // 未指定设备：遍历当前在线的所有设备，逐台清理
            targets = adbDeviceSerials()
            guard !targets.isEmpty else { return }
        }
        for target in targets {
            let out = runADB(["-s", target, "shell", "ps", "-A", "-o", "PID,ARGS"])
            for line in out.split(separator: "\n")
                where line.contains("com.genymobile.scrcpy.Server") && line.contains("video=false") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if let pid = parts.first, pid.allSatisfy(\.isNumber) {
                    _ = runADB(["-s", target, "shell", "kill", "-9", String(pid)])
                }
            }
        }
    }

    /// 直接读默认输出设备的音量（0~100），避免 fork osascript 带来的延迟与开销
    func defaultOutputVolume() -> Int? {
        var devAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &devAddr, 0, nil, &devSize, &dev) == noErr, dev != 0 else {
            return nil
        }

        var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(dev, &volAddr),
           AudioObjectGetPropertyData(dev, &volAddr, 0, nil, &size, &volume) == noErr {
            return Int((volume * 100).rounded())
        }
        // 部分设备只在左右声道上暴露音量
        var values: [Float32] = []
        for channel in [UInt32(1), UInt32(2)] {
            var chAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                    mScope: kAudioObjectPropertyScopeOutput,
                                                    mElement: channel)
            var v = Float32(0)
            var s = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(dev, &chAddr),
               AudioObjectGetPropertyData(dev, &chAddr, 0, nil, &s, &v) == noErr {
                values.append(v)
            }
        }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Float32(values.count)
        return Int((avg * 100).rounded())
    }

    func refreshVolume() {
        guard let vol = defaultOutputVolume() else { return }
        volBar.stringValue = "[\(blockBar(Double(vol)))]"
        volValue.stringValue = "\(vol)%"
        let color = vol >= 80 ? C_RED : C_GREEN
        volBar.textColor = color
        volValue.textColor = color
    }

    /// 会话期间跟随手机媒体音量：0.4 秒轮询一次，换算成软件增益（不改变 Mac 音量）
    private func startPhoneVolumePolling() {
        phoneVolTimer?.invalidate()
        // 3 秒一次即可：音量是用户手动动作，而 adbd 的 shell 请求是串行处理的，
        // 每次 `cmd media_session` 要 fork 一个 app_process（100~200ms），
        // 0.4 秒一轮会把 adbd 占满，导致心跳排队超时、把正常音频流误判成断联。
        phoneVolTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollPhoneVolume()
        }
        // 播放器默认增益为 0（避免启动瞬间突兀出声），这里立即查一次音量，
        // 拿到真实档位后马上套用增益，不用干等第一个 3 秒周期。
        pollPhoneVolume()
    }

    private func pollPhoneVolume() {
        guard let device = activeDevice, !volumeQueryInFlight else { return }
        volumeQueryInFlight = true
        DispatchQueue.global().async {
            let out = self.runADB(["-s", device, "shell", "cmd", "media_session",
                                   "volume", "--stream", "3", "--get"], timeout: 3)
            var index = -1
            var maxIndex = -1
            if let r = out.range(of: "volume is ") {
                index = Int(out[r.upperBound...].prefix { $0.isNumber }) ?? -1
            }
            if let r = out.range(of: "in range [") {
                let parts = out[r.upperBound...].split(separator: ".", omittingEmptySubsequences: true)
                if let last = parts.last { maxIndex = Int(last.prefix { $0.isNumber }) ?? -1 }
            }
            DispatchQueue.main.async {
                self.volumeQueryInFlight = false
                guard self.activeDevice == device else { return }
                guard index >= 0, maxIndex > 0 else {
                    // 读不到音量（adb 忙 / 设备不支持）：连续失败 3 次后回落满增益，
                    // 否则默认增益 0 会让用户永远听不到声音。
                    self.volumeQueryFailures += 1
                    if self.volumeQueryFailures >= 3 {
                        self.coreAudioPlayer?.setGain(1)
                    }
                    return
                }
                self.volumeQueryFailures = 0
                self.phoneVolValue.stringValue = "手机 \(index)/\(maxIndex)"
                self.phoneVolValue.textColor = index == 0 ? C_DIM : C_GREEN
                // Android 音量档位 → 增益。直接套平方感知曲线时，低档位会被压到几乎无声：
                // 例如小米平板的 10/150 → 0.004，相当于静音，表现为「刚开始有声、下一秒就没了」。
                // 这里用「35% 保底 + 剩余部分按平方曲线」映射，既保留跟随手感，又保证听得见。
                let ratio = Double(index) / Double(maxIndex)
                let gain = index == 0 ? 0.0 : 0.35 + 0.65 * ratio * ratio
                self.coreAudioPlayer?.setGain(Float(gain))
            }
        }
    }

    // MARK: - 音量推送通道（server 端 VolumeWatcher）

    /// 建立 adb forward 并在后台持续读取推送行。
    /// scrcpy server 需要先启动才会 bind 抽象 socket，所以连接可能被拒，读循环里按 400ms 重连。
    private func startVolumeWatcher(device: String, session id: UInt64) {
        volumeWatchActive = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let out = self.runADB(["-s", device, "forward", "tcp:0",
                                   "localabstract:transaudio_vol"], timeout: 6)
            guard let port = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return
            }
            DispatchQueue.main.async { self.volumeWatchPort = port }
            while self.isCurrentSession(id), !self.stopping {
                self.readVolumeStream(port: port, session: id)
                usleep(400_000)
            }
        }
    }

    /// 读取推送流直到断开。返回后由 startVolumeWatcher 决定是否重连。
    private func readVolumeStream(port: Int, session id: UInt64) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 512)
        var pending = ""
        while isCurrentSession(id), !stopping {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return }
            pending += String(decoding: buffer[0..<n], as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                applyVolumePush(line, session: id)
            }
        }
    }

    /// 解析 `V <index> <max>` 并套用与轮询一致的增益映射。
    private func applyVolumePush(_ line: String, session id: UInt64) {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "V",
              let index = Int(parts[1]), let maxIndex = Int(parts[2]), maxIndex > 0 else { return }
        DispatchQueue.main.async {
            guard self.isCurrentSession(id), self.coreAudioPlayer != nil else { return }
            self.volumeWatchActive = true
            self.volumeWatchFallbackTimer?.invalidate()
            self.phoneVolTimer?.invalidate()
            self.volumeQueryFailures = 0
            self.phoneVolValue.stringValue = "手机 \(index)/\(maxIndex)"
            self.phoneVolValue.textColor = index == 0 ? C_DIM : C_GREEN
            let ratio = Double(index) / Double(maxIndex)
            let gain = index == 0 ? 0.0 : 0.35 + 0.65 * ratio * ratio
            self.coreAudioPlayer?.setGain(Float(gain))
        }
    }

    /// 推送通道就绪前挂一个 5 秒兜底：若一条推送都没收到（例如仍在用旧版 server jar），
    /// 回退到 adb 轮询，保证音量跟随不会因 jar 未更新而完全失效。
    private func scheduleVolumeWatchFallback(session id: UInt64) {
        volumeWatchFallbackTimer?.invalidate()
        volumeWatchActive = false
        volumeWatchFallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self, self.isCurrentSession(id), !self.volumeWatchActive else { return }
            self.appendDiagnostic("音量推送通道未就绪，回退到 adb 轮询")
            self.startPhoneVolumePolling()
        }
    }
    ///
    /// 为什么不再每次都跑 `adb shell`：
    /// adbd 的 ShellService 是串行处理 shell 请求的，而音量跟随等功能也在占用它，
    /// 单次 `adb shell echo ok` 实测 130~200ms，排队时可达数秒。用它当心跳会把
    /// 正常音频流误判成断联（实测 4 次断联全部由此触发）。PCM 字节数由 C 层原子
    /// 计数，读取零开销、零额外进程，是唯一准确的链路存活信号。
    /// adb shell 仅作为「PCM 静默后的兜底探测」和「低频 RTT 采样」使用。
    private func heartbeat() {
        guard let device = activeDevice, !heartbeatInFlight else { return }
        let session = sessionID

        // 主路径：最近 3 秒内有 PCM 到达 → 链路健康，完全不需要碰 adb
        let pcmAlive = activeEngine == "Native" && Date().timeIntervalSince(lastPCMAt) <= 3
        if pcmAlive {
            heartbeatFailures = 0
            // 低频采样一次 RTT 用于界面显示（30 秒一次，避免给 adbd 添负载）
            if Date().timeIntervalSince(lastRTTSampleAt) >= 30 {
                lastRTTSampleAt = Date()
                probeADB(device: device, session: session, canFail: false)
            }
            return
        }

        // 兜底：PCM 静默（或 Legacy 引擎无 PCM 回传）→ 用 adb 探测
        probeADB(device: device, session: session, canFail: true)
    }

    /// 执行一次 adb 存活探测。canFail=false 时只用于采样，失败不触发重连。
    private func probeADB(device: String, session: UInt64, canFail: Bool) {
        heartbeatInFlight = true
        DispatchQueue.global().async {
            let began = Date()
            let out = self.runADB(["-s", device, "shell", "echo", "ok"], timeout: 6)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            let ok = out.contains("ok")
            DispatchQueue.main.async {
                self.heartbeatInFlight = false
                guard self.isCurrentSession(session), self.activeDevice == device else { return }
                guard ok else {
                    guard canFail else { return }
                    self.heartbeatFailures += 1
                    self.appendDiagnostic("心跳失败 rtt=\(ms)ms 连续失败=\(self.heartbeatFailures)（PCM 已静默 \(Int(Date().timeIntervalSince(self.lastPCMAt)))s）")
                    // 连续 3 次失败才判定断联：单次 adb 卡顿不足以代表链路已断
                    if self.heartbeatFailures >= 3 {
                        self.heartbeatFailures = 0
                        self.failSession("与手机的调试连接断开了", retryable: true, session: session)
                    }
                    return
                }
                self.heartbeatFailures = 0
                self.lastHeartbeatMs = ms
                self.lastRTTSampleAt = Date()
                // adb shell 的固有开销就有 130~200ms，阈值放到 400ms 才有意义
                if ms > 400 {
                    self.appendDiagnostic("adb 探测高延迟 rtt=\(ms)ms")
                }
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
                    self.awdlValue.stringValue = isUp ? "已开启 · 可能影响音频稳定性" : "已关闭 · 连接更稳定"
                    self.awdlValue.textColor = isUp ? C_YELLOW : C_GREEN
                    self.awdlButton.title = isUp ? "关闭" : "恢复"
                    self.awdlButton.isEnabled = true
                }
            }
        }
    }

    /// 是否已获得免密码授权（仅允许切换 awdl0）
    private func awdlHasAuthorization() -> Bool {
        if awdlAuthorizationCache == true { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l", "/sbin/ifconfig", "awdl0", "down"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let ok = p.terminationStatus == 0
        if ok { awdlAuthorizationCache = true }
        return ok
    }

    /// 首次授权：写入仅针对 awdl0 的免密规则，之后切换不再询问密码
    private func installAWDLAuthorization(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let rule = "ALL ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 up, /sbin/ifconfig awdl0 down\n"
            let tmp = "/tmp/transaudio-awdl.sudoers"
            try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)
            let shell = "/usr/bin/install -m 440 -o root -g wheel \(tmp) /etc/sudoers.d/transaudio-awdl"
                + " && /usr/sbin/visudo -cf /etc/sudoers.d/transaudio-awdl"
                + " || { /bin/rm -f /etc/sudoers.d/transaudio-awdl; exit 1; }"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(shell)\" with administrator privileges"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {}
            try? FileManager.default.removeItem(atPath: tmp)
            if ok { ok = self.awdlHasAuthorization() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// AWDL 开关：首次使用需一次管理员授权，之后切换不再询问密码
    @objc func awdlClicked() {
        if awdlIsUp {
            let alert = NSAlert()
            alert.messageText = "要关闭 AWDL 吗？"
            alert.informativeText = "AWDL 为隔空投送、接力与通用剪贴板提供支持。关闭后这些功能将暂时不可用，但有助于减少音频传输的延迟波动。\n\n你可以随时恢复，重启 Mac 后也会自动恢复。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "关闭 AWDL")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let target = !awdlIsUp
        if awdlHasAuthorization() {
            setAWDL(up: target)
            return
        }
        let alert = NSAlert()
        alert.messageText = "需要一次管理员授权"
        alert.informativeText = "切换 AWDL 需要管理员权限。授权一次后，今后的切换将不再询问密码。\n\n授权范围仅限开启或关闭 awdl0 网络接口。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        awdlButton.isEnabled = false
        awdlValue.stringValue = "等待授权…"
        awdlValue.textColor = C_DIM
        installAWDLAuthorization { ok in
            guard ok else {
                self.refreshAWDL()
                let fail = NSAlert()
                fail.messageText = "未能完成授权"
                fail.informativeText = "本次操作已取消，你可以稍后重试。"
                fail.alertStyle = .warning
                fail.runModal()
                return
            }
            self.setAWDL(up: target)
        }
    }

    func setAWDL(up: Bool) {
        awdlButton.isEnabled = false
        awdlValue.stringValue = "处理中…"
        awdlValue.textColor = C_DIM
        DispatchQueue.global().async {
            var ok = false
            if self.awdlHasAuthorization() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                p.arguments = ["-n", "/sbin/ifconfig", "awdl0", up ? "up" : "down"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0 } catch {}
            }
            // 授权规则被移除等情况下回退到系统密码框，保证操作仍可完成
            if !ok {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"/sbin/ifconfig awdl0 \(up ? "up" : "down")\" with administrator privileges"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit() } catch {}
            }
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

    /// Auto 缓冲起始值：只做粗略估计，真正的下限由播放器在播放过程中自行下探学习。
    /// USB 无网络传输，从 40 ms 起；Wi-Fi 按 ping 最坏 RTT 估一个偏保守的起点，
    /// 之后播放器会二分下探到当前环境能稳住的最低值，不再强制下限。
    func measureAutoBuffer(device: String) -> Int {
        guard device.contains(":") else { return 40 }
        let ip = String(device.split(separator: ":")[0])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "10", "-i", "0.2", ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // 逐包解析 time=xx ms
            var samples: [Double] = []
            for line in out.split(separator: "\n") {
                guard let r = line.range(of: "time=") else { continue }
                let token = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
                if let v = Double(token) { samples.append(v) }
            }
            if samples.count >= 2 {
                samples.sort()
                let maxRtt = samples[samples.count - 1]
                // 用「次大值」而不是最大值：启动瞬间手机要 fork scrcpy / 执行 adb 命令，
                // 偶尔会出现一个 100ms+ 的孤立尖峰，用最大值会把缓冲起始值直接顶高一倍
                // （实测 164ms vs 真实 58ms）。丢掉单个最坏样本仍能覆盖真实抖动。
                let robust = samples[samples.count - 2]
                let chosen = min(500, max(40, Int(robust.rounded()) + 40))
                self.appendDiagnostic("Auto 缓冲测量 max=\(Int(maxRtt))ms 次大=\(Int(robust))ms 起始=\(chosen)ms")
                DispatchQueue.main.async {
                    self.rttHint.stringValue = "Auto 起始 \(chosen) ms（抖动 \(Int(robust)) ms，会自动下探）"
                    self.rttHint.textColor = C_CYAN
                }
                return chosen
            }
        } catch {}
        DispatchQueue.main.async {
            self.rttHint.stringValue = "Auto 测量失败 → 120 ms，会自动下探"
            self.rttHint.textColor = C_YELLOW
        }
        return 120
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

    // MARK: - 设备发现与选择

    /// 检测“USB 已插入但没开 USB 调试”的手机。
    /// 这种情况下 USB 设备会被 macOS 枚举出来，但没有 ADB 接口，adb devices 是空的，
    /// 手机也不会弹授权框——必须提示用户去开发者选项打开 USB 调试。
    private func attachedUSBPhoneName() -> String? {
        let brands = ["redmi", "xiaomi", "pixel", "samsung", "oneplus", "oppo", "vivo",
                      "realme", "huawei", "honor", "motorola", "sony", "meizu", "zte",
                      "iqoo", "poco", "nothing", "nubia", "lenovo"]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOUSBHostDevice"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> String? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            }
            guard let name = prop("USB Product Name") else { continue }
            let hay = (name + " " + (prop("USB Vendor Name") ?? "")).lowercased()
            if brands.contains(where: { hay.contains($0) }) { return name }
        }
        return nil
    }

    /// 扫描当前可用设备：adb devices（USB + 已连无线）＋ mDNS ＋ 局域网 5555 端口发现
    func refreshDeviceList(silent: Bool = false, deepScan: Bool? = nil) {
        guard !sessionActive, !isDiscovering else { return }
        isDiscovering = true
        if !silent { deviceStrip.setScanning() }
        // 轻量刷新只查 adb devices 与 USB 侧手机 IP；深扫（mDNS + 全子网）限制频率
        let needDeep: Bool
        if let deepScan { needDeep = deepScan }
        else if silent { needDeep = Date().timeIntervalSince(lastDeepScan) > 15 }
        else { needDeep = true }
        if needDeep { lastDeepScan = Date() }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            // USB 已授权时顺手把手机的无线调试打开（每个序列号间隔重试）
            self.autoUpgradeWirelessFromUSB()
            let devices = self.discoverDevices(deepScan: needDeep)
            // 一台设备都没发现，但 USB 上有手机 → 多半是没开 USB 调试
            var usbHint: String?
            if devices.isEmpty, let phone = self.attachedUSBPhoneName() {
                usbHint = "已连接 \(phone) · 请在开发者选项中开启「USB 调试」"
            }
            DispatchQueue.main.async {
                self.isDiscovering = false
                guard !self.sessionActive else { return }
                self.deviceStrip.render(self.mergeSticky(devices), usbHint: usbHint)
            }
        }
    }

    /// 合并最近出现过的无线设备，避免扫描偶发失败导致卡片“闪一下就消失”
    private func mergeSticky(_ devices: [FoundDevice]) -> [FoundDevice] {
        let now = Date()
        for d in devices {
            lastSeenDevices[d.serial] = (d, now)
        }
        var merged = devices
        // 无线设备 30 秒、USB 设备 10 秒内没再扫到也先保留，避免 adbd 重启/扫描抖动导致卡片闪没
        for (serial, item) in lastSeenDevices {
            let keepFor: TimeInterval = (item.device.kind == .usb) ? 10 : 30
            guard now.timeIntervalSince(item.time) <= keepFor else {
                lastSeenDevices.removeValue(forKey: serial)
                continue
            }
            if !merged.contains(where: { $0.serial == serial }) {
                merged.append(item.device)
            }
        }
        return merged
    }

    /// USB 在线（已授权）时自动开通无线调试：adb tcpip 5555 + connect。
    /// 这样手机端只需在 USB 首次连接时点一次“允许调试”，之后无线即可直接使用。
    private func autoUpgradeWirelessFromUSB() {
        guard !sessionActive else { return }
        let serials = adbDeviceSerials()
        // 已经有无线连接就不折腾
        if serials.contains(where: { $0.contains(":") }) { return }
        guard let usb = serials.first(where: { !$0.contains(":") }) else { return }

        let now = Date()
        if let last = wirelessAttemptAt[usb], now.timeIntervalSince(last) < 30 { return }
        wirelessAttemptAt[usb] = now

        if enableWirelessOverUSB(usbSerial: usb) != nil, let ip = phoneWlanIP(serial: usb) {
            lastIP = ip
        }
    }

    /// 空闲时每 4 秒自动刷新一次，插上 USB / 开热点后设备会自动出现
    func startDeviceAutoRefresh() {
        deviceRefreshTimer?.invalidate()
        deviceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, !self.sessionActive, self.isDeviceStripVisible else { return }
            self.refreshDeviceList(silent: true)
        }
    }

    private func discoverDevices(deepScan: Bool = true) -> [FoundDevice] {
        var result: [FoundDevice] = []
        var connectedIPs = Set<String>()
        let localIP = currentWiFiIP()

        // 1) adb devices：USB 与已连接的无线设备
        let entries = adbDeviceStates()
        var usbSerials: [String] = []
        for entry in entries {
            if entry.serial.contains(":") {
                let ip = String(entry.serial.split(separator: ":")[0])
                if entry.state == "device" {
                    connectedIPs.insert(ip)
                    result.append(FoundDevice(serial: entry.serial, title: ip,
                                              subtitle: "Wi-Fi 已连接", kind: .wifiConnected))
                }
            } else if entry.state == "device" {
                usbSerials.append(entry.serial)
                result.append(FoundDevice(serial: entry.serial, title: entry.serial,
                                          subtitle: "USB 已连接", kind: .usb))
            } else if entry.state == "unauthorized" {
                // 最常见的“搜不到设备”原因：手机上没点“允许 USB 调试”
                result.append(FoundDevice(serial: entry.serial, title: entry.serial,
                                          subtitle: "未授权 · 请在手机上点允许", kind: .usb))
            } else {
                result.append(FoundDevice(serial: entry.serial, title: entry.serial,
                                          subtitle: "离线 · 请重插数据线", kind: .usb))
            }
        }

        // 2) USB 在线时直接读手机的 Wi-Fi IP，给出“一键转无线”卡片
        for usb in usbSerials {
            guard let ip = phoneWlanIP(serial: usb) else { continue }
            let target = "\(ip):5555"
            if connectedIPs.contains(ip) { continue }
            connectedIPs.insert(ip)
            result.append(FoundDevice(serial: target, title: ip,
                                      subtitle: "USB 在线 · 点击转无线", kind: .wifiViaUSB))
        }

        // 3) mDNS 广播（Android 11+ 无线调试）
        if deepScan {
            for serial in mdnsWirelessSerials() {
                let ip = String(serial.split(separator: ":")[0])
                guard !connectedIPs.contains(ip), ip != localIP else { continue }
                connectedIPs.insert(ip)
                result.append(FoundDevice(serial: serial, title: ip,
                                          subtitle: "mDNS 发现 · 点击连接", kind: .wifiDiscovered))
            }

            // 4) 局域网全 /24 扫描 5555 端口（超时放宽到 0.7s，减少偶发漏检）
            let reachable = parallelTcpScan(wirelessScanCandidates(), port: 5555,
                                            timeout: 0.7, concurrency: 64)
            for ip in reachable where !connectedIPs.contains(ip) && ip != localIP {
                connectedIPs.insert(ip)
                result.append(FoundDevice(serial: "\(ip):5555", title: ip,
                                          subtitle: "局域网可连接", kind: .wifiDiscovered))
            }
        }
        return result
    }

    /// 点击设备卡片：绿环已由卡片动画显示，稍作停留后收起设备条并自动连接
    func handleDeviceSelect(_ device: FoundDevice) {
        guard !sessionActive else { return }
        pendingDevice = device
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            self?.collapseAndConnect()
        }
    }

    /// 手动输入 IP：构造成一台待连接的无线设备
    func handleManualIP(_ ip: String) {
        lastIP = ip
        pendingDevice = FoundDevice(serial: "\(ip):5555", title: ip,
                                    subtitle: "手动指定", kind: .wifiDiscovered)
        collapseAndConnect()
    }

    private func collapseAndConnect() {
        guard let device = pendingDevice else { return }
        // 绿色先落到主操作按钮，营造“绿环变形为 START”的视觉
        actionButton.title = "▶  START BRIDGE"
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.isEnabled = true
        animateStrip(visible: false) { [weak self] in
            self?.startStream(preferredDevice: device.serial,
                              needsWirelessConnect: device.needsConnect)
        }
    }

    /// 贝塞尔曲线展开/收起设备条，同时联动窗口高度
    private func animateStrip(visible: Bool, completion: (() -> Void)? = nil) {
        isDeviceStripVisible = visible
        let targetHeight = visible ? stripExpandedHeight : 0
        let targetWindowHeight = visible ? windowExpandedHeight : windowCollapsedHeight
        let oldFrame = window.frame
        let newFrame = NSRect(x: oldFrame.origin.x,
                              y: oldFrame.origin.y + (oldFrame.height - targetWindowHeight),
                              width: oldFrame.width,
                              height: targetWindowHeight)

        // 兜底保护：正常由动画 completion 收尾；若动画时钟被挂起（如锁屏/窗口服务器异常），
        // 超时后直接落到最终态，避免后续连接流程永久卡死
        var didFinish = false
        let finishOnce: () -> Void = {
            guard !didFinish else { return }
            didFinish = true
            completion?()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            // easeOutQuint 贝塞尔曲线：快速起步、平滑减速
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            self.deviceStripHeight?.animator().constant = targetHeight
            self.deviceStrip.animator().alphaValue = visible ? 1 : 0
            self.window.animator().setFrame(newFrame, display: true)
            self.window.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: finishOnce)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, !didFinish else { return }
            self.deviceStripHeight?.constant = targetHeight
            self.deviceStrip.alphaValue = visible ? 1 : 0
            self.window.setFrame(newFrame, display: true)
            finishOnce()
        }
    }

    private func setIdleActionButton() {
        actionButton.title = "请先在上方选择设备"
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.isEnabled = false
    }

    /// 会话结束后重新展开设备条并刷新，让用户重新选择
    private func expandDeviceStrip() {
        pendingDevice = nil
        setIdleActionButton()
        guard !isDeviceStripVisible else {
            refreshDeviceList()
            return
        }
        animateStrip(visible: true) { [weak self] in
            self?.refreshDeviceList()
        }
    }

    @objc func actionTapped() {
        if sessionActive {
            stopStream()
        } else if isPausedOffline {
            // 暂停态点「重试」：重新走一遍发现 + 连接流程
            isPausedOffline = false
            actionButton.isEnabled = false
            actionButton.title = "… SEARCHING"
            statusValue.stringValue = "SEARCHING…"
            statusValue.textColor = C_CYAN
            transportValue.stringValue = "正在重新扫描局域网…"
            transportValue.toolTip = nil
            transportValue.textColor = C_DIM
            startStream()
        } else {
            startStream()
        }
    }

    /// 进入「暂停等待」态：保留排查原因，把主按钮变成可点的「重试」。
    /// 不使用模态弹窗，避免阻塞事件循环后界面卡在 connecting。
    private func enterPausedOffline(hint: String, steps: String) {
        isPausedOffline = true
        statusValue.stringValue = "PAUSED · 手机不在局域网"
        statusValue.textColor = C_YELLOW
        deviceValue.stringValue = hint.isEmpty ? "未找到手机" : hint
        // 只显示短提示，避免长文本撑大窗口；完整排查步骤放到 tooltip 悬停查看
        transportValue.stringValue = hint.isEmpty
            ? "请确认手机与 Mac 在同一 Wi-Fi · 点 ↻ 重试"
            : "\(hint) · 点 ↻ 重试"
        transportValue.toolTip = steps.isEmpty ? nil : steps
        transportValue.textColor = C_DIM
        actionButton.title = "↻ 重试"
        actionButton.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        actionButton.isEnabled = true
        appendDiagnostic("进入暂停等待态：\(hint)，等待用户重试")
    }

    @objc func noSleepToggled(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "noSleepWhenCharging")
        updateSleepAssertion()
    }

    private func isCurrentSession(_ id: UInt64) -> Bool {
        sessionID == id && sessionActive
    }

    func startStream(preferredDevice: String? = nil, needsWirelessConnect: Bool = false, isAutoRecovery: Bool = false) {
        guard !sessionActive, process == nil, coreAudioPlayer == nil else { return }
        isPausedOffline = false
        // 清理暂停态可能遗留的排查步骤 tooltip
        transportValue.toolTip = nil
        // 用户手动开始/切换设备时清零自动重连计数；自动恢复时保留计数
        if !isAutoRecovery {
            autoRecoverAttempts = 0
            isAutoRecovering = false
        }
        guard let dir = scrcpyDir else {
            let alert = NSAlert()
            alert.messageText = "找不到 scrcpy 组件"
            alert.informativeText = "请将 scrcpy 安装到 ~/scrcpy/scrcpy-macos-aarch64-v5.0.1，或放入 App 的 Contents/Resources/scrcpy 目录。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        let engine = enginePopup.titleOfSelectedItem ?? "Native"
        let executable = dir + (engine == "Native" ? "/scrcpy-coreaudio" : "/scrcpy")
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            let alert = NSAlert()
            alert.messageText = "找不到 \(engine) 客户端"
            alert.informativeText = engine == "Native"
                ? "请先运行 scripts/build-scrcpy-coreaudio.sh，或将音频引擎切换为 Legacy。"
                : "请恢复官方 scrcpy 5.0.1 客户端。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
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
        // 音量优先走 server 端推送（零 adb 开销）；若推送通道未就绪再回退轮询
        scheduleVolumeWatchFallback(session: id)

        DispatchQueue.global().async { [self] in
            var dev: String?

            // 指定设备（来自设备条选择）：无线的先 adb connect，再核对序列号
            if let pref = preferredDevice {
                if needsWirelessConnect {
                    // 手机仍以 USB 连着时，先开通 adb tcpip，避免用户还要手动输 IP
                    if !self.adbDeviceSerials().contains(pref),
                       let usb = self.adbDeviceSerials().first(where: { !$0.contains(":") }) {
                        DispatchQueue.main.async {
                            guard self.isCurrentSession(id), !self.stopping else { return }
                            self.statusValue.stringValue = "ENABLING WI-FI…"
                            self.statusValue.textColor = C_CYAN
                        }
                        _ = self.enableWirelessOverUSB(usbSerial: usb)
                    }
                    if !self.adbDeviceSerials().contains(pref) {
                        let out = self.runADB(["connect", pref], timeout: 10)
                        self.lastConnectNoRoute = out.contains("No route to host")
                        self.appendDiagnostic("adb connect \(pref) → \(out.split(separator: "\n").first.map(String.init) ?? out)")
                        usleep(900_000)
                    }
                }
                dev = self.adbDeviceSerials().contains(pref) ? pref : nil

                // 无线设备可能换了 IP（DHCP 重新分配 / 手机重连 Wi-Fi）：
                // 先按原 IP 再连一次，仍不通就重新扫描局域网，而不是直接放弃
                if dev == nil, pref.contains(":") {
                    let out = self.runADB(["connect", pref], timeout: 6)
                    self.lastConnectNoRoute = out.contains("No route to host")
                    usleep(600_000)
                    if self.adbDeviceSerials().contains(pref) {
                        dev = pref
                    } else {
                        self.appendDiagnostic("重连失败：\(pref) 不可达，开始重新扫描局域网")
                        DispatchQueue.main.async {
                            guard self.isCurrentSession(id), !self.stopping else { return }
                            self.statusValue.stringValue = "SEARCHING…"
                            self.statusValue.textColor = C_CYAN
                        }
                        if let found = self.autoFindWirelessDevice() {
                            dev = found
                            lastIP = String(found.split(separator: ":")[0])
                        }
                    }
                }
            }

            // 未指定设备时的历史兜底流程（手动 IP / 热点自动发现）
            if dev == nil, preferredDevice == nil, !lastIP.isEmpty {
                let out = self.runADB(["connect", "\(lastIP):5555"], timeout: 10)
                self.lastConnectNoRoute = out.contains("No route to host")
                usleep(1_200_000)
                dev = self.findDevice()
            }
            if dev == nil, preferredDevice == nil, !lastIP.isEmpty {
                // 再重试一次。注意不要 kill-server：adb server 由 App 以 nodaemon 方式托管，
                // 杀掉后会退回没有本地网络权限的守护进程，无线就再也连不上了
                let out = self.runADB(["connect", "\(lastIP):5555"], timeout: 10)
                self.lastConnectNoRoute = out.contains("No route to host")
                usleep(1_200_000)
                dev = self.findDevice()
            }
            // 保存的 IP 连不上（可能是热点 IP 变了），自动尝试常见网关 + 扫描本地子网
            if dev == nil, preferredDevice == nil, !lastIP.isEmpty {
                DispatchQueue.main.async {
                    guard self.isCurrentSession(id), !self.stopping else { return }
                    self.statusValue.stringValue = "SEARCHING…"
                    self.statusValue.textColor = C_CYAN
                }
                dev = self.autoFindWirelessDevice()
                if let found = dev {
                    let ip = String(found.split(separator: ":")[0])
                    lastIP = ip
                    DispatchQueue.main.async {
                        guard self.isCurrentSession(id) else { return }
                        self.deviceValue.stringValue = found
                        self.transportValue.stringValue = "Wi-Fi (adb tcpip) · 自动发现"
                    }
                }
            }

            guard let device = dev else {
                let (hint, steps) = lastIP.isEmpty ? ("", "") : self.diagnoseConnection(ip: lastIP)
                self.appendDiagnostic("找不到可用设备，诊断：\(hint)")
                DispatchQueue.main.async {
                    guard self.isCurrentSession(id) else { return }
                    // 必须先退出自动重连态：否则 resetToIdle 会认为「仍在重连」，
                    // 既保留 RECONNECTING 文案，也不展开设备条，界面会永久卡在 connecting。
                    self.isAutoRecovering = false
                    self.autoRecoverAttempts = 0
                    self.stopStream {
                        guard !lastIP.isEmpty else { return }
                        self.enterPausedOffline(hint: hint, steps: steps)
                    }
                }
                return
            }
            guard self.isCurrentSession(id), !self.stopping else { return }

            let isWireless = device.contains(":")
            if isWireless { lastIP = String(device.split(separator: ":")[0]) }
            self.activeDevice = device
            self.appendDiagnostic("会话开始 device=\(device) transport=\(isWireless ? "WiFi" : "USB") engine=\(engine) codec=\(codec) buffer=\(bufferChoice) bitrate=\(bitrateK)K")
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
            self.cleanupPhoneServer(serial: device)
            self.savedPhoneVolume = self.phoneMediaVolume(serial: device)

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
                        player.onEngineEvent = { [weak self] message in
                            guard let self, self.isCurrentSession(id) else { return }
                            self.appendDiagnostic(message)
                            self.refreshOutputDevice()
                        }
                        player.onFailure = { [weak self] message in
                            // 采集端断开属于可恢复故障，交给自动重连；输出设备断开则不可恢复
                            self?.failSession(message, retryable: Self.isRecoverableAudioError(message), session: id)
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

            // 音量推送：server 端 VolumeWatcher 监听本地音量并通过独立 abstract socket 推送，
            // 桌面端用 adb forward 接入。整体零 adb shell 调用，不会干扰音频编码线程。
            self.startVolumeWatcher(device: device, session: id)

            // 启动客户端；始终保留 stderr 尾部，把“状态码 0/1”翻译成可读原因。
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            p.environment = env
            p.arguments = args

            let pipe = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = pipe
            let outLock = NSLock()
            var tailLines: [String] = []
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                outLock.lock()
                tailLines.append(contentsOf: s.split(separator: "\n").map(String.init))
                if tailLines.count > 80 { tailLines.removeFirst(tailLines.count - 80) }
                outLock.unlock()
            }
            p.terminationHandler = { [weak self] proc in
                // 等管道把最后几行读完再归类
                usleep(150_000)
                pipe.fileHandleForReading.readabilityHandler = nil
                outLock.lock()
                let lines = tailLines
                outLock.unlock()
                DispatchQueue.main.async {
                    guard let self, self.isCurrentSession(id), !self.stopping else { return }
                    let verdict = self.classifyClientExit(status: proc.terminationStatus, tail: lines)
                    self.writeDiagnosticLog(lines: lines, status: proc.terminationStatus)
                    self.failSession(verdict.message, retryable: verdict.retryable, session: id)
                }
            }

            var launchError: Error?
            // run() 与 process 赋值不可被 Stop 插入，避免遗留未被管理的 client。
            DispatchQueue.main.sync {
                guard self.isCurrentSession(id), !self.stopping else { return }
                do {
                    try p.run()
                    self.process = p
                } catch {
                    launchError = error
                }
            }
            guard self.isCurrentSession(id), !self.stopping else {
                pipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            if let launchError {
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.failSession("无法启动 scrcpy：\(launchError.localizedDescription)", session: id)
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

    /// 归类客户端退出原因，决定是否值得自动重连（自动重连仍失败时才弹提示）
    private func classifyClientExit(status: Int32, tail: [String]) -> (retryable: Bool, message: String) {
        let text = tail.joined(separator: "\n").lowercased()
        if text.contains("audio playback capture") || text.contains("not supported")
            || text.contains("could not start audio") || text.contains("audiorecord") {
            return (true, "手机拒绝了系统声音采集。当前前台应用可能禁止被录制（部分游戏、视频、银行类 App 会这样）。请退出该应用或回到桌面后重新开始。")
        }
        if text.contains("could not find adb device") || text.contains("server connection failed")
            || text.contains("device offline") || text.contains("unauthorized")
            || text.contains("connection reset") || text.contains("broken pipe") {
            return (true, "与手机的调试连接断开了。已自动重连；若仍失败，请重新插拔数据线，或确认手机与 Mac 仍在同一 Wi-Fi。")
        }
        if status == 0 {
            return (true, "手机端采集进程意外结束，已自动重试。")
        }
        return (false, "scrcpy 退出（状态码 \(status)）。请检查手机连接后重试。")
    }

    /// 追加一条诊断日志（不含客户端输出），用于记录重连、心跳等非进程退出类故障
    func appendDiagnostic(_ text: String) {
        let dir = NSHomeDirectory() + "/Library/Logs/TransAudio"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/transaudio.log"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] session=\(sessionID) device=\(activeDevice ?? "-") \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 512 * 1024 {
            try? fm.removeItem(atPath: path)
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 记录最近一次异常的事件与客户端输出，便于事后定位（保留最近 512 KB）
    private func writeDiagnosticLog(lines: [String], status: Int32) {
        let dir = NSHomeDirectory() + "/Library/Logs/TransAudio"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/transaudio.log"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var text = "\n[\(fmt.string(from: Date()))] session=\(sessionID) device=\(activeDevice ?? "-") exit=\(status)\n"
        text += lines.suffix(40).joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 512 * 1024 {
            try? fm.removeItem(atPath: path)
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func markStreaming(session id: UInt64, engine: String, codec: String) {
        guard isCurrentSession(id), !stopping, startTime == nil else { return }
        let wasRecovery = isAutoRecovering
        if wasRecovery {
            self.appendDiagnostic("自动重连成功 device=\(activeDevice ?? "-")")
        }
        // 桥接已出声：若用户开启且在充电，阻止空闲休眠
        self.updateSleepAssertion()
        // 已经恢复出声，清零自动重连计数
        autoRecoverAttempts = 0
        isAutoRecovering = false
        // 音频流已确认开始，重置 PCM 探针基线，避免首个心跳误判静默
        heartbeatFailures = 0
        lastPCMBytes = coreAudioPlayer?.snapshot().receivedPCMBytes ?? 0
        lastPCMAt = Date()
        statusValue.stringValue = "STREAMING · \(engine.uppercased())"
        statusValue.textColor = C_GREEN
        transportValue.stringValue = activeDevice?.contains(":") == true ? "Wi-Fi (adb tcpip)" : "USB (adb)"
        transportValue.textColor = C_DIM
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

    /// 播放器侧的故障是否属于可恢复（采集端断开 / 短暂无数据），可自动重连
    static func isRecoverableAudioError(_ message: String) -> Bool {
        let text = message
        if text.contains("输出设备已断开") { return false }
        return text.contains("已结束音频会话") || text.contains("未发送 PCM")
            || text.contains("等待 scrcpy PCM 超时") || text.contains("连接已断开")
            || text.contains("读取 PCM") || text.contains("接收 PCM")
            || text.contains("接受 PCM") || text.contains("listener")
    }

    private func failSession(_ message: String, retryable: Bool = false, session id: UInt64) {
        guard isCurrentSession(id), !stopping else { return }
        appendDiagnostic("故障：\(message)（可恢复=\(retryable)，已重试=\(autoRecoverAttempts) 次）")

        // 采集端断开、adb 掉线等瞬时故障：不弹窗，整段会话自动重连（最多 2 次）
        if retryable, !isTerminating, let device = activeDevice, autoRecoverAttempts < 2 {
            autoRecoverAttempts += 1
            isAutoRecovering = true
            let round = autoRecoverAttempts
            statusValue.stringValue = "RECONNECTING \(round)/2…"
            statusValue.textColor = C_YELLOW
            transportValue.stringValue = "\(Self.shortHint(message)) · 正在自动重试"
            transportValue.textColor = C_YELLOW
            stopStream { [weak self] in
                guard let self else { return }
                // Stop 过程会把状态改成 STOPPING，这里再恢复为重连提示
                self.statusValue.stringValue = "RECONNECTING \(round)/2…"
                self.statusValue.textColor = C_YELLOW
                self.transportValue.stringValue = "\(Self.shortHint(message)) · 正在自动重试"
                self.transportValue.textColor = C_YELLOW
                self.startStream(preferredDevice: device,
                                 needsWirelessConnect: device.contains(":"),
                                 isAutoRecovery: true)
                // 兜底：若重连没有真正启动（设备找不到等原因提前返回），不要让界面永远停在重连中
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                    guard let self, self.autoRecoverAttempts > 0,
                          !self.sessionActive, !self.stopping, !self.isTerminating else { return }
                    self.appendDiagnostic("重连未启动采集，继续下一轮")
                    self.failSession("重连未能启动音频采集", retryable: true, session: self.sessionID)
                }
            }
            return
        }

        autoRecoverAttempts = 0
        isAutoRecovering = false
        // 始终收不到 PCM 时，最常见的原因就是前台应用禁止被录制，给出对应建议
        let finalText = (message.contains("PCM 超时") || message.contains("未发送 PCM"))
            ? "手机没有送出任何音频数据。当前前台应用可能禁止被录制（部分游戏、视频、银行类 App 会这样）。请退出该应用或回到桌面后重新开始。"
            : message
        stopStream {
            self.statusValue.stringValue = "ERROR"
            self.statusValue.textColor = C_RED
            let alert = NSAlert()
            alert.messageText = "音频会话已中断"
            alert.informativeText = finalText
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    /// 重连时显示的一句话原因
    private static func shortHint(_ message: String) -> String {
        if message.contains("采集") || message.contains("录制") { return "手机拒绝采集系统声音" }
        if message.contains("调试连接") { return "与手机的调试连接断开" }
        if message.contains("输出设备") { return "Mac 输出设备已断开" }
        return "音频流中断"
    }

    /// 连不上手机时自动诊断，返回（一句话原因，排查步骤）。
    /// 先 ping：不通说明手机根本不在局域网；通但 5555 关说明手机重启过、adb tcpip 已失效。
    func diagnoseConnection(ip: String) -> (String, String) {
        if !pingReachable(ip) {
            return ("手机不在当前局域网",
                    "手机可能已断开 Wi-Fi、切换了网络，或 IP 地址发生了变化。\n\n" +
                    "请检查：\n" +
                    "1. 手机已在「设置 › WLAN」中连接，并与 Mac 使用同一网络\n" +
                    "2. 手机当前 IP 是否仍为 \(ip)（重新连接后可能变化）\n" +
                    "3. 路由器未开启「AP 隔离」或「客户端隔离」")
        }
        if !tcpReachable(ip, port: 5555, timeout: 2) {
            return ("无线调试已关闭",
                    "通过 USB 开启的无线调试在手机重启后会失效，这是正常现象。\n\n" +
                    "恢复方式：\n" +
                    "1. 用 USB 数据线连接手机与 Mac，App 会自动恢复\n" +
                    "2. 或在手机「开发者选项」中重新开启「无线调试」")
        }
        if lastConnectNoRoute {
            return ("adb 没有本地网络权限",
                    "手机的端口是通的，但 adb 无法访问本地网络（系统返回 No route to host）。\n\n" +
                    "请按以下步骤修复：\n" +
                    "1. 打开「系统设置 › 隐私与安全性 › 本地网络」\n" +
                    "2. 打开 TransAudio 的开关（若列表中没有，请点按 + 手动添加）\n" +
                    "3. 完全退出并重新打开 TransAudio")
        }
        return ("手机在线，但 adb 无法连接",
                "手机与端口均正常，但 adb 握手失败。\n\n" +
                "请尝试：\n" +
                "1. 再次点按 START BRIDGE 重试\n" +
                "2. 在手机「开发者选项」中重新开关一次「USB 调试」\n" +
                "3. 若手机弹出「是否允许这台电脑调试」，请勾选一律允许并确认")
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

    func startTimers() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            let sec = Int(Date().timeIntervalSince(start))
            self.uptimeValue.stringValue = String(format: "%02d:%02d", sec / 60, sec % 60)
            if self.activeEngine == "Native" {
                let bytes = self.coreAudioPlayer?.snapshot().receivedPCMBytes ?? 0
                self.dataValue.stringValue = String(format: "PCM %.2f MB", Double(bytes) / 1_048_576.0)
                // 记录 PCM 是否仍在增长：这是心跳判断链路存活的主信号（零额外开销）
                if bytes > self.lastPCMBytes {
                    self.lastPCMBytes = bytes
                    self.lastPCMAt = Date()
                }
            } else {
                // Legacy 没有 PCM 回传，只保留原官方路径的时间估算值。
                self.dataValue.stringValue = String(format: "≈ %.2f MB", Double(sec) * 16.0 / 1024.0)
            }
            self.refreshVolume()
            if sec % 5 == 0 {
                // 界面显示始终用 ICMP（真实网络往返 ~7ms）。
                // 心跳用的是 adb shell，含手机端 fork 开销 130~200ms，
                // 把它显示出来会让人误以为音频延迟变高了，所以只在会话中做健康检查。
                self.refreshRTT()
                if self.sessionActive { self.heartbeat() }
            }
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
        if !isAutoRecovering {
            self.appendDiagnostic("会话停止（用户操作）")
        }
        statusValue.stringValue = "STOPPING…"
        statusValue.textColor = C_YELLOW
        actionButton.isEnabled = false
        uiTimer?.invalidate()
        uiTimer = nil

        let client = process
        let player = coreAudioPlayer
        // 记录本次要收尾的会话号：旧会话的异步清理不能杀掉新会话刚拉起的采集进程
        let endedSession = sessionID
        // 主线程先抓取目标设备，避免后台队列读取 activeDevice 造成竞争
        let endedDevice = activeDevice

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

                self.cleanupPhoneServer(serial: endedDevice, endingSession: endedSession)
                if let saved = self.savedPhoneVolume, self.phoneMediaVolume(serial: endedDevice) == 0 {
                    self.setPhoneMediaVolume(saved, serial: endedDevice)
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
        phoneVolTimer?.invalidate()
        phoneVolTimer = nil
        volumeWatchFallbackTimer?.invalidate()
        volumeWatchFallbackTimer = nil
        volumeWatchActive = false
        volumeWatchPort = -1
        volumeQueryInFlight = false
        volumeQueryFailures = 0
        heartbeatFailures = 0
        lastPCMBytes = 0
        lastPCMAt = Date.distantPast
        lastRTTSampleAt = Date.distantPast
        // 会话结束：增益回到 1，手机音量行复位
        coreAudioPlayer?.setGain(1)
        phoneVolValue.stringValue = "手机 —"
        phoneVolValue.textColor = C_DIM
        sessionActive = false
        stopping = false
        // 会话结束，释放空闲休眠阻止断言
        self.updateSleepAssertion()
        process = nil
        coreAudioPlayer = nil
        startTime = nil
        activeDevice = nil
        // 自动恢复期间保持 RECONNECTING 提示，不闪回 IDLE
        if isAutoRecovering {
            statusValue.stringValue = "RECONNECTING…"
            statusValue.textColor = C_YELLOW
        } else {
            statusValue.stringValue = "IDLE"
            statusValue.textColor = C_YELLOW
            transportValue.stringValue = "手机需与 Mac 同一 Wi-Fi"
            transportValue.toolTip = nil
            transportValue.textColor = C_DIM
        }
        uptimeValue.stringValue = "00:00"
        dataValue.stringValue = "0.0 MB"
        setSettingsEnabled(true)
        // 会话结束后 Auto 档恢复简短显示，实际目标值仍在下次 Start 时写入
        bufferPopup.item(at: 0)?.title = "Auto"
        bufferPopup.title = "Auto"
        // 回到空闲态：重新展开设备条供重新选择（退出 App 与自动恢复时不做）
        if !isTerminating && !isAutoRecovering {
            expandDeviceStrip()
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isTerminating = true
        if sessionActive || process != nil || coreAudioPlayer != nil {
            stopStream { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }
}
