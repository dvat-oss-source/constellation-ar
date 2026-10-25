import Foundation
import simd
import SkyCore
import XCTest
@testable import ConstellationAR

/// The fixed-sky night preset, drawn by the real sky engine, stands in for the camera (the simulator has none): the
/// overlay's stars become a luminance frame, which goes through detection, plate solving and the attitude conversion.
@MainActor
final class AutoAlignTests: XCTestCase {
    private static let intrinsics = SkyCore.CameraIntrinsics.fieldOfView(horizontalDegrees: 63, bufferWidth: 1920, bufferHeight: 1080)

    private struct Scene {
        var engine: SkyEngine
        var truth: simd_double3x3
        var image: LuminanceImage
        var environment: AutoAlignEnvironment
    }

    private func makeScene(heading: Double = 0, noise: Double = 2) throws -> Scene {
        let data = try SkyData.load()
        let engine = SkyEngine(layers: LayerSettings(), satellites: SatelliteTracker())
        engine.install(data)
        let truth = LookController.deviceFromReference(azimuth: FixedSkyPreset.azimuth + heading, altitude: FixedSkyPreset.altitude)
        let geometry = CameraGeometry(intrinsics: .nominal(size: SIMD2(1920, 1080), longAxisFOVDegrees: 63),
                                      drawableSize: SIMD2(1179, 2556))
        let context = OverlayContext(hostTime: 0, displayTime: 0, skyDate: FixedSkyPreset.date, observer: FixedSkyPreset.observer,
                                     deviceFromReference: truth, camera: geometry, lighting: 1, isSkyOnly: false, contentScale: 3)
        let frame = engine.frame(context)

        var field = [Float](repeating: 10, count: 1920 * 1080)
        var rng = SplitMix(seed: 5)
        for batch in frame.batches {
            guard case .points(let points) = batch else { continue }
            for p in points {
                let pixel = geometry.mapping.pixel(fromScreen: SIMD2(Double(p.position.x), Double(p.position.y)))
                let amplitude = min(255, Double(p.radius) / 3 * 40)
                let cx = Int(pixel.x), cy = Int(pixel.y)
                guard cx > 6, cy > 6, cx < 1914, cy < 1074 else { continue }
                for y in (cy - 6)...(cy + 6) {
                    for x in (cx - 6)...(cx + 6) {
                        let dx = Double(x) + 0.5 - pixel.x, dy = Double(y) + 0.5 - pixel.y
                        field[y * 1920 + x] += Float(amplitude * exp(-(dx * dx + dy * dy) / (2 * 1.4 * 1.4)))
                    }
                }
            }
        }
        let bytes = field.map { UInt8(min(max(Double($0) + noise * rng.gaussian(), 0), 255)) }
        let session = engine.session(for: FixedSkyPreset.date, observer: FixedSkyPreset.observer)
        return Scene(engine: engine, truth: truth, image: LuminanceImage(pixels: bytes, width: 1920, height: 1080),
                     environment: AutoAlignEnvironment(session: session, instant: AstroInstant(date: FixedSkyPreset.date), nightFactor: 1,
                                                       captureTime: 100, motionAttitude: nil))
    }

    private func aligner(for scene: Scene) async throws -> AutoAligner {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "solver_db", withExtension: "bin"), "solver_db.bin is not bundled")
        let aligner = AutoAligner(databaseURL: url)
        for _ in 0..<100 where !aligner.isReady { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(aligner.isReady)
        aligner.environment = { _ in scene.environment }
        return aligner
    }

    private func frame(_ scene: Scene, exposure: Double = 0.125) -> AutoAligner.Frame {
        let image = scene.image
        return AutoAligner.Frame(hostTime: 100, exposureDuration: exposure, intrinsics: Self.intrinsics, luminance: { image })
    }

    private func angle(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
        let r = a * b.transpose
        return acos(min(1, max(-1, (r[0][0] + r[1][1] + r[2][2] - 1) / 2))) * 180 / .pi
    }

    private func waitForOutcome(_ aligner: AutoAligner) async throws {
        for _ in 0..<200 where aligner.diagnostics.lastLine == "ready" { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testRenderedNightSkyYieldsAbsoluteAttitude() async throws {
        let scene = try makeScene()
        let aligner = try await aligner(for: scene)
        var received: [StarFix] = []
        aligner.ingestStarFix = { received.append($0) }
        aligner.submit(frame(scene))
        try await waitForOutcome(aligner)
        let fix = try XCTUnwrap(received.first, aligner.diagnostics.lastLine)
        XCTAssertEqual(fix.source, .plateSolve)
        XCTAssertGreaterThanOrEqual(fix.starCount, 8)
        let error = angle(simd_double3x3(fix.deviceFromReference), scene.truth)
        print("AUTOALIGN fixed-sky night: \(fix.starCount) stars, attitude error \(String(format: "%.4f", error))°, sigma \(String(format: "%.3f", fix.sigmaDegrees))°, \(aligner.diagnostics.lastLine)")
        XCTAssertLessThan(error, 0.05)
        XCTAssertNotNil(aligner.status)
    }

    func testDaylightAndShortExposuresAreNotSolved() async throws {
        var scene = try makeScene()
        let aligner = try await aligner(for: scene)
        scene.environment.nightFactor = 0.5
        let dusk = scene.environment
        aligner.environment = { _ in dusk }
        aligner.submit(frame(scene))
        scene.environment.nightFactor = 1
        let night = scene.environment
        aligner.environment = { _ in night }
        aligner.submit(frame(scene, exposure: 1.0 / 60))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(aligner.diagnostics.attempts, 0)
    }

    func testMotionDisagreementRejectsTheSolution() async throws {
        var scene = try makeScene()
        let wrong = simd_quatd(scene.truth * Rotation.rx(25 * .pi / 180))
        scene.environment.motionAttitude = { _ in wrong }
        let aligner = try await aligner(for: scene)
        let environment = scene.environment
        aligner.environment = { _ in environment }
        var received = 0
        aligner.ingestStarFix = { _ in received += 1 }
        aligner.submit(frame(scene))
        try await waitForOutcome(aligner)
        XCTAssertEqual(received, 0)
        XCTAssertEqual(aligner.diagnostics.rejected, 1, aligner.diagnostics.lastLine)
    }

    func testNoiseOnlyFrameGivesNoFix() async throws {
        var scene = try makeScene(noise: 6)
        var rng = SplitMix(seed: 9)
        let bytes = (0..<(1920 * 1080)).map { _ in UInt8(min(max(12 + 5 * rng.gaussian(), 0), 255)) }
        scene.image = LuminanceImage(pixels: bytes, width: 1920, height: 1080)
        let aligner = try await aligner(for: scene)
        var received = 0
        aligner.ingestStarFix = { _ in received += 1 }
        aligner.submit(frame(scene))
        try await waitForOutcome(aligner)
        XCTAssertEqual(received, 0)
        XCTAssertTrue(aligner.diagnostics.lastLine.hasPrefix("no solution"), aligner.diagnostics.lastLine)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        (-2 * log(max(uniform(), 1e-300))).squareRoot() * cos(2 * .pi * uniform())
    }
}
