import Foundation
import simd
import Testing
@testable import SkyCore

/// Comparisons with Skyfield 1.55 (`tools/make_fixtures.py satellites`).
@Suite(.enabled(if: SatelliteTestData.hasPassFixtures)) struct SatelliteFixtureTests {
    /// Skyfield's builtin IERS UT1−UTC for late October 2026 (Data/fixtures/earth_orientation.json).
    static let fixtureDUT1 = 0.0888

    static let fixture = try? SatellitePassFixture.load()
    static let satellites: [TrackedSatellite] = {
        guard let data = FileManager.default.contents(atPath: SatelliteTestData.ommSnapshotPath) else { return [] }
        return (try? OMMParser.satellites(from: data)) ?? []
    }()

    static func window(_ f: SatellitePassFixture, dut1: Double) throws -> (AstroInstant, AstroInstant) {
        let start = try #require(SatelliteTestData.utc(f.startUtc))
        let end = try #require(SatelliteTestData.utc(f.endUtc))
        return (AstroInstant(date: start, ut1MinusUTC: dut1), AstroInstant(date: end, ut1MinusUTC: dut1))
    }

    /// Skyfield-style visibility at a sample, or nil when any condition is within its margin of the threshold.
    static func clearVisibility(alt: Double, sunAlt: Double?, sunlit: Bool, sunlitStable: Bool,
                                config: SatellitePassConfiguration) -> Bool? {
        guard let sunAlt, sunlitStable, abs(alt - config.minimumVisibleAltitudeDegrees) > 0.05,
              abs(sunAlt - config.darkSkySunAltitudeDegrees) > 0.02 else { return nil }
        return sunlit && sunAlt < config.darkSkySunAltitudeDegrees && alt >= config.minimumVisibleAltitudeDegrees
    }

    /// Our sunlit flag is the same 5 s before and after (so a boundary-straddling sample is not counted).
    static func sunlitStable(_ sat: TrackedSatellite, _ instant: AstroInstant) throws -> Bool {
        let flags = try [-5.0, 0, 5].map { try sat.isSunlit(at: instant.adding(seconds: $0)) }
        return Set(flags).count == 1
    }

    @Test func ommSnapshotParses() throws {
        let data = try #require(FileManager.default.contents(atPath: SatelliteTestData.ommSnapshotPath))
        let result = try OMMParser.parse(data)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(result.skipped.isEmpty)
        #expect(result.satellites.count == raw.count)
        let iss = try #require(result.satellite(noradID: CelesTrak.issNoradID))
        #expect(iss.name == "ISS (ZARYA)" && iss.isISS)
        for (sat, object) in zip(result.satellites, raw) {
            #expect(sat.noradID == object["NORAD_CAT_ID"] as? Int)
            #expect(sat.record.meanMotion == object["MEAN_MOTION"] as? Double)
            let epoch = try #require(object["EPOCH"] as? String)
            let fraction = Double("0." + (epoch.split(separator: ".").last ?? "0")) ?? 0
            let seconds = sat.epoch.timeIntervalSince1970
            #expect(abs((seconds - seconds.rounded(.down)) - fraction) < 2e-6, "\(epoch)")
        }
        if let f = Self.fixture {
            let age = SatelliteDataAge(fetchedAt: iss.epoch, satellites: result.satellites,
                                       now: try #require(SatelliteTestData.utc(f.startUtc)))
            SatelliteTestData.report("snapshot: \(result.satellites.map(\.name)); at window start: \(age.summary)")
        }
    }

    @Test(arguments: [0.0, fixtureDUT1]) func passesMatchSkyfield(dut1: Double) throws {
        let f = try #require(Self.fixture)
        #expect(f.horizonDeg == 0)
        let (start, end) = try Self.window(f, dut1: dut1)
        let predictor = SatellitePassPredictor()
        var dRise = 0.0, dCulm = 0.0, dSet = 0.0, dAlt = 0.0, sumRise = 0.0, matched = 0
        var sunMismatch = 0, sunAltDiff = 0.0
        for (oi, o) in f.observers.enumerated() {
            let observer = SatelliteObserver(location: o.location)
            for sat in Self.satellites {
                let mine = try predictor.passes(of: sat, observer: observer, from: start, to: end, includeVisibility: false)
                let theirs = f.passes.filter { $0.norad == sat.noradID && $0.observer == oi }
                var used = Set<Int>()
                for p in theirs {
                    guard let k = mine.indices.first(where: { abs(mine[$0].rise.instant.jdUTC - p.riseJdUtc) * 86_400 < 60 }) else {
                        Issue.record("\(o.name) \(sat.name): Skyfield pass rising \(p.riseJdUtc) (max \(p.maxAltDeg)°) not found")
                        continue
                    }
                    used.insert(k)
                    let m = mine[k]
                    let r = (m.rise.instant.jdUTC - p.riseJdUtc) * 86_400
                    let c = (m.culmination.instant.jdUTC - p.culminationJdUtc) * 86_400
                    let s = (m.set.instant.jdUTC - p.setJdUtc) * 86_400
                    dRise = max(dRise, abs(r)); dCulm = max(dCulm, abs(c)); dSet = max(dSet, abs(s))
                    sumRise += r
                    dAlt = max(dAlt, abs(m.maxAltitudeDegrees - p.maxAltDeg))
                    #expect(abs(r) <= 10 && abs(c) <= 10 && abs(s) <= 10, "\(o.name) \(sat.name) \(p.riseJdUtc): \(r) \(c) \(s)")
                    if let lit = p.sunlitAtCulmination, lit != m.sunlitAtCulmination,
                       try Self.sunlitStable(sat, AstroInstant(jdUTC: p.culminationJdUtc, ut1MinusUTC: dut1)) {
                        sunMismatch += 1
                    }
                    if let sunAlt = p.sunAltAtCulminationDeg {
                        let ours = try observer.sunAltitudeDegrees(at: AstroInstant(jdUTC: p.culminationJdUtc, ut1MinusUTC: dut1))
                        sunAltDiff = max(sunAltDiff, abs(ours - sunAlt))
                    }
                    matched += 1
                }
                for (k, m) in mine.enumerated() where !used.contains(k) {
                    SatelliteTestData.report("dut1=\(dut1) \(o.name) \(sat.name): extra pass max \(m.maxAltitudeDegrees)° at \(m.culmination.date.formatted(.iso8601))")
                    #expect(m.maxAltitudeDegrees < 0.05, "extra pass that Skyfield does not list")
                }
            }
        }
        SatelliteTestData.report("passes dut1=\(dut1): matched \(matched)/\(f.passes.count); max |Δrise| \(dRise) s (mean \(sumRise / Double(max(matched, 1))) s), |Δculm| \(dCulm) s, |Δset| \(dSet) s, |Δmax alt| \(dAlt)°; sun alt at culmination max |Δ| \(sunAltDiff)°; sunlit-at-culmination mismatches away from shadow edges \(sunMismatch)")
        #expect(matched == f.passes.count)
        #expect(dAlt < 0.05)
        #expect(sunAltDiff < 0.01)
        #expect(sunMismatch == 0)
    }

    @Test(arguments: [0.0, fixtureDUT1]) func samplesMatchSkyfield(dut1: Double) throws {
        let f = try #require(Self.fixture)
        var dAlt = 0.0, dAz = 0.0, dRange = 0.0, dSunAlt = 0.0
        var sunlitMismatches: [String] = [], edgeMismatches = 0
        for sample in f.samples {
            let sat = try #require(Self.satellites.first { $0.noradID == sample.norad })
            let observer = SatelliteObserver(location: f.observers[sample.observer].location)
            let instant = AstroInstant(jdUTC: sample.jdUtc, ut1MinusUTC: dut1)
            let o = try sat.observation(at: instant, observer: observer)
            dAlt = max(dAlt, abs(o.position.altitudeDegrees - sample.altDeg))
            if sample.altDeg < 89 {
                let az = Angle.degrees(Angle.wrapPi(Angle.radians(o.position.azimuthDegrees - sample.azDeg)))
                dAz = max(dAz, abs(az) * cos(Angle.radians(sample.altDeg)))
            }
            dRange = max(dRange, abs(o.position.rangeKilometres - sample.rangeKm))
            if let sunAlt = sample.sunAltDeg { dSunAlt = max(dSunAlt, abs(o.sunAltitudeDegrees - sunAlt)) }
            if o.isSunlit != sample.sunlit {
                if try Self.sunlitStable(sat, instant) {
                    sunlitMismatches.append("\(sat.name) jd \(sample.jdUtc)")
                } else {
                    edgeMismatches += 1
                }
            }
        }
        SatelliteTestData.report("samples dut1=\(dut1): \(f.samples.count); max |Δalt| \(dAlt)°, |Δaz|·cos(alt) \(dAz)°, |Δrange| \(dRange) km, |Δsun alt| \(dSunAlt)°; sunlit mismatches: \(sunlitMismatches.count) clear + \(edgeMismatches) within 5 s of a shadow edge")
        #expect(dAlt < 0.05 && dAz < 0.05)
        #expect(dRange < 1)
        #expect(dSunAlt < 0.01)
        #expect(sunlitMismatches.isEmpty, "\(sunlitMismatches)")
    }

    @Test func visibilityConsistentWithSkyfield() throws {
        let f = try #require(Self.fixture)
        let (start, end) = try Self.window(f, dut1: Self.fixtureDUT1)
        let predictor = SatellitePassPredictor()
        let config = predictor.configuration
        var checkedSamples = 0, visibleSamples = 0, nextFound = 0
        for (oi, o) in f.observers.enumerated() {
            let observer = SatelliteObserver(location: o.location)
            for sat in Self.satellites {
                let mine = try predictor.passes(of: sat, observer: observer, from: start, to: end)
                let samples = f.samples.filter { $0.norad == sat.noradID && $0.observer == oi }
                var verdicts: [(jd: Double, visible: Bool)] = []
                for s in samples {
                    let instant = AstroInstant(jdUTC: s.jdUtc, ut1MinusUTC: Self.fixtureDUT1)
                    guard let visible = Self.clearVisibility(alt: s.altDeg, sunAlt: s.sunAltDeg, sunlit: s.sunlit,
                                                             sunlitStable: try Self.sunlitStable(sat, instant),
                                                             config: config) else { continue }
                    verdicts.append((s.jdUtc, visible))
                    let pass = mine.first { $0.rise.instant.jdUTC <= s.jdUtc && s.jdUtc <= $0.set.instant.jdUTC }
                    let inSegment = pass?.visible.map { $0.start.instant.jdUTC <= s.jdUtc && s.jdUtc <= $0.end.instant.jdUTC } ?? false
                    #expect(inSegment == visible, "\(o.name) \(sat.name) jd \(s.jdUtc): Skyfield visible=\(visible), ours=\(inSegment)")
                    checkedSamples += 1
                    if visible { visibleSamples += 1 }
                }

                guard let next = try predictor.nextVisiblePass(of: sat, observer: observer, after: start,
                                                               withinDays: (end.jdUTC - start.jdUTC) - 0.05,
                                                               includeInProgress: false) else {
                    #expect(!f.passes.contains { $0.norad == sat.noradID && $0.observer == oi && $0.maxAltDeg >= 10.1
                        && $0.sunlitAtCulmination == true && ($0.sunAltAtCulminationDeg ?? 0) < -6.1 },
                            "\(o.name) \(sat.name): Skyfield has a visible culmination but no next visible pass was found")
                    continue
                }
                nextFound += 1
                let skyfield = f.passes.first { $0.norad == sat.noradID && $0.observer == oi
                    && abs($0.riseJdUtc - next.rise.instant.jdUTC) * 86_400 < 10 }
                #expect(skyfield != nil, "\(o.name) \(sat.name): next visible pass is not a Skyfield pass")
                let earlierVisibleCulmination = f.passes.contains { $0.norad == sat.noradID && $0.observer == oi
                    && $0.setJdUtc < next.rise.instant.jdUTC && $0.maxAltDeg >= 10.1 && $0.sunlitAtCulmination == true
                    && ($0.sunAltAtCulminationDeg ?? 0) < -6.1 }
                #expect(!earlierVisibleCulmination)
                #expect(!verdicts.contains { $0.visible && $0.jd < next.rise.instant.jdUTC })
                if let first = verdicts.first(where: \.visible), let segment = next.visible {
                    #expect(first.jd >= segment.start.instant.jdUTC - 1e-9)
                }
                let summary = SatellitePassSummary(pass: next, elementEpoch: sat.epoch)
                SatelliteTestData.report("next visible, \(o.name): \(summary.promptText)")
            }
        }
        SatelliteTestData.report("visibility: \(checkedSamples) clear Skyfield samples agree (\(visibleSamples) visible); next visible pass found for \(nextFound) satellite/observer pairs")
        #expect(checkedSamples > 500 && visibleSamples > 0)
    }

    @Test func minimumDurationSkipsShortGlimpses() throws {
        let f = try #require(Self.fixture)
        let (start, end) = try Self.window(f, dut1: Self.fixtureDUT1)
        let found = Self.satellites.first { $0.isISS }
        let iss = try #require(found)
        let observer = SatelliteObserver(location: f.observers[0].location)
        let predictor = SatellitePassPredictor()
        let days = end.jdUTC - start.jdUTC
        let all = try predictor.passes(of: iss, observer: observer, from: start, to: end).filter { $0.visible != nil }
        func sameRise(_ a: SatellitePass?, _ b: SatellitePass?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.rise.instant.jdUTC - b.rise.instant.jdUTC) * 86_400 < 0.1
        }
        let first = try predictor.nextVisiblePass(of: iss, observer: observer, after: start, withinDays: days)
        #expect(sameRise(first, all.first))
        let firstLong = try #require(all.first { $0.visible!.duration >= 120 })
        #expect(!sameRise(first, firstLong))
        let long = try predictor.nextVisiblePass(of: iss, observer: observer, after: start, withinDays: days,
                                                 minimumDurationSeconds: 120)
        #expect(sameRise(long, firstLong))
        #expect((long?.visible?.duration ?? 0) >= 120)
    }
}
