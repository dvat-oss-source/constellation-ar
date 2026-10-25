import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct StarDetectorTests {
    @Test func centroidErrorOnGaussianPSFs() {
        var g = SplitMixRNG(seed: 11)
        let frame = SyntheticFrame(width: 400, height: 300, noiseSigma: 2)
        var errors: [Double] = []
        var missed = 0
        for trial in 0..<200 {
            var f = frame
            f.psfSigma = Double.random(in: 1.0...1.9, using: &g)
            let truth = SIMD2(Double.random(in: 40..<360, using: &g), Double.random(in: 40..<260, using: &g))
            let peak = Double.random(in: 40...200, using: &g)
            let flux = peak * 2 * .pi * f.psfSigma * f.psfSigma
            f.zeroMagnitudeFlux = flux
            let pixels = f.render([SyntheticStar(pixel: truth, magnitude: 0)], seed: UInt64(trial))
            let found = StarDetector.detect(luminance: pixels, width: f.width, height: f.height, rowBytes: f.width, maxStars: 3)
            guard let best = found.first else { missed += 1; continue }
            errors.append(simd_distance(best.position, truth))
        }
        let rms = (errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count)).squareRoot()
        report(String(format: "detector: centroid rms %.3f px, max %.3f px over %d PSFs (%d missed)", rms, errors.max() ?? 0, errors.count, missed))
        #expect(missed == 0)
        #expect((errors.max() ?? 1) < 0.1)
    }

    @Test func rowStrideIsHonoured() {
        let frame = SyntheticFrame(width: 200, height: 150, noiseSigma: 1)
        let truth = SIMD2(87.3, 61.6)
        let tight = frame.render([SyntheticStar(pixel: truth, magnitude: 3)], seed: 1)
        var padded = [UInt8](repeating: 0, count: 224 * 150)
        for y in 0..<150 { for x in 0..<200 { padded[y * 224 + x] = tight[y * 200 + x] } }
        let a = StarDetector.detect(luminance: tight, width: 200, height: 150, rowBytes: 200)
        let b = StarDetector.detect(luminance: padded, width: 200, height: 150, rowBytes: 224)
        #expect(a.count == 1 && b.count == 1)
        #expect(simd_distance(a[0].position, b[0].position) < 1e-9)
    }

    @Test func regionRestrictsDetection() {
        let frame = SyntheticFrame(width: 300, height: 200, noiseSigma: 1.5)
        let stars = [SyntheticStar(pixel: SIMD2(60.2, 50.7), magnitude: 3), SyntheticStar(pixel: SIMD2(220.4, 140.1), magnitude: 3)]
        let pixels = frame.render(stars, seed: 5)
        let all = StarDetector.detect(luminance: pixels, width: 300, height: 200, rowBytes: 300)
        let right = StarDetector.detect(luminance: pixels, width: 300, height: 200, rowBytes: 300,
                                        region: .around(SIMD2(220, 140), radius: 25))
        #expect(all.count == 2)
        #expect(right.count == 1 && simd_distance(right[0].position, stars[1].pixel) < 0.1)
    }

    @Test func hotPixelsAndNoiseGiveNoStars() {
        var frame = SyntheticFrame(width: 1280, height: 720, noiseSigma: 6)
        frame.hotPixels = 150
        var total = 0
        let frames = PlateSolverTests.trials(6)
        for seed in 0..<frames {
            total += StarDetector.detect(luminance: frame.render([], seed: UInt64(seed)), width: 1280, height: 720, rowBytes: 1280).count
        }
        report("detector: \(total) spurious stars in \(frames) noise-only frames at sigma 6 with 150 hot pixels each")
        #expect(total <= frames / 3 + 1)
    }

    @Test func hotPixelBesideStarKeepsStar() {
        var frame = SyntheticFrame(width: 300, height: 200, noiseSigma: 2)
        frame.hotPixels = 60
        let truth = SIMD2(150.4, 100.3)
        let found = StarDetector.detect(luminance: frame.render([SyntheticStar(pixel: truth, magnitude: 2.5)], seed: 8),
                                        width: 300, height: 200, rowBytes: 300, maxStars: 1)
        #expect(found.count == 1 && simd_distance(found[0].position, truth) < 0.15)
    }
}

