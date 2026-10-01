import AppKit
import ClassMirrorCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular activation policy is required for the same Space-based
        // system full-screen behavior used by standard macOS applications.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ClassMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var receiver = ReceiverController()
    @State private var preferences = AppPreferences()

    var body: some Scene {
        WindowGroup("ClassMirror", id: "receiver") {
            ReceiverStatusView(controller: receiver, preferences: preferences)
        }
        .defaultSize(width: 520, height: 380)
        .defaultWindowPlacement { content, context in
            let idealSize = content.sizeThatFits(.unspecified)
            let visibleFrame = context.defaultDisplay.visibleRect
            return WindowPlacement(size: CGSize(
                width: min(max(idealSize.width, 520), visibleFrame.width),
                height: min(max(idealSize.height, 380), visibleFrame.height)
            ))
        }
        .commands {
            CommandMenu("Receiver") {
                Button("전체 화면") {
                    PlayerWindowCoordinator.shared.toggleFullScreen()
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button(receiver.snapshot.audioMuted ? "오디오 켜기" : "오디오 음소거") {
                    receiver.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button(receiver.snapshot.keepWindowOnTop ? "항상 위 끄기" : "항상 위") {
                    receiver.toggleKeepOnTop()
                }
                .keyboardShortcut("k")

                Button("연결 해제") {
                    Task { await receiver.disconnect() }
                }
                .keyboardShortcut("d")
                .disabled(receiver.snapshot.session == .idle)
            }
        }

        MenuBarExtra("ClassMirror", systemImage: menuBarSymbol) {
            MenuBarContentView(controller: receiver, preferences: preferences)
        }

        Settings {
            SettingsView(preferences: preferences)
        }
    }

    private var menuBarSymbol: String {
        receiver.snapshot.service.isReady ? "airplayvideo.circle.fill" : "airplayvideo.circle"
    }
}
