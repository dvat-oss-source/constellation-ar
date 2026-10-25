import Foundation
import Testing
import simd
@testable import SkyCore

struct SweepOutcome {
    var locks: [(t: Double, id: String)] = []
    var events: [(t: Double, event: LockEvent)] = []
    var dwells: [(id: String, start: Double, end: Double)] = []
    var lockPerFrame: [(t: Double, id: String?)] = []
    var rangeViolations: [String] = []
    var narrated: [String] = []
    var minimumAltitudeDegrees: Double = 90

    var sequence: [String] { locks.map(\.id) }

    var description: String {
        locks.map { "\($0.id)@\(String(format: "%.2f", $0.t))" }.joined(separator: " → ")
    }

    /// Times at which a lock returned to the constellation locked two steps earlier within `window` seconds.
    func returns(within window: Double) -> [String] {
        zip(zip(locks, locks.dropFirst()), locks.dropFirst(2)).compactMap { pair, c in
            let (a, b) = pair
            return c.id == a.id && c.t - b.t < window ? "\(a.id)→\(b.id)→\(c.id)@\(c.t)" : nil
        }
    }

    var shortestHold: Double {
        zip(locks, locks.dropFirst()).map { $1.t - $0.t }.min() ?? .infinity
    }

    /// Frames during each dwell (after `settle` seconds) whose lock is not the dwell target.
    func dwellMisses(settle: Double) -> [String] {
        dwells.flatMap { d in
            lockPerFrame.filter { $0.t >= d.start + settle && $0.t <= d.end && $0.id != d.id }
                .map { "\(d.id) dwell t=\(String(format: "%.2f", $0.t)) lock=\($0.id ?? "-")" }
        }
    }
}

enum SweepSimulation {
    static let targets = ["Ori", "UMa", "Cas"]

