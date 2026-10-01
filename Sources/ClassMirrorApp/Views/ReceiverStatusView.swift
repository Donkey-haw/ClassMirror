import ClassMirrorCore
import SwiftUI

struct ReceiverStatusView: View {
    let controller: ReceiverController
    let preferences: AppPreferences
    @State private var windowCoordinator = PlayerWindowCoordinator.shared
    @State private var fullScreenControlsVisible = false
    @State private var controlsHideTask: Task<Void, Never>?

    private var presentation: ReceiverPresentation {
        ReceiverPresentation.make(snapshot: controller.snapshot)
    }

    var body: some View {
        Group {
            if case .streaming = controller.snapshot.session {
                player
            } else {
                status
            }
        }
        .background {
            WindowAccessor { window in
                windowCoordinator.bind(window)
                window.title = "ClassMirror"
                window.level = windowCoordinator.isFullScreen
                    ? .normal
                    : (controller.snapshot.keepWindowOnTop ? .floating : .normal)
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.contentMinSize = isStreaming
                    ? CGSize(width: 240, height: 180)
                    : CGSize(width: 480, height: 330)
                window.ensureVisibleOnAvailableScreen()
            }
            .frame(width: 0, height: 0)
        }
        .task {
            if controller.snapshot.service == .stopped {
                await controller.start(configuration: configuration)
            }
        }
        .onChange(of: preferences.playerWindowScale) {
            resizePlayerWindow(preserveMaximizedState: false)
        }
        .onChange(of: controller.videoDimensions) {
            resizePlayerWindow(preserveMaximizedState: true)
        }
        .onChange(of: windowCoordinator.isFullScreen) {
            fullScreenControlsVisible = false
        }
    }

    private var status: some View {
        VStack(spacing: 24) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(presentation.color)
                .symbolEffect(.pulse, isActive: isBusy)

            VStack(spacing: 8) {
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                Text(presentation.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if case let .authenticating(request) = controller.snapshot.session {
                VStack(spacing: 6) {
                    Text("AirPlay PIN")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(request.pin)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AirPlay PIN \(request.pin)")
            }

            controls

            Label(
                preferences.peerToPeerEnabled
                    ? "학교망 직접 연결 모드 · Apple TV와 충돌 가능"
                    : "Apple TV 동시 사용 모드 · 로컬 네트워크",
                systemImage: preferences.peerToPeerEnabled ? "antenna.radiowaves.left.and.right" : "appletv"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let recovery = controller.lastFailure?.recoverySuggestion {
                Text(recovery)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(minWidth: 480, minHeight: 330)
        .padding(32)
    }

    private var player: some View {
        ZStack(alignment: .bottom) {
            MetalVideoView(renderer: controller.videoRenderer)
                .background(Color.black)
                .onTapGesture(count: 2) {
                    windowCoordinator.toggleFullScreen()
                }

            if !windowCoordinator.isFullScreen || fullScreenControlsVisible {
                HStack(spacing: 12) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(presentation.title)
                        .fontWeight(.semibold)
                    Text(presentation.detail)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(controller.snapshot.audioMuted ? "오디오 켜기" : "음소거") {
                        controller.toggleMute()
                    }
                    Menu(preferences.playerWindowScale.title) {
                        ForEach(PlayerWindowScale.allCases) { scale in
                            Button {
                                preferences.playerWindowScale = scale
                            } label: {
                                if preferences.playerWindowScale == scale {
                                    Label(scale.title, systemImage: "checkmark")
                                } else {
                                    Text(scale.title)
                                }
                            }
                        }
                    }
                    Button(windowCoordinator.isFullScreen ? "전체 화면 종료" : "전체 화면") {
                        windowCoordinator.toggleFullScreen()
                    }
                    Button("연결 해제") {
                        Task { await controller.disconnect() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 240, minHeight: 180)
        .onContinuousHover { phase in
            guard windowCoordinator.isFullScreen else { return }
            switch phase {
            case .active:
                showFullScreenControlsTemporarily()
            case .ended:
                controlsHideTask?.cancel()
                fullScreenControlsVisible = false
            }
        }
        .animation(.easeOut(duration: 0.18), value: fullScreenControlsVisible)
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.snapshot.service {
        case .stopped, .failed:
            Button("수신기 켜기") {
                Task { await controller.start(configuration: configuration) }
            }
            .buttonStyle(.borderedProminent)
        case .starting, .restarting:
            ProgressView()
                .controlSize(.small)
        case .ready:
            HStack(spacing: 12) {
                Button("수신기 다시 시작") {
                    Task { await controller.restart(configuration: configuration) }
                }
                Button("수신기 끄기") {
                    Task { await controller.stop() }
                }
            }
        }
    }

    private var configuration: ReceiverConfiguration {
        ReceiverConfiguration(
            receiverName: preferences.receiverName,
            deviceID: preferences.receiverDeviceID,
            requiresPIN: preferences.requiresPIN,
            peerToPeerEnabled: preferences.peerToPeerEnabled,
            audioEnabled: preferences.audioEnabled
        )
    }

    private var isBusy: Bool {
        switch controller.snapshot.service {
        case .starting, .restarting:
            true
        default:
            false
        }
    }

    private var isStreaming: Bool {
        if case .streaming = controller.snapshot.session { return true }
        return false
    }

    private func resizePlayerWindow(preserveMaximizedState: Bool) {
        guard isStreaming, !windowCoordinator.isFullScreen else { return }
        let dimensions = controller.videoDimensions
        let width = dimensions.displayWidth > 0
            ? dimensions.displayWidth
            : dimensions.sourceWidth
        let height = dimensions.displayHeight > 0
            ? dimensions.displayHeight
            : dimensions.sourceHeight
        NSApp.windows.first(where: { $0.title == "ClassMirror" })?.resizeForVideo(
            pixelWidth: width,
            pixelHeight: height,
            scale: preferences.playerWindowScale,
            preserveMaximizedState: preserveMaximizedState
        )
    }

    private func showFullScreenControlsTemporarily() {
        fullScreenControlsVisible = true
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            fullScreenControlsVisible = false
        }
    }
}
