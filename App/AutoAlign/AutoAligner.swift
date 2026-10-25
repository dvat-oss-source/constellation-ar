import Foundation
import Observation
import QuartzCore
import SkyCore
import simd

/// What the aligner needs to know about the world for one camera frame; supplied per attempt by the app.
struct AutoAlignEnvironment: Sendable {
    var session: SkySession
    var instant: AstroInstant
    /// 0 = day … 1 = night.
    var nightFactor: Double
    /// Host time the frame's attitude belongs to (`AppModel.captureTime(frameHostTime:exposure:)`).
    var captureTime: Double
    /// Raw Core Motion attitude (no heading correction) at a host time; nil when motion is not the attitude source.
    var motionAttitude: (@Sendable (Double) -> simd_quatd?)?
}

/// Night-time automatic alignment: plate-solves the camera image every few seconds and hands the resulting absolute
/// attitude to the heading filter as a `StarFix`.
@MainActor
@Observable
final class AutoAligner {
    struct Frame: Sendable {
        var hostTime: Double
        var exposureDuration: Double?
        var intrinsics: SkyCore.CameraIntrinsics
        var luminance: @Sendable () -> LuminanceImage?
        var sequence: UInt64 = 0
        /// Attempt regardless of the pacing interval (frames the session recorder stores at full resolution).
        var forced = false
    }

    struct Diagnostics: Sendable {
        var attempts = 0
        var solved = 0
        var rejected = 0
        var lastLine = "idle"
    }

    nonisolated static let minimumExposure = 1.0 / 20
    nonisolated static let nightThreshold = 0.95
    nonisolated static let maximumBlurDegrees = 0.4
    /// Core Motion's gravity-derived tilt is good to well under a degree; a plate solution that disagrees by more is wrong.
    nonisolated static let maximumTiltDisagreementDegrees = 3.0

    /// "Auto-aligned · 23 stars · ±0.03°" for a few seconds after a fix; nil otherwise. Shown by the UI.
    private(set) var status: String?
    private(set) var diagnostics = Diagnostics()
    private(set) var lastFix: StarFix?

    @ObservationIgnored var environment: (@MainActor (Frame) -> AutoAlignEnvironment?)?
    /// Delivery point for the heading filter: wire to the app's `ingest(_ fix: StarFix)`.
    @ObservationIgnored var ingestStarFix: (@MainActor (StarFix) -> Void)?
    /// Every finished attempt with the frame it was made on (for the session recorder's cross-check).
    @ObservationIgnored var didFinish: (@MainActor (Frame, Outcome) -> Void)?
    /// Current attitude uncertainty in degrees, if the filter has one; fixes are requested more often while it is large.
    @ObservationIgnored var accuracyDegrees: (@MainActor () -> Double?)?

    @ObservationIgnored private var solver: PlateSolver?
    @ObservationIgnored private var lastAttempt = -Double.infinity
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(databaseURL: URL? = Bundle.main.url(forResource: "solver_db", withExtension: "bin")) {
        guard let databaseURL else {
            diagnostics.lastLine = "solver_db.bin missing"
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let loaded = Result { try PlateSolver(database: SolverDatabase(url: databaseURL)) }
            await self?.installSolver(loaded)
        }
    }

    private func installSolver(_ result: Result<PlateSolver, any Error>) {
        switch result {
        case .success(let solver):
            self.solver = solver
            diagnostics.lastLine = "ready"
        case .failure(let error):
            diagnostics.lastLine = "database: \(error)"
        }
    }

    var isReady: Bool { solver != nil }

    /// Offers a camera frame; most calls return immediately. Detection and solving run off the main actor.
    func submit(_ frame: Frame) {
        guard !busy, let solver, let environment, let exposure = frame.exposureDuration, exposure >= Self.minimumExposure else { return }
        let now = CACurrentMediaTime()
        let degraded = (accuracyDegrees?() ?? .infinity) > 0.5
        guard frame.forced || now - lastAttempt >= (degraded ? 2 : 5) else { return }
        guard let env = environment(frame), env.nightFactor >= Self.nightThreshold else { return }
        lastAttempt = now
        busy = true
        diagnostics.attempts += 1
        Task.detached(priority: .utility) { [weak self] in
            let outcome = Self.process(frame, exposure: exposure, environment: env, solver: solver)
            await self?.finish(outcome, frame: frame)
        }
    }

    // MARK: Worker

    enum Outcome: Sendable {
        case fix(StarFix, detected: Int, milliseconds: Double)
        case skipped(String)
        case noSolution(detected: Int, milliseconds: Double)
        case rejected(String)
    }

