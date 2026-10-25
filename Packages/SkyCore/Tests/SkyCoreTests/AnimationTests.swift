import Foundation
import Testing
import simd
@testable import SkyCore

struct AnimationFixture: Sendable {
    var name: String
    var pairs: [(Int, Int)]
    var magnitudes: [Int: Double]

    var schedule: DrawInSchedule { DrawInSchedule(id: name, pairs: pairs, magnitudes: magnitudes) }

    static func chain(_ n: Int, seed: UInt64) -> AnimationFixture {
        var g = LockRNG(seed: seed)
        let mags = Dictionary(uniqueKeysWithValues: (1...(n + 1)).map { ($0, LockTestData.uniform(0...5, &g)) })
        return AnimationFixture(name: "chain\(n)", pairs: (1...n).map { ($0, $0 + 1) }, magnitudes: mags)
    }

    static let chain3 = chain(3, seed: 1)
    static let chain30 = chain(30, seed: 2)
    static let chain40 = chain(40, seed: 3)
    static let star10 = AnimationFixture(
        name: "star10", pairs: (1...10).map { (0, $0) },
        magnitudes: Dictionary(uniqueKeysWithValues: (0...10).map { ($0, $0 == 4 ? 0.5 : 2 + Double($0) / 10) }))
    static let twoComponents = AnimationFixture(
        name: "two", pairs: [(1, 2), (2, 3), (3, 1), (3, 4), (10, 11), (11, 12), (12, 13), (13, 14)],
        magnitudes: [1: 3, 2: 2.5, 3: 1, 4: 4, 10: 4, 11: 4.5, 12: 2, 13: 3.5, 14: 5])
    static let single = AnimationFixture(name: "single", pairs: [(7, 8)], magnitudes: [7: 1, 8: 2])
    static let unknownMagnitudes = AnimationFixture(name: "nomag", pairs: [(5, 6), (6, 7), (7, 5)], magnitudes: [6: 2])

    static let synthetic = [chain3, star10, chain30, twoComponents, single, chain40, unknownMagnitudes]
}

