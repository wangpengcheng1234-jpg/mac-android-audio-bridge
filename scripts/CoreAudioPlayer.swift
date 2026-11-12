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
    private var underflowStreak = 0
    private var lastUnderflowEvents: UInt64 = 0
    private var adaptationCooldown = 0
    private var currentRatePPM: Int32 = 1_000_000
    private var debugLog: FileHandle?
    private let debugEnabled = ProcessInfo.processInfo.environment["ITRAE_AUDIO_DEBUG"] == "1"

    var onFirstPCM: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTargetBufferChange: ((Int) -> Void)?

    init(targetBufferMs: Int, autoBuffer: Bool) throws {
        self.autoBuffer = autoBuffer
        self.targetBufferMs = min(500, max(20, targetBufferMs))
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
            engine.prepare()
            try engine.start()
            startControlTimer()
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
            closeDescriptors()
            throw error
        }
    }

    func snapshot() -> CoreAudioSnapshot {
        CoreAudioSnapshot(pcm_ring_snapshot(ring))
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
        controlQueue.asyncAfter(deadline: .now() + 0.012) {
            self.engine.stop()
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
        if !firstPCMReceived && Date().timeIntervalSince(startedAt) > 15 {
            reportFailure("等待 scrcpy PCM 超时")
            return
        }
        if !Self.deviceIsAlive(selectedDeviceID) {
            reportFailure("Mac 输出设备已断开，音频会话已停止")
            return
        }

        let value = snapshot()
        if value.underflowEvents > lastUnderflowEvents {
            underflowStreak += 1
        } else {
            underflowStreak = 0
        }
        lastUnderflowEvents = value.underflowEvents
        if adaptationCooldown > 0 { adaptationCooldown -= 1 }

        if autoBuffer && adaptationCooldown == 0 && underflowStreak >= 2 && targetBufferMs < 500 {
            targetBufferMs = min(500, targetBufferMs + 50)
            pcm_ring_set_target_frames(ring, targetBufferMs * 48)
            adaptationCooldown = 5
            underflowStreak = 0
            let target = targetBufferMs
            DispatchQueue.main.async { self.onTargetBufferChange?(target) }
            log("ADAPT target=\(target)ms underflows=\(value.underflowEvents)")
        }

        var desiredRate: Int32 = 1_000_000
        if value.state == UInt32(PCMRingStatePlaying.rawValue) {
            let errorMs = Int32((value.availableFrames - value.targetFrames) / 48)
            if abs(errorMs) > 10 {
                desiredRate += min(5_000, max(-5_000, errorMs * 50))
            }
        }
        currentRatePPM += (desiredRate - currentRatePPM) / 4
        pcm_ring_set_consumption_rate_ppm(ring, currentRatePPM)
        if debugEnabled {
            log("STATS \(snapshotDescription())")
        }
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
