import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct LockEngineTests {
    static let frame = 1.0 / 60

    @discardableResult
    static func run(_ engine: inout LockEngine, from t0: Double, to t1: Double, fps: Double = 60,
                    scores: (Double) -> [String: Double]) -> [(time: Double, event: LockEvent)] {
        var out: [(time: Double, event: LockEvent)] = []
        var k = 0
        while true {
            let t = t0 + Double(k) / fps
            if t >= t1 - 1e-12 { break }
            for e in engine.update(time: t, scores: scores(t)) { out.append((t, e)) }
            k += 1
        }
        return out
    }

    @Test func locksLeaderAfterInitialDwell() {
        var engine = LockEngine()
        let events = Self.run(&engine, from: 0, to: 2) { _ in ["Ori": 1.0, "Tau": 0.5] }
        #expect(events.map(\.event) == [.locked("Ori")])
        let t = events.first?.time ?? -1
        #expect(t >= 0.3 - 1e-9 && t < 0.3 + 2 * Self.frame)
    }

    @Test func belowMinimumScoreNeverLocks() {
        var engine = LockEngine()
        let events = Self.run(&engine, from: 0, to: 5) { _ in ["Ori": 0.1] }
        #expect(events.isEmpty)
        #expect(engine.currentLock == nil)
    }

    @Test func challengerMustHoldSevenTenthsAndLeadByTwentyPercent() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        #expect(engine.currentLock == "A")
        let events = Self.run(&engine, from: 1, to: 3) { _ in ["A": 1, "B": 1.25] }
        #expect(events.map(\.event) == [.changed(from: "A", to: "B")])
        let t = events.first?.time ?? -1
        #expect(t >= 1.7 - 1e-9 && t < 1.7 + 2 * Self.frame)
    }

    @Test func exactlyTwentyPercentQualifies() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        let events = Self.run(&engine, from: 1, to: 3) { _ in ["A": 1, "B": 1.2] }
        #expect(events.map(\.event) == [.changed(from: "A", to: "B")])
    }

    @Test func lessThanTwentyPercentNeverSwitches() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        let events = Self.run(&engine, from: 1, to: 60) { _ in ["A": 1, "B": 1.19] }
        #expect(events.isEmpty)
        #expect(engine.currentLock == "A")
    }

    @Test func equalishScoresNeverSwitch() {
        var engine = LockEngine()
        var g = LockRNG(seed: 11)
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1, "B": 0.9] }
        #expect(engine.currentLock == "A")
        let events = Self.run(&engine, from: 1, to: 120) { _ in
            ["A": LockTestData.uniform(0.92...1.08, &g), "B": LockTestData.uniform(0.92...1.08, &g),
             "C": LockTestData.uniform(0.92...1.08, &g)]
        }
        #expect(events.isEmpty)
    }

    @Test func briefSpikesNeverSwitch() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        let events = Self.run(&engine, from: 1, to: 30) { t in
            let phase = (t - 1).truncatingRemainder(dividingBy: 0.75)
            return ["A": 1, "B": phase < 0.65 ? 3 : 0.5]
        }
        #expect(events.isEmpty)
    }

    @Test func timerRestartsWhenChallengerStopsQualifying() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        var events = Self.run(&engine, from: 1, to: 1.6) { _ in ["A": 1, "B": 1.5] }
        events += Self.run(&engine, from: 1.6, to: 1.62) { _ in ["A": 1, "B": 1.1] }
        events += Self.run(&engine, from: 1.62, to: 2.2) { _ in ["A": 1, "B": 1.5] }
        #expect(events.isEmpty)
        events = Self.run(&engine, from: 2.2, to: 3) { _ in ["A": 1, "B": 1.5] }
        #expect(events.map(\.event) == [.changed(from: "A", to: "B")])
        #expect(abs((events.first?.time ?? 0) - 2.32) < 2 * Self.frame)
    }

    @Test func timerRestartsWhenADifferentChallengerTakesOver() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        let alternating = Self.run(&engine, from: 1, to: 11) { t in
            Int((t - 1) / 0.5) % 2 == 0 ? ["A": 1, "B": 2, "C": 1.5] : ["A": 1, "B": 1.5, "C": 2]
        }
        #expect(alternating.isEmpty)
        let steady = Self.run(&engine, from: 11, to: 12) { _ in ["A": 1, "B": 1.5, "C": 2] }
        #expect(steady.map(\.event) == [.changed(from: "A", to: "C")])
    }

    @Test func unlocksAfterScoreStaysLow() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        let events = Self.run(&engine, from: 1, to: 4) { _ in [:] }
        #expect(events.map(\.event) == [.unlocked("A")])
        #expect(abs((events.first?.time ?? 0) - 2) < 2 * Self.frame)
        #expect(engine.currentLock == nil)
    }

    @Test func staleLockWaitsForAChallengerInsteadOfUnlocking() {
        var engine = LockEngine()
        Self.run(&engine, from: 0, to: 1) { _ in ["A": 1] }
        let whipping = Self.run(&engine, from: 1, to: 5) { t in
            Int((t - 1) / 0.4) % 2 == 0 ? ["B": 1, "C": 0.5] : ["B": 0.5, "C": 1]
        }
        #expect(whipping.isEmpty)
        #expect(engine.currentLock == "A")
        let settled = Self.run(&engine, from: 5, to: 6) { _ in ["C": 1] }
        #expect(settled.map(\.event) == [.changed(from: "A", to: "C")])
    }

    @Test func tiesBreakByIdentifier() {
        var engine = LockEngine()
        let events = Self.run(&engine, from: 0, to: 1) { _ in ["Psc": 1, "And": 1, "Cet": 1] }
        #expect(events.map(\.event) == [.locked("And")])
    }

    /// Checks the anti-flicker rule from the outside on random score streams: every change must be preceded by
    /// ≥ 0.7 s in which the new constellation led everything else and scored ≥ 1.2× the old lock.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5])
    func randomScoreStreamsRespectAntiFlickerRule(seed: UInt64) {
        var g = LockRNG(seed: seed)
        let ids = ["A", "B", "C", "D", "E"]
        var level = Dictionary(uniqueKeysWithValues: ids.map { ($0, LockTestData.uniform(0...1.5, &g)) })
        var history: [(t: Double, scores: [String: Double])] = []
        var engine = LockEngine()
        var locks: [(t: Double, id: String)] = []
        let fps = 30.0
        for k in 0..<Int(300 * fps) {
            let t = Double(k) / fps
            for id in ids {
                level[id] = min(max(level[id]! + LockTestData.uniform(-0.08...0.08, &g), 0), 2)
            }
            history.append((t, level))
            for e in engine.update(time: t, scores: level) {
                switch e {
                case .locked(let id): locks.append((t, id))
                case .changed(let from, let to):
                    locks.append((t, to))
                    let window = history.filter { $0.t >= t - 0.7 - 1e-9 }
                    #expect(window.first.map { t - $0.t } ?? 0 >= 0.7 - 1e-9)
                    for h in window {
                        let s = h.scores
                        #expect(s[to]! >= 1.2 * s[from]!)
                        #expect(ids.allSatisfy { $0 == to || s[$0]! <= s[to]! })
                    }
                case .unlocked: Issue.record("scores never go to zero for long, unexpected unlock")
                }
            }
        }
        #expect(locks.count > 2)
        for (a, b) in zip(locks, locks.dropFirst()) {
            #expect(b.t - a.t >= 0.7 - 1e-9)
        }
    }
}

