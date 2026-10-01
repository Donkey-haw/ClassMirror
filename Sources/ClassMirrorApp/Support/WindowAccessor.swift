import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            configure(window)
        }
    }
}

extension NSWindow {
    func ensureVisibleOnAvailableScreen() {
        let minimumVisibleArea: CGFloat = 96 * 96
        let largestVisibleArea = NSScreen.screens
            .map { frame.intersection($0.visibleFrame) }
            .filter { !$0.isNull }
            .map { $0.width * $0.height }
            .max() ?? 0
        guard largestVisibleArea < minimumVisibleArea,
              let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            return
        }

        var correctedFrame = frame
        correctedFrame.size.width = min(correctedFrame.width, visibleFrame.width)
        correctedFrame.size.height = min(correctedFrame.height, visibleFrame.height)
        correctedFrame.origin = CGPoint(
            x: visibleFrame.midX - correctedFrame.width / 2,
            y: visibleFrame.midY - correctedFrame.height / 2
        )
        setFrame(correctedFrame, display: false)
    }

    func resizeForVideo(
        pixelWidth: Int,
        pixelHeight: Int,
        scale: PlayerWindowScale,
        preserveMaximizedState: Bool
    ) {
        guard pixelWidth > 0, pixelHeight > 0,
              let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        // A rotation changes the stream dimensions, but it must not undo the
        // user's maximized/full-screen choice. Explicit scale menu actions may
        // leave zoom mode before applying their requested size.
        if styleMask.contains(.fullScreen) { return }
        if isZoomed {
            guard !preserveMaximizedState else { return }
            performZoom(nil)
        }

        let displayScale = max(backingScaleFactor, 1)
        let nativePointSize = CGSize(
            width: CGFloat(pixelWidth) / displayScale,
            height: CGFloat(pixelHeight) / displayScale
        )
        let maximumContentSize = CGSize(
            width: visibleFrame.width * 0.9,
            height: visibleFrame.height * 0.9
        )
        let fitMultiplier = min(
            maximumContentSize.width / nativePointSize.width,
            maximumContentSize.height / nativePointSize.height
        )
        let requestedMultiplier = scale.multiplier ?? min(fitMultiplier, 1)
        let capMultiplier = min(fitMultiplier, requestedMultiplier)
        let contentSize = CGSize(
            width: max(nativePointSize.width * capMultiplier, 240),
            height: max(nativePointSize.height * capMultiplier, 180)
        )
        setContentSize(contentSize)
        ensureVisibleOnAvailableScreen()
    }
}
