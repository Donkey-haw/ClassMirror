import ClassMirrorCore
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ReceiverController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.classmirror.mac",
        category: "Receiver"
    )
    private(set) var snapshot = ReceiverSnapshot()
    private(set) var lastFailure: ReceiverFailure?
    private(set) var videoDimensions = VideoDimensions(
        sourceWidth: 0,
        sourceHeight: 0,
        displayWidth: 0,
        displayHeight: 0
    )
    private let engine: any ReceiverEngine
    let videoRenderer: MetalVideoRenderer
    private let videoDecoder: H264VideoDecoder
    private let audioDecoder: AirPlayAudioDecoder
    private let audioPlayback: AudioPlaybackController
    private let networkMonitor = NetworkAvailabilityMonitor()
    private var stateMachine = ReceiverStateMachine()
    private var activeConfiguration: ReceiverConfiguration?
    private var eventTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var interruptedSessionRecoveryTask: Task<Void, Never>?

    init(engine: any ReceiverEngine = AirPlayReceiverEngine()) {
        let renderer = MetalVideoRenderer()
        let audioPlayback = AudioPlaybackController()
        self.engine = engine
        videoRenderer = renderer
        self.audioPlayback = audioPlayback
        videoDecoder = H264VideoDecoder(
            onFrame: { [weak renderer] pixelBuffer, presentationTime in
                renderer?.display(pixelBuffer, presentationTime: presentationTime)
            },
            onFailure: { failure in
                fputs("ClassMirror VideoDecoder: \(failure.message) [\(failure.status)]\n", stderr)
            }
        )
        audioDecoder = AirPlayAudioDecoder(
            onOutput: { [weak audioPlayback] decoded in
                audioPlayback?.enqueue(decoded)
            },
            onFailure: { failure in
                fputs("ClassMirror AudioDecoder: \(failure.message) [\(failure.status)]\n", stderr)
            }
        )
    }

    func start(configuration: ReceiverConfiguration) async {
        guard snapshot.service == .stopped || isFailed else { return }
        activeConfiguration = configuration
        transition(.startRequested)
        lastFailure = nil
        observeEvents()
        observeNetworkChanges()

        do {
            try await engine.start(configuration: configuration)
        } catch {
            transition(.serviceFailed(error))
            lastFailure = error
        }
    }

    func stop() async {
        interruptedSessionRecoveryTask?.cancel()
        interruptedSessionRecoveryTask = nil
        activeConfiguration = nil
        await engine.stop()
        resetMediaPipeline()
        transition(.stopRequested)
    }

    func restart(configuration: ReceiverConfiguration) async {
        interruptedSessionRecoveryTask?.cancel()
        interruptedSessionRecoveryTask = nil
        activeConfiguration = configuration
        if snapshot.service == .stopped {
            await start(configuration: configuration)
            return
        }

        transition(.serviceRestartRequested)
        resetMediaPipeline()
        await engine.stop()
        do {
            try await engine.start(configuration: configuration)
        } catch {
            transition(.serviceFailed(error))
            lastFailure = error
        }
    }

    func disconnect() async {
        interruptedSessionRecoveryTask?.cancel()
        interruptedSessionRecoveryTask = nil
        await engine.disconnect()
        resetMediaPipeline()
        transition(.disconnected)
    }

    func toggleMute() {
        transition(.setAudioMuted(!snapshot.audioMuted))
        audioPlayback.setMuted(snapshot.audioMuted)
    }

    func toggleKeepOnTop() {
        transition(.setKeepWindowOnTop(!snapshot.keepWindowOnTop))
    }

    private var isFailed: Bool {
        if case .failed = snapshot.service { return true }
        return false
    }

    private func observeEvents() {
        if eventTask == nil {
            eventTask = Task { [weak self, engine] in
                for await event in engine.events() {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    consume(event)
                }
            }
        }
        if videoTask == nil {
            let videoDecoder = videoDecoder
            videoTask = Task.detached { [weak self, engine, videoDecoder] in
                for await event in engine.videoEvents() {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .video(sample):
                        videoDecoder.decode(sample)
                    case let .videoDimensions(dimensions):
                        await MainActor.run { [weak self] in
                            self?.videoDimensions = dimensions
                        }
                    }
                }
            }
        }
        if audioTask == nil {
            let audioDecoder = audioDecoder
            audioTask = Task.detached { [engine, audioDecoder] in
                for await event in engine.audioEvents() {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .audioFormat(format):
                        audioDecoder.configure(format)
                    case let .audio(sample):
                        audioDecoder.decode(sample)
                    }
                }
            }
        }
    }

    private func observeNetworkChanges() {
        guard networkTask == nil else { return }
        networkTask = Task { [weak self, networkMonitor] in
            var previousAvailability: Bool?
            for await isAvailable in networkMonitor.updates {
                guard !Task.isCancelled else { return }
                let wasAvailable = previousAvailability
                previousAvailability = isAvailable

                // Activating AWDL produces a new satisfied NWPath while an
                // iPad is beginning P2P pairing. Restarting here tears down
                // the receiver before its PIN callback can arrive. Bonjour
                // and wildcard sockets already follow interface changes in
                // direct mode, so no service restart is necessary there.
                guard let self,
                      let configuration = activeConfiguration,
                      !configuration.peerToPeerEnabled,
                      wasAvailable == false,
                      isAvailable else {
                    continue
                }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      activeConfiguration == configuration,
                      snapshot.service.isReady else {
                    continue
                }
                Self.logger.notice("Local network became available again; restarting receiver registration")
                await restart(configuration: configuration)
            }
        }
    }

    private func consume(_ event: ReceiverEngineEvent) {
        switch event {
        case let .serviceReady(advertisedName):
            transition(.serviceStarted(advertisedName: advertisedName))
        case let .serviceFailed(failure):
            lastFailure = failure
            resetMediaPipeline()
            transition(.serviceFailed(failure))
        case let .authenticationRequested(request):
            interruptedSessionRecoveryTask?.cancel()
            interruptedSessionRecoveryTask = nil
            transition(.authenticationRequested(request))
        case let .connected(device):
            interruptedSessionRecoveryTask?.cancel()
            interruptedSessionRecoveryTask = nil
            transition(.authenticationAccepted(device))
        case let .videoStarted(device, statistics):
            interruptedSessionRecoveryTask?.cancel()
            interruptedSessionRecoveryTask = nil
            transition(.videoStarted(device, statistics))
        case let .statisticsUpdated(statistics):
            transition(.statisticsUpdated(statistics))
        case let .connectionInterrupted(failure):
            lastFailure = failure
            resetMediaPipeline()
            transition(.connectionInterrupted(failure))
            recoverInterruptedSession()
        case .disconnected:
            interruptedSessionRecoveryTask?.cancel()
            interruptedSessionRecoveryTask = nil
            resetMediaPipeline()
            transition(.disconnected)
        }
    }

    private func recoverInterruptedSession() {
        interruptedSessionRecoveryTask?.cancel()
        Self.logger.notice("AirPlay session interrupted; scheduling stale-session cleanup")
        interruptedSessionRecoveryTask = Task { [weak self, engine] in
            // Give an immediate AirPlay retry enough time to publish its new
            // PIN first. A new authentication event cancels this cleanup.
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            await engine.disconnect()
            guard !Task.isCancelled else { return }
            resetMediaPipeline()
            transition(.disconnected)
            interruptedSessionRecoveryTask = nil
            Self.logger.notice("Stale AirPlay session cleared without restarting receiver")
        }
    }

    private func transition(_ event: ReceiverEvent) {
        do {
            snapshot = try stateMachine.handle(event)
        } catch {
            lastFailure = error
        }
    }

    private func clearVideoDimensions() {
        videoDimensions = VideoDimensions(
            sourceWidth: 0,
            sourceHeight: 0,
            displayWidth: 0,
            displayHeight: 0
        )
    }

    private func resetMediaPipeline() {
        videoDecoder.reset()
        videoRenderer.clear()
        audioDecoder.reset()
        audioPlayback.reset()
        clearVideoDimensions()
    }
}
