import Foundation
import Testing
import simd
@testable import SkyCore

private struct Noise {
    var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }
    mutating func uniform() -> Double { Double.random(in: 0..<1, using: &rng) }
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
    mutating func unitVector() -> SIMD3<Double> {
        simd_normalize(SIMD3(gaussian(), gaussian(), gaussian()))
    }
    mutating func smallRotation(sigma: Double) -> simd_quatd {
        Rotations.quaternion(rotationVector: SIMD3(gaussian(), gaussian(), gaussian()) * sigma)
    }
}

private func degrees(_ q: simd_quatd) -> Double { Angle.degrees(simd_length(Rotations.rotationVector(q))) }

@Suite struct AttitudeFitTests {
    @Test func recoversKnownRotation() {
        var n = Noise(seed: 1)
        for _ in 0..<50 {
            let truth = Rotations.quaternion(rotationVector: n.unitVector() * Double.random(in: 0.01...3, using: &n.rng))
            let pairs = (0..<5).map { _ -> AttitudeFit.Pair in
                let s = n.unitVector()
                return AttitudeFit.Pair(source: s, observed: truth.act(s))
            }
            let solution = AttitudeFit.solve(pairs)!
            #expect(degrees(solution.rotation * truth.inverse) < 1e-9)
            #expect(solution.rmsResidual < 1e-9)
        }
    }

    @Test func noisyObservationsGiveSmallError() {
        var n = Noise(seed: 2)
        let truth = Rotations.quaternion(rotationVector: SIMD3(0.01, -0.02, 0.05))
        let pairs = (0..<12).map { _ -> AttitudeFit.Pair in
            let s = n.unitVector()
            return AttitudeFit.Pair(source: s, observed: n.smallRotation(sigma: Angle.radians(0.1)).act(truth.act(s)))
        }
        let solution = AttitudeFit.solve(pairs)!
        #expect(degrees(solution.rotation * truth.inverse) < 0.1)
        #expect(Angle.degrees(solution.rmsResidual) < 0.3)
    }

    @Test func multiStarSolvesAllThreeAxes() throws {
        // True correction: 4 deg of yaw plus a 0.4 deg tilt.
        let truth = Rotations.quaternion(rotationVector: SIMD3(Angle.radians(0.3), Angle.radians(-0.25), Angle.radians(4)))
        let stars: [SIMD3<Double>] = [
            SIMD3(0.5, 0.3, 0.8), SIMD3(-0.4, 0.7, 0.55),
        ]
        let observations = stars.enumerated().map { i, s in
            StarObservation(hostTime: Double(i) * 30, expected: s, observed: truth.act(simd_normalize(s)), sigmaDegrees: 0.2)
        }
        let solution = try #require(MultiStarAligner.solve(observations, now: 60))
        #expect(degrees(solution.correction * truth.inverse) < 1e-6)
        #expect(solution.sigmaDegrees >= MultiStarAligner.sigmaFloor / 2.0.squareRoot() - 1e-9)
        #expect(solution.count == 2)
    }

    @Test func multiStarNeedsTwoSeparatedRecentStars() {
        let s = SIMD3(0.5, 0.3, 0.8)
        let near = StarObservation(hostTime: 0, expected: s, observed: s, sigmaDegrees: 0.2)
        #expect(MultiStarAligner.solve([near], now: 1) == nil)
        let tooClose = StarObservation(hostTime: 0, expected: simd_normalize(s + SIMD3(0.01, 0, 0)), observed: s, sigmaDegrees: 0.2)
        #expect(MultiStarAligner.solve([near, tooClose], now: 1) == nil)
        let other = StarObservation(hostTime: 0, expected: SIMD3(-0.4, 0.7, 0.55), observed: SIMD3(-0.4, 0.7, 0.55), sigmaDegrees: 0.2)
        #expect(MultiStarAligner.solve([near, other], now: 1) != nil)
        #expect(MultiStarAligner.solve([near, other], now: 10_000) == nil)
    }

