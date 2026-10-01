import ClassMirrorCore
import SwiftUI

struct ReceiverPresentation {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    static func make(snapshot: ReceiverSnapshot) -> ReceiverPresentation {
        if case let .failed(failure) = snapshot.service {
            return ReceiverPresentation(
                title: "수신기를 시작할 수 없음",
                detail: failure.message,
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        }

        switch snapshot.session {
        case let .streaming(device, statistics):
            let resolution = statistics.width > 0 ? "\(statistics.width) × \(statistics.height)" : "영상 수신 중"
            let frameRate = statistics.framesPerSecond > 0
                ? " · \(Int(statistics.framesPerSecond.rounded())) fps"
                : ""
            return ReceiverPresentation(
                title: device.identity.name,
                detail: resolution + frameRate,
                symbol: "rectangle.on.rectangle.fill",
                color: .green
            )
        case let .authenticating(request):
            return ReceiverPresentation(
                title: "연결 인증 대기 중",
                detail: request.device.name,
                symbol: "number.square.fill",
                color: .blue
            )
        case .connecting:
            return ReceiverPresentation(
                title: "연결 중",
                detail: "기기와 안전한 세션을 준비하고 있습니다.",
                symbol: "arrow.triangle.2.circlepath",
                color: .blue
            )
        case .waitingForVideo:
            return ReceiverPresentation(
                title: "영상 기다리는 중",
                detail: "연결은 완료되었고 첫 화면을 기다립니다.",
                symbol: "hourglass",
                color: .blue
            )
        case let .interrupted(_, failure):
            return ReceiverPresentation(
                title: "연결이 중단됨",
                detail: failure.message,
                symbol: "wifi.exclamationmark",
                color: .orange
            )
        case .idle:
            break
        }

        switch snapshot.service {
        case let .ready(advertisedName):
            return ReceiverPresentation(
                title: "연결 대기 중",
                detail: "iPad에서 \"\(advertisedName)\"을 선택하세요.",
                symbol: "airplayvideo",
                color: .green
            )
        case .starting, .restarting:
            return ReceiverPresentation(
                title: "수신기 준비 중",
                detail: "로컬 네트워크 서비스를 시작하고 있습니다.",
                symbol: "arrow.triangle.2.circlepath",
                color: .blue
            )
        case .stopped:
            return ReceiverPresentation(
                title: "수신기 꺼짐",
                detail: "수신기를 켜면 iPad의 화면 미러링 목록에 나타납니다.",
                symbol: "airplayvideo",
                color: .secondary
            )
        case let .failed(failure):
            return ReceiverPresentation(
                title: "수신 오류",
                detail: failure.message,
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
    }
}
