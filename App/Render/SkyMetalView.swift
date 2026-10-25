import Metal
import QuartzCore
import SwiftUI
import UIKit

/// CAMetalLayer-backed view driven by a CAMetalDisplayLink (up to 120 Hz). Gestures are reported in drawable pixels.
final class SkyMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var onFrame: ((CAMetalDisplayLink.Update, CAMetalLayer) -> Void)?
    var onPan: ((SIMD2<Double>) -> Void)?
    var onTap: ((SIMD2<Double>) -> Void)?

    private var displayLink: CAMetalDisplayLink?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(device: any MTLDevice, pixelFormat: MTLPixelFormat) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        backgroundColor = .black
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if window != nil, displayLink == nil, !bounds.isEmpty {
            startDisplayLink()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            setNeedsLayout()
        }
    }

    private func startDisplayLink() {
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private var pixelScale: Double { Double(traitCollection.displayScale) }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let t = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        onPan?(SIMD2(Double(t.x), Double(t.y)) * pixelScale)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let p = recognizer.location(in: self)
        onTap?(SIMD2(Double(p.x), Double(p.y)) * pixelScale)
    }
}

extension SkyMetalView: @MainActor CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        onFrame?(update, metalLayer)
    }
}

struct SkyView: UIViewRepresentable {
    let driver: SceneDriver

    func makeUIView(context: Context) -> SkyMetalView {
        driver.makeView()
    }

    func updateUIView(_ uiView: SkyMetalView, context: Context) {}
}