enum AnimationChecks {
    /// Every timing/ordering rule of the draw-in for one schedule. `allowCompressed` permits a stagger below 80 ms
    /// only when even 80 ms with the minimum segment duration cannot fit in 1.5 s.
    static func validate(_ s: DrawInSchedule, pairs: [(Int, Int)], magnitudes: [Int: Double],
                         config: DrawInConfig = DrawInConfig()) {
        let name = s.id
        #expect(s.segments.count == pairs.count, "\(name)")
        guard !pairs.isEmpty else { return }

        let mag = { (h: Int) -> Double in magnitudes[h].flatMap { $0.isFinite ? $0 : nil } ?? .infinity }
        let starHips = Set(pairs.flatMap { [$0.0, $0.1] })
        #expect(Set(s.stars.map(\.hip)) == starHips, "\(name)")
        let brightest = starHips.min { mag($0) != mag($1) ? mag($0) < mag($1) : $0 < $1 }!
        #expect(s.stars.first?.hip == brightest, "\(name): first star lit must be the brightest")
        #expect(s.stars.first?.lightStart == 0, "\(name)")
        for (a, b) in zip(s.stars, s.stars.dropFirst()) {
            #expect(mag(a.hip) <= mag(b.hip) && a.lightStart <= b.lightStart, "\(name): brightest first")
        }
        #expect(s.starsLitAt <= s.drawDuration + 1e-9, "\(name): stars all lit during the draw")

        let depth = Dictionary(uniqueKeysWithValues: s.stars.map { ($0.hip, $0.depth) })
        var parent: [Int: Int] = [:]
        for h in starHips { parent[h] = h }
        func find(_ x: Int) -> Int { parent[x] == x ? x : find(parent[x]!) }
        for (a, b) in pairs { parent[find(a)] = find(b) }
        for component in Dictionary(grouping: starHips, by: find).values {
            let roots = component.filter { depth[$0] == 0 }
            let componentBrightest = component.min { mag($0) != mag($1) ? mag($0) < mag($1) : $0 < $1 }!
            #expect(roots == [componentBrightest], "\(name): each component's BFS starts at its brightest star")
        }

        for (i, seg) in s.segments.enumerated() {
            let pair = pairs[i]
            #expect(seg.index == i)
            #expect(seg.reversed ? (seg.toHip, seg.fromHip) == pair : (seg.fromHip, seg.toHip) == pair, "\(name)")
            let df = depth[seg.fromHip]!, dt = depth[seg.toHip]!
            #expect(seg.wave == df && df <= dt && dt <= df + 1, "\(name): BFS order seg \(i)")
            #expect(abs(seg.start - Double(seg.wave) * s.stagger) < 1e-12, "\(name)")
            #expect(seg.start >= Double(df) * s.stagger - 1e-12, "\(name): never starts before its from-star's wave")
        }
        for star in s.stars where star.depth > 0 {
            let reachedBy = s.segments.filter { $0.toHip == star.hip && $0.wave == star.depth - 1 }
            #expect(!reachedBy.isEmpty, "\(name): star \(star.hip) is reached from the previous wave")
        }

        #expect(s.waveCount == (s.segments.map(\.wave).max() ?? -1) + 1)
        let lastEnd = (s.segments.map(\.start).max() ?? 0) + s.segmentDuration
        #expect(abs(s.drawDuration - lastEnd) < 1e-9, "\(name)")
        #expect(s.drawDuration >= config.drawDurationRange.lowerBound - 1e-9
            && s.drawDuration <= config.drawDurationRange.upperBound + 1e-9, "\(name): total \(s.drawDuration)")
        if s.waveCount > 1 {
            if s.isStaggerCompressed {
                let gaps = Double(s.waveCount - 1)
                #expect(gaps * config.staggerRange.lowerBound + config.minimumSegmentDuration
                    > config.drawDurationRange.upperBound, "\(name): compressed only when unavoidable")
                #expect(abs(s.segmentDuration - config.minimumSegmentDuration) < 1e-12)
            } else {
                #expect(config.staggerRange.contains(s.stagger), "\(name): stagger \(s.stagger)")
            }
        }

        #expect(s.labelStart >= s.drawDuration - 1e-12, "\(name): label after draw")
        #expect(s.pulseStart >= s.drawDuration - 1e-12, "\(name): pulse after draw")
        #expect(s.artworkStart >= s.pulseEnd - 1e-12, "\(name): artwork after pulse")
        #expect(s.artworkStart >= s.labelStart + s.labelDuration - 1e-12, "\(name): artwork after label")

        for i in s.segments.indices {
            let start = s.segments[i].start, d = s.segmentDuration
            #expect(s.progress(i, at: start) == 0)
            #expect(s.progress(i, at: start - 0.01) == 0)
            #expect(abs(s.progress(i, at: start + d / 2) - 0.5) < 1e-9, "\(name): ease-in-out midpoint")
            #expect(s.progress(i, at: start + 0.05 * d) < 0.01, "\(name): eases in")
            #expect(s.progress(i, at: start + 0.95 * d) > 0.99, "\(name): eases out")
            #expect(s.progress(i, at: start + d) == 1)
        }

        var peaks = [Double](repeating: 0, count: s.segments.count)
        var falling = [Bool](repeating: false, count: s.segments.count)
        var previous = [Double](repeating: 0, count: s.segments.count)
        var t = -0.1
        while t <= s.completion + 0.5 {
            for i in s.segments.indices {
                let g = s.glow(i, at: t), p = s.progress(i, at: t)
                #expect(g >= 0 && g <= 1 && p >= 0 && p <= 1 && s.glowPosition(i, at: t) >= 0
                    && s.glowPosition(i, at: t) <= 1)
                if t <= s.pulseStart || t >= s.pulseEnd { #expect(g == 0, "\(name): glow only during the pulse") }
                if g < previous[i] - 1e-12 { falling[i] = true }
                if falling[i] && g > previous[i] + 1e-12 { Issue.record("\(name): seg \(i) glows twice") }
                peaks[i] = max(peaks[i], g)
                previous[i] = g
            }
            for j in s.stars.indices { #expect(s.starAlpha(j, at: t) >= 0 && s.starAlpha(j, at: t) <= 1) }
            #expect(s.labelAlpha(at: t) >= 0 && s.labelAlpha(at: t) <= 1)
            #expect(s.artworkAlpha(at: t) >= 0 && s.artworkAlpha(at: t) <= 1)
            t += 0.005
        }
        #expect(peaks.allSatisfy { $0 > 0.9 }, "\(name): the pulse reaches every segment")
        #expect(s.labelAlpha(at: s.labelStart) == 0 && s.labelAlpha(at: s.labelStart + s.labelDuration) == 1)
        #expect(s.artworkAlpha(at: s.artworkStart) == 0 && s.artworkAlpha(at: s.completion) == 1)
    }
}