    @Test func residualGrowsWhenStarsDisagree() throws {
        let a = SIMD3(0.5, 0.3, 0.8), b = SIMD3(-0.4, 0.7, 0.55)
        let bad = Rotations.quaternion(rotationVector: SIMD3(0.01, 0, 0))
        let consistent = [StarObservation(hostTime: 0, expected: a, observed: a, sigmaDegrees: 0.2),
                          StarObservation(hostTime: 0, expected: b, observed: b, sigmaDegrees: 0.2)]
        let inconsistent = [consistent[0], StarObservation(hostTime: 0, expected: b, observed: bad.act(simd_normalize(b)), sigmaDegrees: 0.2)]
        let good = try #require(MultiStarAligner.solve(consistent, now: 0))
        let poor = try #require(MultiStarAligner.solve(inconsistent, now: 0))
        #expect(poor.sigmaDegrees > good.sigmaDegrees)
    }
}

@Suite struct HeadingFilterTests {
    private func coreMotion(at t: Double) -> simd_quatd {
        // A phone panning and tilting.
        Rotations.quaternion(rotationVector: SIMD3(0.4 * sin(t / 40), 0.2 * cos(t / 55), 2 * sin(t / 90) + 1))
    }

    @Test func convergesOnYawOffsetAndDriftWithBoundedUncertainty() {
        var n = Noise(seed: 7)
        var filter = HeadingFilter(epoch: 0)
        let yaw0 = Angle.radians(9), drift = Angle.radians(0.002)
        let fixSigma = 0.3
        var worstAfterSettle = 0.0
        var sigmaAtFix: [Double] = []
        var cumulative = 0.0
        var last = coreMotion(at: 0)
        for step in 0...1200 {
            let t = Double(step) * 5
            let cm = coreMotion(at: t)
            cumulative += 2 * atan2(simd_length((last.inverse * cm).imag), abs((last.inverse * cm).real))
            last = cm
            filter.advance(cumulativeTurn: cumulative)
            let truth = Rotations.quaternion(rotationVector: SIMD3(0, 0, yaw0 + drift * t))
            if step % 12 == 0 {
                let noisy = cm * truth * n.smallRotation(sigma: Angle.radians(fixSigma) / 2.0.squareRoot() / 1.2)
                filter.ingest(StarFix(hostTime: t, deviceFromReference: noisy, sigmaDegrees: fixSigma, starCount: 3, source: .multiStar),
                              coreMotion: cm)
                sigmaAtFix.append(filter.sigmaDegrees(at: t))
            } else if step > 120 {
                let estimated = filter.correction(at: t)
                worstAfterSettle = max(worstAfterSettle, degrees(estimated * truth.inverse))
            }
            #expect(filter.sigmaDegrees(at: t) <= filter.parameters.maxSigma)
        }
        #expect(worstAfterSettle < 0.6)
        #expect(sigmaAtFix.last! < sigmaAtFix.first!)
        #expect(sigmaAtFix.last! < 0.5)
        #expect(abs(Angle.degrees(filter.yawRate) - 0.002) < 0.0015)
    }

    @Test func uncertaintyGrowsWithTimeAndTurningAndFixesShrinkIt() {
        var filter = HeadingFilter(epoch: 0)
        let cm = coreMotion(at: 0)
        filter.ingest(StarFix(hostTime: 0, deviceFromReference: cm, sigmaDegrees: 0.2, starCount: 1, source: .tapSnapped), coreMotion: cm)
        let fresh = filter.sigmaDegrees(at: 0)
        #expect(fresh < 0.4)
        let later = filter.sigmaDegrees(at: 600)
        #expect(later > fresh)
        filter.advance(cumulativeTurn: 0)
        filter.advance(cumulativeTurn: 20)
        #expect(filter.sigmaDegrees(at: 0) > fresh)
        filter.ingest(StarFix(hostTime: 600, deviceFromReference: cm, sigmaDegrees: 0.2, starCount: 1, source: .tapSnapped), coreMotion: cm)
        #expect(filter.sigmaDegrees(at: 600) < later)
    }

