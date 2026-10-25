import Foundation
import Metal
import QuartzCore
import simd

/// Per display-link tick: newest camera frame + attitude interpolated at that frame's capture time → overlay
/// provider → one draw. In sky-only mode the attitude comes from (smoothed) motion, drag-to-look or the preset.
@MainActor
final class SceneDriver {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let nominalSensorSize = SIMD2<Double>(1920, 1080)
    static let nominalFieldOfView = 70.0

    private unowned let model: AppModel
    private let renderer: Renderer
    private var cameraFrame: CameraFrame?
    private var measuredIntrinsics: CameraIntrinsics?
    private var smoother = AttitudeSmoother()
    private var displayRate = RateMeter()
    private var cameraRate = RateMeter()
    private(set) var lastContext: OverlayContext?
    /// Display time − capture time of the camera frame drawn last.
    private(set) var cameraToDisplayLatency: Double?
    /// Capture time − timestamp of the motion sample used (positive = attitude interpolated, ~0 = clamped to newest).
    private(set) var attitudeSampleAge: Double?

    var displayFramesPerSecond: Double { displayRate.rate }
    var renderedCameraFramesPerSecond: Double { cameraRate.rate }

    init(model: AppModel, device: any MTLDevice) throws {
        self.model = model
        renderer = try Renderer(device: device, pixelFormat: Self.pixelFormat)
    }

    func makeView() -> SkyMetalView {
        let view = SkyMetalView(device: renderer.device, pixelFormat: Self.pixelFormat)
        view.onFrame = { [weak self] update, layer in self?.render(update, layer: layer) }
        view.onPan = { [weak self] delta in self?.pan(delta) }
        view.onTap = { [weak self] point in self?.tap(point) }
        return view
    }

    private func render(_ update: CAMetalDisplayLink.Update, layer: CAMetalLayer) {
        let displayTime = update.targetPresentationTimestamp
        displayRate.tick(at: displayTime)
        let drawableSize = SIMD2(Double(layer.drawableSize.width), Double(layer.drawableSize.height))
        guard drawableSize.x > 0, drawableSize.y > 0 else { return }

        var background = RenderBackground.sky(lighting: model.lightingBlend)
        var hostTime = displayTime
        var attitude: simd_double3x3
        var intrinsics: CameraIntrinsics

        if model.showsCamera, let receiver = model.capture?.receiver {
            if let frame = receiver.takeLatest() {
                cameraFrame = frame
                cameraRate.tick(at: frame.hostTime)
                if let measured = frame.intrinsics { measuredIntrinsics = measured }
            }
        } else {
            cameraFrame = nil
        }

        if let frame = cameraFrame {
            hostTime = frame.hostTime + model.captureTimeReference.rawValue * (frame.exposureDuration ?? 0)
            let sample = model.motion.buffer.attitude(at: hostTime)
            attitude = sample?.matrix ?? model.look.deviceFromReference
            attitudeSampleAge = sample.map { hostTime - $0.timestamp }
            let size = SIMD2(Double(frame.size.x), Double(frame.size.y))
            intrinsics = frame.intrinsics ?? measuredIntrinsics?.scaled(to: size)
                ?? .nominal(size: size, longAxisFOVDegrees: Self.nominalFieldOfView)
            background = .camera(frame)
            cameraToDisplayLatency = displayTime - frame.hostTime
            smoother.reset()
        } else {
            attitude = skyOnlyAttitude(at: displayTime)
            intrinsics = measuredIntrinsics ?? .nominal(size: Self.nominalSensorSize, longAxisFOVDegrees: Self.nominalFieldOfView)
            cameraToDisplayLatency = nil
            attitudeSampleAge = nil
        }

        // The fixed-sky preset must stay repeatable, so it never takes the persisted heading correction.
        if model.effectiveAttitudeSource != .fixed {
            attitude = model.alignment.apply(to: attitude)
        }
        let geometry = CameraGeometry(intrinsics: intrinsics, drawableSize: drawableSize)
        let context = OverlayContext(hostTime: hostTime, displayTime: displayTime, skyDate: model.skyDate(now: Date()),
                                     observer: model.observer, deviceFromReference: attitude, camera: geometry,
                                     lighting: model.lightingBlend, isSkyOnly: cameraFrame == nil,
                                     contentScale: Double(layer.contentsScale))
        lastContext = context
        let overlay = model.overlayProvider(context)
        renderer.draw(to: update.drawable, background: background, geometry: geometry,
                      deviceFromReference: attitude, overlay: overlay, redTheme: model.redTheme,
                      contentScale: context.contentScale)
    }

    func setMilkyWay(levels: [UInt8], width: Int, height: Int) {
        renderer.setMilkyWay(levels: levels, width: width, height: height)
    }

    private func skyOnlyAttitude(at time: Double) -> simd_double3x3 {
        switch model.effectiveAttitudeSource {
        case .motion:
            guard let latest = model.motion.buffer.latestAttitude else { return model.look.deviceFromReference }
            return simd_double3x3(smoother.update(latest.deviceFromReference, at: time))
        case .drag:
            smoother.reset()
            return model.look.deviceFromReference
        case .fixed:
            smoother.reset()
            return LookController.deviceFromReference(azimuth: FixedSkyPreset.azimuth, altitude: FixedSkyPreset.altitude)
        }
    }

    private func pan(_ delta: SIMD2<Double>) {
        guard model.effectiveAttitudeSource == .drag, let context = lastContext else { return }
        model.look.pan(byPixels: delta, radiansPerPixel: context.camera.radiansPerPixel)
    }

    private func tap(_ point: SIMD2<Double>) {
        guard let context = lastContext else { return }
        model.handleTap(at: point, context: context)
    }
}

struct RateMeter {
    private(set) var rate: Double = 0
    private var last: Double?

    mutating func tick(at time: Double) {
        defer { last = time }
        guard let last, time > last else { return }
        let instantaneous = 1 / (time - last)
        rate = rate == 0 ? instantaneous : rate * 0.95 + instantaneous * 0.05
    }
}
