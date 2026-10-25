import Foundation
import Metal
import Observation
import simd

/// Placeholders until SkyCore supplies real values through `AppModel.skyReadoutProvider`.
struct SkyReadout: Sendable {
    var raDec = "— (SkyCore)"
    var siderealTime = "— (SkyCore)"
    var constellation = "— (SkyCore)"
}

struct DebugSection: Identifiable, Sendable {
    let title: String
    let lines: [String]
    var id: String { title }
}

@MainActor
@Observable
final class AppModel {
    enum AttitudeSource: String, CaseIterable, Identifiable {
        case motion = "Motion"
        case drag = "Drag"
        case fixed = "Fixed sky"
        var id: Self { self }
    }

    enum LightingOverride: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case day = "Day"
        case twilight = "Twilight"
        case night = "Night"
        var id: Self { self }
    }

    /// Which instant of a frame's exposure the attitude is sampled at, as a fraction of the exposure duration
    /// added to the presentation timestamp. Not documented by Apple; settle on hardware by panning at night.
    enum CaptureTimeReference: Double, CaseIterable, Identifiable {
        case earlier = -0.5
        case timestamp = 0
        case midExposure = 0.5
        var id: Self { self }
        var label: String {
            switch self {
            case .earlier: "PTS − exp/2"
            case .timestamp: "PTS"
            case .midExposure: "PTS + exp/2"
            }
        }
    }

    static let nightExposureChoices: [Double] = [1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2]

    let isSimulator: Bool
    let motion = MotionTracker()
    let location = LocationProvider()
    let alignment = HeadingAlignment()
    let look = LookController()
    @ObservationIgnored let capture: CameraCapture?
    @ObservationIgnored private(set) var driver: SceneDriver? = nil
    private(set) var setupError: String? = nil

    // Integration points for SkyCore / the coordinator.
    @ObservationIgnored var overlayProvider: OverlayProvider = HorizonOverlay.frame
    /// Receives taps (drawable pixels) with the frame's context; pick the object and call `alignment.align`.
    @ObservationIgnored var tapHandler: (@MainActor (SIMD2<Double>, OverlayContext) -> Void)? = nil
    /// Sun altitude → 0 (day) … 1 (night). Without it, Auto means day.
    @ObservationIgnored var sunLightingProvider: (@MainActor (Date, ObserverLocation?) -> Double)? = nil
    @ObservationIgnored var skyReadoutProvider: (@MainActor (OverlayContext) -> SkyReadout)? = nil

    var skyOnly = false
    var attitudeSource: AttitudeSource
    var lightingOverride: LightingOverride = .auto
    var redTheme = false
    var showDebug: Bool
    var timeOffsetHours: Double = 0
    var captureTimeReference: CaptureTimeReference = .midExposure
    var nightExposureDuration: Double = 1.0 / 8 {
        didSet { pushNightExposure() }
    }
    var nightStrategy: NightExposureStrategy = .manual {
        didSet { pushNightExposure() }
    }
    private(set) var cameraStatus: CameraCapture.Status = .idle
    private(set) var headingQuality = HeadingQuality()
    private(set) var debugSections: [DebugSection] = []
    private(set) var lastTap: String? = nil
    private(set) var nightProbeRunning = false

    @ObservationIgnored private var refreshTask: Task<Void, Never>? = nil
    @ObservationIgnored private var pushedLighting: Double? = nil

    init() {
        #if targetEnvironment(simulator)
        isSimulator = true
        #else
        isSimulator = false
        #endif
        let defaults = UserDefaults.standard
        showDebug = defaults.bool(forKey: "debug")
        if defaults.bool(forKey: "fixedSky") {
            attitudeSource = .fixed
        } else {
            attitudeSource = isSimulator ? .drag : .motion
        }
        let device = MTLCreateSystemDefaultDevice()
        capture = isSimulator ? nil : device.map { CameraCapture(metalDevice: $0) }

        if let lighting = defaults.string(forKey: "lighting").flatMap(LightingOverride.init(rawValue:)) {
            lightingOverride = lighting
        }
        if defaults.object(forKey: "lookAzimuth") != nil {
            look.azimuth = defaults.double(forKey: "lookAzimuth")
        }
        if defaults.object(forKey: "lookAltitude") != nil {
            look.altitude = defaults.double(forKey: "lookAltitude")
        }
        if let device {
            do {
                driver = try SceneDriver(model: self, device: device)
            } catch {
                setupError = "Renderer: \(error)"
            }
        } else {
            setupError = "Metal is not available"
        }
        if isSimulator { cameraStatus = .unavailable("simulator") }
    }

    var showsCamera: Bool { !skyOnly && cameraStatus == .running }

    var effectiveAttitudeSource: AttitudeSource {
        attitudeSource == .motion && !motion.isRunning ? .drag : attitudeSource
    }

    var lightingBlend: Double {
        switch lightingOverride {
        case .day: 0
        case .twilight: 0.5
        case .night: 1
        case .auto: sunLightingProvider?(skyDate(now: Date()), observer) ?? 0
        }
    }

    func skyDate(now: Date) -> Date {
        attitudeSource == .fixed ? FixedSkyPreset.date : now.addingTimeInterval(timeOffsetHours * 3600)
    }

    var observer: ObserverLocation? {
        attitudeSource == .fixed ? FixedSkyPreset.observer : location.observer
    }

    func activate() async {
        location.start()
        motion.start()
        startRefreshing()
        if let capture {
            cameraStatus = await capture.start()
            pushedLighting = nil
        }
    }

    func deactivate() {
        refreshTask?.cancel()
        refreshTask = nil
        motion.stop()
        location.stop()
        if let capture {
            Task { await capture.stop() }
            if cameraStatus == .running { cameraStatus = .idle }
        }
    }

    func handleTap(at point: SIMD2<Double>, context: OverlayContext) {
        if let tapHandler {
            tapHandler(point, context)
            return
        }
        let (az, alt) = OverlayContext.horizontal(reference: context.referenceDirection(screen: point))
        lastTap = String(format: "tap az %.1f° alt %.1f° at (%.0f, %.0f) px", az, alt, point.x, point.y)
    }

    func refocusFar() {
        guard let capture else { return }
        Task { await capture.refocusFar() }
    }

    func runNightProbe() {
        guard let capture, !nightProbeRunning else { return }
        nightProbeRunning = true
        Task {
            _ = await capture.runNightProbe()
            nightProbeRunning = false
        }
    }

    private func pushNightExposure() {
        guard let capture else { return }
        let duration = nightExposureDuration, strategy = nightStrategy
        Task { await capture.setNightExposure(duration: duration, strategy: strategy) }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refresh() async {
        let latestMotion = motion.buffer.latestSample
        headingQuality.update(accuracyDegrees: location.headingAccuracy, magneticAccuracy: latestMotion?.magneticAccuracy)
        alignment.update(headingAccuracy: location.headingAccuracy)

        var snapshot: CaptureSnapshot?
        if let capture {
            let blend = lightingBlend
            if pushedLighting.map({ abs($0 - blend) > 0.01 }) ?? true {
                await capture.setLighting(blend: blend)
                pushedLighting = blend
            }
            snapshot = await capture.snapshot()
            cameraStatus = snapshot?.status ?? cameraStatus
        }
        debugSections = makeDebugSections(snapshot: snapshot, latestMotion: latestMotion)
    }

    private func makeDebugSections(snapshot: CaptureSnapshot?, latestMotion: MotionSample?) -> [DebugSection] {
        let context = driver?.lastContext
        var sections: [DebugSection] = []

        sections.append(DebugSection(title: "App", lines: [
            AppInfo.summary,
            "Vertex API key: \(AppInfo.hasVertexAPIKey ? "present" : "missing")",
            "Gemma model: \(AppInfo.gemmaModelID ?? "unset")",
        ]))

        var sky: [String] = []
        if let context {
            let (az, alt) = OverlayContext.horizontal(reference: context.viewDirection)
            sky.append(String(format: "view centre alt %.2f° az %.2f°", alt, az))
            let readout = skyReadoutProvider?(context) ?? SkyReadout()
            sky.append("RA/Dec \(readout.raDec)")
            sky.append("sidereal time \(readout.siderealTime)")
            sky.append("constellation \(readout.constellation)")
            sky.append("sky date \(context.skyDate.formatted(date: .abbreviated, time: .standard))")
        }
        sky.append("source \(effectiveAttitudeSource.rawValue), lighting \(String(format: "%.2f", lightingBlend)) (\(LightingPhase(blend: lightingBlend).rawValue))")
        sections.append(DebugSection(title: "Sky", lines: sky))

        var render: [String] = []
        if let driver {
            render.append(String(format: "display %.1f fps, camera frames drawn %.1f fps", driver.displayFramesPerSecond, driver.renderedCameraFramesPerSecond))
            if let latency = driver.cameraToDisplayLatency {
                render.append(String(format: "capture → display %.1f ms", latency * 1000))
            }
            if let age = driver.attitudeSampleAge {
                render.append(String(format: "capture time − motion sample %.1f ms", age * 1000))
            }
        }
        if let context {
            let g = context.camera
            render.append(String(format: "drawable %.0f×%.0f px, scale %.3f px/sensor px", g.drawableSize.x, g.drawableSize.y, g.scale))
        }
        sections.append(DebugSection(title: "Rendering", lines: render))

        var camera: [String] = ["status \(String(describing: cameraStatus))"]
        if let context {
            let i = context.camera.intrinsics
            let fov = i.fieldOfViewDegrees
            camera.append(String(format: "%@ fx %.1f fy %.1f cx %.1f cy %.1f (%.0f×%.0f)", i.isMeasured ? "intrinsics" : "nominal",
                                 i.fx, i.fy, i.cx, i.cy, i.referenceSize.x, i.referenceSize.y))
            camera.append(String(format: "FOV %.2f° × %.2f°", fov.x, fov.y))
        }
        if let stats = capture?.receiver?.statistics, stats.frames > 0 {
            camera.append(String(format: "delivered %.1f fps, %llu frames (%llu with intrinsics, %llu dropped), delivery latency %.1f ms",
                                 stats.framesPerSecond, stats.frames, stats.framesWithIntrinsics, stats.dropped, stats.deliveryLatency * 1000))
            camera.append("frame exposure " + (stats.lastExposureDuration.map { String(format: "%.5f s", $0) } ?? "n/a")
                          + ", ISO " + (stats.lastISO.map { String(format: "%.0f", $0) } ?? "n/a"))
        }
        if let snapshot {
            camera.append("device exposure " + (snapshot.exposureDuration.map { String(format: "%.5f s", $0) } ?? "n/a")
                          + ", ISO " + (snapshot.iso.map { String(format: "%.0f", $0) } ?? "n/a"))
            if let e = snapshot.exposure {
                camera.append("exposure \(e.phase.rawValue): \(e.strategy)"
                              + (e.requestedDuration.map { String(format: ", %.3f s", $0) } ?? "")
                              + (e.requestedISO.map { String(format: ", ISO %.0f", $0) } ?? "")
                              + String(format: ", max frame %.3f s", e.maxFrameDuration))
            }
            let lens = snapshot.lensPosition.map { String(format: "%.3f", $0) } ?? "n/a"
            camera.append("lens position \(lens)\(snapshot.isAdjustingFocus ? " (adjusting)" : "")"
                          + (snapshot.focus.map { ", locked \(String(format: "%.3f", $0.lensPosition)) \($0.source.rawValue)" } ?? ""))
            camera += snapshot.probe?.lines ?? []
            camera += snapshot.nightProbe.map(\.line)
        }
        sections.append(DebugSection(title: "Camera", lines: camera))

        var motionLines: [String] = [motion.isRunning ? "device motion 100 Hz, xTrueNorthZVertical" : (motion.unavailableReason ?? "motion stopped")]
        motionLines.append("rotation matrix: \(motion.buffer.conventionTest.summary)")
        if let lag = motion.buffer.minimumDeliveryLag {
            motionLines.append(String(format: "handler time − CMLogItem.timestamp ≥ %.2f ms", lag * 1000))
        }
        let heading = headingQuality.accuracyDegrees.map { String(format: "±%.0f°", $0) } ?? "invalid"
        let magnetic = latestMotion.map { "\($0.magneticAccuracy)" } ?? "n/a"
        motionLines.append("heading accuracy \(heading), magnetometer calibration \(magnetic)\(headingQuality.needsFigure8 ? " → figure-8" : "")")
        motionLines.append(String(format: "yaw correction %.2f°%@", alignment.yawCorrection * 180 / .pi, alignment.suggestsRealign ? " (re-align suggested)" : ""))
        if let lastTap { motionLines.append(lastTap) }
        sections.append(DebugSection(title: "Motion", lines: motionLines))

        var locationLines = ["authorization \(location.authorization.rawValue)"]
        if let o = observer {
            locationLines.append(String(format: "%.5f, %.5f, %.0f m%@", o.latitude, o.longitude, o.altitude, o.isLive ? "" : " (not live)"))
        }
        if let accuracy = location.horizontalAccuracy {
            locationLines.append(String(format: "horizontal accuracy %.0f m", accuracy))
        }
        sections.append(DebugSection(title: "Location", lines: locationLines))
        return sections
    }
}