@Suite struct AnimationScheduleTests {
    @Test(arguments: AnimationFixture.synthetic)
    func syntheticFiguresMeetDrawInRules(fixture: AnimationFixture) {
        AnimationChecks.validate(fixture.schedule, pairs: fixture.pairs, magnitudes: fixture.magnitudes)
    }

    @Test func timingSolverCases() {
        #expect(AnimationFixture.single.schedule.drawDuration == 1.0)
        let chain3 = AnimationFixture.chain3.schedule
        #expect(chain3.stagger == 0.1)
        #expect(abs(chain3.drawDuration - ((Double(chain3.waveCount) - 1) * 0.1 + chain3.segmentDuration)) < 1e-12)
        let star = AnimationFixture.star10.schedule
        #expect(star.waveCount == 2)
        #expect(star.stars.first?.hip == 4)
        let chain30 = AnimationFixture.chain30.schedule
        #expect(chain30.drawDuration <= 1.5 + 1e-9)
        let deep = DrawInSchedule(id: "deep", pairs: (1...40).map { ($0, $0 + 1) }, magnitudes: [1: 0])
        #expect(deep.waveCount == 40)
        #expect(deep.isStaggerCompressed)
        #expect(abs(deep.drawDuration - 1.5) < 1e-9)
        let mid = DrawInSchedule(id: "mid", pairs: (1...14).map { ($0, $0 + 1) }, magnitudes: [1: 0])
        #expect(mid.waveCount == 14)
        #expect(!mid.isStaggerCompressed && mid.stagger >= 0.08 && mid.drawDuration <= 1.5 + 1e-9)
    }

    @Test func twoComponentsStartTogetherFromTheirBrightestStars() {
        let s = AnimationFixture.twoComponents.schedule
        let roots = s.stars.filter { $0.depth == 0 }.map(\.hip)
        #expect(roots == [3, 12])
        #expect(s.segments.filter { $0.wave == 0 }.map(\.index).sorted() == [1, 2, 3, 5, 6])
    }

    @Test func emptyFigureOnlyFadesLabel() {
        let s = DrawInSchedule(id: "none", pairs: [], magnitudes: [:])
        #expect(s.waveCount == 0 && s.drawDuration == 0 && s.stars.isEmpty)
        #expect(s.labelAlpha(at: s.labelDuration) == 1)
    }

    @Test(.enabled(if: LockTestData.hasFigures))
    func realConstellationsMeetDrawInRules() throws {
        let lines = try #require(LockTestData.lines)
        let catalog = try #require(LockTestData.catalog)
        var staggers: [Double] = [], totals: [Double] = [], compressed: [String] = []
        for figure in lines.constellations {
            let s = try #require(LockTestData.schedules[figure.id])
            var mags: [Int: Double] = [:]
            for h in figure.starHips { if let star = catalog.star(hip: h) { mags[h] = Double(star.vmag) } }
            AnimationChecks.validate(s, pairs: figure.pairs, magnitudes: mags)
            totals.append(s.drawDuration)
            if s.isStaggerCompressed {
                compressed.append("\(s.id)(waves \(s.waveCount), stagger \(String(format: "%.4f", s.stagger)))")
            } else if s.waveCount > 1 {
                staggers.append(s.stagger)
            }
            if ["Ori", "UMa", "Cas"].contains(s.id) {
                print("SKYCORE drawin \(s.id): segments=\(s.segments.count) waves=\(s.waveCount) stagger=\(String(format: "%.4f", s.stagger)) segDur=\(String(format: "%.3f", s.segmentDuration)) total=\(String(format: "%.3f", s.drawDuration)) label@\(String(format: "%.2f", s.labelStart)) pulse@\(String(format: "%.2f", s.pulseStart))-\(String(format: "%.2f", s.pulseEnd)) artwork@\(String(format: "%.2f", s.artworkStart)) done@\(String(format: "%.2f", s.completion)) first=\(s.stars.first!.hip)")
            }
        }
        print("SKYCORE drawin all \(lines.constellations.count): stagger(min/max, uncompressed)=\(String(format: "%.4f/%.4f", staggers.min() ?? 0, staggers.max() ?? 0)) total(min/max)=\(String(format: "%.3f/%.3f", totals.min() ?? 0, totals.max() ?? 0)) compressed=\(compressed)")
        #expect(compressed.count <= 1)
    }
}

