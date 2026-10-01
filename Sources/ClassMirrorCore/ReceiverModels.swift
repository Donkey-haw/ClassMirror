import Foundation

public enum ReceiverServiceState: Equatable, Sendable {
    case stopped
    case starting
    case ready(advertisedName: String)
    case restarting
    case failed(ReceiverFailure)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum ReceiverSessionState: Equatable, Sendable {
    case idle
    case authenticating(ConnectionRequest)
    case connecting(DeviceIdentity)
    case waitingForVideo(ConnectedDevice)
    case streaming(ConnectedDevice, StreamStatistics)
    case interrupted(ConnectedDevice, ReceiverFailure)
}

public struct ConnectionRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let device: DeviceIdentity
    public let pin: String
    public let expiresAt: Date

    public init(id: UUID = UUID(), device: DeviceIdentity, pin: String, expiresAt: Date) {
        self.id = id
        self.device = device
        self.pin = pin
        self.expiresAt = expiresAt
    }
}

public struct DeviceIdentity: Equatable, Sendable {
    public let name: String
    public let model: String?

    public init(name: String, model: String? = nil) {
        self.name = name
        self.model = model
    }
}

public struct ConnectedDevice: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let identity: DeviceIdentity

    public init(id: UUID = UUID(), identity: DeviceIdentity) {
        self.id = id
        self.identity = identity
    }
}

public struct StreamStatistics: Equatable, Sendable {
    public var framesPerSecond: Double
    public var width: Int
    public var height: Int
    public var videoCodec: String
    public var audioCodec: String?

    public init(
        framesPerSecond: Double = 0,
        width: Int = 0,
        height: Int = 0,
        videoCodec: String = "—",
        audioCodec: String? = nil
    ) {
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }
}

public struct ReceiverFailure: Error, Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case coreUnavailable
        case localNetworkDenied
        case serviceRegistrationFailed
        case authenticationFailed
        case connectionLost
        case invalidTransition
        case internalError
    }

    public let code: Code
    public let message: String
    public let recoverySuggestion: String?

    public init(code: Code, message: String, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

public struct ReceiverSnapshot: Equatable, Sendable {
    public var service: ReceiverServiceState
    public var session: ReceiverSessionState
    public var audioMuted: Bool
    public var keepWindowOnTop: Bool

    public init(
        service: ReceiverServiceState = .stopped,
        session: ReceiverSessionState = .idle,
        audioMuted: Bool = false,
        keepWindowOnTop: Bool = false
    ) {
        self.service = service
        self.session = session
        self.audioMuted = audioMuted
        self.keepWindowOnTop = keepWindowOnTop
    }
}
