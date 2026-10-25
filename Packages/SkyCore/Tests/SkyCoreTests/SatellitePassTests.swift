import Foundation
import simd
import Testing
@testable import SkyCore

@Suite struct SatellitePassTests {
    static let observers: [(name: String, location: GeoLocation)] = [
        ("Houston", GeoLocation(latitude: 29.56, longitude: -95.09, height: 10)),
        ("London", GeoLocation(latitude: 51.48, longitude: -0.0015, height: 45)),
        ("Tromsø", GeoLocation(latitude: 69.65, longitude: 18.96, height: 100)),
        ("Sydney", GeoLocation(latitude: -33.87, longitude: 151.21, height: 50)),
    ]

    struct BrutePass {
        var rise: Double
        var culmination: Double
        var maxAltitude: Double
        var set: Double
    }

    /// Fixed-step scan with linear interpolation of horizon crossings; seconds after `start`.
    static func bruteForcePasses(_ sat: TrackedSatellite, _ observer: SatelliteObserver, start: AstroInstant,
                                 seconds: Double, step: Double) throws -> [BrutePass] {
        var passes: [BrutePass] = []
        var previous = try sat.topocentric(at: start, observer: observer).altitudeDegrees
        var open: BrutePass?
        var s = step
        while s <= seconds {
            let alt = try sat.topocentric(at: start.adding(seconds: s), observer: observer).altitudeDegrees
            if previous < 0 && alt >= 0 {
                open = BrutePass(rise: s - step * alt / (alt - previous), culmination: s, maxAltitude: alt, set: 0)
            } else if var p = open {
                if alt > p.maxAltitude { p.maxAltitude = alt; p.culmination = s }
                if alt < 0 {
                    p.set = s - step * alt / (alt - previous)
                    passes.append(p)
                    open = nil
                } else {
                    open = p
                }
            }
            previous = alt
            s += step
        }
        return passes
    }

