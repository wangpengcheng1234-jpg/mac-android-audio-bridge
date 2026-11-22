import AVFoundation
import CoreAudio
import Darwin
import Foundation

struct CoreAudioSnapshot {
    let receivedPCMBytes: UInt64
    let renderedFrames: UInt64
    let underflowEvents: UInt64
    let underflowFrames: UInt64
    let overflowEvents: UInt64
    let overflowFrames: UInt64
    let rebufferEvents: UInt64
    let availableFrames: Int
    let targetFrames: Int
    let state: UInt32
    let consumptionRatePPM: Int32

    init(_ value: PCMRingSnapshot) {
        receivedPCMBytes = value.receivedPCMBytes
        renderedFrames = value.renderedFrames
        underflowEvents = value.underflowEvents
        underflowFrames = value.underflowFrames
        overflowEvents = value.overflowEvents
        overflowFrames = value.overflowFrames
        rebufferEvents = value.rebufferEvents
        availableFrames = value.availableFrames
        targetFrames = value.targetFrames
        state = value.state
        consumptionRatePPM = value.consumptionRatePPM
    }

    var bufferMs: Int { availableFrames / 48 }
    var targetMs: Int { targetFrames / 48 }
}

final class CoreAudioPlayer {
    static let sampleRate = 48_000
    private static let channels = 2
    private static let bytesPerFrame = 8
    private static let protocolHeaderSize = 16

    private let ring: OpaquePointer
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let controlQueue = DispatchQueue(label: "com.spyblue.phoneaudio.coreaudio.control")
    private var controlTimer: DispatchSourceTimer?
    private let lifecycleLock = NSLock()
    private let logLock = NSLock()

    private var listenFD: Int32 = -1
    private var connectionFD: Int32 = -1
    private var socketPath = ""
    private var running = false
    private var stopping = false
    private var stopped = false
    private var stopCompletions: [() -> Void] = []
    private var selectedDeviceID = AudioDeviceID(0)
    private var startedAt = Date()
    private var firstPCMReceived = false

    private let autoBuffer: Bool
    private(set) var targetBufferMs: Int
    /// 物理下限：CoreAudio 一次回调 + 一包音频的最小可播放时长，不能再低
    private let hardFloorMs = 20
    /// 已确认「会欠载」的下界（初始等于物理下限）
    private var floorMs: Int = 20
    /// 已确认「稳定播放」的最低值
    private var bestStableMs: Int = 0
    private var stableTicks = 0
    private var probing = false
    private var probeBaseMs = 0
    private var minAvailableFrames = Int.max
    private var lastUnderflowEvents: UInt64 = 0
    private var adaptationCooldown = 0
    /// 判定稳定所需的连续秒数
    private let stableWindow = 60
    private var currentRatePPM: Int32 = 1_000_000
    /// 水位慢速积分修正（消除稳态偏差，减少周期性欠载）
    private var waterLevelBiasPPM: Int32 = 0
    /// 为了 128 帧低延迟缓冲而临时改动的设备缓冲原值
    private var previousDeviceBufferFrames: UInt32?
    private var deviceForBufferRestore: AudioDeviceID?
    private var debugLog: FileHandle?
    private let debugEnabled = ProcessInfo.processInfo.environment["ITRAE_AUDIO_DEBUG"] == "1"

    var onFirstPCM: (() -> Void)?
    /// 引擎事件回调（输出设备切换、引擎被系统停止等），用于写入诊断日志
    var onEngineEvent: ((String) -> Void)?
    /// 设备变更通知 / 默认输出设备监听
    private var configObserver: NSObjectProtocol?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    var onFailure: ((String) -> Void)?
    var onTargetBufferChange: ((Int) -> Void)?

