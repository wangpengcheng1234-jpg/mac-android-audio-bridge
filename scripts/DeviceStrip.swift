import Cocoa

// MARK: - 设备模型

enum DeviceKind {
    case usb                // adb devices 里的 USB 设备（序列号不含 ":"）
    case wifiConnected      // adb devices 里已连接的无线设备（含 ":"）
    case wifiDiscovered     // 局域网扫描到、尚未 adb connect 的设备
    case wifiViaUSB         // USB 连着时读到手机 Wi-Fi IP，点击可一键开通无线
    case manual             // “手动输入 IP”卡片

    var badge: String {
        switch self {
        case .usb:           return "USB"
        case .wifiConnected: return "WI-FI"
        case .wifiDiscovered:return "WI-FI"
        case .wifiViaUSB:    return "USB→WI-FI"
        case .manual:        return "手动"
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .usb:           return C_MAGENTA
        case .wifiConnected: return C_CYAN
        case .wifiDiscovered:return C_BLUE
        case .wifiViaUSB:    return C_GREEN
        case .manual:        return C_YELLOW
        }
    }
}

struct FoundDevice: Equatable {
    /// adb 序列号；无线为 "ip:5555"，手动卡片为 "manual"
    let serial: String
    /// 主标题（IP 或 USB 序列号）
    let title: String
    /// 副标题（连接状态说明）
    let subtitle: String
    let kind: DeviceKind

    /// 是否需要先执行 adb connect 才能使用
    var needsConnect: Bool { kind == .wifiDiscovered || kind == .wifiViaUSB }
}

// MARK: - 设备卡片（可点击，选中显绿环）

final class DeviceCard: NSButton {

    let device: FoundDevice
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")

    /// 选中态：绿色描边 + 淡绿底
    var isSelectedDevice = false {
        didSet { animateSelection() }
    }

    init(device: FoundDevice) {
        self.device = device
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 148).isActive = true
        heightAnchor.constraint(equalToConstant: 58).isActive = true

        badgeLabel.stringValue = device.kind.badge
        badgeLabel.font = mono(9, .bold)
        badgeLabel.textColor = device.kind.badgeColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)

        titleLabel.stringValue = device.title
        titleLabel.font = mono(12, .bold)
        titleLabel.textColor = C_WHITE
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        stateLabel.stringValue = device.subtitle
        stateLabel.font = mono(9)
        stateLabel.textColor = C_DIM
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateLabel)

        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            titleLabel.topAnchor.constraint(equalTo: badgeLabel.bottomAnchor, constant: 3),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            stateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        applyStyle(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func animateSelection() {
        guard let layer = layer else { return }
        let targetWidth: CGFloat = isSelectedDevice ? 2.5 : 1.5
        let targetBorder = (isSelectedDevice ? C_GREEN : C_BORDER).cgColor
        let targetFill = (isSelectedDevice
            ? C_GREEN.withAlphaComponent(0.14)
            : NSColor(calibratedWhite: 1, alpha: 0.04)).cgColor
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)

        // layer-backed view 上隐式动画被 AppKit 禁用，这里用显式 CABasicAnimation
        // 同时写入 model 值，防止动画结束后跳变
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(timing)

        let widthAnim = CABasicAnimation(keyPath: "borderWidth")
        widthAnim.fromValue = layer.presentation()?.borderWidth ?? layer.borderWidth
        widthAnim.toValue = targetWidth
        widthAnim.duration = 0.22
        widthAnim.timingFunction = timing
        layer.add(widthAnim, forKey: "selectBorderWidth")
        layer.borderWidth = targetWidth

        let colorAnim = CABasicAnimation(keyPath: "borderColor")
        colorAnim.fromValue = layer.presentation()?.borderColor ?? layer.borderColor
        colorAnim.toValue = targetBorder
        colorAnim.duration = 0.22
        colorAnim.timingFunction = timing
        layer.add(colorAnim, forKey: "selectBorderColor")
        layer.borderColor = targetBorder

        let fillAnim = CABasicAnimation(keyPath: "backgroundColor")
        fillAnim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        fillAnim.toValue = targetFill
        fillAnim.duration = 0.22
        fillAnim.timingFunction = timing
        layer.add(fillAnim, forKey: "selectBackground")
        layer.backgroundColor = targetFill

        CATransaction.commit()
    }

    private func applyStyle(animated: Bool) {
        let border = isSelectedDevice ? C_GREEN : C_BORDER
        let fill = isSelectedDevice ? C_GREEN.withAlphaComponent(0.14) : NSColor(calibratedWhite: 1, alpha: 0.04)
        layer?.borderColor = border.cgColor
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = isSelectedDevice ? 2.5 : 1.5
    }

    /// 悬停高亮（未选中时）
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isSelectedDevice else { return }
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.09).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        guard !isSelectedDevice else { return }
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
    }
}