    @Test func tapFixesLeaveTiltAloneButMultiStarSetsIt() {
        var filter = HeadingFilter(epoch: 0)
        let cm = coreMotion(at: 0)
        let tilted = Rotations.quaternion(rotationVector: SIMD3(Angle.radians(0.5), 0, Angle.radians(3)))
        filter.ingest(StarFix(hostTime: 0, deviceFromReference: cm * tilted, sigmaDegrees: 0.2, starCount: 1, source: .tap), coreMotion: cm)
        #expect(degrees(filter.tilt) < 1e-9)
        #expect(abs(Angle.degrees(filter.yaw(at: 0)) - 3) < 0.05)
        filter.ingest(StarFix(hostTime: 1, deviceFromReference: cm * tilted, sigmaDegrees: 0.1, starCount: 3, source: .multiStar), coreMotion: cm)
        #expect(degrees(filter.tilt) > 0.2)
    }

    @Test func boresightIsRemovedBeforeEstimating() {
        var filter = HeadingFilter(epoch: 0)
        let cm = coreMotion(at: 3)
        let lens = LensCalibration(boresight: SIMD3(0.004, -0.003, 0.002))
        let truth = Rotations.quaternion(rotationVector: SIMD3(0, 0, Angle.radians(5)))
        filter.ingest(StarFix(hostTime: 3, deviceFromReference: lens.boresightInDevice * cm * truth, sigmaDegrees: 0.1, starCount: 2, source: .multiStar),
                      coreMotion: cm, boresight: lens.boresightInDevice)
        #expect(degrees(filter.correction(at: 3) * truth.inverse) < 0.02)
    }

    @Test func persistsThroughJSON() throws {
        var filter = HeadingFilter(epoch: 0)
        let cm = coreMotion(at: 0)
        filter.ingest(StarFix(hostTime: 0, deviceFromReference: cm, sigmaDegrees: 0.2, starCount: 1, source: .tap), coreMotion: cm)
        let decoded = try JSONDecoder().decode(HeadingFilter.self, from: JSONEncoder().encode(filter))
        #expect(decoded == filter)
    }
}

@Suite struct FrameWarpTests {
    static let intrinsics = CameraIntrinsics(fx: 1500, fy: 1490, cx: 962, cy: 538, bufferWidth: 1920, bufferHeight: 1080)
    static let base = simd_quatd(CameraPose.looking(at: SIMD3(0.3, 0.8, 0.45)).referenceToDevice)
    static let spin = SIMD3(0.12, 0.3, -0.05)

    static func attitude(_ t: Double) -> simd_quatd {
        Rotations.quaternion(rotationVector: spin * (t - 10)) * base
    }

    static func projector(_ attitude: simd_quatd) -> Projector {
        let enuToCamera = CameraPose.deviceToCamera * simd_double3x3(attitude) * CameraPose.enuToReference
        return Projector(enuToCamera: enuToCamera, intrinsics: SkyCore.CameraIntrinsics(fx: intrinsics.fx, fy: intrinsics.fy, cx: intrinsics.cx,
                                                                                       cy: intrinsics.cy, bufferWidth: 1920, bufferHeight: 1080),
                         mapping: .identity(bufferWidth: 1920, bufferHeight: 1080))
    }

    static let directions: [SIMD3<Double>] = {
        let centre = simd_normalize(SIMD3(0.3, 0.8, 0.45))
        return [SIMD3(0, 0, 0), SIMD3(0.12, 0.03, 0.02), SIMD3(-0.15, -0.05, 0.04), SIMD3(0.05, -0.1, -0.09)].map { simd_normalize(centre + $0) }
    }()

    @Test func warpedFrameMatchesDirectProjectionAtDisplayAttitude() throws {
        let frameTime = 10.0, displayTime = 10.09
        let warp = FrameWarp(frameTime: frameTime, displayAttitude: Self.attitude(displayTime), readoutSeconds: 0,
                             intrinsics: Self.intrinsics, attitude: Self.attitude)
        var worst = 0.0
        for w in Self.directions {
            let captured = try #require(Self.projector(Self.attitude(frameTime)).pixel(enu: w))
            let shown = try #require(Self.projector(Self.attitude(displayTime)).pixel(enu: w))
            #expect(simd_distance(shown, captured) > 20)
            worst = max(worst, simd_distance(warp.sensorPixel(forDisplayPixel: shown), captured))
            #expect(simd_distance(warp.displayPixel(forSensorPixel: captured), shown) < 1e-6)
        }
        #expect(worst < 1e-6)
    }