@Suite struct AnimationTimelineTests {
    static let a = AnimationFixture.chain3.schedule
    static let b = AnimationFixture.star10.schedule
    static let c = AnimationFixture.twoComponents.schedule

    static func value(_ v: ConstellationVisual?, segment i: Int) -> Double { v?.segments[i].progress ?? -1 }

    @Test func freshLockDrawsIn() {
        var tl = DrawInTimeline()
        tl.lock(Self.c, at: 10)
        let s = Self.c
        let v0 = tl.visual(for: "two", at: 10)!
        #expect(v0.mode == .drawIn && v0.isLocked && v0.highlight == 1)
        #expect(v0.segments.allSatisfy { $0.progress == 0 } && v0.label == 0 && v0.artwork == 0)
        #expect(v0.stars.allSatisfy { $0.alpha == 0 })
        let lit = tl.visual(for: "two", at: 10 + s.starFadeDuration)!
        #expect(lit.stars.first { $0.hip == 3 }?.alpha == 1)
        let drawn = tl.visual(for: "two", at: 10 + s.drawDuration)!
        #expect(drawn.segments.allSatisfy { $0.progress == 1 } && drawn.label == 0)
        let pulsing = tl.visual(for: "two", at: 10 + s.pulseStart + s.pulseDuration / 2)!
        #expect(pulsing.segments.contains { $0.glow > 0.5 } && pulsing.artwork == 0)
        let done = tl.visual(for: "two", at: 10 + s.completion)!
        #expect(done.label == 1 && done.artwork == 1 && done.segments.allSatisfy { $0.glow == 0 })
    }

    @Test func unlockFadesToRestWithoutAnimating() {
        var tl = DrawInTimeline()
        tl.lock(Self.c, at: 0)
        tl.unlock(at: 0.5)
        let frozen = tl.visual(for: "two", at: 0.5)!
        #expect(!frozen.isLocked)
        var previousHighlight = 1.0
        var t = 0.5
        while t < 0.5 + DrawInConfig().unlockFadeDuration {
            let v = tl.visual(for: "two", at: t)!
            #expect(v.segments.map(\.progress) == frozen.segments.map(\.progress))
            #expect(v.highlight <= previousHighlight + 1e-12)
            previousHighlight = v.highlight
            t += 0.005
        }
        #expect(tl.frame(at: 0.5 + DrawInConfig().unlockFadeDuration).isEmpty)
        #expect(tl.lockedID == nil)
    }