    @Test func passesMatchBruteForceScan() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        let start = AstroInstant(date: sat.epoch)
        let duration = 86_400.0
        let predictor = SatellitePassPredictor()
        var maxRise = 0.0, maxSet = 0.0, maxCulmination = 0.0, total = 0
        var predictorTime = Duration.zero
        for (name, location) in Self.observers.prefix(3) {
            let observer = SatelliteObserver(location: location)
            let clock = ContinuousClock()
            let t0 = clock.now
            let predicted = try predictor.passes(of: sat, observer: observer, from: start,
                                                 to: start.adding(seconds: duration), includeVisibility: false)
            predictorTime += clock.now - t0
            let brute = try Self.bruteForcePasses(sat, observer, start: start, seconds: duration, step: 2)
            let extra = predicted.filter { p in
                !brute.contains { abs($0.rise - (p.rise.instant.jdUTC - start.jdUTC) * 86_400) < 5 }
            }
            for p in extra { SatelliteTestData.report("\(name): extra pass max \(p.maxAltitudeDegrees)° duration \(p.duration) s") }
            #expect(extra.allSatisfy { $0.maxAltitudeDegrees < 0.05 })
            #expect(predicted.count - extra.count == brute.count, "\(name): \(predicted.count) vs \(brute.count)")
            for b in brute {
                guard let p = predicted.first(where: { abs(($0.rise.instant.jdUTC - start.jdUTC) * 86_400 - b.rise) < 5 }) else {
                    Issue.record("\(name): missed pass max \(b.maxAltitude)°")
                    continue
                }
                func sec(_ e: SatellitePassEvent) -> Double { (e.instant.jdUTC - start.jdUTC) * 86_400 }
                maxRise = max(maxRise, abs(sec(p.rise) - b.rise))
                maxSet = max(maxSet, abs(sec(p.set) - b.set))
                maxCulmination = max(maxCulmination, abs(sec(p.culmination) - b.culmination))
                #expect(p.maxAltitudeDegrees >= b.maxAltitude - 1e-9)
                #expect(abs(p.rise.altitudeDegrees) < 0.005 && abs(p.set.altitudeDegrees) < 0.005)
                #expect(p.rise.instant.jdUTC < p.culmination.instant.jdUTC && p.culmination.instant.jdUTC < p.set.instant.jdUTC)
                total += 1
            }
        }
        SatelliteTestData.report("brute-force check: \(total) passes, max |Δrise| \(maxRise) s, |Δset| \(maxSet) s, |Δculm| \(maxCulmination) s (2 s grid); predictor \(predictorTime) for 3 observer-days (debug)")
        #expect(total > 10)
        #expect(maxRise < 0.1 && maxSet < 0.1 && maxCulmination <= 1.0)
    }

    @Test func culminationIsTheMaximum() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        let observer = SatelliteObserver(location: Self.observers[3].location)
        let start = AstroInstant(date: sat.epoch)
        let passes = try SatellitePassPredictor().passes(of: sat, observer: observer, from: start,
                                                         to: start.adding(seconds: 2 * 86_400), includeVisibility: false)
        #expect(!passes.isEmpty)
        for p in passes {
            for dt in [-0.5, 0.5] {
                let alt = try sat.topocentric(at: p.culmination.instant.adding(seconds: dt), observer: observer).altitudeDegrees
                #expect(alt <= p.maxAltitudeDegrees + 1e-7)
            }
            #expect(p.duration > 0 && p.duration < 15 * 60)
        }
    }

    @Test func visibleSegmentsMatchDenseSampling() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        let predictor = SatellitePassPredictor()
        let config = predictor.configuration
        var found = 0
        var maxBoundaryError = 0.0
        for (name, location) in Self.observers {
            let observer = SatelliteObserver(location: location)
            let start = AstroInstant(date: sat.epoch)
            let passes = try predictor.passes(of: sat, observer: observer, from: start, to: start.adding(seconds: 4 * 86_400))
            for pass in passes {
                var visible: [Double] = []
                var s = 0.0
                let span = pass.duration
                while s <= span {
                    let o = try sat.observation(at: pass.rise.instant.adding(seconds: s), observer: observer)
                    if o.isVisible(minimumAltitudeDegrees: config.minimumVisibleAltitudeDegrees,
                                   darkSkySunAltitudeDegrees: config.darkSkySunAltitudeDegrees) { visible.append(s) }
                    s += 0.5
                }
                guard let segment = pass.visible else {
                    #expect(visible.isEmpty, "\(name): dense sampling found a visible stretch the predictor missed")
                    continue
                }
                found += 1
                let startS = (segment.start.instant.jdUTC - pass.rise.instant.jdUTC) * 86_400
                let endS = (segment.end.instant.jdUTC - pass.rise.instant.jdUTC) * 86_400
                guard let first = visible.first, let last = visible.last else {
                    Issue.record("\(name): predictor reports a visible segment the dense scan never saw")
                    continue
                }
                maxBoundaryError = max(maxBoundaryError, abs(first - startS), abs(last - endS))
                #expect(abs(first - startS) <= 0.5 && abs(last - endS) <= 0.5)
                #expect(segment.maximum.altitudeDegrees >= config.minimumVisibleAltitudeDegrees)
                #expect(segment.maximum.altitudeDegrees <= pass.maxAltitudeDegrees + 1e-9)
                SatelliteTestData.report("\(name) visible \(segment.start.date.formatted(.iso8601)) \(Int(segment.duration)) s max \(String(format: "%.1f", segment.maximum.altitudeDegrees))° (\(segment.startReason.rawValue) → \(segment.endReason.rawValue))")
            }
        }
        SatelliteTestData.report("visible segments: \(found), max boundary difference vs 0.5 s sampling \(maxBoundaryError) s")
        #expect(found > 0)
    }

    @Test func nextVisiblePassAndSummary() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        let predictor = SatellitePassPredictor()
        var checked = 0
        for (name, location) in Self.observers {
            let observer = SatelliteObserver(location: location)
            let now = AstroInstant(date: sat.epoch)
            guard let next = try predictor.nextVisiblePass(of: sat, observer: observer, after: now, withinDays: 5) else {
                SatelliteTestData.report("\(name): no visible ISS pass within 5 days of the 2018 epoch")
                continue
            }
            checked += 1
            let segment = try #require(next.visible)
            #expect(segment.maximum.altitudeDegrees >= 10)
            #expect(segment.end.instant.jdUTC > now.jdUTC)

            let all = try predictor.passes(of: sat, observer: observer, from: now, to: next.set.instant.adding(seconds: 1))
            let earlierVisible = all.filter { $0.set.instant.jdUTC < next.rise.instant.jdUTC && ($0.visible?.maximum.altitudeDegrees ?? 0) >= 10 }
            #expect(earlierVisible.isEmpty)

            let middle = AstroInstant(jdUTC: (segment.start.instant.jdUTC + segment.end.instant.jdUTC) / 2)
            let inProgress = try predictor.nextVisiblePass(of: sat, observer: observer, after: middle)
            #expect(abs((inProgress?.rise.instant.jdUTC ?? 0) - next.rise.instant.jdUTC) * 86_400 < 0.01)
            let later = try predictor.nextVisiblePass(of: sat, observer: observer, after: middle, includeInProgress: false)
            #expect((later?.rise.instant.jdUTC ?? .infinity) > middle.jdUTC)

            let summary = SatellitePassSummary(pass: next, elementEpoch: sat.epoch)
            #expect(summary.isVisible && summary.magnitude == nil)
            #expect(summary.start == segment.start.date && summary.end == segment.end.date)
            #expect(summary.startDirection == CompassDirection.name(azimuthDegrees: segment.start.azimuthDegrees))
            #expect(summary.promptText.contains("ISS (ZARYA)") && summary.promptText.contains("magnitude unknown"))
            SatelliteTestData.report("\(name): \(summary.promptText)")

            let viaConvenience = try predictor.nextISSPassSummary(satellites: [sat], location: location, now: sat.epoch)
            #expect(viaConvenience == summary)
        }
        #expect(checked > 0)
    }
}
