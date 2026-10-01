import Foundation
import Network

final class NetworkAvailabilityMonitor: @unchecked Sendable {
    let updates: AsyncStream<Bool>

    private let monitor = NWPathMonitor()
    private let continuation: AsyncStream<Bool>.Continuation
    private let queue = DispatchQueue(label: "com.classmirror.network-path")

    init() {
        (updates, continuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        monitor.pathUpdateHandler = { [continuation] path in
            continuation.yield(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        continuation.finish()
    }
}