    nonisolated static func process(_ frame: Frame, exposure: Double, environment env: AutoAlignEnvironment,
                                    solver: PlateSolver) -> Outcome {
        let started = CACurrentMediaTime()
        let half = exposure / 2
        var blur = 0.0
        if let motion = env.motionAttitude, let a = motion(frame.hostTime - half), let b = motion(frame.hostTime + half) {
            blur = Angle.degrees(rotationAngle(a, b))
            if blur > maximumBlurDegrees { return .skipped(String(format: "moving %.2f°/exposure", blur)) }
        }
        guard let image = frame.luminance() else { return .skipped("frame unreadable") }
        let stars = StarDetector.detect(luminance: image.pixels, width: image.width, height: image.height,
                                        rowBytes: image.width, maxStars: 50)
        guard stars.count >= 6, let solution = solver.solve(stars: stars, intrinsics: frame.intrinsics) else {
            return .noSolution(detected: stars.count, milliseconds: (CACurrentMediaTime() - started) * 1000)
        }
        guard solution.rmsPixels < 2.5,
              let attitude = PlateSolveAttitude.deviceFromReference(solution, session: env.session, instant: env.instant) else {
            return .rejected("residual \(String(format: "%.1f", solution.rmsPixels)) px")
        }
        let time = env.captureTime
        if let motion = env.motionAttitude, let reference = motion(time) {
            let up = SIMD3<Double>(0, 0, 1)
            let tilt = Angle.degrees(Angle.separation(reference.act(up), attitude.deviceFromReference.act(up)))
            if tilt > maximumTiltDisagreementDegrees { return .rejected(String(format: "tilt differs %.1f°", tilt)) }
        }
        let sigma = (attitude.sigmaDegrees * attitude.sigmaDegrees + 0.09 * blur * blur).squareRoot()
        let fix = StarFix(hostTime: time, deviceFromReference: attitude.deviceFromReference, sigmaDegrees: sigma,
                          starCount: attitude.starCount, source: .plateSolve)
        return .fix(fix, detected: stars.count, milliseconds: (CACurrentMediaTime() - started) * 1000)
    }

    nonisolated static func rotationAngle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
    }

    private func finish(_ outcome: Outcome, frame: Frame) {
        busy = false
        didFinish?(frame, outcome)
        switch outcome {
        case .fix(let fix, let detected, let milliseconds):
            diagnostics.solved += 1
            diagnostics.lastLine = String(format: "solved · %d detected · %d matched · %.0f ms", detected, fix.starCount, milliseconds)
            lastFix = fix
            ingestStarFix?(fix)
            status = String(format: "Auto-aligned · %d stars · ±%.2f°", fix.starCount, fix.sigmaDegrees)
            clearTask?.cancel()
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { self?.status = nil }
            }
        case .skipped(let reason):
            diagnostics.lastLine = "skipped · \(reason)"
        case .noSolution(let detected, let milliseconds):
            diagnostics.lastLine = String(format: "no solution · %d detected · %.0f ms", detected, milliseconds)
        case .rejected(let reason):
            diagnostics.rejected += 1
            diagnostics.lastLine = "rejected · \(reason)"
        }
    }
}

extension AutoAligner {
    /// Offers a camera frame; the pixels are read back only if an attempt is actually made.
    func submit(_ frame: CameraFrame, forced: Bool = false) {
        guard let k = frame.intrinsics else { return }
        submit(Frame(hostTime: frame.hostTime, exposureDuration: frame.exposureDuration,
                     intrinsics: SkyCore.CameraIntrinsics(fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                                                          bufferWidth: k.referenceSize.x, bufferHeight: k.referenceSize.y),
                     luminance: { frame.luminance() }, sequence: frame.sequence, forced: forced))
    }

    /// Environment for the live app: the sky session and lighting from the model, motion from the attitude buffer.
    func configure(model: AppModel) {
        environment = { @MainActor [weak model] (frame: Frame) -> AutoAlignEnvironment? in
            guard let model, let observer = model.observer else { return nil }
            let date = model.skyDate(now: Date())
            let buffer = model.motion.buffer
            let usesMotion = model.effectiveAttitudeSource == .motion
            let motionAttitude: (@Sendable (Double) -> simd_quatd?)? = usesMotion
                ? { @Sendable (hostTime: Double) -> simd_quatd? in buffer.attitude(at: hostTime)?.deviceFromReference }
                : nil
            return AutoAlignEnvironment(
                session: model.engine.session(for: date, observer: observer), instant: AstroInstant(date: date),
                nightFactor: model.lightingBlend,
                captureTime: model.captureTime(frameHostTime: frame.hostTime, exposure: frame.exposureDuration),
                motionAttitude: motionAttitude)
        }
        ingestStarFix = { @MainActor [weak model] (fix: StarFix) in model?.ingest(fix) }
        accuracyDegrees = { @MainActor [weak model] () -> Double? in model?.alignment.accuracyDegrees }
        didFinish = { @MainActor [weak model] (frame: Frame, outcome: Outcome) in model?.recordPlateSolve(frame, outcome) }
    }
}