@Suite struct LockCooldownTests {
    @Test func splitMix64MatchesReferenceSequence() {
        var g = LockRNG(seed: 0)
        let first = g.next(), second = g.next()
        #expect(first == 0xE220_A839_7B1D_CDAF)
        #expect(second == 0x6E78_9E6A_A1B9_65F4)
    }

    @Test func durationsStayWithin30To45AndSpanTheRange() {
        var cooldown = NarrationCooldown<LockRNG>(seed: 42)
        var lo = Double.infinity, hi = -Double.infinity
        for i in 0..<10_000 {
            let d = cooldown.markNarrated("C\(i % 13)", at: Double(i))
            lo = min(lo, d)
            hi = max(hi, d)
        }
        #expect(lo >= 30 && hi <= 45)
        #expect(lo < 30.1 && hi > 44.9)
    }

    @Test func blocksWithin30sAllowsAfter45s() {
        var g = LockRNG(seed: 5)
        for k in 0..<200 {
            var cooldown = NarrationCooldown<LockRNG>(seed: UInt64(k))
            let t0 = LockTestData.uniform(0...1000, &g)
            let first = cooldown.narrateIfAllowed("Ori", at: t0)
            let early = cooldown.narrateIfAllowed("Ori", at: t0 + 15)
            #expect(first)
            #expect(!early)
            #expect(!cooldown.canNarrate("Ori", at: t0 + 29.999))
            #expect(cooldown.canNarrate("Ori", at: t0 + 45))
            #expect(cooldown.canNarrate("UMa", at: t0 + 1))
            let next = cooldown.nextAllowedTime(for: "Ori")!
            #expect(next - t0 >= 30 && next - t0 <= 45)
        }
    }

