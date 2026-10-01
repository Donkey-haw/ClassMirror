import Foundation

public enum ReceiverEvent: Equatable, Sendable {
    case startRequested
    case serviceStarted(advertisedName: String)
    case serviceRestartRequested
    case serviceFailed(ReceiverFailure)
    case stopRequested
    case authenticationRequested(ConnectionRequest)
    case authenticationAccepted(ConnectedDevice)
    case authenticationRejected
    case videoStarted(ConnectedDevice, StreamStatistics)
    case statisticsUpdated(StreamStatistics)
    case connectionInterrupted(ReceiverFailure)
    case disconnected
    case setAudioMuted(Bool)
    case setKeepWindowOnTop(Bool)
}

public struct ReceiverStateMachine: Sendable {
    public private(set) var snapshot: ReceiverSnapshot

    public init(snapshot: ReceiverSnapshot = ReceiverSnapshot()) {
        self.snapshot = snapshot
    }

    @discardableResult
    public mutating func handle(_ event: ReceiverEvent) throws(ReceiverFailure) -> ReceiverSnapshot {
        switch event {
        case .startRequested:
            guard snapshot.service == .stopped || isServiceFailed else {
                throw invalidTransition("수신기가 이미 시작되었거나 시작 중입니다.")
            }
            snapshot.service = .starting

        case let .serviceStarted(advertisedName):
            guard snapshot.service == .starting || snapshot.service == .restarting else {
                throw invalidTransition("시작 요청 없이 수신 준비 상태로 변경할 수 없습니다.")
            }
            snapshot.service = .ready(advertisedName: advertisedName)

        case .serviceRestartRequested:
            guard snapshot.service.isReady || isServiceFailed else {
                throw invalidTransition("실행 중이거나 실패한 수신기만 다시 시작할 수 있습니다.")
            }
            snapshot.service = .restarting
            snapshot.session = .idle

        case let .serviceFailed(failure):
            snapshot.service = .failed(failure)
            snapshot.session = .idle

        case .stopRequested:
            snapshot.service = .stopped
            snapshot.session = .idle

        case let .authenticationRequested(request):
            guard snapshot.service.isReady else {
                throw invalidTransition("준비된 수신기만 새 연결 요청을 받을 수 있습니다.")
            }
            // UxPlay can issue a fresh PIN while the same AirPlay attempt is
            // still authenticating (for example after a lost/retried RTSP
            // challenge). Always replace the visible request with the newest
            // challenge so the PIN shown by the app matches the core.
            switch snapshot.session {
            case .idle, .authenticating, .interrupted:
                break
            default:
                throw invalidTransition("이미 연결된 기기가 있습니다.")
            }
            snapshot.session = .authenticating(request)

        case let .authenticationAccepted(device):
            switch snapshot.session {
            case .authenticating:
                break
            case .idle where snapshot.service.isReady:
                break
            default:
                throw invalidTransition("수신 대기 또는 인증 중인 세션만 연결할 수 있습니다.")
            }
            snapshot.session = .connecting(device.identity)

        case .authenticationRejected:
            guard case .authenticating = snapshot.session else {
                throw invalidTransition("거절할 인증 요청이 없습니다.")
            }
            snapshot.session = .idle

        case let .videoStarted(device, statistics):
            switch snapshot.session {
            case .connecting, .waitingForVideo:
                snapshot.session = .streaming(device, statistics)
            default:
                throw invalidTransition("연결 중인 기기 없이 영상을 시작할 수 없습니다.")
            }

        case let .statisticsUpdated(statistics):
            guard case let .streaming(device, _) = snapshot.session else {
                throw invalidTransition("활성 영상 스트림이 없습니다.")
            }
            snapshot.session = .streaming(device, statistics)

        case let .connectionInterrupted(failure):
            switch snapshot.session {
            case let .streaming(device, _), let .waitingForVideo(device):
                snapshot.session = .interrupted(device, failure)
            default:
                snapshot.session = .idle
            }

        case .disconnected:
            snapshot.session = .idle

        case let .setAudioMuted(isMuted):
            snapshot.audioMuted = isMuted

        case let .setKeepWindowOnTop(isOnTop):
            snapshot.keepWindowOnTop = isOnTop
        }

        return snapshot
    }

    private var isServiceFailed: Bool {
        if case .failed = snapshot.service { return true }
        return false
    }

    private func invalidTransition(_ message: String) -> ReceiverFailure {
        ReceiverFailure(code: .invalidTransition, message: message)
    }
}
