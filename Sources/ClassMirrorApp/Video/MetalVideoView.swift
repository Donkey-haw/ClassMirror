import CoreImage
import CoreMedia
import CoreVideo
import MetalKit
import SwiftUI

final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var latestPixelBuffer: CVPixelBuffer?
    private weak var view: MTKView?

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        context = device.map { CIContext(mtlDevice: $0) }
        super.init()
    }

    func display(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.withLock {
            latestPixelBuffer = pixelBuffer
        }
        requestDraw()
    }

    func clear() {
        lock.withLock {
            latestPixelBuffer = nil
        }
        requestDraw()
    }

    @MainActor
    func configure(_ view: MTKView) {
        view.device = device
        view.delegate = self
        self.view = view
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.025, 0.025, 0.03, 1)
        // Rendering is driven by decoded frames. A continuously ticking MTKView
        // re-rendered stale frames at 60 Hz and could starve the media consumer.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoResizeDrawable = true
        view.setNeedsDisplay(view.bounds)
    }

    private func requestDraw() {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.view else { return }
            view.setNeedsDisplay(view.bounds)
        }
    }

    @MainActor
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    @MainActor
    func draw(in view: MTKView) {
        guard let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable else {
            return
        }

        clearDrawable(view, commandBuffer: commandBuffer)

        let pixelBuffer = lock.withLock { latestPixelBuffer }
        if let pixelBuffer, let context {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let target = CGRect(
                x: 0,
                y: 0,
                width: drawable.texture.width,
                height: drawable.texture.height
            )
            let fittedImage = aspectFit(image, inside: target)
            context.render(
                fittedImage,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: target,
                colorSpace: colorSpace
            )
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    @MainActor
    private func clearDrawable(_ view: MTKView, commandBuffer: MTLCommandBuffer) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = view.clearColor
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        encoder?.endEncoding()
    }

    private func aspectFit(_ image: CIImage, inside target: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        let scale = min(target.width / source.width, target.height / source.height)
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -source.origin.x,
            y: -source.origin.y
        ))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (target.width - scaled.extent.width) / 2
        let y = (target.height - scaled.extent.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

struct MetalVideoView: NSViewRepresentable {
    let renderer: MetalVideoRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.configure(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