    init(targetBufferMs: Int, autoBuffer: Bool) throws {
        self.autoBuffer = autoBuffer
        self.targetBufferMs = min(500, max(20, targetBufferMs))
        self.bestStableMs = self.targetBufferMs
        self.floorMs = hardFloorMs
        guard let ring = pcm_ring_create(Self.sampleRate) else {
            throw NSError(domain: "CoreAudioPlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法分配 PCM 环形缓冲"])
        }
        self.ring = ring
        pcm_ring_set_target_frames(ring, self.targetBufferMs * 48)
        configureEngine()
        if debugEnabled {
            let path = "/tmp/phone-audio-coreaudio.log"
            FileManager.default.createFile(atPath: path, contents: nil)
            debugLog = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try? debugLog?.truncate(atOffset: 0)
        }
    }

    deinit {
        engine.stop()
        closeDescriptors()
        if let log = debugLog {
            try? log.close()
        }
        pcm_ring_destroy(ring)
    }

    private func configureEngine() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(Self.sampleRate),
                                         channels: AVAudioChannelCount(Self.channels),
                                         interleaved: false) else {
            fatalError("Unsupported CoreAudio PCM format")
        }
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBuffers in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBuffers)
            guard buffers.count >= 2,
                  let leftData = buffers[0].mData,
                  let rightData = buffers[1].mData else {
                return noErr
            }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            _ = pcm_ring_render(ring, left, right, Int(frameCount))
            return noErr
        }
        sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    /// Starts the listener and output engine without changing the system default output.
    func start() throws -> String {
        lifecycleLock.lock()
        stopped = false
        stopping = false
        running = true
        startedAt = Date()
        lifecycleLock.unlock()

        do {
            socketPath = try makeListener()
            selectedDeviceID = try Self.defaultOutputDevice()
            var deviceID = selectedDeviceID
            guard let outputAudioUnit = engine.outputNode.audioUnit else {
                throw NSError(domain: "CoreAudioPlayer", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "无法访问 CoreAudio 输出单元"])
            }
            let status = AudioUnitSetProperty(outputAudioUnit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw NSError(domain: "CoreAudioPlayer", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "无法绑定当前 Mac 输出设备（\(status)）"])
            }
            // 先把设备缓冲压到 128 帧再启动，省 4~8 ms 输出延迟
            tuneDeviceBuffer(deviceID)
            engine.prepare()
            try engine.start()
            startControlTimer()
            observeOutputDeviceChanges()
            Thread.detachNewThread { [weak self] in
                self?.acceptAndRead()
            }
            log("START target=\(targetBufferMs)ms auto=\(autoBuffer) outputID=\(selectedDeviceID)")
            return socketPath
        } catch {
            lifecycleLock.lock()
            running = false
            lifecycleLock.unlock()
            engine.stop()
            restoreDeviceBuffer()
            closeDescriptors()
            throw error
        }
    }

    /// 跟随手机媒体音量的软件增益（0~1），不改变 Mac 音量
    func setGain(_ value: Float) {
        pcm_ring_set_gain(ring, value)
    }

    /// 监听输出设备变化。
    ///
    /// 两个必须处理的场景（不处理就会「明明在推流却没声音」）：
    /// 1. 系统默认输出设备变了（插拔耳机、接上蓝牙）→ AVAudioEngine 自身**会停止**，
    ///    并发出 AVAudioEngineConfigurationChange；不重启就永久静音。
    /// 2. 当前绑定的设备被移除 → 引擎同样停止。
    private func observeOutputDeviceChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleOutputDeviceChange(reason: "AVAudioEngineConfigurationChange")
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChange(reason: "默认输出设备变更")
        }
        defaultDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func handleOutputDeviceChange(reason: String) {
        guard running, !stopping else { return }
        let snapshotDeviceID = selectedDeviceID
        // 设备切换瞬间 HAL 还没稳定，稍等一下再重绑
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.rebindToDefaultOutput(reason: reason, previousDevice: snapshotDeviceID)
        }
    }

    /// 把输出单元重新绑到当前系统默认输出设备并重启引擎
    private func rebindToDefaultOutput(reason: String, previousDevice: AudioDeviceID) {
        guard running, !stopping else { return }
        guard let newID = try? Self.defaultOutputDevice(), newID != 0 else {
            onEngineEvent?("输出设备切换失败：读不到默认输出设备")
            return
        }
        let oldName = Self.deviceName(previousDevice)
        let newName = Self.deviceName(newID)
        let wasRunning = engine.isRunning

        // 换设备前先把旧设备的缓冲大小还原，避免把它一直留在 128 帧
        if newID != previousDevice { restoreDeviceBuffer() }

        if !wasRunning { engine.stop() }
        selectedDeviceID = newID
        var deviceID = newID
        guard let au = engine.outputNode.audioUnit else {
            onEngineEvent?("输出设备切换失败：拿不到 output unit")
            return
        }
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0,
                                     &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else {
            onEngineEvent?("输出设备切换失败：绑定 \(newName) 返回 \(st)")
            return
        }
        tuneDeviceBuffer(newID)
        engine.prepare()
        do {
            try engine.start()
            onEngineEvent?("输出设备已切换 → \(newName)（原 \(oldName)，\(reason)，引擎重启\(wasRunning ? "" : "（此前已停止）")）")
        } catch {
            onEngineEvent?("输出设备切换后引擎重启失败：\(error.localizedDescription)")
        }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        guard id != 0 else { return "未知" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return st == noErr ? (name as String) : "未知"
    }

    func snapshot() -> CoreAudioSnapshot {        CoreAudioSnapshot(pcm_ring_snapshot(ring))
    }

    func stop(completion: @escaping () -> Void = {}) {
        lifecycleLock.lock()
        if stopped {
            lifecycleLock.unlock()
            completion()
            return
        }
        if stopping {
            stopCompletions.append(completion)
            lifecycleLock.unlock()
            return
        }
        stopping = true
        running = false
        stopCompletions.append(completion)
        lifecycleLock.unlock()

        pcm_ring_request_stop(ring)
        controlTimer?.cancel()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let block = defaultDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            defaultDeviceListenerBlock = nil
        }
        controlQueue.asyncAfter(deadline: .now() + 0.012) {
            self.engine.stop()
            self.restoreDeviceBuffer()
            self.closeDescriptors()
            self.log("STOP \(self.snapshotDescription())")
            self.logLock.lock()
            try? self.debugLog?.close()
            self.debugLog = nil
            self.logLock.unlock()

            self.lifecycleLock.lock()
            self.stopped = true
            self.stopping = false
            let completions = self.stopCompletions
            self.stopCompletions.removeAll()
            self.lifecycleLock.unlock()
            completions.forEach { $0() }
        }
    }

    private func makeListener() throws -> String {
        let path = "/tmp/itrae-pcm-\(UUID().uuidString).sock"
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else {
            throw NSError(domain: "CoreAudioPlayer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PCM socket 路径过长"])
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.socketError("创建 PCM socket 失败") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        unlink(path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.socketError("绑定 PCM socket 失败")
            Darwin.close(fd)
            throw error
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let error = Self.socketError("监听 PCM socket 失败")
            Darwin.close(fd)
            unlink(path)
            throw error
        }
        _ = chmod(path, mode_t(S_IRUSR | S_IWUSR))
        lifecycleLock.lock()
        listenFD = fd
        lifecycleLock.unlock()
        return path
    }

    private func acceptAndRead() {
        while isRunning() {
            lifecycleLock.lock()
            let fd = listenFD
            lifecycleLock.unlock()
            if fd < 0 { return }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                if isRunning() { reportFailure("PCM listener 异常：\(Self.errnoDescription())") }
                return
            }
            if result == 0 { continue }
            if descriptor.revents & Int16(POLLIN) != 0 {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if isRunning() { reportFailure("接受 PCM 连接失败：\(Self.errnoDescription())") }
                    return
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                lifecycleLock.lock()
                if running {
                    connectionFD = client
                    lifecycleLock.unlock()
                    readConnection(client)
                } else {
                    lifecycleLock.unlock()
                    Darwin.close(client)
                }
                return
            }
            if descriptor.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) != 0,
               isRunning() {
                reportFailure("PCM listener 已关闭")
                return
            }
        }
    }

    private func readConnection(_ fd: Int32) {
        var header: [UInt8] = []
        header.reserveCapacity(Self.protocolHeaderSize)
        var pending: [UInt8] = []
        pending.reserveCapacity(Self.bytesPerFrame * 2)
        var receiveBuffer = [UInt8](repeating: 0, count: 64 * 1024)

        while isRunning() {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 100)
            if pollResult < 0 {
                if errno == EINTR { continue }
                if isRunning() { reportFailure("读取 PCM 失败：\(Self.errnoDescription())") }
                return
            }
            if pollResult == 0 { continue }
            if descriptor.revents & Int16(POLLIN) == 0 {
                if descriptor.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) != 0,
                   isRunning() {
                    reportFailure("scrcpy PCM 连接已断开")
                }
                return
            }
            let count = receiveBuffer.withUnsafeMutableBytes { pointer in
                Darwin.recv(fd, pointer.baseAddress, pointer.count, 0)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if isRunning() { reportFailure("接收 PCM 失败：\(Self.errnoDescription())") }
                return
            }
            if count == 0 {
                if isRunning() { reportFailure(firstPCMReceived ? "scrcpy 已结束音频会话" : "scrcpy 未发送 PCM 数据") }
                return
            }

            var offset = 0
            if header.count < Self.protocolHeaderSize {
                let needed = Self.protocolHeaderSize - header.count
                let used = min(needed, count)
                header.append(contentsOf: receiveBuffer[0..<used])
                offset = used
                if header.count == Self.protocolHeaderSize {
                    do {
                        try Self.validateHeader(header)
                        log("PCM_HEADER rate=48000 channels=2 format=Float32LE")
                    } catch {
                        reportFailure(error.localizedDescription)
                        return
                    }
                }
            }
            guard offset < count else { continue }
            let pcmBytes = count - offset
            pcm_ring_note_received_bytes(ring, pcmBytes)
            pending.append(contentsOf: receiveBuffer[offset..<count])
            let frameBytes = pending.count / Self.bytesPerFrame * Self.bytesPerFrame
            guard frameBytes > 0 else { continue }

            let written = pending.withUnsafeBytes { rawBuffer -> Int in
                let samples = rawBuffer.baseAddress!.assumingMemoryBound(to: Float.self)
                return pcm_ring_write_interleaved(ring, samples, frameBytes / Self.bytesPerFrame)
            }
            let frames = frameBytes / Self.bytesPerFrame
            // 停止过程中 ring 已拒收，剩余数据不算真实溢出
            if written < frames, isRunning() {
                pcm_ring_note_overflow(ring, frames - written)
            }
            pending.removeFirst(frameBytes)

            if !firstPCMReceived {
                firstPCMReceived = true
                DispatchQueue.main.async {
                    self.onFirstPCM?()
                }
            }
        }
    }

    private static func validateHeader(_ header: [UInt8]) throws {
        func u32(_ offset: Int) -> UInt32 {
            UInt32(header[offset]) |
            UInt32(header[offset + 1]) << 8 |
            UInt32(header[offset + 2]) << 16 |
            UInt32(header[offset + 3]) << 24
        }
        guard Array(header[0..<4]) == Array("ITRA".utf8),
              u32(4) == 1, u32(8) == UInt32(sampleRate),
              u32(12) == 2 else {
            throw NSError(domain: "CoreAudioPlayer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "scrcpy PCM 协议头不兼容"])
        }
    }

    private func startControlTimer() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.controlTick() }
        controlTimer = timer
        timer.resume()
    }

    private func controlTick() {
        guard isRunning() else { return }
        if !firstPCMReceived && Date().timeIntervalSince(startedAt) > 10 {
            reportFailure("等待 scrcpy PCM 超时")
            return
        }
        if !Self.deviceIsAlive(selectedDeviceID) {
            reportFailure("Mac 输出设备已断开，音频会话已停止")
            return
        }
        // 看门狗：设备还在但引擎已经被系统停掉（切耳机、系统设置变化、睡眠唤醒）。
        // 这种情况下 scrcpy 还在推流、界面也显示正常，但实际一点声音都没有。
        if !engine.isRunning {
            log("WATCHDOG engine stopped, rebind")
            onEngineEvent?("检测到音频引擎已停止（仍在推流），正在重绑输出设备")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rebindToDefaultOutput(reason: "引擎已停止·看门狗", previousDevice: self.selectedDeviceID)
            }
            return
        }

        let value = snapshot()
        let underflowed = value.underflowEvents > lastUnderflowEvents
        lastUnderflowEvents = value.underflowEvents
        if adaptationCooldown > 0 { adaptationCooldown -= 1 }

        if autoBuffer {
            if value.state == UInt32(PCMRingStatePlaying.rawValue) {
                minAvailableFrames = min(minAvailableFrames, value.availableFrames)
            }

            if underflowed {
                // 发生欠载：当前水位不够，把当前值记为「不稳」，回到上一个已知稳定值
                stableTicks = 0
                minAvailableFrames = Int.max
                if probing {
                    probing = false
                    floorMs = max(floorMs, targetBufferMs)
                    targetBufferMs = probeBaseMs
                    bestStableMs = min(bestStableMs, probeBaseMs)
                    applyTarget(probeBaseMs)
                    adaptationCooldown = 30
                    log("ADAPT probe-fail target=\(probeBaseMs)ms floor=\(floorMs)ms")
                } else {
                    let raised = min(500, targetBufferMs + 8)
                    floorMs = max(floorMs, targetBufferMs)
                    bestStableMs = raised
                    targetBufferMs = raised
                    applyTarget(raised)
                    adaptationCooldown = 60
                    log("ADAPT raise target=\(raised)ms floor=\(floorMs)ms")
                }
            } else {
                stableTicks += 1
                if stableTicks >= stableWindow, adaptationCooldown == 0 {
                    // 连续稳定一个窗口：当前值可作为新的已知稳定点
                    bestStableMs = min(bestStableMs, targetBufferMs)
                    probing = false

                    // 余量充足且上下界之间仍有间隙时，二分下探
                    let headroomFrames = targetBufferMs * 48 * 3 / 10
                    let headroomOk = minAvailableFrames >= headroomFrames
                    if bestStableMs - floorMs > 4, headroomOk {
                        let mid = (floorMs + bestStableMs) / 2
                        let next = max(floorMs + 4, (mid / 4) * 4)
                        if next < targetBufferMs {
                            probeBaseMs = targetBufferMs
                            probing = true
                            applyTarget(next)
                            adaptationCooldown = 5
                            log("ADAPT probe \(targetBufferMs)->\(next)ms floor=\(floorMs) best=\(bestStableMs)")
                        }
                    }
                    stableTicks = 0
                    minAvailableFrames = Int.max
                }
            }
        }

        var desiredRate: Int32 = 1_000_000
        if value.state == UInt32(PCMRingStatePlaying.rawValue) {
            let errorMs = Int32((value.availableFrames - value.targetFrames) / 48)
            // 慢速积分：把稳态水位偏差拉回目标中点，抵消两端时钟的长期漂移
            waterLevelBiasPPM += max(-40, min(40, errorMs * 4))
            waterLevelBiasPPM = max(-1_000, min(1_000, waterLevelBiasPPM))
            // 快速比例项：偏差较大时快速追赶
            if abs(errorMs) > 10 {
                desiredRate += min(5_000, max(-5_000, errorMs * 50))
            }
            desiredRate += waterLevelBiasPPM
        } else {
            waterLevelBiasPPM = 0
        }
        desiredRate = min(1_010_000, max(990_000, desiredRate))
        currentRatePPM += (desiredRate - currentRatePPM) / 4
        pcm_ring_set_consumption_rate_ppm(ring, currentRatePPM)
        if debugEnabled {
            log("STATS \(snapshotDescription())")
        }
    }

    private func applyTarget(_ ms: Int) {
        let clamped = min(500, max(hardFloorMs, ms))
        guard clamped != targetBufferMs else { return }
        targetBufferMs = clamped
        pcm_ring_set_target_frames(ring, clamped * 48)
        let target = clamped
        DispatchQueue.main.async { self.onTargetBufferChange?(target) }
    }

    /// 输出设备缓冲压到 128 帧（48 kHz 下约 2.7 ms），会话结束恢复原值。
    /// 只影响本机 CoreAudio 输出延迟，不改变系统音量与采样率。
    private func tuneDeviceBuffer(_ device: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &current) == noErr,
              current > 128 else { return }

        var want: UInt32 = 128
        guard AudioObjectSetPropertyData(device, &addr, 0, nil, size, &want) == noErr else { return }

        var applied: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &applied) == noErr,
              applied < current else { return }
        previousDeviceBufferFrames = current
        deviceForBufferRestore = device
        log("DEVICE buffer \(current)->\(applied) frames")
    }

    /// 恢复会话开始前的设备缓冲，避免影响其他 App 的输出
    private func restoreDeviceBuffer() {
        guard let previous = previousDeviceBufferFrames, let device = deviceForBufferRestore else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var want = previous
        let size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectSetPropertyData(device, &addr, 0, nil, size, &want) == noErr {
            log("DEVICE buffer restored \(previous) frames")
        }
        previousDeviceBufferFrames = nil
        deviceForBufferRestore = nil
    }

    private func isRunning() -> Bool {
        lifecycleLock.lock()
        let value = running
        lifecycleLock.unlock()
        return value
    }

    private func reportFailure(_ message: String) {
        log("ERROR \(message)")
        guard isRunning() else { return }
        DispatchQueue.main.async {
            self.onFailure?(message)
        }
    }

    private func closeDescriptors() {
        lifecycleLock.lock()
        let client = connectionFD
        let listener = listenFD
        connectionFD = -1
        listenFD = -1
        let path = socketPath
        socketPath = ""
        lifecycleLock.unlock()

        if client >= 0 {
            _ = Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        if listener >= 0 {
            Darwin.close(listener)
        }
        if !path.isEmpty {
            unlink(path)
        }
    }

    private func snapshotDescription() -> String {
        let value = snapshot()
        return "state=\(value.state) level=\(value.bufferMs)ms target=\(value.targetMs)ms " +
               "ratePPM=\(value.consumptionRatePPM) pcmBytes=\(value.receivedPCMBytes) " +
               "underflows=\(value.underflowEvents) missing=\(value.underflowFrames) " +
               "rebuffers=\(value.rebufferEvents) overflows=\(value.overflowEvents) dropped=\(value.overflowFrames)"
    }

    private func log(_ message: String) {
        guard debugEnabled || message.hasPrefix("ERROR") else { return }
        logLock.lock()
        if let log = debugLog {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                try? log.write(contentsOf: data)
            }
        }
        logLock.unlock()
    }

    private static func socketError(_ prefix: String) -> NSError {
        NSError(domain: "CoreAudioPlayer", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(prefix)：\(errnoDescription())"])
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else {
            throw NSError(domain: "CoreAudioPlayer", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "未找到当前 Mac 输出设备"])
        }
        return deviceID
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }
}