    @Test func rollingShutterCorrectionFollowsPerRowExposureTime() throws {
        let frameTime = 10.0, displayTime = 10.07, readout = 0.032
        for sign in [1.0, -1.0] {
            let warp = FrameWarp(frameTime: frameTime, displayAttitude: Self.attitude(displayTime), readoutSeconds: readout * sign,
                                 intrinsics: Self.intrinsics, attitude: Self.attitude)
            var worst = 0.0
            for w in Self.directions {
                // Where a rolling-shutter sensor recorded the star: its row is exposed at its own time.
                var pixel = try #require(Self.projector(Self.attitude(frameTime)).pixel(enu: w))
                for _ in 0..<12 {
                    let t = frameTime + (pixel.y / 1080 - 0.5) * readout * sign
                    pixel = try #require(Self.projector(Self.attitude(t)).pixel(enu: w))
                }
                let shown = try #require(Self.projector(Self.attitude(displayTime)).pixel(enu: w))
                worst = max(worst, simd_distance(warp.sensorPixel(forDisplayPixel: shown), pixel))
            }
            #expect(worst < 1e-4)
        }
    }
}

@Suite struct LensCalibrationTests {
    @Test func radialDistortionRoundTrips() {
        let d = RadialDistortion(k1: -0.012, k2: 0.004)
        for p in [SIMD2(0.0, 0.0), SIMD2(0.4, -0.2), SIMD2(-0.65, 0.37)] {
            #expect(simd_distance(d.undistort(d.distort(p)), p) < 1e-12)
        }
    }

    @Test func projectorAppliesDistortionAndKeepsRaysConsistent() throws {
        var projector = FrameWarpTests.projector(FrameWarpTests.base)
        let direction = projector.ray(pixel: SIMD2(1750, 950))
        let plain = try #require(projector.pixel(enu: direction))
        projector.distortion = RadialDistortion(k1: -0.03)
        let bent = try #require(projector.pixel(enu: direction))
        #expect(simd_distance(plain, bent) > 5)
        #expect(Angle.separation(projector.ray(pixel: bent), direction) < 1e-9)
    }

    @Test func boresightInDeviceMatchesTheCameraFrameRotation() {
        let lens = LensCalibration(boresight: SIMD3(0.004, -0.003, 0.002))
        let attitude = FrameWarpTests.base
        let drawn = CameraPose.deviceToCamera * simd_double3x3(lens.boresightInDevice * attitude)
        let truth = simd_double3x3(lens.boresightRotation) * CameraPose.deviceToCamera * simd_double3x3(attitude)
        for c in 0..<3 { #expect(simd_length(drawn[c] - truth[c]) < 1e-12) }
    }

    @Test func appliesFocalAndPrincipalPointRefinements() {
        let lens = LensCalibration(focalScaleX: 1.002, focalScaleY: 0.999, principalShiftX: 0.001, principalShiftY: -0.002)
        let i = lens.applied(to: SkyCore.CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 540, bufferWidth: 1920, bufferHeight: 1080))
        #expect(abs(i.fx - 1503) < 1e-9 && abs(i.fy - 1498.5) < 1e-9)
        #expect(abs(i.cx - 961.92) < 1e-9 && abs(i.cy - 537.84) < 1e-9)
    }