    @Test func onlyTheLockedConstellationAnimates() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        tl.lock(Self.b, at: 0.6)
        let frozen = tl.visual(for: Self.a.id, at: 0.6)!.segments.map(\.progress)
        var t = 0.6
        while t < 2 {
            let frame = tl.frame(at: t)
            #expect(frame.filter(\.isLocked).map(\.id) == [Self.b.id])
            if let outgoing = frame.first(where: { $0.id == Self.a.id }) {
                #expect(outgoing.segments.map(\.progress) == frozen)
                #expect(outgoing.label == 0 && outgoing.artwork == 0)
            }
            t += 0.005
        }
        #expect(tl.frame(at: 2).map(\.id) == [Self.b.id])
    }

    @Test func relockWithinSixtySecondsAppearsDrawn() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        tl.unlock(at: 5)
        tl.lock(Self.a, at: 64.9)
        let v = tl.visual(for: Self.a.id, at: 64.9)!
        #expect(v.mode == .recalled)
        #expect(v.segments.allSatisfy { $0.progress == 1 })
        let settled = tl.visual(for: Self.a.id, at: 64.9 + DrawInConfig().recallFadeDuration)!
        #expect(settled.highlight == 1 && settled.label == 1 && settled.artwork == 1)
        #expect(settled.stars.allSatisfy { $0.alpha == 1 })
    }

    @Test func relockAfterSixtySecondsAnimatesAgain() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        tl.unlock(at: 5)
        tl.lock(Self.a, at: 65.1)
        let v = tl.visual(for: Self.a.id, at: 65.1)!
        #expect(v.mode == .drawIn)
        #expect(v.segments.allSatisfy { $0.progress == 0 })
    }

    @Test func recallWindowCountsFromLastTimeShownDrawn() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        tl.unlock(at: 300)
        tl.lock(Self.a, at: 350)
        #expect(tl.visual(for: Self.a.id, at: 350)?.mode == .recalled)
        tl.unlock(at: 351)
        tl.lock(Self.a, at: 400)
        #expect(tl.visual(for: Self.a.id, at: 400)?.mode == .recalled)
    }

    @Test func unlockBeforeDrawCompletesDoesNotCountAsDrawn() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        tl.unlock(at: 0.4)
        tl.lock(Self.a, at: 10)
        let v = tl.visual(for: Self.a.id, at: 10)!
        #expect(v.mode == .drawIn && v.segments.allSatisfy { $0.progress == 0 })
    }

    @Test func relockDuringFadeOutContinuesWithoutJumping() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        tl.unlock(at: 0.4)
        let before = tl.visual(for: Self.a.id, at: 0.6)!
        tl.lock(Self.a, at: 0.6)
        let after = tl.visual(for: Self.a.id, at: 0.6)!
        #expect(after.segments.map(\.progress) == before.segments.map(\.progress))
        #expect(abs(after.highlight - before.highlight) < 1e-12)
        let later = tl.visual(for: Self.a.id, at: 0.6 + 2)!
        #expect(later.highlight == 1 && later.segments.allSatisfy { $0.progress == 1 })
    }

    @Test func relockingTheCurrentConstellationIsANoOp() {
        var tl = DrawInTimeline()
        tl.lock(Self.a, at: 0)
        let before = tl.visual(for: Self.a.id, at: 0.5)
        tl.lock(Self.a, at: 0.3)
        #expect(tl.visual(for: Self.a.id, at: 0.5) == before)
    }

    @Test func reduceMotionIsOnePlainFade() {
        var tl = DrawInTimeline(reduceMotion: true)
        tl.lock(Self.c, at: 1)
        var previous = -1.0
        var t = 1.0
        while t < 4 {
            let v = tl.visual(for: Self.c.id, at: t)!
            #expect(v.mode == .plainFade)
            #expect(v.segments.allSatisfy { $0.progress == 1 && $0.glow == 0 && $0.alpha == v.highlight })
            #expect(v.stars.allSatisfy { $0.alpha == v.highlight })
            #expect(v.label == v.highlight && v.artwork == v.highlight)
            #expect(v.highlight >= previous)
            previous = v.highlight
            t += 0.005
        }
        #expect(tl.visual(for: Self.c.id, at: 1 + DrawInConfig().reduceMotionFadeDuration)?.highlight == 1)
        tl.unlock(at: 4)
        #expect(tl.visual(for: Self.c.id, at: 4 + DrawInConfig().reduceMotionFadeDuration / 2)!.highlight < 1)
        #expect(tl.frame(at: 4 + DrawInConfig().reduceMotionFadeDuration).isEmpty)
    }

    /// A half-drawn segment's tip stays on the chord point between its two stars while the camera moves.
    @Test func halfDrawnSegmentStaysAttachedWhilePanning() {
        let from = simd_normalize(SIMD3<Double>(0.1, 1, 0.6)), to = simd_normalize(SIMD3<Double>(-0.15, 1, 0.75))
        let segment = SegmentVisual(index: 0, fromHip: 1, toHip: 2, progress: 0.4, alpha: 1, glow: 0, glowPosition: 0)
        let tip = from + 0.4 * (to - from)
        var restrictedError = 0.0
        for k in 0..<20 {
            let yaw = Angle.radians(Double(k) - 10)
            let forward = LockTestData.rotate(simd_normalize(from + to), about: SIMD3(0, 0, 1), by: yaw)
            let projector = LockTestData.projector(looking: forward)
            let drawn = projector.drawnPart(of: segment, from: from, to: to)
            let expectedStart = projector.screenPoint(enu: from)!, expectedTip = projector.screenPoint(enu: tip)!
            #expect(drawn != nil)
            #expect(simd_distance(drawn!.start, expectedStart) < 1e-6)
            #expect(simd_distance(drawn!.end, expectedTip) < 1e-6)
            #expect(abs(drawn!.startT) < 1e-12 && abs(drawn!.endT - 0.4) < 1e-12)
            if let viaRestricted = projector.clipSegment(from, to)?.restricted(to: 0, 0.4) {
                restrictedError = max(restrictedError, simd_distance(viaRestricted.end, expectedTip))
            }
        }
        print("SKYCORE ClippedSegment.restricted tip error on a 13° segment: \(String(format: "%.2f", restrictedError)) pt")
        let none = SegmentVisual(index: 0, fromHip: 1, toHip: 2, progress: 0, alpha: 1, glow: 0, glowPosition: 0)
        #expect(LockTestData.projector(looking: from).drawnPart(of: none, from: from, to: to) == nil)
    }

    enum Step: Sendable { case lock(Int), unlock, reduceMotion(Bool) }

    static func randomSteps(seed: UInt64, duration: Double, toggleReduceMotion: Bool) -> [(Double, Step)] {
        var g = LockRNG(seed: seed)
        var steps: [(Double, Step)] = []
        var t = 0.0
        while true {
            t += LockTestData.uniform(0.02...1.6, &g)
            guard t < duration else { break }
            let r = g.next() % 10
            let step: Step = toggleReduceMotion && r == 0 ? .reduceMotion(g.next() % 2 == 0)
                : r < 3 ? .unlock : .lock(Int(g.next() % 4))
            steps.append((t, step))
        }
        return steps
    }

    /// Plays random lock/unlock/re-lock sequences and samples every 5 ms: every value stays within [0, 1], one
    /// visual per constellation, at most one locked, and (without Reduce Motion toggling) nothing visible jumps.
    @Test(arguments: [(UInt64(1), false), (2, false), (3, false), (4, true), (5, true), (6, true)])
    func randomLockingKeepsValuesInRange(seed: UInt64, reduceMotion: Bool) {
        var schedules = [Self.a, Self.b, Self.c]
        let real = ["Ori", "UMa", "Cas"].compactMap { LockTestData.schedules[$0] }
        schedules.append(real.first ?? AnimationFixture.chain30.schedule)
        schedules += real.dropFirst()
        var tl = DrawInTimeline(reduceMotion: reduceMotion)
        let steps = Self.randomSteps(seed: seed, duration: 10, toggleReduceMotion: false)
        checkSequence(&tl, steps: steps, schedules: schedules, checkContinuity: true)
        var mixed = DrawInTimeline(reduceMotion: reduceMotion)
        let mixedSteps = Self.randomSteps(seed: seed &+ 100, duration: 10, toggleReduceMotion: true)
        checkSequence(&mixed, steps: mixedSteps, schedules: schedules, checkContinuity: false)
    }

    func checkSequence(_ tl: inout DrawInTimeline, steps: [(Double, Step)], schedules: [DrawInSchedule],
                       checkContinuity: Bool) {
        var next = 0
        var previous: [String: [Double]] = [:]
        var violations: [String] = []
        var jumps: [String] = []
        for k in 0...2000 {
            let t = Double(k) * 0.005
            while next < steps.count, steps[next].0 <= t {
                switch steps[next].1 {
                case .lock(let i): tl.lock(schedules[i % schedules.count], at: steps[next].0)
                case .unlock: tl.unlock(at: steps[next].0)
                case .reduceMotion(let on): tl.reduceMotion = on
                }
                next += 1
            }
            let frame = tl.frame(at: t)
            violations += LockTestData.unitRangeViolations(frame).map { "t=\(t) \($0)" }
            #expect(Set(frame.map(\.id)).count == frame.count, "one visual per constellation")
            #expect(frame.filter(\.isLocked).count <= 1, "only one constellation locked")
            var current: [String: [Double]] = [:]
            for v in frame {
                current[v.id] = v.stars.map(\.alpha) + v.segments.flatMap { [$0.progress * $0.alpha, $0.glow] }
                    + [v.label, v.artwork]
            }
            if checkContinuity {
                for id in Set(current.keys).union(previous.keys) {
                    let now = current[id], before = previous[id]
                    let n = max(now?.count ?? 0, before?.count ?? 0)
                    for j in 0..<n {
                        let x = now.map { $0[j] } ?? 0, y = before.map { $0[j] } ?? 0
                        if abs(x - y) > 0.1 { jumps.append("t=\(t) \(id)[\(j)] \(y)→\(x)") }
                    }
                }
            }
            previous = current
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        #expect(jumps.isEmpty, "\(jumps.prefix(5))")
    }
}