    @Test func simulatedRequestsNeverRepeatWithin30s() {
        var cooldown = NarrationCooldown<LockRNG>(seed: 99)
        var g = LockRNG(seed: 100)
        let ids = ["Ori", "UMa", "Cas", "Leo", "Cyg"]
        var last: [String: Double] = [:]
        var t = 0.0
        var narrated = 0
        while t < 4 * 3600 {
            t += LockTestData.uniform(0.1...6, &g)
            let id = ids[Int(g.next() % UInt64(ids.count))]
            let allowed = cooldown.narrateIfAllowed(id, at: t)
            if let previous = last[id] {
                if allowed { #expect(t - previous >= 30) } else { #expect(t - previous < 45) }
            } else {
                #expect(allowed)
            }
            if allowed {
                last[id] = t
                narrated += 1
            }
        }
        #expect(narrated > 100)
    }

    @Test func sameSeedSameDurations() {
        var a = NarrationCooldown<LockRNG>(seed: 7), b = NarrationCooldown<LockRNG>(seed: 7)
        let da = (0..<50).map { a.markNarrated("X", at: Double($0) * 100) }
        let db = (0..<50).map { b.markNarrated("X", at: Double($0) * 100) }
        #expect(da == db)
    }
}

@Suite struct LockScoringTests {
    /// A closed square figure of side `size` degrees centred on `center` (ENU frame).
    static func square(_ id: String, at center: SIMD3<Double>, size: Double = 6, magnitude: Double = 3) -> FigureGeometry {
        let c = simd_normalize(center)
        let east = simd_normalize(simd_cross(SIMD3(0, 0, 1), c))
        let north = simd_cross(c, east)
        let h = Angle.radians(size / 2)
        let corners = [(-h, -h), (h, -h), (h, h), (-h, h)].map { simd_normalize(c + $0.0 * east + $0.1 * north) }
        let segments = (0..<4).map {
            FigureGeometry.Segment(start: corners[$0], end: corners[($0 + 1) % 4], magnitude: magnitude)
        }
        return FigureGeometry(id: id, segments: segments)
    }

    static let forward = simd_normalize(SIMD3<Double>(0, 1, 0.8))

    static func offset(_ degrees: Double) -> SIMD3<Double> {
        LockTestData.rotate(forward, about: SIMD3(0, 0, 1), by: Angle.radians(degrees))
    }

    @Test func centredFigureBeatsOffCentreFigure() {
        let scorer = ConstellationScorer(figures: [Self.square("Mid", at: Self.forward),
                                                  Self.square("Off", at: Self.offset(9))])
        let result = scorer.evaluate(projector: LockTestData.projector(looking: Self.forward),
                                     skyToENU: matrix_identity_double3x3, officialID: nil)
        #expect(result.map(\.id) == ["Mid", "Off"])
        let mid = result[0]
        #expect(mid.coverage > 0.9 && mid.coverage <= 1)
        #expect(result[1].coverage > 0 && result[1].coverage < mid.coverage)
    }

    @Test func offScreenAndBehindFiguresScoreNothing() {
        let scorer = ConstellationScorer(figures: [Self.square("Side", at: Self.offset(60)),
                                                  Self.square("Behind", at: -Self.forward)])
        let result = scorer.evaluate(projector: LockTestData.projector(looking: Self.forward),
                                     skyToENU: matrix_identity_double3x3, officialID: nil)
        #expect(result.isEmpty)
    }