@Suite struct PlateWahbaTests {
    @Test func recoversRotation() throws {
        var g = SplitMixRNG(seed: 3)
        for _ in 0..<50 {
            let r = plateRandomRotation(&g)
            let ref = (0..<6).map { _ in randomUnitVector(&g) }
            let found = try #require(PlateWahba.rotation(body: ref.map { r * $0 }, reference: ref))
            #expect(rotationAngle(found, r) < 1e-10)
            #expect(abs(found.determinant - 1) < 1e-12)
        }
    }
}

@Suite struct PlateSolverTests {
    /// Debug builds run a tenth of the trials (the detector is ~100x slower unoptimised). `PLATESOLVE_TRIAL_SCALE=5` with
    /// `swift test -c release -Xswiftc -enable-testing` multiplies the release counts for a tighter estimate.
    static func trials(_ base: Int) -> Int {
        #if DEBUG
        let factor = 0.1
        #else
        let factor = 1.0
        #endif
        let scale = Double(ProcessInfo.processInfo.environment["PLATESOLVE_TRIAL_SCALE"] ?? "") ?? 1
        return max(2, Int(Double(base) * factor * scale))
    }

    @Test func databaseHeader() {
        let db = SolverFixtures.database
        report("solver_db: \(db.starCount) stars to mag \(db.magnitudeLimit), \(db.patternCount) patterns, table \(db.tableLength), fov \(db.minFovDegrees)-\(db.maxFovDegrees) deg")
        #expect(db.starCount > 1000 && db.patternCount > 10_000)
    }

    struct TrialStats {
        var trials = 0, solved = 0, wrong = 0
        var errors: [Double] = [], times: [Double] = [], detectTimes: [Double] = [], matches: [Int] = [], detections: [Int] = []
        var failures: [String] = []
    }

    /// Stars rendered from the catalogue through the real `Projector` at random attitudes and fields of view, solved from pixels only.
    static func syntheticTrials(count: Int, width w: Int, height h: Int, magnitudeLimit: Double, missing: Double,
                                noise: ClosedRange<Double>, seed: UInt64) -> TrialStats {
        let solver = PlateSolver(database: SolverFixtures.database)
        var g = SplitMixRNG(seed: seed)
        var stats = TrialStats()
        for trial in 0..<count {
            stats.trials += 1
            let fov = Double.random(in: 52...72, using: &g)
            let truth = plateRandomRotation(&g)
            let truthIntrinsics = SolverFixtures.intrinsics(horizontalDegrees: fov, width: w, height: h)
            let projector = Projector(enuToCamera: truth, intrinsics: truthIntrinsics, mapping: .identity(bufferWidth: Double(w), bufferHeight: Double(h)))
            var stars = SolverFixtures.project(projector, magnitudeLimit: magnitudeLimit) { $0.directionDouble }
            let visible = stars.filter { $0.pixel.x > 0 && $0.pixel.x < Double(w) && $0.pixel.y > 0 && $0.pixel.y < Double(h) }.count
            stars.removeAll { _ in Double.random(in: 0..<1, using: &g) < missing }
            var frame = SyntheticFrame(width: w, height: h, noiseSigma: Double.random(in: noise, using: &g))
            frame.hotPixels = 30
            frame.falseBlobs = 6
            let pixels = frame.render(stars, seed: UInt64(trial) &+ seed &* 1000)
            let t0 = ContinuousClock.now
            let detected = StarDetector.detect(luminance: pixels, width: w, height: h, rowBytes: w, maxStars: 40)
            stats.detectTimes.append((ContinuousClock.now - t0) / .seconds(1))
            stats.detections.append(detected.count)
            // Prior focal length off by up to 3%, as when Apple's intrinsics belong to a slightly different crop.
            var prior = truthIntrinsics
            let priorError = Double.random(in: -0.03...0.03, using: &g)
            prior.fx *= 1 + priorError; prior.fy *= 1 + priorError
            guard let solution = solver.solve(stars: detected, intrinsics: prior) else {
                stats.failures.append("trial \(trial): fov \(Int(fov)) visible \(visible) detected \(detected.count)")
                continue
            }
            let error = Angle.degrees(rotationAngle(solution.cameraFromCatalog, truth))
            if error > 0.2 {
                stats.wrong += 1
            } else {
                stats.solved += 1
                stats.errors.append(error); stats.times.append(solution.solveSeconds); stats.matches.append(solution.matches.count)
            }
        }
        return stats
    }