    /// Dwell on each figure centroid, panning between them along great circles at `speed` °/s, sampled at `fps`,
    /// with optional hand jitter (uniform ±`jitter`°, knots at 10 Hz, linearly interpolated).
    static func run(speed: Double, fps: Double, jitter: Double, seed: UInt64, dwell: Double = 3) throws -> SweepOutcome {
        let scorer = try #require(LockTestData.scorer)
        let roman = try #require(LockTestData.roman)
        let session = LockTestData.session, instant = LockTestData.sweepInstant
        let m = session.icrsToENU(at: instant)
        let points = try targets.map { session.enu(icrs: try #require(scorer.figure($0)).centroid, at: instant) }

        var out = SweepOutcome()
        out.minimumAltitudeDegrees = points.map { Angle.degrees(asin($0.z)) }.min()!
        var legs: [(start: Double, end: Double, from: Int, to: Int)] = []
        var t = 0.0
        for i in points.indices {
            if i > 0 {
                let pan = Angle.degrees(Angle.separation(points[i - 1], points[i])) / speed
                legs.append((t, t + pan, i - 1, i))
                t += pan
            }
            legs.append((t, t + dwell, i, i))
            out.dwells.append((targets[i], t, t + dwell))
            t += dwell
        }
        let total = t

        var g = LockRNG(seed: seed)
        let knots = (0...Int(total * 10) + 2).map { _ in
            SIMD2(LockTestData.uniform(-jitter...jitter, &g), LockTestData.uniform(-jitter...jitter, &g))
        }
        var coordinator = ConstellationLockCoordinator<LockRNG>(schedules: LockTestData.schedules, seed: seed)
        let frames = Int((total * fps).rounded(.down))
        for k in 0...frames {
            let t = Double(k) / fps
            let leg = legs.first { t <= $0.end } ?? legs[legs.count - 1]
            var dir = leg.from == leg.to ? points[leg.from]
                : LockTestData.slerp(points[leg.from], points[leg.to], (t - leg.start) / (leg.end - leg.start))
            if jitter > 0 {
                let u = t * 10, k0 = Int(u), f = u - Double(k0)
                let offset = Angle.radians(1) * (knots[k0] * (1 - f) + knots[k0 + 1] * f)
                let right = simd_normalize(simd_cross(dir, SIMD3(0, 0, 1)))
                let up = simd_cross(right, dir)
                dir = simd_normalize(dir + offset.x * right + offset.y * up)
            }
            let projector = LockTestData.projector(looking: dir)
            let official = ConstellationScorer.officialConstellation(projector: projector, session: session,
                                                                     at: instant, roman: roman)
            let scores = scorer.scores(projector: projector, skyToENU: m, officialID: official)
            let update = coordinator.update(time: t, scores: scores)
            for e in update.events {
                out.events.append((t, e))
                switch e {
                case .locked(let id), .changed(from: _, to: let id): out.locks.append((t, id))
                case .unlocked: break
                }
            }
            if let n = update.narrate { out.narrated.append(n) }
            out.rangeViolations += LockTestData.unitRangeViolations(coordinator.frame(at: t)).map { "t=\(t) \($0)" }
            out.lockPerFrame.append((t, coordinator.currentLock))
        }
        return out
    }
}

@Suite struct SweepTests {
    @Test(.enabled(if: LockTestData.hasSky))
    func targetsAreWellAboveTheHorizon() throws {
        let outcome = try SweepSimulation.run(speed: 40, fps: 10, jitter: 0, seed: 1, dwell: 0.5)
        print("SKYCORE sweep minimum target altitude \(String(format: "%.1f", outcome.minimumAltitudeDegrees))°")
        #expect(outcome.minimumAltitudeDegrees > 25)
    }

    /// Fast pan: intermediate constellations never lead long enough, so exactly one change per transition.
    @Test(.enabled(if: LockTestData.hasSky), arguments: [(40.0, 60.0, 0.0), (40, 30, 0.5)])
    func fastPanLocksExactlyOriUMaCas(speed: Double, fps: Double, jitter: Double) throws {
        let outcome = try SweepSimulation.run(speed: speed, fps: fps, jitter: jitter, seed: 7)
        print("SKYCORE sweep fast \(Int(speed))°/s \(Int(fps))fps jitter±\(jitter)°: \(outcome.description)")
        #expect(outcome.sequence == SweepSimulation.targets)
        #expect(outcome.events.count == 3, "\(outcome.events)")
        #expect(outcome.narrated == SweepSimulation.targets)
        #expect(outcome.dwellMisses(settle: 1).isEmpty, "\(outcome.dwellMisses(settle: 1).prefix(3))")
        #expect(outcome.rangeViolations.isEmpty, "\(outcome.rangeViolations.prefix(3))")
    }

    /// Slow pan with hand jitter: intermediate constellations may lock, but cleanly (no flicker).
    @Test(.enabled(if: LockTestData.hasSky), arguments: [UInt64(1), 2, 3])
    func slowJitteryPanNeverFlickers(seed: UInt64) throws {
        let outcome = try SweepSimulation.run(speed: 5, fps: 30, jitter: 0.5, seed: seed)
        print("SKYCORE sweep slow 5°/s 30fps jitter±0.5° seed \(seed): \(outcome.description)")
        #expect(outcome.returns(within: 2).isEmpty, "\(outcome.returns(within: 2))")
        #expect(outcome.shortestHold >= 0.7 - 1e-9)
        #expect(outcome.events.allSatisfy { if case .unlocked = $0.event { false } else { true } })
        #expect(outcome.dwellMisses(settle: 1).isEmpty, "\(outcome.dwellMisses(settle: 1).prefix(3))")
        #expect(Array(outcome.sequence.prefix(1)) == ["Ori"] && outcome.sequence.last == "Cas")
        #expect(outcome.sequence.contains("UMa"))
        #expect(outcome.rangeViolations.isEmpty, "\(outcome.rangeViolations.prefix(3))")
    }

    @Test(.enabled(if: LockTestData.hasSky))
    func scoringCostPerFrameIsReported() throws {
        let scorer = try #require(LockTestData.scorer)
        let roman = try #require(LockTestData.roman)
        let session = LockTestData.session, instant = LockTestData.sweepInstant
        let m = session.icrsToENU(at: instant)
        let forward = session.enu(icrs: try #require(scorer.figure("Ori")).centroid, at: instant)
        let projectors = (0..<200).map {
            LockTestData.projector(looking: LockTestData.rotate(forward, about: SIMD3(0, 0, 1),
                                                                by: Angle.radians(Double($0) * 0.5)))
        }
        var checksum = 0.0
        let elapsed = ContinuousClock().measure {
            for p in projectors {
                let official = ConstellationScorer.officialConstellation(projector: p, session: session, at: instant,
                                                                         roman: roman)
                checksum += scorer.evaluate(projector: p, skyToENU: m, officialID: official).first?.score ?? 0
            }
        }
        let samples = scorer.figures.map(\.samples.count).reduce(0, +)
        print("SKYCORE scoring cost (debug build): \(elapsed / projectors.count) per frame, \(samples) samples total")
        #expect(checksum > 0)
    }

    /// Other pan speeds: reported, and always flicker-free.
    @Test(.enabled(if: LockTestData.hasSky), arguments: [10.0, 20, 30, 35, 45, 60])
    func otherPanSpeedsNeverFlicker(speed: Double) throws {
        let outcome = try SweepSimulation.run(speed: speed, fps: 60, jitter: 0.5, seed: 11)
        print("SKYCORE sweep \(Int(speed))°/s 60fps jitter±0.5°: \(outcome.description)")
        #expect(outcome.returns(within: 2).isEmpty)
        #expect(outcome.shortestHold >= 0.7 - 1e-9)
        #expect(outcome.sequence.first == "Ori" && outcome.sequence.last == "Cas" && outcome.sequence.contains("UMa"))
        #expect(outcome.rangeViolations.isEmpty)
    }
}