    @Test func officialConstellationGetsBonusEvenWithoutFigure() {
        let config = LockScoringConfig()
        let scorer = ConstellationScorer(figures: [Self.square("Fig", at: Self.offset(12))], config: config)
        let result = scorer.evaluate(projector: LockTestData.projector(looking: Self.forward),
                                     skyToENU: matrix_identity_double3x3, officialID: "Off")
        let official = result.first { $0.id == "Off" }
        #expect(official?.isOfficial == true)
        #expect(official?.coverage == 0)
        #expect(abs((official?.score ?? 0) - config.romanBonus) < 1e-12)
    }

    @Test func brighterFigureOutscoresFainterTwin() {
        let scorer = ConstellationScorer(figures: [Self.square("Bright", at: Self.offset(-8), magnitude: 1),
                                                  Self.square("Faint", at: Self.offset(8), magnitude: 5)])
        let scores = scorer.scores(projector: LockTestData.projector(looking: Self.forward),
                                   skyToENU: matrix_identity_double3x3, officialID: nil)
        #expect(scores["Bright"]! > scores["Faint"]!)
    }

    @Test func icrsRoundTripThroughENU() {
        let session = LockTestData.session
        let p = simd_normalize(SIMD3<Double>(0.3, -0.5, 0.8))
        let enu = session.enu(icrs: p, at: LockTestData.sweepInstant)
        let back = ConstellationScorer.icrs(fromENU: enu, session: session, at: LockTestData.sweepInstant)
        #expect(Angle.separation(p, back) < 1e-12)
    }

    /// Aims 1–2° beyond the official boundary just outside Rigel, Saiph and Betelgeuse (into Lepus, Eridanus and
    /// Monoceros) with a 60° portrait camera at several roll angles: the Roman lookup names the neighbour, the
    /// stick-figure override must still pick Orion.
    @Test(.enabled(if: LockTestData.hasSky))
    func aimingJustPastOrionsEdgeStillPicksOrion() throws {
        let scorer = try #require(LockTestData.scorer)
        let roman = try #require(LockTestData.roman)
        let catalog = try #require(LockTestData.catalog)
        let session = LockTestData.session, instant = LockTestData.sweepInstant
        let ori = try #require(scorer.figure("Ori"))
        let m = session.icrsToENU(at: instant)
        func east(_ hip: Int) -> SIMD3<Double> {
            simd_normalize(simd_cross(SIMD3<Double>(0, 0, 1), catalog.star(hip: hip)!.directionDouble))
        }
        let cases: [(name: String, hip: Int, outward: SIMD3<Double>?, neighbour: String)] = [
            ("Rigel→Lep", 24436, nil, "Lep"), ("Saiph→Lep", 27366, nil, "Lep"),
            ("Rigel→Eri", 24436, -east(24436), "Eri"), ("Betelgeuse→Mon", 27989, east(27989), "Mon"),
        ]
        var tested = 0
        for c in cases {
            let star = catalog.star(hip: c.hip)!.directionDouble
            var dir = c.outward ?? (star - ori.centroid)
            dir = simd_normalize(dir - simd_dot(dir, star) * star)
            let target = simd_normalize(star + dir)
            var boundary = 0.0
            while roman.constellation(icrs: LockTestData.move(star, toward: target, by: Angle.radians(boundary))) == "Ori",
                  boundary < 15 {
                boundary += 0.05
            }
            for extra in [1.0, 2.0] {
                let aimICRS = LockTestData.move(star, toward: target, by: Angle.radians(boundary + extra))
                let official = roman.constellation(icrs: aimICRS)
                #expect(official == c.neighbour, "\(c.name) +\(extra)°")
                let aim = session.enu(icrs: aimICRS, at: instant)
                let zenithUp = SIMD3<Double>(0, 0, 1)
                for roll in [-30.0, 0, 30] {
                    let up = LockTestData.rotate(zenithUp, about: aim, by: Angle.radians(roll))
                    let projector = LockTestData.projector(looking: aim, up: up)
                    let officialAtCentre = ConstellationScorer.officialConstellation(
                        projector: projector, session: session, at: instant, roman: roman)
                    let result = scorer.evaluate(projector: projector, skyToENU: m, officialID: officialAtCentre)
                    let summary = result.prefix(3).map { "\($0.id) \(String(format: "%.2f", $0.score))" }
                    print("SKYCORE edge \(c.name) boundary=\(String(format: "%.1f", boundary))° +\(extra)° roll=\(roll) official=\(officialAtCentre ?? "-") top=\(summary)")
                    #expect(result.first?.id == "Ori", "\(c.name) +\(extra)° roll \(roll): \(summary)")
                    tested += 1
                }
            }
        }
        #expect(tested == 24)
    }