// MARK: - 设备条容器

final class DeviceStripView: PanelView {

    /// 选中某台设备
    var onSelect: ((FoundDevice) -> Void)?
    /// 手动输入 IP 后点连接
    var onManualConnect: ((String) -> Void)?
    /// 重新扫描
    var onRescan: (() -> Void)?

    private let statusLabel = textLabel("准备扫描…", color: C_DIM, size: 10)
    private let rescanButton = NSButton(title: "↻ 重新扫描", target: nil, action: nil)
    private let cardsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let manualRow = NSView()
    private let manualField = NSTextField()
    private let manualConnect = NSButton(title: "连接", target: nil, action: nil)
    private let manualCancel = NSButton(title: "取消", target: nil, action: nil)

    private var cards: [DeviceCard] = []
    private var renderedSerials: [String] = []
    /// USB 已连接但未开启调试时的提示文案
    private var usbHint: String?
    private(set) var selectedSerial: String?

    override init(title: String, borderColor: NSColor = C_GREEN) {
        super.init(title: title, borderColor: borderColor)
        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildSubviews() {
        // 右上角状态 + 重扫
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        rescanButton.bezelStyle = .inline
        rescanButton.font = mono(10)
        rescanButton.contentTintColor = C_CYAN
        rescanButton.target = self
        rescanButton.action = #selector(rescanTapped)
        rescanButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rescanButton)

        // 卡片横向滚动区
        cardsStack.orientation = .horizontal
        cardsStack.spacing = 10
        cardsStack.alignment = .centerY
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.documentView = cardsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // 手动输入行（默认隐藏）
        manualRow.translatesAutoresizingMaskIntoConstraints = false
        manualRow.isHidden = true
        addSubview(manualRow)

        manualField.placeholderString = "输入手机 IP，如 192.168.1.20"
        manualField.font = mono(12)
        manualField.translatesAutoresizingMaskIntoConstraints = false
        manualRow.addSubview(manualField)

        manualConnect.bezelStyle = .rounded
        manualConnect.font = mono(11, .bold)
        manualConnect.contentTintColor = .white
        manualConnect.bezelColor = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.32, alpha: 1)
        manualConnect.target = self
        manualConnect.action = #selector(manualConnectTapped)
        manualConnect.translatesAutoresizingMaskIntoConstraints = false
        manualRow.addSubview(manualConnect)

