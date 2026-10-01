import AppKit
import Observation

/// Owns the app's real AppKit full-screen transition. This uses macOS Spaces,
/// the standard green window button, and the system enter/exit animations.
@MainActor
@Observable
final class PlayerWindowCoordinator: NSObject {
    static let shared = PlayerWindowCoordinator()

    private(set) var isFullScreen = false
    private weak var window: NSWindow?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: nil
        )
    }

    func bind(_ window: NSWindow) {
        self.window = window
        window.collectionBehavior.insert(.fullScreenPrimary)
        isFullScreen = window.styleMask.contains(.fullScreen)
    }

    func toggleFullScreen() {
        guard let window else { return }
        // Floating windows cannot participate reliably in a system full-screen
        // Space. The view restores the requested level after full screen exits.
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        isFullScreen = true
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        isFullScreen = false
    }
}
