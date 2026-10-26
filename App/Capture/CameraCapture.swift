import AVFoundation
import Metal
import os

struct CaptureSnapshot: Sendable {
    var status: CameraCapture.Status
    var activeLens: CaptureLens?
    var probe: CameraProbe?
    var focus: FocusOutcome?
    var exposure: ExposureState?
    var exposureDuration: Double?
    var iso: Float?
    var lensPosition: Float?
    var isAdjustingFocus: Bool
    var nightProbe: [NightProbeTrial]
}

/// One physical back camera at a time (never a virtual multi-lens device). Runs on its own serial queue; frames are
/// delivered to `receiver` on a second queue in the native landscape orientation (no connection rotation).
actor CameraCapture {
    enum Status: Sendable, Equatable {
        case idle, running, denied
        case unavailable(String)
        case failed(String)
    }

    nonisolated let sessionQueue = DispatchSerialQueue(label: "ConstellationAR.camera.session", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { sessionQueue.asUnownedSerialExecutor() }
    nonisolated let receiver: VideoFrameReceiver?

    private let session: AVCaptureSession
    private let videoQueue = DispatchQueue(label: "ConstellationAR.camera.video", qos: .userInteractive)
    private let log = Logger(subsystem: "org.constellationar.app", category: "camera")
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var device: AVCaptureDevice?
    private var connection: AVCaptureConnection?
    private(set) var selectedLens: CaptureLens = .wide
    private var lensObservation: NSKeyValueObservation?
    private var focus = FocusController()
    private var exposure = ExposureController()
    private var lightingBlend: Double = 0
    private(set) var status: Status = .idle
    private var probe: CameraProbe?
    private var focusOutcome: FocusOutcome?
    private var exposureState: ExposureState?
    private var nightProbe: [NightProbeTrial] = []

    init(metalDevice: any MTLDevice) {
        session = AVCaptureSession()
        receiver = VideoFrameReceiver(metalDevice: metalDevice)
    }

    func setInitialLens(_ lens: CaptureLens) {
        // A stopped session still owns its physical input. Don't relabel that input on foreground return.
        guard device == nil, status != .running else { return }
        selectedLens = lens
    }

    /// Reconfigures the session for another physical lens while running.
    func setLens(_ lens: CaptureLens) async -> Status? {
        guard lens != selectedLens else { return nil }
        guard CaptureLens.available().contains(lens) else { return .unavailable("lens \(lens.label) unavailable") }
        selectedLens = lens
        guard status == .running else { return nil }
        return await switchDevice()
    }

    @discardableResult
    func start() async -> Status {
        if status == .running { return status }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return set(.denied) }
        default:
            return set(.denied)
        }
        if device == nil, let failure = configure() {
            return set(failure)
        }
        guard let device else { return set(.unavailable("no camera")) }

        session.startRunning()
        guard session.isRunning else { return set(.failed("session did not start")) }
        receiver?.setSynchronizationClock(session.synchronizationClock)
        if let clock = session.synchronizationClock {
            probe?.syncClockOffsetFromHost = CMClockGetTime(clock).seconds - CMClockGetTime(CMClockGetHostTimeClock()).seconds
        }
        exposureState = exposure.apply(blend: lightingBlend, to: device)
        // Focus awaits and lets the lighting refresh enter this actor. Mark capture running first so a
        // newer lighting phase is actually applied, rather than merely cached until the next resume.
        status = .running
        let outcome = await focus.lockFar(device, lens: selectedLens, autofocus: shouldAutofocus)
        if self.device === device, session.isRunning { focusOutcome = outcome }
        if let probe { log.info("camera probe: \(probe.lines.joined(separator: " | "), privacy: .public)") }
        return status
    }

    func stop() {
        session.stopRunning()
        if status == .running { status = .idle }
    }

    /// 0 = day … 1 = night. Re-applies exposure only when the phase or blend actually changes.
    func setLighting(blend: Double) {
        let previous = lightingBlend
        lightingBlend = min(max(blend, 0), 1)
        guard let device, status == .running else { return }
        let phaseChanged = LightingPhase(blend: previous) != LightingPhase(blend: lightingBlend)
        if phaseChanged || abs(previous - lightingBlend) > 0.02 {
            exposureState = exposure.apply(blend: lightingBlend, to: device)
        }
        if phaseChanged {
            Task { await self.reapplyFocus() }
        }
    }

    private func reapplyFocus() async {
        guard let device, status == .running else { return }
        focusOutcome = await focus.lockFar(device, lens: selectedLens, autofocus: shouldAutofocus)
    }

    func setNightExposure(duration: Double, strategy: NightExposureStrategy) {
        exposure.nightExposureDuration = duration
        exposure.nightStrategy = strategy
        guard let device, status == .running else { return }
        exposureState = exposure.apply(blend: lightingBlend, to: device)
    }

    /// Autofocus again on the distant centre and store the result as the new far position.
    func refocusFar() async {
        guard let device, status == .running else { return }
        focusOutcome = await focus.lockFar(device, lens: selectedLens, autofocus: true)
    }

    func snapshot() -> CaptureSnapshot {
        CaptureSnapshot(status: status, activeLens: device == nil ? nil : selectedLens, probe: probe, focus: focusOutcome, exposure: exposureState,
                        exposureDuration: device?.exposureDuration.seconds, iso: device?.iso,
                        lensPosition: device?.lensPosition, isAdjustingFocus: device?.isAdjustingFocus ?? false,
                        nightProbe: nightProbe)
    }

    /// Tries night exposure settings for a moment each and measures what the hardware delivers, then restores.
    func runNightProbe() async -> [NightProbeTrial] {
        guard let device, let receiver, status == .running else { return [] }
        let saved = exposure
        let maxExposure = device.activeFormat.maxExposureDuration.seconds
        var plan: [(String, Double, NightExposureStrategy)] = [1.0 / 30, 1.0 / 8, 1.0 / 4, maxExposure].map {
            (String(format: "manual %.3f s", $0), $0, .manual)
        }
        if probe?.shutterPrioritySupported == true {
            plan += [1.0 / 8, maxExposure].map { (String(format: "ISO auto %.3f s", $0), $0, .shutterPriority) }
        }

        var trials: [NightProbeTrial] = []
        for (label, duration, strategy) in plan {
            exposure.nightExposureDuration = duration
            exposure.nightStrategy = strategy
            _ = exposure.apply(blend: 1, to: device)
            let settle = max(0.6, duration * 3)
            try? await Task.sleep(for: .seconds(settle))
            let before = receiver.statistics
            let window = max(1.2, duration * 6)
            try? await Task.sleep(for: .seconds(window))
            let after = receiver.statistics
            let elapsed = after.lastHostTime - before.lastHostTime
            let fps = elapsed > 0 ? Double(after.frames - before.frames) / elapsed : 0
            trials.append(NightProbeTrial(label: label, requestedDuration: duration, measuredFPS: fps,
                                          deviceExposure: device.exposureDuration.seconds, deviceISO: device.iso,
                                          frameExposure: after.lastExposureDuration, frameISO: after.lastISO,
                                          maxFrameDuration: device.activeVideoMaxFrameDuration.seconds))
        }
        exposure = saved
        exposureState = exposure.apply(blend: lightingBlend, to: device)
        nightProbe = trials
        for trial in trials { log.info("night probe: \(trial.line, privacy: .public)") }
        return trials
    }

    private var shouldAutofocus: Bool {
        switch LightingPhase(blend: lightingBlend) {
        case .day: true
        case .twilight: true
        case .night: false
        }
    }

    private func set(_ newStatus: Status) -> Status {
        status = newStatus
        return newStatus
    }

    private func cameraDevice(for lens: CaptureLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
    }

    /// Returns a failure status, or nil on success.
    private func configure() -> Status? {
        guard receiver != nil else { return .failed("no Metal texture cache") }
        guard let camera = cameraDevice(for: selectedLens) ?? cameraDevice(for: .wide) else {
            return .unavailable("no back camera")
        }
        if let lens = CaptureLens.displayOrder.first(where: { cameraDevice(for: $0)?.uniqueID == camera.uniqueID }) {
            selectedLens = lens
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        return attach(camera: camera)
    }

    private func switchDevice() async -> Status? {
        guard let camera = cameraDevice(for: selectedLens) else {
            return .unavailable("lens \(selectedLens.label) unavailable")
        }
        session.beginConfiguration()
        var failure = attach(camera: camera)
        if failure != nil, selectedLens != .wide, let wide = cameraDevice(for: .wide) {
            log.error("lens switch failed, reverting to 1x")
            selectedLens = .wide
            if attach(camera: wide) == nil { failure = .unavailable("lens switch failed; reverted to 1×") }
        }
        session.commitConfiguration()
        guard let device else { return failure }
        exposureState = exposure.apply(blend: lightingBlend, to: device)
        focusOutcome = await focus.lockFar(device, lens: selectedLens, autofocus: shouldAutofocus)
        log.info("switched to \(self.selectedLens.label, privacy: .public) camera")
        return failure
    }

    /// Input must be attached before the output's video connection exists.
    private func attach(camera: AVCaptureDevice) -> Status? {
        guard let receiver else { return .failed("no Metal texture cache") }
        if let input = videoInput {
            session.removeInput(input)
            videoInput = nil
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            return .failed("camera input: \(error.localizedDescription)")
        }
        input.unifiedAutoExposureDefaultsEnabled = true
        guard session.canAddInput(input) else { return .failed("cannot add camera input") }
        session.addInput(input)
        videoInput = input

        if videoOutput == nil {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(receiver, queue: videoQueue)
            guard session.canAddOutput(output) else { return .failed("cannot add video output") }
            session.addOutput(output)
            videoOutput = output
        }
        guard let connection = videoOutput?.connection(with: .video) else { return .failed("no video connection") }

        // Intrinsic matrix delivery is only offered with stabilization off, so that comes first.
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
        let (format, tried) = chooseFormat(camera, connection)
        guard let format else { return .unavailable("no suitable video format") }
        if (try? camera.lockForConfiguration()) != nil {
            camera.activeFormat = format
            if format.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
                camera.isVideoHDREnabled = false
            }
            camera.unlockForConfiguration()
        }
        if connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        let maxFrameRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        exposure.dayFrameRate = CameraFormatRank.dayFrameRate(lens: selectedLens, maximum: maxFrameRate)
        lensObservation?.invalidate()
        device = camera
        lensObservation = camera.observe(\.lensPosition, options: [.initial, .new]) { [receiver] camera, _ in
            receiver.setLensPosition(camera.lensPosition)
        }
        self.connection = connection
        probe = CameraProbe(device: camera, connection: connection, formatsTried: tried)
        return nil
    }

    /// Keep the main camera's existing high-rate policy. Secondary cameras prioritize delivered detail over
    /// high-speed formats; those can trade resolution/binning and exposure time for a rate we don't need.
    private func chooseFormat(_ camera: AVCaptureDevice, _ connection: AVCaptureConnection) -> (AVCaptureDevice.Format?, [String]) {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let rank: CameraFormatRank
        }
        let candidates: [Candidate] = camera.formats.compactMap { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  (1280...1920).contains(dims.width), dims.height >= 720 else { return nil }
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard fps >= 30 else { return nil }
            if selectedLens != .wide {
                // A format whose range starts above 60 cannot honor the secondary-camera rate cap.
                guard format.videoSupportedFrameRateRanges.contains(where: {
                    max($0.minFrameRate, 30) <= min($0.maxFrameRate, 60)
                }) else { return nil }
            }
            return Candidate(format: format, rank: CameraFormatRank(width: dims.width, height: dims.height,
                             fov: format.videoFieldOfView, fps: fps, isBinned: format.isVideoBinned,
                             fullRange: subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        }
        let ranked = candidates.sorted { a, b in
            a.rank.isPreferred(to: b.rank, lens: selectedLens)
        }

        var tried: [String] = []
        guard (try? camera.lockForConfiguration()) != nil else { return (ranked.first?.format, tried) }
        defer { camera.unlockForConfiguration() }
        for candidate in ranked.prefix(8) {
            camera.activeFormat = candidate.format
            let supported = connection.isCameraIntrinsicMatrixDeliverySupported
            let r = candidate.rank
            tried.append(String(format: "%d×%d %.0ffps FOV %.1f° %@ binned=%@ intrinsics=%@", r.width, r.height, r.fps,
                                r.fov, r.fullRange ? "420f" : "420v", r.isBinned ? "yes" : "no", supported ? "yes" : "no"))
            if supported { return (candidate.format, tried) }
        }
        return (ranked.first?.format, tried)
    }
}

/// Value-only format policy so resolution/rate tradeoffs can be checked without camera hardware.
struct CameraFormatRank {
    let width: Int32
    let height: Int32
    let fov: Float
    let fps: Double
    let isBinned: Bool
    let fullRange: Bool

    static func dayFrameRate(lens: CaptureLens, maximum: Double) -> Double {
        min(maximum, lens == .wide ? 120 : 60)
    }

    func isPreferred(to other: Self, lens: CaptureLens) -> Bool {
        let fovA = (fov * 2).rounded(), fovB = (other.fov * 2).rounded()
        if fovA != fovB { return fovA > fovB }
        if lens != .wide {
            if width != other.width { return width > other.width }
            if isBinned != other.isBinned { return !isBinned }
        }
        let rateA = Self.dayFrameRate(lens: lens, maximum: fps)
        let rateB = Self.dayFrameRate(lens: lens, maximum: other.fps)
        if rateA != rateB { return rateA > rateB }
        let wideA = width * 9 == height * 16, wideB = other.width * 9 == other.height * 16
        if wideA != wideB { return wideA }
        if width != other.width { return width > other.width }
        return fullRange && !other.fullRange
    }
}