        manualCancel.bezelStyle = .inline
        manualCancel.font = mono(11)
        manualCancel.contentTintColor = C_DIM
        manualCancel.target = self
        manualCancel.action = #selector(manualCancelTapped)
        manualCancel.translatesAutoresizingMaskIntoConstraints = false
        manualRow.addSubview(manualCancel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            rescanButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            rescanButton.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            manualRow.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            manualRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            manualRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            manualRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            manualField.leadingAnchor.constraint(equalTo: manualRow.leadingAnchor),
            manualField.centerYAnchor.constraint(equalTo: manualRow.centerYAnchor),
            manualField.trailingAnchor.constraint(equalTo: manualConnect.leadingAnchor, constant: -10),

            manualConnect.centerYAnchor.constraint(equalTo: manualRow.centerYAnchor),
            manualConnect.trailingAnchor.constraint(equalTo: manualCancel.leadingAnchor, constant: -8),
            manualCancel.centerYAnchor.constraint(equalTo: manualRow.centerYAnchor),
            manualCancel.trailingAnchor.constraint(equalTo: manualRow.trailingAnchor),
        ])
    }

    // MARK: 数据刷新

    func setScanning() {
        statusLabel.stringValue = "正在扫描局域网…"
        statusLabel.textColor = C_YELLOW
    }

    func render(_ devices: [FoundDevice], usbHint: String? = nil) {
        // 手动输入模式下不刷新列表，避免打断输入
        guard manualRow.isHidden else { return }
        self.usbHint = usbHint

        let serials = devices.map { $0.serial }

        // 设备集合没变就只更新状态文字，避免自动刷新时卡片闪烁、丢失选中态
        if serials == renderedSerials && !cards.isEmpty {
            let (text, color) = statusText(for: devices)
            statusLabel.stringValue = text
            statusLabel.textColor = color
            return
        }
        renderedSerials = serials

        cardsStack.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()

        for d in devices {
            let card = DeviceCard(device: d)
            card.target = self
            card.action = #selector(cardTapped(_:))
            cardsStack.addArrangedSubview(card)
            cards.append(card)
        }

        // 末尾固定的“手动输入 IP”卡片
        let manual = FoundDevice(serial: "manual",
                                 title: "手动输入 IP",
                                 subtitle: "不在列表里？手动指定",
                                 kind: .manual)
        let manualCard = DeviceCard(device: manual)
        manualCard.target = self
        manualCard.action = #selector(cardTapped(_:))
        cardsStack.addArrangedSubview(manualCard)
        cards.append(manualCard)

        // 列表重建后恢复选中态
        let stillThere = selectedSerial.map { s in cards.contains { $0.device.serial == s } } ?? false
        if !stillThere { selectedSerial = nil }
        for c in cards { c.isSelectedDevice = (c.device.serial == selectedSerial) }

        let (text, color) = statusText(for: devices)
        statusLabel.stringValue = text
        statusLabel.textColor = color
        manualRow.isHidden = true
        scrollView.isHidden = false
    }

    /// 状态栏文案：优先提示未授权/离线这类需要用户动手的情况
    private func statusText(for devices: [FoundDevice]) -> (String, NSColor) {
        if devices.contains(where: { $0.subtitle.contains("未授权") }) {
            return ("设备尚未授权 · 请在手机上允许 USB 调试", C_YELLOW)
        }
        if devices.contains(where: { $0.subtitle.contains("离线") }) {
            return ("设备已离线 · 请重新连接数据线", C_YELLOW)
        }
        if devices.isEmpty, let usbHint {
            return (usbHint, C_YELLOW)
        }
        if devices.isEmpty {
            return ("未发现设备 · 可通过 USB 连接或手动输入 IP", C_YELLOW)
        }
        return ("已发现 \(devices.count) 台设备 · 点按即可连接", C_GREEN)
    }

    func setSelected(serial: String) {
        selectedSerial = serial
        for c in cards { c.isSelectedDevice = (c.device.serial == serial) }
    }

    // MARK: 交互

    @objc private func cardTapped(_ sender: DeviceCard) {
        // 未授权时点了也连不上，直接给出明确指引
        if sender.device.subtitle.contains("未授权") {
            statusLabel.stringValue = "请在手机上允许 USB 调试，连接会自动继续"
            statusLabel.textColor = C_YELLOW
            return
        }
        if sender.device.kind == .manual {
            showManualInput()
        } else {
            setSelected(serial: sender.device.serial)
            onSelect?(sender.device)
        }
    }

    @objc private func rescanTapped() {
        onRescan?()
    }

    private func showManualInput() {
        scrollView.isHidden = true
        manualRow.isHidden = false
        statusLabel.stringValue = "手动指定手机 IP"
        window?.makeFirstResponder(manualField)
    }

    @objc private func manualConnectTapped() {
        let ip = manualField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            manualField.backgroundColor = NSColor(calibratedRed: 0.5, green: 0.15, blue: 0.15, alpha: 1)
            return
        }
        onManualConnect?(ip)
    }

    @objc private func manualCancelTapped() {
        manualRow.isHidden = true
        scrollView.isHidden = false
        manualField.stringValue = ""
    }
}
