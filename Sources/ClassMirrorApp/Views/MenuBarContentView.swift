import ClassMirrorCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    let controller: ReceiverController
    let preferences: AppPreferences

    var body: some View {
        Text(serviceLabel)
        Divider()
        Button("창 열기") {
            openWindow(id: "receiver")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Button(controller.snapshot.audioMuted ? "오디오 켜기" : "오디오 음소거") {
            controller.toggleMute()
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])

        Button(controller.snapshot.keepWindowOnTop ? "항상 위 끄기" : "항상 위") {
            controller.toggleKeepOnTop()
        }
        .keyboardShortcut("k")

        Button("연결 해제") {
            Task { await controller.disconnect() }
        }
        .keyboardShortcut("d")
        .disabled(!hasActiveSession)

        Divider()

        if controller.snapshot.service == .stopped {
            Button("수신기 켜기") {
                Task { await controller.start(configuration: configuration) }
            }
        } else {
            Button("수신기 끄기") {
                Task { await controller.stop() }
            }
        }

        SettingsLink {
            Text("설정…")
        }

        Divider()
        Button("ClassMirror 종료") {
            NSApplication.shared.terminate(nil)
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

    private var serviceLabel: String {
        switch controller.snapshot.service {
        case .ready:
            "● 수신 켜짐"
        case .starting, .restarting:
            "● 준비 중"
        case .failed:
            "● 수신 오류"
        case .stopped:
            "○ 수신 꺼짐"
        }
    }

    private var hasActiveSession: Bool {
        controller.snapshot.session != .idle
    }
}
