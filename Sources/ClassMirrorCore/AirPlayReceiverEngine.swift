import AirPlayCoreC
import Foundation
import OSLog

public actor AirPlayReceiverEngine: ReceiverEngine {
    private let bridge: AirPlayEventBridge
    private var receiverLifetime: ReceiverLifetime?

    public init() {
        bridge = AirPlayEventBridge()
    }

    public func start(configuration: ReceiverConfiguration) async throws(ReceiverFailure) {
        guard receiverLifetime == nil else {
            throw ReceiverFailure(
                code: .invalidTransition,
                message: "AirPlay 수신기가 이미 실행 중입니다."
            )
        }

        guard await LocalNetworkAuthorizer.requestAuthorization() else {
            throw ReceiverFailure(
                code: .localNetworkDenied,
                message: "로컬 네트워크 접근이 허용되지 않았습니다.",
                recoverySuggestion: "시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 ClassMirror를 허용하세요."
            )
        }

        bridge.prepare(configuration: configuration)

        var callbacks = cm_receiver_callbacks_t()
        callbacks.context = Unmanaged.passUnretained(bridge).toOpaque()
        callbacks.on_state = { context, state, errorCode, message in
            eventBridge(context)?.receiveState(
                state,
                errorCode: errorCode,
                message: string(message)
            )
        }
        callbacks.on_connection_request = { context, deviceID, model, name in
            eventBridge(context)?.receiveConnectionRequest(
                deviceID: string(deviceID),
                model: optionalString(model),
                name: string(name)
            ) ?? false
        }
        callbacks.on_pin = { context, pin in
            eventBridge(context)?.receivePIN(string(pin))
        }
        callbacks.on_video = { context, codec, bytes, length, nalCount, localTime, remoteTime in
            guard let bytes, length > 0 else { return }
            eventBridge(context)?.receiveVideo(
                codec: codec,
                data: Data(bytes: bytes, count: length),
                nalCount: Int(nalCount),
                localTime: localTime,
                remoteTime: remoteTime
            )
        }
        callbacks.on_audio_format = {
            context,
            compressionType,
            samplesPerFrame,
            usingScreen,
            isMedia,
            formatIdentifier in
            eventBridge(context)?.receiveAudioFormat(
                AudioFormatInfo(
                    compressionType: compressionType,
                    samplesPerFrame: samplesPerFrame,
                    isScreenAudio: usingScreen,
                    isMedia: isMedia,
                    formatIdentifier: formatIdentifier
                )
            )
        }
        callbacks.on_audio = {
            context,
            compressionType,
            bytes,
            length,
            sequenceNumber,
            rtpTime,
            localTime,
            remoteTime in
            guard let bytes, length > 0 else { return }
            eventBridge(context)?.receiveAudio(
                CompressedAudioSample(
                    compressionType: compressionType,
                    data: Data(bytes: bytes, count: length),
                    sequenceNumber: sequenceNumber,
                    rtpTime: rtpTime,
                    localTimeNanoseconds: localTime,
                    remoteTimeNanoseconds: remoteTime
                )
            )
        }
        callbacks.on_video_size = { context, sourceWidth, sourceHeight, displayWidth, displayHeight in
            eventBridge(context)?.receiveVideoDimensions(
                VideoDimensions(
                    sourceWidth: Int(sourceWidth.rounded()),
                    sourceHeight: Int(sourceHeight.rounded()),
                    displayWidth: Int(displayWidth.rounded()),
                    displayHeight: Int(displayHeight.rounded())
                )
            )
        }
        callbacks.on_log = { context, level, message in
            eventBridge(context)?.receiveLog(level: level, message: string(message))
        }

        guard let createdReceiver = cm_receiver_create(callbacks) else {
            let failure = ReceiverFailure(
                code: .coreUnavailable,
                message: "AirPlay Receiver Core를 생성할 수 없습니다.",
                recoverySuggestion: "앱을 다시 실행한 뒤 수신기를 다시 켜세요."
            )
            bridge.receiveStartFailure(failure)
            throw failure
        }

        let result = configuration.receiverName.withCString { receiverName in
            configuration.deviceID.withCString { deviceID in
                var coreConfiguration = cm_receiver_configuration_t(
                    receiver_name: receiverName,
                    device_id: deviceID,
                    width: 1920,
                    height: 1080,
                    refresh_rate: 60,
                    max_fps: 60,
                    require_pin_each_connection: configuration.requiresPIN,
                    peer_to_peer_enabled: configuration.peerToPeerEnabled,
                    audio_enabled: configuration.audioEnabled
                )
                return cm_receiver_start(createdReceiver, &coreConfiguration)
            }
        }

        guard result == 0 else {
            cm_receiver_destroy(createdReceiver)
            let failure = ReceiverFailure.startFailure(coreCode: Int(result))
            bridge.receiveStartFailure(failure)
            throw failure
        }

        receiverLifetime = ReceiverLifetime(receiver: createdReceiver)
    }

    public func stop() async {
        guard let receiverLifetime else { return }
        receiverLifetime.destroy()
        self.receiverLifetime = nil
        bridge.didStop()
    }

    public func disconnect() async {
        guard let receiver = receiverLifetime?.receiver else { return }
        cm_receiver_disconnect(receiver)
        bridge.didDisconnect()
    }

    nonisolated public func events() -> AsyncStream<ReceiverEngineEvent> {
        bridge.events
    }

    nonisolated public func videoEvents() -> AsyncStream<ReceiverVideoEvent> {
        bridge.videoEvents
    }

    nonisolated public func audioEvents() -> AsyncStream<ReceiverAudioEvent> {
        bridge.audioEvents
    }

}

