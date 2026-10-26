import Foundation
import Metal
import QuartzCore
import SkyCore
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
    private var warping = false
    private var displayRate = RateMeter()
    private var cameraRate = RateMeter()
    private(set) var lastContext: OverlayContext?
    private(set) var lastWarp: FrameWarp?
    /// Raw Core Motion attitude (before boresight and correction) behind `lastContext`.
    private(set) var lastCoreMotion: simd_quatd?
    var isWarping: Bool { warping }
    /// Display time − capture time of the camera frame drawn last.
    private(set) var cameraToDisplayLatency: Double?
    /// Capture time − timestamp of the motion sample used (positive = attitude interpolated, ~0 = clamped to newest).
    private(set) var attitudeSampleAge: Double?

    var displayFramesPerSecond: Double { displayRate.rate }
    var renderedCameraFramesPerSecond: Double { cameraRate.rate }

    func resetIntrinsicsCache() {
        measuredIntrinsics = nil
    }

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
        var warp: FrameWarp?
        let lensCalibration = model.activeLensCalibration
        let useCorrection = model.effectiveAttitudeSource != .fixed

        if model.showsCamera, let receiver = model.capture?.receiver {
            if let frame = receiver.takeLatest() {
                cameraFrame = frame
                cameraRate.tick(at: frame.hostTime)
                if let measured = frame.intrinsics { measuredIntrinsics = measured }
                model.autoAlign.submit(frame, forced: model.recorder.storedFull(sequence: frame.sequence))
            }
            updateWarpState(deliveredFPS: receiver.statistics.framesPerSecond)
        } else {
            cameraFrame = nil
        }

        if let frame = cameraFrame {
            let timing = model.calibration.timing ?? .none
            let frameTime = model.captureTime(frameHostTime: frame.hostTime, exposure: frame.exposureDuration)
            let size = SIMD2(Double(frame.size.x), Double(frame.size.y))
            let raw = frame.intrinsics ?? measuredIntrinsics?.scaled(to: size) ?? .nominal(size: size, longAxisFOVDegrees: Self.nominalFieldOfView)
            intrinsics = raw.refined(by: lensCalibration)

            // Warped: the (possibly slow, long-exposure) frame is re-projected to the gyro attitude at display time, and the
            // overlay uses that attitude too. Frame-matched: the overlay uses the attitude at the frame's own time.
            let attitudeTime = warping ? displayTime : frameTime
            let buffer = model.motion.buffer
            let fallback = simd_quatd(model.look.deviceFromReference)
            func coreMotion(at t: Double) -> simd_quatd {
                if warping, let predicted = buffer.predictedAttitude(at: t) { return predicted.deviceFromReference }
                return buffer.attitude(at: t)?.deviceFromReference ?? fallback
            }
            let sample = buffer.attitude(at: attitudeTime)
            let raw0 = coreMotion(at: attitudeTime)
            lastCoreMotion = raw0
            let alignment = model.alignment
            func drawn(at t: Double) -> simd_quatd {
                useCorrection ? alignment.drawnAttitude(coreMotion: coreMotion(at: t), at: t) : coreMotion(at: t)
            }
            let displayAttitude = drawn(at: attitudeTime)
            attitude = simd_double3x3(displayAttitude)
            hostTime = attitudeTime
            attitudeSampleAge = sample.map { attitudeTime - $0.timestamp }
            background = .camera(frame)
            cameraToDisplayLatency = displayTime - frame.hostTime
            smoother.reset()
            warp = FrameWarp(frameTime: frameTime, displayAttitude: displayAttitude, readoutSeconds: timing.readoutSeconds,
                             intrinsics: Self.skyIntrinsics(intrinsics), attitude: { drawn(at: $0) })
        } else {
            attitude = skyOnlyAttitude(at: displayTime)
            lastCoreMotion = simd_quatd(attitude)
            intrinsics = (measuredIntrinsics ?? .nominal(size: Self.nominalSensorSize, longAxisFOVDegrees: Self.nominalFieldOfView))
                .refined(by: lensCalibration)
            cameraToDisplayLatency = nil
            attitudeSampleAge = nil
            if useCorrection { attitude = model.alignment.apply(to: attitude, at: displayTime) }
        }
        lastWarp = warp

        let distortion = lensCalibration.flatMap { $0.hasDistortion ? $0.distortion : nil }
        let geometry = CameraGeometry(intrinsics: intrinsics, drawableSize: drawableSize, distortion: distortion)
        let context = OverlayContext(hostTime: hostTime, displayTime: displayTime, skyDate: model.skyDate(now: Date()),
                                     observer: model.observer, deviceFromReference: attitude, camera: geometry,
                                     lighting: model.lightingBlend, isSkyOnly: cameraFrame == nil,
                                     contentScale: Double(layer.contentsScale))
        lastContext = context
        let overlay = model.overlayProvider(context)
        if let frame = cameraFrame, model.recorder.isRecording {
            model.recorder.recordRender([
                "seq": frame.sequence, "frameHostTime": frame.hostTime, "submittedAt": CACurrentMediaTime(),
                "targetDisplayTime": displayTime, "drawableSize": [drawableSize.x, drawableSize.y],
                "sensorSize": [frame.size.x, frame.size.y], "pixelsPerSensorPixel": geometry.scale,
                "warping": warping, "redTheme": model.redTheme,
            ])
        }
        renderer.draw(to: update.drawable, background: background, geometry: geometry,
                      deviceFromReference: attitude, warp: warp, overlay: overlay, redTheme: model.redTheme,
                      contentScale: context.contentScale, lighting: model.lightingBlend)
    }

    /// Warp when the camera cannot keep up (night exposures, below ~40 fps); stay frame-matched at the day rate, where
    /// the frame is only a few milliseconds old. Hysteresis keeps it from flapping near the threshold.
    private func updateWarpState(deliveredFPS fps: Double) {
        switch model.warpMode {
        case .on: warping = true
        case .off: warping = false
        case .auto:
            guard fps > 0 else { return }
            if warping, fps > 55 { warping = false } else if !warping, fps < 40 { warping = true }
        }
    }

    private static func skyIntrinsics(_ i: CameraIntrinsics) -> SkyCore.CameraIntrinsics {
        SkyCore.CameraIntrinsics(fx: i.fx, fy: i.fy, cx: i.cx, cy: i.cy, bufferWidth: i.referenceSize.x, bufferHeight: i.referenceSize.y)
    }

    /// The view point where the star (or Moon disc) under a tap really is in the camera image, or nil without a frame or
    /// a clear detection. Works in the buffer pixels of the frame the tap landed on, through the warp.
    func snappedScreenPoint(kind: AlignmentCandidate.Kind, near point: SIMD2<Double>) -> SIMD2<Double>? {
        guard model.snapTaps, let frame = cameraFrame, let warp = lastWarp, let context = lastContext, !context.isSkyOnly else { return nil }
        let display = context.camera.mapping.pixel(fromScreen: point)
        let centre = warp.sensorPixel(forDisplayPixel: display)
        guard let window = Self.luminanceWindow(of: frame.pixelBuffer, around: centre, halfSize: 40) else { return nil }
        let found: SIMD2<Double>?
        switch kind {
        case .sun:
            return nil
        case .moon:
            found = TapSnap.moon(in: window, near: centre, radius: max(2, tan(Angle.radians(0.2575)) * warp.intrinsics.fx))
        case .star, .planet:
            found = TapSnap.star(in: window, near: centre, radius: 36)
        }
        return found.map { context.camera.mapping.screen(fromPixel: warp.displayPixel(forSensorPixel: $0)) }
    }

    private static func luminanceWindow(of buffer: CVPixelBuffer, around centre: SIMD2<Double>, halfSize: Int) -> LuminanceWindow? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let x0 = max(0, Int(centre.x) - halfSize), y0 = max(0, Int(centre.y) - halfSize)
        let x1 = min(width, Int(centre.x) + halfSize), y1 = min(height, Int(centre.y) + halfSize)
        let w = x1 - x0, h = y1 - y0
        guard w >= 24, h >= 24 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let source = base.advanced(by: (y0 + row) * rowBytes + x0 * 4).assumingMemoryBound(to: UInt8.self)
            for col in 0..<w {
                // BGRA: 0.114 B + 0.587 G + 0.299 R
                pixels[row * w + col] = UInt8((29 * Int(source[col * 4]) + 150 * Int(source[col * 4 + 1]) + 77 * Int(source[col * 4 + 2])) >> 8)
            }
        }
        return LuminanceWindow(width: w, height: h, origin: SIMD2(Double(x0), Double(y0)), pixels: pixels)
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