    static func summary(_ label: String, _ s: TrialStats) -> String {
        func pct(_ v: [Double], _ q: Double) -> Double { let a = v.sorted(); return a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * q))] }
        let rms = (s.errors.map { $0 * $0 }.reduce(0, +) / Double(max(s.errors.count, 1))).squareRoot()
        return String(format: "plate solve [%@]: %.1f%% solved (%d/%d, %d wrong); attitude error rms %.4f deg, p95 %.4f, max %.4f; solve ms median %.2f p95 %.2f max %.2f; detect ms median %.1f; detections median %.0f, matches median %d",
                      label, 100 * Double(s.solved) / Double(s.trials), s.solved, s.trials, s.wrong, rms, pct(s.errors, 0.95), s.errors.max() ?? 0,
                      pct(s.times, 0.5) * 1000, pct(s.times, 0.95) * 1000, (s.times.max() ?? 0) * 1000, pct(s.detectTimes, 0.5) * 1000,
                      pct(s.detections.map(Double.init), 0.5), s.matches.sorted().isEmpty ? 0 : s.matches.sorted()[s.matches.count / 2])
    }

    @Test func syntheticSolveRateAndAccuracy() {
        let s = Self.syntheticTrials(count: Self.trials(200), width: 1280, height: 720, magnitudeLimit: 5.2, missing: 0.2, noise: 2...6, seed: 2026)
        report(Self.summary("mag<=5.2, 20% missing", s))
        for f in s.failures.prefix(8) { report("plate solve failure: \(f)") }
        #expect(s.wrong == 0)
        #expect(Double(s.solved) / Double(s.trials) >= 0.95)
        #expect((s.errors.max() ?? 1) < 0.05)
    }

    /// A phone at night under a mediocre sky: only the brightest stars register, a third of them are lost, noise is high.
    @Test func sparseSkySolveRate() {
        let s = Self.syntheticTrials(count: Self.trials(150), width: 1280, height: 720, magnitudeLimit: 4.0, missing: 0.3, noise: 4...9, seed: 4)
        report(Self.summary("mag<=4.0, 30% missing, noise 4-9", s))
        #expect(s.wrong == 0)
        #expect(Double(s.solved) / Double(s.trials) >= 0.85)
    }

    @Test func fullResolutionTiming() {
        let s = Self.syntheticTrials(count: Self.trials(20), width: 1920, height: 1080, magnitudeLimit: 5.0, missing: 0.2, noise: 3...5, seed: 8)
        report(Self.summary("1920x1080", s))
        #expect(s.wrong == 0 && s.solved >= s.trials - 1)
    }

    @Test func randomStarListsNeverSolve() {
        let solver = PlateSolver(database: SolverFixtures.database)
        var g = SplitMixRNG(seed: 77)
        let intrinsics = SolverFixtures.intrinsics(horizontalDegrees: 63, width: 1920, height: 1080)
        var falseSolves = 0
        var slowest = 0.0
        let trials = Self.trials(2000)
        for _ in 0..<trials {
            let count = Int.random(in: 8...40, using: &g)
            let stars = (0..<count).map { i in
                DetectedStar(x: Double.random(in: 20..<1900, using: &g), y: Double.random(in: 20..<1060, using: &g),
                             flux: Double(count - i) * 10, peak: 20, snr: 10)
            }
            let started = ContinuousClock.now
            if solver.solve(stars: stars, intrinsics: intrinsics) != nil { falseSolves += 1 }
            slowest = max(slowest, (ContinuousClock.now - started) / .seconds(1))
        }
        report(String(format: "plate solve: %d false solves in %d random star lists; slowest rejection %.0f ms", falseSolves, trials, slowest * 1000))
        #expect(falseSolves == 0)
    }

    @Test func randomNoiseImagesNeverSolve() {
        let solver = PlateSolver(database: SolverFixtures.database)
        var falseSolves = 0, detections = 0
        let trials = Self.trials(12)
        for seed in 0..<trials {
            var frame = SyntheticFrame(width: 960, height: 540, noiseSigma: Double(3 + seed % 5))
            frame.hotPixels = 100
            frame.falseBlobs = 25
            let pixels = frame.render([], seed: UInt64(seed) &+ 500)
            let found = StarDetector.detect(luminance: pixels, width: 960, height: 540, rowBytes: 960, maxStars: 40)
            detections += found.count
            if solver.solve(stars: found, intrinsics: SolverFixtures.intrinsics(horizontalDegrees: 63, width: 960, height: 540)) != nil { falseSolves += 1 }
        }
        report("plate solve: \(falseSolves) false solves in \(trials) noise-and-blob images (\(detections) detections)")
        #expect(falseSolves == 0)
    }

    /// Camera pixels → device attitude in the Core Motion reference frame at a real place and time, with aberration and refraction.
    @Test func deviceAttitudeEndToEnd() throws {
        let solver = PlateSolver(database: SolverFixtures.database)
        let location = GeoLocation(latitude: 34.05, longitude: -118.25, height: 100)
        let date = Date(timeIntervalSince1970: 1_787_000_000)
        let session = SkySession(date: date, location: location)
        let instant = AstroInstant(date: date)
        let icrsToENU = session.icrsToENU(at: instant)
        var g = SplitMixRNG(seed: 99)
        let (w, h) = (1280, 720)
        let intrinsics = SolverFixtures.intrinsics(horizontalDegrees: 63, width: w, height: h)
        var errors: [Double] = []
        var attempts = 0
        let wanted = Self.trials(25)
        while errors.count < wanted && attempts < 3 * wanted {
            attempts += 1
            let alt = Double.random(in: 25...80, using: &g), az = Double.random(in: 0..<360, using: &g)
            let pose = CameraPose.looking(at: HorizontalCoordinates(altitude: Angle.radians(alt), azimuth: Angle.radians(az)).enu,
                                          up: SIMD3(Double.random(in: -0.2...0.2, using: &g), Double.random(in: -0.2...0.2, using: &g), 1))
            let projector = Projector(pose: pose, intrinsics: intrinsics, mapping: .identity(bufferWidth: Double(w), bufferHeight: Double(h)))
            let stars = SolverFixtures.project(projector, magnitudeLimit: 5.0) {
                Refraction.standard.apparent(enu: icrsToENU * SkySession.aberrate($0.directionDouble, beta: session.earthVelocityOverC))
            }
            let frame = SyntheticFrame(width: w, height: h, noiseSigma: 3)
            let detected = StarDetector.detect(luminance: frame.render(stars, seed: UInt64(attempts)), width: w, height: h, rowBytes: w, maxStars: 40)
            guard let solution = solver.solve(stars: detected, intrinsics: intrinsics),
                  let fix = PlateSolveAttitude.deviceFromReference(solution, session: session, instant: instant) else { continue }
            let truth = simd_double3x3(simd_quatd(pose.referenceToDevice))
            let error = Angle.degrees(rotationAngle(simd_double3x3(fix.deviceFromReference), truth))
            errors.append(error)
            #expect(fix.sigmaDegrees > 0 && fix.sigmaDegrees < 0.1)
        }
        report(String(format: "device attitude: %d fixes, error rms %.4f deg, max %.4f deg (aberration + refraction modelled)",
                      errors.count, (errors.map { $0 * $0 }.reduce(0, +) / Double(max(errors.count, 1))).squareRoot(), errors.max() ?? 0))
        #expect(errors.count >= wanted * 4 / 5)
        #expect((errors.max() ?? 1) < 0.05)
    }
}
