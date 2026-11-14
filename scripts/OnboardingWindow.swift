import Cocoa

/// TransAudio 新手引导 —— Apple 风格模态设置助手
/// 用 NSApp.runModal 模态运行，保证窗口独占事件焦点，按钮事件可靠送达。
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow!
    private let onComplete: () -> Void

    private var currentStep = 0

    // MARK: - Steps

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "waveform",
            title: "欢迎使用 TransAudio",
            subtitle: "把 Android 手机的声音实时送到 Mac 播放\n不依赖蓝牙，走 USB 或 Wi-Fi"
        ),
        OnboardingStep(
            icon: "cable.connector",
            title: "连接数据线",
            subtitle: "用 USB 数据线将手机连接到 Mac\n这是最稳定、零延迟的方式"
        ),
        OnboardingStep(
            icon: "iphone.gen3.radiowaves.left.and.right",
            title: "开启 USB 调试",
            subtitle: "在手机上进入「设置 → 关于手机」\n连续点击「版本号」7 次开启开发者选项\n然后在「开发者选项」中打开「USB 调试」"
        ),
        OnboardingStep(
            icon: "dot.radiowaves.left.and.right",
            title: "无线连接（可选）",
            subtitle: "想用 Wi-Fi 或手机热点？先用 USB 连一次\n之后 App 会自动帮你找到手机，IP 变了也不怕"
        ),
    ]

    // MARK: - Views

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let pageIndicator = NSStackView()
    private var pageDots: [PageDotView] = []
    private let continueButton = NSButton()
    private let skipButton = NSButton()

    // MARK: - Init

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init()
        buildWindow()
    }

    // MARK: - Window

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 440)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "TransAudio 设置"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        // 根视图（与主窗口一致的纯色层背景）
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).cgColor
        window.contentView = root

        // 图标
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = NSColor(calibratedRed: 0.00, green: 0.84, blue: 1.00, alpha: 1)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(iconView)

        // 标题
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)

        // 副标题
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitleLabel)

        // 页面指示器（圆点）
        pageIndicator.orientation = .horizontal
        pageIndicator.alignment = .centerY
        pageIndicator.spacing = 8
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageIndicator)
        for _ in 0..<steps.count {
            let dot = PageDotView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            pageIndicator.addArrangedSubview(dot)
            pageDots.append(dot)
        }

        // 继续按钮
        continueButton.bezelStyle = .rounded
        continueButton.font = .systemFont(ofSize: 14, weight: .semibold)
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(continueButton)

        // 跳过按钮
        skipButton.title = "跳过"
        skipButton.bezelStyle = .inline
        skipButton.font = .systemFont(ofSize: 12, weight: .regular)
        skipButton.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(skipButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            subtitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            subtitleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),

            pageIndicator.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -64),
            pageIndicator.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            continueButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            continueButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            continueButton.widthAnchor.constraint(equalToConstant: 120),
            continueButton.heightAnchor.constraint(equalToConstant: 32),

            skipButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            skipButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])

        showStep(0)
    }

    // MARK: - Modal run

    /// 模态运行引导，结束后自动关闭
    func runModal() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    // MARK: - NSWindowDelegate

    /// 用户点红色关闭按钮时，也要结束模态会话并视为完成，避免 App 卡死
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow == window {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            NSApp.stopModal()
            onComplete()
        }
    }

    // MARK: - Steps

    private func showStep(_ index: Int) {
        guard index >= 0, index < steps.count else { return }
        currentStep = index
        let step = steps[index]

        iconView.image = NSImage(systemSymbolName: step.icon, accessibilityDescription: nil)
        titleLabel.stringValue = step.title
        subtitleLabel.stringValue = step.subtitle
        continueButton.title = index == steps.count - 1 ? "完成" : (index == 0 ? "开始设置" : "下一步")
        for (i, dot) in pageDots.enumerated() {
            dot.isActive = i == index
        }
        skipButton.isHidden = index == steps.count - 1
    }

    // MARK: - Actions

    @objc private func continueTapped() {
        if currentStep < steps.count - 1 {
            showStep(currentStep + 1)
        } else {
            finish()
        }
    }

    @objc private func skipTapped() {
        finish()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        NSApp.stopModal()
        window.close()
        onComplete()
    }
}

// MARK: - Step Model

struct OnboardingStep {
    let icon: String
    let title: String
    let subtitle: String
}

// MARK: - Page Dot

/// 引导步骤指示器的圆点视图
final class PageDotView: NSView {
    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        if isActive {
            NSColor(calibratedRed: 0.00, green: 0.84, blue: 1.00, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: 0.4, alpha: 1).setFill()
        }
        path.fill()
    }
}
