import Foundation

public enum ReceiverEngineEvent: Sendable {
    case serviceReady(advertisedName: String)
    case serviceFailed(ReceiverFailure)
    case authenticationRequested(ConnectionRequest)
    case connected(ConnectedDevice)
    case videoStarted(ConnectedDevice, StreamStatistics)
    case statisticsUpdated(StreamStatistics)
    case connectionInterrupted(ReceiverFailure)
    case disconnected
}

public struct ReceiverConfiguration: Equatable, Sendable {
    public var receiverName: String
    public var deviceID: String
    public var requiresPIN: Bool
    public var peerToPeerEnabled: Bool
    public var audioEnabled: Bool

    public init(
        receiverName: String,
        deviceID: String = "02:00:00:00:00:01",
        requiresPIN: Bool = true,
        peerToPeerEnabled: Bool = false,
        audioEnabled: Bool = true
    ) {
        self.receiverName = receiverName
        self.deviceID = deviceID
        self.requiresPIN = requiresPIN
        self.peerToPeerEnabled = peerToPeerEnabled
        self.audioEnabled = audioEnabled
    }
}

public enum VideoCodec: String, Equatable, Sendable {
    case h264 = "H.264"
    case h265 = "H.265"
    case unknown = "Unknown"
}

public struct CompressedVideoSample: Equatable, Sendable {
    public let codec: VideoCodec
    public let data: Data
    public let nalCount: Int
    public let localTimeNanoseconds: UInt64
    public let remoteTimeNanoseconds: UInt64

    public init(
        codec: VideoCodec,
        data: Data,
        nalCount: Int,
        localTimeNanoseconds: UInt64,
        remoteTimeNanoseconds: UInt64
    ) {
        self.codec = codec
        self.data = data
        self.nalCount = nalCount
        self.localTimeNanoseconds = localTimeNanoseconds
        self.remoteTimeNanoseconds = remoteTimeNanoseconds
    }
}

public struct AudioFormatInfo: Equatable, Sendable {
    public let compressionType: UInt8
    public let samplesPerFrame: UInt16
    public let isScreenAudio: Bool
    public let isMedia: Bool
    public let formatIdentifier: UInt64

    public init(
        compressionType: UInt8,
        samplesPerFrame: UInt16,
        isScreenAudio: Bool,
        isMedia: Bool,
        formatIdentifier: UInt64
    ) {
        self.compressionType = compressionType
        self.samplesPerFrame = samplesPerFrame
        self.isScreenAudio = isScreenAudio
        self.isMedia = isMedia
        self.formatIdentifier = formatIdentifier
    }
}

public struct CompressedAudioSample: Equatable, Sendable {
    public let compressionType: UInt8
    public let data: Data
    public let sequenceNumber: UInt16
    public let rtpTime: UInt32
    public let localTimeNanoseconds: UInt64
    public let remoteTimeNanoseconds: UInt64

    public init(
        compressionType: UInt8,
        data: Data,
        sequenceNumber: UInt16,
        rtpTime: UInt32,
        localTimeNanoseconds: UInt64,
        remoteTimeNanoseconds: UInt64
    ) {
        self.compressionType = compressionType
        self.data = data
        self.sequenceNumber = sequenceNumber
        self.rtpTime = rtpTime
        self.localTimeNanoseconds = localTimeNanoseconds
        self.remoteTimeNanoseconds = remoteTimeNanoseconds
    }
}

public struct VideoDimensions: Equatable, Sendable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let displayWidth: Int
    public let displayHeight: Int

    public init(sourceWidth: Int, sourceHeight: Int, displayWidth: Int, displayHeight: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

public enum ReceiverVideoEvent: Equatable, Sendable {
    case video(CompressedVideoSample)
    case videoDimensions(VideoDimensions)
}

public enum ReceiverAudioEvent: Equatable, Sendable {
    case audioFormat(AudioFormatInfo)
    case audio(CompressedAudioSample)
}

public protocol ReceiverEngine: Sendable {
    func start(configuration: ReceiverConfiguration) async throws(ReceiverFailure)
    func stop() async
    func disconnect() async
    func events() -> AsyncStream<ReceiverEngineEvent>
    func videoEvents() -> AsyncStream<ReceiverVideoEvent>
    func audioEvents() -> AsyncStream<ReceiverAudioEvent>
}

public actor UnavailableReceiverEngine: ReceiverEngine {
    public init() {}

    public func start(configuration: ReceiverConfiguration) async throws(ReceiverFailure) {
        throw ReceiverFailure(
            code: .coreUnavailable,
            message: "AirPlay Receiver Core가 아직 연결되지 않았습니다.",
            recoverySuggestion: "Phase 0 Core 빌드를 완료한 뒤 수신기를 다시 시작하세요."
        )
    }

    public func stop() async {}
    public func disconnect() async {}

    nonisolated public func events() -> AsyncStream<ReceiverEngineEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated public func videoEvents() -> AsyncStream<ReceiverVideoEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated public func audioEvents() -> AsyncStream<ReceiverAudioEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