    @Test func calibrationJSONDecodesPartialSections() throws {
        let timing = try PrecisionCalibration.decode(Data(#"{"timing":{"offsetSeconds":0.012,"readoutSeconds":-0.03}}"#.utf8))
        #expect(timing.timing == TimingCalibration(offsetSeconds: 0.012, readoutSeconds: -0.03))
        #expect(timing.lens == nil)
        let full = PrecisionCalibration(timing: TimingCalibration.none, lens: LensCalibration(focalScaleX: 1.01, boresight: SIMD3(0.001, 0, 0)))
        #expect(try PrecisionCalibration.decode(JSONEncoder().encode(full)) == full)
    }

    /// The shape tools/calibrate_lens.py and tools/analyze_session.py write, including their diagnostics sections.
    @Test func decodesWhatThePythonToolsWrite() throws {
        let json = """
        {
          "timing": {"offsetSeconds": 0.01367, "readoutSeconds": 0.02673},
          "timingFit": {"pairs": 173, "gain": 0.983, "correlation": 0.999, "residualPixels": 0.235, "readoutStandardError": 0.004},
          "lens": {
            "focalScaleX": 1.004, "focalScaleY": 0.997, "principalShiftX": 0.002, "principalShiftY": -0.0015,
            "distortion": {"k1": -0.008, "k2": 0.004},
            "boresight": [0.0061, -0.0044, 0.0035]
          },
          "lensFit": {"rmsPixels": 0.31, "stars": 480, "rejected": 3, "yawDegrees": [7.0], "standardError": {"k1": 0.0001}}
        }
        """
        let calibration = try PrecisionCalibration.decode(Data(json.utf8))
        #expect(calibration.timing == TimingCalibration(offsetSeconds: 0.01367, readoutSeconds: 0.02673))
        let lens = try #require(calibration.lens)
        #expect(lens.focalScaleX == 1.004 && lens.focalScaleY == 0.997)
        #expect(lens.distortion == RadialDistortion(k1: -0.008, k2: 0.004))
        #expect(lens.boresight == SIMD3(0.0061, -0.0044, 0.0035))
    }
}

@Suite struct TapSnapTests {
    @Test func snapsToTheStarCentroid() throws {
        var n = Noise(seed: 11)
        let centre = SIMD2(31.3, 28.7)
        var pixels = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<64 {
            for x in 0..<64 {
                let dx = Double(x) + 0.5 - centre.x, dy = Double(y) + 0.5 - centre.y
                let v = 20 + 2 * n.gaussian() + 120 * exp(-(dx * dx + dy * dy) / (2 * 1.4 * 1.4))
                pixels[y * 64 + x] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        let window = LuminanceWindow(width: 64, height: 64, origin: SIMD2(100, 200), pixels: pixels)
        let snapped = try #require(TapSnap.star(in: window, near: SIMD2(100 + 36, 200 + 25), radius: 12))
        #expect(simd_distance(snapped, SIMD2(100 + centre.x, 200 + centre.y)) < 0.15)
        #expect(TapSnap.star(in: window, near: SIMD2(100 + 4, 200 + 4), radius: 3) == nil)
    }

    private func moonWindow(centre: SIMD2<Double>, radius: Double, litFrom: Double?) -> LuminanceWindow {
        var pixels = [UInt8](repeating: 0, count: 48 * 48)
        for y in 0..<48 {
            for x in 0..<48 {
                var covered = 0
                for sy in 0..<4 { for sx in 0..<4 {
                    let p = SIMD2(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4) - centre
                    if simd_length(p) <= radius, litFrom.map({ p.x >= $0 }) ?? true { covered += 1 }
                } }
                pixels[y * 48 + x] = UInt8(15 + 200 * Double(covered) / 16)
            }
        }
        return LuminanceWindow(width: 48, height: 48, origin: SIMD2(500, 300), pixels: pixels)
    }

    @Test func findsTheMoonDiscCentreForFullAndCrescentPhases() throws {
        let centre = SIMD2(23.6, 24.4), radius = 7.0
        for litFrom in [nil, -2.0, 2.5, 4.5] as [Double?] {
            let window = moonWindow(centre: centre, radius: radius, litFrom: litFrom)
            let found = try #require(TapSnap.moon(in: window, near: SIMD2(500 + 22, 300 + 26), radius: radius))
            let error = simd_distance(found, SIMD2(500 + centre.x, 300 + centre.y))
            #expect(error < 0.6, "phase edge \(String(describing: litFrom)): off by \(error) px")
        }
    }
}