    /// Aiming at the length-weighted centroid of a well-known figure (several rolls) picks that constellation.
    @Test(.enabled(if: LockTestData.hasSky))
    func figureCentroidsPickTheirOwnConstellation() throws {
        let scorer = try #require(LockTestData.scorer)
        let roman = try #require(LockTestData.roman)
        let session = LockTestData.session, instant = LockTestData.sweepInstant
        let m = session.icrsToENU(at: instant)
        let famous = ["Ori", "UMa", "Cas", "Leo", "Cyg", "Lyr", "Sco", "Cru", "Tau", "Gem", "CMa", "Peg", "And",
                      "Per", "Aql", "Sgr", "Boo", "Vir", "Her", "Aur", "Cep", "Dra", "UMi", "Cen", "Del", "CMi"]
        var misses: [String] = []
        for figure in scorer.figures {
            let aim = m * figure.centroid
            var won = true
            for roll in [0.0, 60, 120] {
                let up = LockTestData.rotate(SIMD3(0, 0, 1), about: aim, by: Angle.radians(roll))
                let projector = LockTestData.projector(looking: aim, up: up)
                let official = ConstellationScorer.officialConstellation(projector: projector, session: session,
                                                                         at: instant, roman: roman)
                let best = scorer.evaluate(projector: projector, skyToENU: m, officialID: official).first?.id
                if best != figure.id {
                    won = false
                    misses.append("\(figure.id)→\(best ?? "-")@\(Int(roll))")
                }
            }
            if famous.contains(figure.id) { #expect(won, "\(figure.id)") }
        }
        print("SKYCORE centroid misses (\(misses.count)): \(misses.joined(separator: " "))")
    }
}

@Suite struct LockCoordinatorTests {
    static func schedule(_ id: String) -> DrawInSchedule {
        DrawInSchedule(id: id, pairs: [(1, 2), (2, 3)], magnitudes: [1: 2, 2: 1, 3: 3])
    }

    @Test func lockEventsDriveTimelineAndNarration() {
        var c = ConstellationLockCoordinator<LockRNG>(
            schedules: ["A": Self.schedule("A"), "B": Self.schedule("B")], seed: 3)
        var narrated: [(Double, String)] = []
        var events: [LockEvent] = []
        func run(_ t0: Double, _ t1: Double, _ scores: [String: Double]) {
            var t = t0
            while t < t1 - 1e-9 {
                let u = c.update(time: t, scores: scores)
                events += u.events
                if let n = u.narrate { narrated.append((t, n)) }
                #expect(LockTestData.unitRangeViolations(c.frame(at: t)).isEmpty)
                t += 1.0 / 60
            }
        }
        run(0, 3, ["A": 1])
        #expect(c.timeline.lockedID == "A")
        run(3, 6, ["A": 0.2, "B": 1])
        #expect(c.timeline.lockedID == "B")
        run(6, 9, ["A": 1, "B": 0.2])
        #expect(c.timeline.lockedID == "A")
        #expect(c.frame(at: 9).last?.mode == .recalled)
        run(9, 60, ["A": 1, "B": 0.2])
        run(60, 62, ["A": 0.2, "B": 1])
        #expect(events == [.locked("A"), .changed(from: "A", to: "B"), .changed(from: "B", to: "A"),
                           .changed(from: "A", to: "B")])
        #expect(narrated.map(\.1) == ["A", "B", "B"])
        #expect(c.cooldown.nextAllowedTime(for: "A") != nil)
    }

    @Test func unknownConstellationStillLocksWithLabelOnly() {
        var c = ConstellationLockCoordinator<LockRNG>(schedules: [:], seed: 1)
        var t = 0.0
        while t < 4 {
            _ = c.update(time: t, scores: ["Xyz": 1])
            t += 1.0 / 30
        }
        let v = c.frame(at: 4).last
        #expect(v?.id == "Xyz")
        #expect(v?.segments.isEmpty == true)
        #expect(v?.label == 1)
    }
}