private final class ReceiverLifetime: @unchecked Sendable {
    private(set) var receiver: OpaquePointer?

    init(receiver: OpaquePointer) {
        self.receiver = receiver
    }

    func destroy() {
        guard let receiver else { return }
        cm_receiver_destroy(receiver)
        self.receiver = nil
    }

    deinit {
        destroy()
    }
}

private final class AirPlayEventBridge: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.classmirror.mac",
        category: "AirPlayCore"
    )
    let events: AsyncStream<ReceiverEngineEvent>
    let videoEvents: AsyncStream<ReceiverVideoEvent>
    let audioEvents: AsyncStream<ReceiverAudioEvent>

    private let eventContinuation: AsyncStream<ReceiverEngineEvent>.Continuation
    private let videoContinuation: AsyncStream<ReceiverVideoEvent>.Continuation
    private let audioContinuation: AsyncStream<ReceiverAudioEvent>.Continuation
    private let lock = NSLock()
    private var configuration = ReceiverConfiguration(receiverName: "ClassMirror")
    private var identity = DeviceIdentity(name: "iPad 또는 iPhone")
    private var connectedDevice: ConnectedDevice?
    private var didPublishReady = false
    private var hasConnection = false
    private var didPublishConnected = false
    private var didPublishVideoStarted = false
    private var videoCodec: VideoCodec = .h264
    private var videoDimensions = VideoDimensions(
        sourceWidth: 0,
        sourceHeight: 0,
        displayWidth: 0,
        displayHeight: 0
    )
    private var audioCodec: String?
    private var newestAACELDRTPTime: UInt32?
    private var frameCount = 0
    private var statisticsStartTime = DispatchTime.now().uptimeNanoseconds

    init() {
        (events, eventContinuation) = AsyncStream.makeStream(
            of: ReceiverEngineEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        // H.264 inter frames and AAC packets must never evict one another.
        // Independent unbounded streams preserve packet order and let each
        // decoder apply its own low-latency policy.
        (videoEvents, videoContinuation) = AsyncStream.makeStream(
            of: ReceiverVideoEvent.self,
            bufferingPolicy: .unbounded
        )
        (audioEvents, audioContinuation) = AsyncStream.makeStream(
            of: ReceiverAudioEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    func prepare(configuration: ReceiverConfiguration) {
        lock.withLock {
            self.configuration = configuration
            resetSessionLocked()
            didPublishReady = false
        }
    }

    func receiveState(_ state: cm_receiver_state_t, errorCode: Int32, message: String) {
        Self.logger.debug("Receiver state=\(state.rawValue, privacy: .public) code=\(errorCode, privacy: .public)")
        switch state {
        case CM_RECEIVER_STATE_READY:
            let event: ReceiverEngineEvent? = lock.withLock {
                if !didPublishReady {
                    didPublishReady = true
                    return .serviceReady(advertisedName: configuration.receiverName)
                }
                guard hasConnection else { return nil }
                resetSessionLocked()
                return .disconnected
            }
            if let event { eventContinuation.yield(event) }

        case CM_RECEIVER_STATE_STREAMING:
            publishVideoStartedIfNeeded()

        case CM_RECEIVER_STATE_INTERRUPTED:
            // Drop bridge-side ownership immediately. The RTSP helper sockets
            // may remain alive briefly, but a retry must be treated as a new
            // session so it can publish a renewed PIN and start video again.
            lock.withLock {
                resetSessionLocked()
            }
            eventContinuation.yield(.connectionInterrupted(ReceiverFailure(
                code: .connectionLost,
                message: message.isEmpty ? "AirPlay 연결이 중단되었습니다." : message,
                recoverySuggestion: "같은 네트워크 연결을 확인하면 자동으로 다시 연결할 수 있습니다."
            )))

        case CM_RECEIVER_STATE_FAILED:
            eventContinuation.yield(.serviceFailed(ReceiverFailure(
                code: .internalError,
                message: message.isEmpty ? "AirPlay 수신기 오류가 발생했습니다." : message,
                recoverySuggestion: errorCode == 0 ? nil : "오류 코드: \(errorCode)"
            )))

        default:
            break
        }
    }

    func receiveConnectionRequest(deviceID: String, model: String?, name: String) -> Bool {
        let event: ReceiverEngineEvent? = lock.withLock {
            guard !hasConnection else { return nil }
            hasConnection = true
            identity = DeviceIdentity(
                name: name.isEmpty ? "iPad 또는 iPhone" : name,
                model: model
            )
            connectedDevice = ConnectedDevice(identity: identity)
            frameCount = 0
            statisticsStartTime = DispatchTime.now().uptimeNanoseconds

            guard !configuration.requiresPIN, let connectedDevice else { return nil }
            didPublishConnected = true
            return .connected(connectedDevice)
        }
        if let event { eventContinuation.yield(event) }
        return true
    }

    func receivePIN(_ pin: String) {
        Self.logger.info("AirPlay PIN challenge received or renewed")
        let request = lock.withLock {
            ConnectionRequest(
                device: identity,
                pin: pin,
                expiresAt: Date().addingTimeInterval(60)
            )
        }
        eventContinuation.yield(.authenticationRequested(request))
    }

    func receiveVideo(
        codec: cm_video_codec_t,
        data: Data,
        nalCount: Int,
        localTime: UInt64,
        remoteTime: UInt64
    ) {
        let translatedCodec: VideoCodec
        switch codec {
        case CM_VIDEO_CODEC_H264:
            translatedCodec = .h264
        case CM_VIDEO_CODEC_H265:
            translatedCodec = .h265
        default:
            translatedCodec = .unknown
        }

        let statisticsEvent: ReceiverEngineEvent? = lock.withLock {
            videoCodec = translatedCodec
            frameCount += 1
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now - statisticsStartTime
            guard elapsed >= 1_000_000_000, let connectedDevice else { return nil }
            let statistics = makeStatisticsLocked(elapsedNanoseconds: elapsed)
            frameCount = 0
            statisticsStartTime = now
            guard didPublishVideoStarted, didPublishConnected else { return nil }
            _ = connectedDevice
            return .statisticsUpdated(statistics)
        }

        videoContinuation.yield(.video(CompressedVideoSample(
            codec: translatedCodec,
            data: data,
            nalCount: nalCount,
            localTimeNanoseconds: localTime,
            remoteTimeNanoseconds: remoteTime
        )))
        if let statisticsEvent { eventContinuation.yield(statisticsEvent) }
    }

    func receiveAudioFormat(_ format: AudioFormatInfo) {
        lock.withLock {
            audioCodec = audioCodecName(compressionType: format.compressionType)
        }
        audioContinuation.yield(.audioFormat(format))
    }

    func receiveAudio(_ sample: CompressedAudioSample) {
        if sample.compressionType == 8 {
            let shouldYield = lock.withLock { () -> Bool in
                guard let newestAACELDRTPTime else {
                    self.newestAACELDRTPTime = sample.rtpTime
                    return true
                }
                let delta = Int32(bitPattern: sample.rtpTime &- newestAACELDRTPTime)
                guard delta > 0 else { return false }
                self.newestAACELDRTPTime = sample.rtpTime
                return true
            }
            guard shouldYield else { return }
        }
        audioContinuation.yield(.audio(sample))
    }

    func receiveVideoDimensions(_ dimensions: VideoDimensions) {
        lock.withLock {
            videoDimensions = dimensions
        }
        videoContinuation.yield(.videoDimensions(dimensions))
    }

    func receiveLog(level: Int32, message: String) {
        guard !message.isEmpty else { return }
        // UxPlay includes the temporary PIN in one informational line. Never
        // persist that secret in unified logging.
        guard !message.contains("AIRPLAY PASSWORD"),
              !message.contains("PIN =") else { return }
        if message.contains("authentication rejected") {
            Self.logger.error("AirPlay authentication rejected: nonce mismatch")
        } else if message.contains("Client authentication success") {
            Self.logger.info("AirPlay authentication succeeded")
        } else if message.contains("Client authentication failure") {
            Self.logger.error("AirPlay authentication failed")
        } else if message.contains("tcp socket was closed by client") {
            Self.logger.notice("AirPlay media socket was closed by client")
        } else if message.contains("error in recv") || message.contains("error  in header recv") {
            Self.logger.error("AirPlay media socket receive error")
        } else if level <= 1 {
            Self.logger.error("\(message, privacy: .public)")
        } else if level <= 4 {
            Self.logger.info("\(message, privacy: .public)")
        }
    }

    func receiveStartFailure(_ failure: ReceiverFailure) {
        eventContinuation.yield(.serviceFailed(failure))
    }

    func didStop() {
        lock.withLock {
            resetSessionLocked()
            didPublishReady = false
        }
    }

    func didDisconnect() {
        lock.withLock {
            resetSessionLocked()
        }
    }

    private func publishVideoStartedIfNeeded() {
        let eventsToPublish: [ReceiverEngineEvent] = lock.withLock {
            guard !didPublishVideoStarted else { return [] }
            let device = connectedDevice ?? ConnectedDevice(identity: identity)
            connectedDevice = device
            var result: [ReceiverEngineEvent] = []
            if !didPublishConnected {
                didPublishConnected = true
                result.append(.connected(device))
            }
            didPublishVideoStarted = true
            result.append(.videoStarted(device, makeStatisticsLocked(elapsedNanoseconds: 0)))
            return result
        }
        for event in eventsToPublish {
            eventContinuation.yield(event)
        }
    }

    private func makeStatisticsLocked(elapsedNanoseconds: UInt64) -> StreamStatistics {
        let fps: Double
        if elapsedNanoseconds == 0 {
            fps = 0
        } else {
            fps = Double(frameCount) / (Double(elapsedNanoseconds) / 1_000_000_000)
        }
        let width = videoDimensions.displayWidth > 0
            ? videoDimensions.displayWidth
            : videoDimensions.sourceWidth
        let height = videoDimensions.displayHeight > 0
            ? videoDimensions.displayHeight
            : videoDimensions.sourceHeight
        return StreamStatistics(
            framesPerSecond: fps,
            width: width,
            height: height,
            videoCodec: videoCodec.rawValue,
            audioCodec: audioCodec
        )
    }

    private func resetSessionLocked() {
        identity = DeviceIdentity(name: "iPad 또는 iPhone")
        connectedDevice = nil
        hasConnection = false
        didPublishConnected = false
        didPublishVideoStarted = false
        videoCodec = .h264
        videoDimensions = VideoDimensions(
            sourceWidth: 0,
            sourceHeight: 0,
            displayWidth: 0,
            displayHeight: 0
        )
        audioCodec = nil
        newestAACELDRTPTime = nil
        frameCount = 0
        statisticsStartTime = DispatchTime.now().uptimeNanoseconds
    }
}

private func eventBridge(_ context: UnsafeMutableRawPointer?) -> AirPlayEventBridge? {
    guard let context else { return nil }
    return Unmanaged<AirPlayEventBridge>.fromOpaque(context).takeUnretainedValue()
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map(String.init(cString:)) ?? ""
}

private func optionalString(_ pointer: UnsafePointer<CChar>?) -> String? {
    let value = string(pointer)
    return value.isEmpty ? nil : value
}

private func audioCodecName(compressionType: UInt8) -> String {
    switch compressionType {
    case 2:
        "ALAC"
    case 4:
        "AAC"
    case 8:
        "AAC-ELD"
    default:
        "Audio \(compressionType)"
    }
}

private extension ReceiverFailure {
    static func startFailure(coreCode: Int) -> ReceiverFailure {
        switch coreCode {
        case -3:
            ReceiverFailure(
                code: .internalError,
                message: "수신기 기기 식별자가 올바르지 않습니다.",
                recoverySuggestion: "ClassMirror 설정을 초기화한 뒤 다시 시도하세요."
            )
        case -4, -8:
            ReceiverFailure(
                code: .serviceRegistrationFailed,
                message: "로컬 네트워크에 ClassMirror를 등록하지 못했습니다.",
                recoverySuggestion: "로컬 네트워크 권한과 방화벽 설정을 확인하세요."
            )
        case -7:
            ReceiverFailure(
                code: .serviceRegistrationFailed,
                message: "AirPlay 수신 포트를 열지 못했습니다.",
                recoverySuggestion: "다른 AirPlay 수신 앱을 종료한 뒤 다시 시도하세요."
            )
        default:
            ReceiverFailure(
                code: .coreUnavailable,
                message: "AirPlay Receiver Core를 시작하지 못했습니다.",
                recoverySuggestion: "수신기를 다시 시작하세요. 오류 코드: \(coreCode)"
            )
        }
    }
}
