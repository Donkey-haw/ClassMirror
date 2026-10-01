import Foundation
import Network

enum LocalNetworkAuthorizer {
    private static let cache = LocalNetworkAuthorizationCache()

    static func requestAuthorization() async -> Bool {
        await cache.requestAuthorization()
    }
}

private actor LocalNetworkAuthorizationCache {
    private var isGranted = false

    func requestAuthorization() async -> Bool {
        if isGranted { return true }
        let granted = await LocalNetworkAuthorizationRequest().run()
        if granted {
            isGranted = true
        }
        return granted
    }
}

private final class LocalNetworkAuthorizationRequest: @unchecked Sendable {
    private static let serviceType = "_classmirror._tcp"

    private let queue = DispatchQueue(label: "com.classmirror.local-network-authorization")
    private let serviceName = UUID().uuidString
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var didFinish = false

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            queue.async { [self] in
                start()
            }
        }
    }

    private func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.serviceType,
                domain: "local."
            )
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    startBrowser()
                case .failed:
                    finish(false)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 30) { [self] in
                finish(false)
            }
        } catch {
            finish(false)
        }
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed:
                finish(false)
            case let .waiting(error):
                if case let .dns(code) = error, code == -65_570 {
                    finish(false)
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let foundOwnService = results.contains { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return false }
                return name == serviceName
            }
            if foundOwnService {
                finish(true)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func finish(_ granted: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        continuation?.resume(returning: granted)
    }
}
