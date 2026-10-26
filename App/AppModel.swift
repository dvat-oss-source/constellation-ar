import Foundation
import Metal
import SwiftUI
import Observation
import QuartzCore
import SkyCore
import simd

/// Readouts of the screen centre for the debug panel, supplied through `AppModel.skyReadoutProvider`.
struct SkyReadout: Sendable {
    var raDec = "—"
    var siderealTime = "—"
    var constellation = "—"
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

    /// Whether the camera frame is re-projected to the display-time gyro attitude (night) or drawn frame-matched (day).
    enum WarpMode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case on = "Warp"
        case off = "Frame"
        var id: Self { self }
    }

    /// One-sigma accuracy credited to a tap on a drawn star, and to a tap snapped onto the star's image, degrees.
    static let tapSigma = 1.0
    static let snappedTapSigma = 0.4

    static let nightExposureChoices: [Double] = [1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2]

    let isSimulator: Bool
    let motion = MotionTracker()
    let location = LocationProvider()
    let alignment = HeadingAlignment()
    let autoAlign = AutoAligner()
    let look = LookController()
    @ObservationIgnored let capture: CameraCapture?
    @ObservationIgnored let recorder = SessionRecorder()
    let layers: LayerSettings
    let satellites: SatelliteTracker
    let narrator = Narrator()
    let focus = ConstellationFocus()
    let focusChat = FocusChatModel()
    @ObservationIgnored let engine: SkyEngine
    /// Sky engine for focus overlays (same module; not part of observation).
    var skyEngine: SkyEngine { engine }
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
    var lightingOverride: LightingOverride = .auto {
        didSet { UserDefaults.standard.set(lightingOverride.rawValue, forKey: "lighting") }
    }
    var redTheme = false
    var showDebug: Bool {
        didSet { UserDefaults.standard.set(showDebug, forKey: "debug") }
    }
    var warpMode: WarpMode = .auto
    var snapTaps = true
    var recordingConfig = SessionConfig()
    private(set) var calibration = PrecisionCalibration()
    private(set) var calibrationSource = "none"
    private(set) var recordingStatus: String? = nil
    private(set) var lastRecording: String? = nil
    private(set) var lastFix: String? = nil
    var timeOffsetHours: Double = 0
    var captureTimeReference: CaptureTimeReference = .midExposure
    var nightExposureDuration: Double = 1.0 / 8 {
        didSet { pushNightExposure() }
    }
    var nightStrategy: NightExposureStrategy = .manual {
        didSet { pushNightExposure() }
    }
    private(set) var cameraStatus: CameraCapture.Status = .idle
    private(set) var availableCaptureLenses: [CaptureLens] = []
    var selectedCaptureLens: CaptureLens = .wide {
        didSet {
            guard selectedCaptureLens != oldValue, !suppressLensSwitch else { return }
            UserDefaults.standard.set(selectedCaptureLens.rawValue, forKey: CaptureLens.persistenceKey)
            Task { await switchCaptureLens(revertingTo: oldValue) }
        }
    }
    private(set) var headingQuality = HeadingQuality()
    private(set) var debugSections: [DebugSection] = []
    private(set) var lastTap: String? = nil
    private(set) var nightProbeRunning = false
    private(set) var card: ConstellationCardModel? = nil
    private(set) var pinnedFacts: ConstellationFacts? = nil
    private(set) var pinnedCard: ConstellationCardModel? = nil
    var focusChatPendingScroll = false
    private(set) var objectInfo: ObjectInfo? = nil
    private(set) var skyDataError: String? = nil
    private(set) var skyDataLoaded = false
    private(set) var skyDataLoadSeconds: Double? = nil
    var showLayers: Bool {
        didSet { UserDefaults.standard.set(showLayers, forKey: "showLayers") }
    }
    var showSatellites: Bool {
        didSet { UserDefaults.standard.set(showSatellites, forKey: "showSatellites") }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>? = nil
    @ObservationIgnored private var pushedLighting: Double? = nil
    @ObservationIgnored private var hideCardTask: Task<Void, Never>? = nil
    @ObservationIgnored private var infoTask: Task<Void, Never>? = nil
    @ObservationIgnored private var deepDiveTask: Task<Void, Never>? = nil
    @ObservationIgnored private var autoDeepDiveTask: Task<Void, Never>? = nil
    /// Constellations that already triggered a network deep dive this launch (cache hits are always allowed).
    @ObservationIgnored private var deepDiveRequestedNetwork: Set<String> = []
    @ObservationIgnored private var pendingAutoPinID: String?
    @ObservationIgnored private var suppressLensSwitch = false

    init() {
        #if targetEnvironment(simulator)
        isSimulator = true
        #else
        isSimulator = false
        #endif
        let defaults = UserDefaults.standard
        showDebug = defaults.bool(forKey: "debug")
        showLayers = defaults.bool(forKey: "showLayers")
        showSatellites = defaults.bool(forKey: "showSatellites")
        let layers = LayerSettings(), satellites = SatelliteTracker()
        self.layers = layers
        self.satellites = satellites
        engine = SkyEngine(layers: layers, satellites: satellites)
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
        availableCaptureLenses = isSimulator ? [] : CaptureLens.available()
        selectedCaptureLens = .wide
        if isSimulator { cameraStatus = .unavailable("simulator") }
        if ProcessInfo.processInfo.arguments.contains("-autoPinOri") { pendingAutoPinID = "Ori" }

        overlayProvider = { [weak self, engine] context in
            var frame = engine.frame(context)
            guard let self else { return frame }
            if let id = self.focus.pinnedID, let geometry = self.focus.resources.boundaryGeometry {
                frame.add(FocusOverlay.boundarySegments(id: id, geometry: geometry, context: context, engine: engine))
            }
            if let outlineID = self.focus.outlineConstellationID(engine: engine, layers: self.layers, context: context),
               self.focus.resources.artworkOutlines?.hasOutline(for: outlineID) == true,
               let data = engine.dataForFocus,
               let sky = self.focus.resources.skyOutline(for: outlineID, artwork: data.artwork, catalog: data.catalog) {
                self.focus.beginOutlineIfNeeded(id: outlineID, displayTime: context.displayTime)
                let progress = self.focus.outlineAnimation.progress(at: context.displayTime)
                frame.add(FocusOverlay.outlineSegments(sky: sky, progress: progress, context: context, engine: engine,
                                                       redTheme: self.redTheme))
            }
            return frame
        }
        tapHandler = { [weak self] point, context in self?.handleFocusTap(at: point, context: context) }
        focus.load()
        sunLightingProvider = { [engine] date, observer in engine.nightFactor(date: date, observer: observer) }
        skyReadoutProvider = { [engine] in engine.readout($0) }
        engine.onEvent = { [weak self] in self?.handle($0) }
        motion.setRecorder(recorder)
        capture?.receiver?.setRecorder(recorder)
        reloadCalibration()
        loadSkyData()
        autoAlign.configure(model: self)
    }

    // MARK: Precision

    func reloadCalibration() {
        let loaded = CalibrationStore.load()
        calibration = loaded.calibration
        calibrationSource = loaded.source
        applyLensBoresight()
    }

    /// Phase-6 lens JSON applies to the 1× wide camera only.
    var activeLensCalibration: LensCalibration? {
        selectedCaptureLens == .wide ? calibration.lens : nil
    }

    var showsLensPicker: Bool {
        !isSimulator && cameraStatus == .running && effectiveAttitudeSource == .motion && showsCamera
            && availableCaptureLenses.count > 1
    }

    func applyLensBoresight() {
        if selectedCaptureLens == .wide, let lens = calibration.lens {
            alignment.setBoresight(lens.boresightInDevice)
        } else {
            alignment.setBoresight(simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)))
        }
    }

    private func switchCaptureLens(revertingTo previous: CaptureLens) async {
        guard let capture else { return }
        applyLensBoresight()
        driver?.resetIntrinsicsCache()
        if let failure = await capture.setLens(selectedCaptureLens) {
            suppressLensSwitch = true
            selectedCaptureLens = .wide
            suppressLensSwitch = false
            UserDefaults.standard.set(CaptureLens.wide.rawValue, forKey: CaptureLens.persistenceKey)
            applyLensBoresight()
            if await capture.snapshot().activeLens == nil { cameraStatus = failure }
        }
    }

    /// When the centre row of a frame was exposed: the frame's timestamp, the chosen point of its exposure, and the measured offset.
    func captureTime(frameHostTime: Double, exposure: Double?) -> Double {
        frameHostTime + captureTimeReference.rawValue * (exposure ?? 0) + (calibration.timing?.offsetSeconds ?? 0)
    }

    /// Entry point for star-derived orientation fixes (the plate solver, the multi-star solve and taps all land here).
    /// `fix.hostTime` is a host-clock time (`CACurrentMediaTime` base), best taken from `captureTime(frameHostTime:exposure:)`.
    func ingest(_ fix: StarFix) {
        guard let cm = motion.buffer.attitude(at: fix.hostTime)?.deviceFromReference ?? driver?.lastCoreMotion else { return }
        ingest(fix, coreMotion: cm)
    }

    private func ingest(_ fix: StarFix, coreMotion cm: simd_quatd) {
        alignment.ingest(fix, coreMotion: cm, cumulativeTurn: motion.buffer.cumulativeTurn)
        lastFix = String(format: "%@ ×%d σ %.2f° → ±%.2f°", fix.source.rawValue, fix.starCount, fix.sigmaDegrees, alignment.accuracyDegrees)
        if recorder.isRecording, let line = (try? JSONEncoder().encode(fix)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] {
            recorder.recordTap(line.merging(["accuracyAfter": alignment.accuracyDegrees]) { _, new in new })
        }
    }

    /// Cross-check data: every plate-solve fix, and every outcome on a frame the recorder stored at full resolution.
    func recordPlateSolve(_ frame: AutoAligner.Frame, _ outcome: AutoAligner.Outcome) {
        guard recorder.isRecording else { return }
        var line: [String: Any] = ["seq": frame.sequence, "t": frame.hostTime, "full": frame.forced]
        if let exposure = frame.exposureDuration { line["exposure"] = exposure }
        switch outcome {
        case .fix(let fix, let detected, _):
            guard let encoded = (try? JSONEncoder().encode(fix)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else { return }
            line.merge(encoded) { _, new in new }
            line["outcome"] = "fix"
            line["detected"] = detected
        case .skipped(let reason), .rejected(let reason):
            guard frame.forced else { return }
            line["outcome"] = reason
        case .noSolution(let detected, _):
            guard frame.forced else { return }
            line["outcome"] = "no solution"
            line["detected"] = detected
        }
        recorder.recordPlateSolve(line)
    }

    func startRecording() {
        var meta: [String: Any] = [
            "app": AppInfo.summary, "device": Self.deviceModel, "os": UIDevice.current.systemVersion, "isSimulator": isSimulator,
            "captureTimeReference": captureTimeReference.rawValue, "warpMode": warpMode.rawValue,
            "nightExposure": nightExposureDuration, "nightStrategy": nightStrategy.rawValue,
        ]
        if let observer { meta["observer"] = ["latitude": observer.latitude, "longitude": observer.longitude, "altitude": observer.altitude] }
        if let data = try? JSONEncoder().encode(calibration), let object = try? JSONSerialization.jsonObject(with: data) {
            meta["calibration"] = object
        }
        do {
            try recorder.start(config: recordingConfig, meta: meta)
            lastRecording = nil
        } catch {
            lastRecording = "could not start: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        let test = motion.buffer.conventionTest
        let verdict = test.convention == .matrixIsDeviceFromReference ? "deviceFromReference" : "referenceFromDevice"
        guard let summary = recorder.stop(finalMeta: ["attitudeQuaternionIs": verdict, "rotationConventionTest": test.summary]) else { return }
        recordingStatus = nil
        lastRecording = String(format: "saved %@: %.0f s, %d motion rows, %d frames (%d small, %d full)", summary.name, summary.seconds,
                               summary.motionRows, summary.frames, summary.storedSmall, summary.storedFull)
    }

    private static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private func writeRecordingExtras() {
        guard recorder.isRecording else { recordingStatus = nil; return }
        recordingStatus = recorder.status
        let now = CACurrentMediaTime()
        if let o = observer {
            recorder.recordLocation(["t": now, "latitude": o.latitude, "longitude": o.longitude, "altitude": o.altitude, "live": o.isLive,
                                     "horizontalAccuracy": location.horizontalAccuracy ?? -1, "headingAccuracy": location.headingAccuracy ?? -1,
                                     "trueHeading": location.trueHeading ?? -1])
        }
        guard let o = observer else { return }
        let timing = calibration.timing ?? .none
        for request in recorder.takePredictionRequests() {
            guard let k = request.intrinsics, let cm = motion.buffer.attitude(at: captureTime(frameHostTime: request.hostTime, exposure: request.exposure))
            else { continue }
            let t = captureTime(frameHostTime: request.hostTime, exposure: request.exposure)
            let attitude = alignment.drawnAttitude(coreMotion: cm.deviceFromReference, at: t)
            let date = skyDate(now: Date().addingTimeInterval(t - now))
            var intrinsics = SkyCore.CameraIntrinsics(fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy, bufferWidth: Double(request.width), bufferHeight: Double(request.height))
            if let lens = activeLensCalibration { intrinsics = lens.applied(to: intrinsics) }
            var projector = Projector(pose: CameraPose(referenceToDevice: simd_double3x3(attitude)), intrinsics: intrinsics,
                                      mapping: .identity(bufferWidth: Double(request.width), bufferHeight: Double(request.height)))
            if let lens = activeLensCalibration, lens.hasDistortion { projector.distortion = lens.distortion }
            let objects: [[String: Any]] = engine.predictionObjects(date: date, observer: o, maxMagnitude: 2.5).compactMap { object in
                guard let p = projector.pixel(enu: object.enu), p.x >= 0, p.y >= 0, p.x < Double(request.width), p.y < Double(request.height) else { return nil }
                return ["name": object.name, "mag": object.magnitude, "x": p.x, "y": p.y]
            }
            recorder.recordPredictions(["seq": request.sequence, "t": request.hostTime, "frameTime": t, "objects": objects,
                                        "attitude": [attitude.imag.x, attitude.imag.y, attitude.imag.z, attitude.real],
                                        "readoutSeconds": timing.readoutSeconds, "accuracyDegrees": alignment.accuracyDegrees])
        }
    }

    var showsCamera: Bool { !skyOnly && cameraStatus == .running }

    var focusEdgeTarget: (point: SIMD2<Double>, size: SIMD2<Double>)? {
        guard focus.isPinned, let id = focus.pinnedID, let atlas = focus.resources.atlas, let context = driver?.lastContext,
              let point = FocusEdgeArrow.referenceScreenPoint(id: id, atlas: atlas, engine: engine, context: context) else { return nil }
        return (point, context.camera.drawableSize)
    }

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
        if attitudeSource == .fixed { return FixedSkyPreset.observer }
        // The simulator has no GPS fix unless one is set, so it borrows the preset's place.
        return location.observer ?? (isSimulator ? FixedSkyPreset.observer : nil)
    }

    func activate() async {
        location.start()
        motion.start()
        startRefreshing()
        satellites.start { [weak self] in
            guard let self, let o = self.observer else { return nil }
            return (self.skyDate(now: Date()), GeoLocation(latitude: o.latitude, longitude: o.longitude, height: o.altitude))
        }
        if let capture {
            await capture.setInitialLens(.wide)
            cameraStatus = await capture.start()
            applyLensBoresight()
            let saved = CaptureLens.loadPersisted(available: availableCaptureLenses)
            if saved != .wide, availableCaptureLenses.contains(saved) {
                suppressLensSwitch = true
                selectedCaptureLens = saved
                suppressLensSwitch = false
                await switchCaptureLens(revertingTo: .wide)
            }
            pushedLighting = nil
        }
    }

    func deactivate() {
        refreshTask?.cancel()
        refreshTask = nil
        satellites.stop()
        narrator.stop()
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
        handleFocusTap(at: point, context: context)
    }

    func handleFocusTap(at point: SIMD2<Double>, context: OverlayContext) {
        if focus.tapMode == .align {
            focus.tapMode = .explore
            performAlignTap(at: point, context: context)
            return
        }
        if let hit = focus.constellation(at: point, engine: engine, context: context) {
            pinConstellation(id: hit.id, name: hit.name, context: context)
            lastTap = String(format: "focus %@ at (%.0f, %.0f) px", hit.name, point.x, point.y)
            return
        }
        let (az, alt) = OverlayContext.horizontal(reference: context.referenceDirection(screen: point))
        lastTap = String(format: "tap az %.1f° alt %.1f° (no boundary hit)", az, alt)
    }

    private func performAlignTap(at point: SIMD2<Double>, context: OverlayContext) {
        let snap: (AlignmentCandidate.Kind, SIMD2<Double>) -> SIMD2<Double>? = { [weak driver] kind, p in
            driver?.snappedScreenPoint(kind: kind, near: p)
        }
        let outcome = engine.handleTap(at: point, context: context, canAlign: effectiveAttitudeSource != .fixed,
                                       headingAccuracy: location.headingAccuracy, snap: snap)
        var info = outcome.info
        if let detail = outcome.detail { info?.alignmentNote = align(on: detail, context: context) }
        showInfo(info)
    }

    func pinConstellation(id: String, name: String, context: OverlayContext,
                          preservingDeepDiveFrom source: ConstellationCardModel? = nil) {
        hideCardTask?.cancel()
        focus.pin(constellation: id, name: name)
        engine.applyFocusPin(id, context: context)
        focus.beginOutlineIfNeeded(id: id, displayTime: context.displayTime)
        pinnedFacts = focus.facts(for: id, context: context, engine: engine)
        let pinned = ConstellationCardModel(id: id, name: name, narration: engine.narrationCard(id),
                                            catalogStars: engine.catalogStars(for: id))
        if let source, source.id == id { pinned.deepDive = source.deepDive }
        pinnedCard = pinned
        focusChat.reset()
        if ProcessInfo.processInfo.arguments.contains("-autoPinOri"), id == "Ori" {
            focusChat.messages = [
                FocusChatMessage(role: .user, text: "Which star marks Orion's shoulder?"),
                FocusChatMessage(role: .assistant, text: "Betelgeuse marks Orion's eastern shoulder — a red supergiant and one of the brightest stars in the sky [P:Ori-wiki-8].",
                                 verificationLabel: "verified"),
            ]
        }
        card = nil
    }

    func dismissFocusPin() {
        if let context = driver?.lastContext {
            engine.applyFocusPin(nil, context: context)
        } else {
            engine.focusOverrideID = nil
        }
        focus.dismissPin()
        pinnedFacts = nil
        pinnedCard = nil
        focusChat.reset()
        focusChatPendingScroll = false
    }

    func askQuestionFromLockCard() {
        guard let lockCard = card, let context = driver?.lastContext else { return }
        focusChatPendingScroll = true
        pinConstellation(id: lockCard.id, name: lockCard.name, context: context, preservingDeepDiveFrom: lockCard)
    }

    func sendFocusChat() {
        guard let id = focus.pinnedID, let name = focus.pinnedName, let facts = pinnedFacts, let context = driver?.lastContext else { return }
        focusChat.send(constellationID: id, constellationName: name, facts: facts,
                       narration: engine.narrationCard(id), resources: focus.resources, context: context, engine: engine)
    }

    /// Turns a tap on a star into an orientation fix: with two or more recent stars the three-axis multi-star solve,
    /// otherwise a yaw about the vertical. Returns the note shown on the card.
    private func align(on detail: SkyEngine.AlignmentDetail, context: OverlayContext) -> String {
        let t = context.hostTime
        let cm = driver?.lastCoreMotion ?? simd_quatd(context.deviceFromReference)
        let sigma = detail.snapped ? Self.snappedTapSigma : Self.tapSigma
        let observation = StarObservation(hostTime: t, expected: detail.expected, observed: alignment.correction(at: t).act(detail.observed),
                                          sigmaDegrees: sigma)
        let fix: StarFix
        if let solution = alignment.add(observation, now: t) {
            fix = StarFix(hostTime: t, deviceFromReference: (alignment.boresight * cm * solution.correction).normalized,
                          sigmaDegrees: solution.sigmaDegrees, starCount: solution.count, source: .multiStar)
        } else {
            let attitude = simd_quatd(context.deviceFromReference) * simd_quatd(angle: detail.yawDelta, axis: SIMD3(0, 0, 1))
            fix = StarFix(hostTime: t, deviceFromReference: attitude.normalized, sigmaDegrees: sigma, starCount: 1,
                          source: detail.snapped ? .tapSnapped : .tap)
        }
        ingest(fix, coreMotion: cm)
        let stars = fix.starCount > 1 ? "\(fix.starCount) stars" : (detail.snapped ? "snapped to the star" : "tap")
        return String(format: "Aligned on %@ (%@), now ±%.1f°.", detail.name, stars, alignment.accuracyDegrees)
    }

    func showInfo(_ info: ObjectInfo?) {
        infoTask?.cancel()
        objectInfo = info
        guard info != nil else { return }
        infoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.objectInfo = nil }
        }
    }

    // MARK: Sky data, lock card, deep dive

    private func loadSkyData() {
        Task { [weak self] in
            let started = CACurrentMediaTime()
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SkyData, any Error> in
                Result { try SkyData.load() }
            }.value
            guard let self else { return }
            switch result {
            case .success(let data):
                engine.install(data)
                driver?.setMilkyWay(levels: data.milkyWayLevels, width: SkyData.milkyWaySize.width, height: SkyData.milkyWaySize.height)
                skyDataLoaded = true
                skyDataLoadSeconds = CACurrentMediaTime() - started
            case .failure(let error):
                skyDataError = "Sky data: \(error)"
            }
        }
    }

    private func handle(_ event: SkyEvent) {
        switch event {
        case .locked(let id, let narrate):
            if let t = driver?.lastContext?.displayTime { focus.beginOutlineIfNeeded(id: id, displayTime: t) }
            guard !focus.isPinned else { return }
            hideCardTask?.cancel()
            autoDeepDiveTask?.cancel()
            deepDiveTask?.cancel()
            narrator.stop()
            let model = ConstellationCardModel(id: id, name: engine.constellationName(id), narration: engine.narrationCard(id),
                                               catalogStars: engine.catalogStars(for: id))
            withAnimation(.easeOut(duration: 0.15)) { card = model }
            if narrate, let text = model.spokenText { narrator.speak(text) }
            scheduleAutoDeepDive(constellationID: id)
        case .unlocked:
            guard !focus.isPinned else { return }
            hideCardTask?.cancel()
            autoDeepDiveTask?.cancel()
            hideCardTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.easeIn(duration: 0.25)) { card = nil }
                deepDiveTask?.cancel()
                narrator.stop()
            }
        }
    }

    static let deepDiveQuestion = "Tell me more about this constellation: its story, how to recognise it, and what is near it tonight."

    private func scheduleAutoDeepDive(constellationID: String) {
        autoDeepDiveTask?.cancel()
        autoDeepDiveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, let self else { return }
            guard card?.id == constellationID, !focus.isPinned else { return }
            askDeepDive()
        }
    }

    func askDeepDive() {
        guard let card = pinnedCard ?? card else { return }
        let id = card.id
        let cacheStore = DeepDiveCache.applicationSupport()
        if let saved = cacheStore.answer(constellationID: id, question: Self.deepDiveQuestion) {
            card.deepDive = .done(saved)
            return
        }
        if case .failed = card.deepDive {
            deepDiveRequestedNetwork.remove(id)
        } else if deepDiveRequestedNetwork.contains(id) {
            return
        }
        if case .streaming = card.deepDive { return }
        guard let context = driver?.lastContext, let facts = engine.deepDiveFacts(for: id, context: context) else {
            card.deepDive = .failed("The sky is not ready yet (waiting for location or catalogs).")
            return
        }
        deepDiveRequestedNetwork.insert(id)
        let client = DeepDiveClient(cache: cacheStore, modelID: AppInfo.gemmaModelID, apiKey: AppInfo.vertexAPIKey,
                                    projectID: AppInfo.gcpProjectID, location: AppInfo.gemmaLocation)
        let prompt = DeepDiveClient.prompt(facts: facts, question: Self.deepDiveQuestion)
        card.deepDive = .streaming("")
        deepDiveTask?.cancel()
        deepDiveTask = Task { [weak self, weak card] in
            for await update in client.ask(constellationID: id, question: Self.deepDiveQuestion, prompt: prompt) {
                guard let card else { return }
                switch update {
                case .text(let text): card.deepDive = .streaming(text)
                case .finished:
                    if case .streaming(let text) = card.deepDive { card.deepDive = .done(text) }
                case .cached(let text, let reason): card.deepDive = .cached(text: text, reason: reason)
                case .failed(let message):
                    card.deepDive = .failed(message)
                    self?.deepDiveRequestedNetwork.remove(id)
                }
            }
        }
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
        alignment.update(headingAccuracy: location.headingAccuracy, now: CACurrentMediaTime(), cumulativeTurn: motion.buffer.cumulativeTurn)
        writeRecordingExtras()

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
        tryAutoPinIfNeeded()
    }

    private func tryAutoPinIfNeeded() {
        guard let id = pendingAutoPinID, skyDataLoaded, focus.resources.hitTest != nil,
              let context = driver?.lastContext else { return }
        pendingAutoPinID = nil
        pinConstellation(id: id, name: engine.constellationName(id), context: context)
    }

    private func makeDebugSections(snapshot: CaptureSnapshot?, latestMotion: MotionSample?) -> [DebugSection] {
        let context = driver?.lastContext
        var sections: [DebugSection] = []

        sections.append(DebugSection(title: "App", lines: [
            AppInfo.summary,
            "Vertex API key: \(AppInfo.hasVertexAPIKey ? "present" : "missing")",
            "Gemma model: \(AppInfo.gemmaModelID ?? "unset") (\(AppInfo.gcpProjectID == nil ? "express URL" : "project \(AppInfo.gemmaLocation ?? "global")"))",
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
            sky.append(String(format: "overlay build %.2f ms, locked %@", engine.frameMilliseconds, engine.lockedID ?? "none"))
        }
        if let skyDataError { sky.append(skyDataError) } else if let seconds = skyDataLoadSeconds { sky.append(String(format: "sky catalogs loaded in %.2f s", seconds)) } else { sky.append("sky catalogs loading…") }
        if let status = satellites.dataStatus { sky.append("satellites: \(status.summary)") }
        if let error = satellites.errorMessage { sky.append(error) }
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
        if let lens = snapshot?.activeLens {
            let fov = snapshot?.probe.map { String(format: ", horizontal FOV %.1f°", $0.fieldOfViewDegrees) } ?? ""
            camera.append("active lens \(lens.label)\(fov)")
        }
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

        var precision = [String(format: "accuracy ±%.2f° (%@)", alignment.accuracyDegrees,
                                alignment.isAligned ? "\(alignment.filter.fixCount) fixes" : "not aligned: compass only")]
        let f = alignment.filter
        precision.append(String(format: "yaw %.2f° drift %+.4f°/s, tilt %.2f°", Angle.degrees(f.yaw(at: CACurrentMediaTime())),
                                Angle.degrees(f.yawRate), Angle.degrees(simd_length(Rotations.rotationVector(f.tilt)))))
        if let m = alignment.lastMultiStar {
            precision.append(String(format: "multi-star: %d stars, rms %.2f°, σ %.2f°", m.count, m.rmsResidualDegrees, m.sigmaDegrees))
        }
        if let lastFix { precision.append("last fix \(lastFix)") }
        precision.append("auto-align: \(autoAlign.diagnostics.lastLine)")
        precision.append("frame path: " + (driver?.isWarping == true ? "gyro warp to display time" : "frame-matched") + " (\(warpMode.rawValue))")
        precision.append("calibration: \(calibrationSource)")
        if let t = calibration.timing { precision.append(String(format: "timing offset %+.1f ms, rolling shutter %+.1f ms", t.offsetSeconds * 1000, t.readoutSeconds * 1000)) }
        if let l = calibration.lens {
            precision.append(String(format: "lens f×%.4f/%.4f, centre %+.2f/%+.2f%%, k1 %+.4f, boresight %.3f° %.3f° %.3f°", l.focalScaleX, l.focalScaleY,
                                    l.principalShiftX * 100, l.principalShiftY * 100, l.distortion.k1,
                                    Angle.degrees(l.boresight.x), Angle.degrees(l.boresight.y), Angle.degrees(l.boresight.z)))
        }
        if let recordingStatus { precision.append(recordingStatus) } else if let lastRecording { precision.append(lastRecording) }
        sections.append(DebugSection(title: "Precision", lines: precision))

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
