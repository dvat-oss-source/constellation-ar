import Foundation
import simd

public struct SatellitePassConfiguration: Sendable, Hashable, Codable {
    /// Rise/set altitude, degrees (geometric, airless), like Skyfield `find_events(altitude_degrees:)`.
    public var horizonDegrees: Double
    /// Lowest altitude that counts as visible (NASA Spot the Station reports passes from 10°).
    public var minimumVisibleAltitudeDegrees: Double
    /// The observer's sky is dark when the Sun is below this altitude (civil dusk by default).
    public var darkSkySunAltitudeDegrees: Double
    /// Coarse scan step cap; the step is also capped at 1/100 of the orbital period.
    public var maximumStepSeconds: Double
    /// Sampling step for locating the visible portion inside a pass.
    public var visibilityStepSeconds: Double
    public var riseSetToleranceSeconds: Double
    public var culminationToleranceSeconds: Double

    public init(horizonDegrees: Double = 0, minimumVisibleAltitudeDegrees: Double = 10,
                darkSkySunAltitudeDegrees: Double = -6, maximumStepSeconds: Double = 30,
                visibilityStepSeconds: Double = 5, riseSetToleranceSeconds: Double = 0.05,
                culminationToleranceSeconds: Double = 0.1) {
        self.horizonDegrees = horizonDegrees
        self.minimumVisibleAltitudeDegrees = minimumVisibleAltitudeDegrees
        self.darkSkySunAltitudeDegrees = darkSkySunAltitudeDegrees
        self.maximumStepSeconds = maximumStepSeconds
        self.visibilityStepSeconds = visibilityStepSeconds
        self.riseSetToleranceSeconds = riseSetToleranceSeconds
        self.culminationToleranceSeconds = culminationToleranceSeconds
    }
}

public struct SatellitePassEvent: Sendable, Hashable {
    public var instant: AstroInstant
    public var altitudeDegrees: Double
    public var azimuthDegrees: Double
    public var rangeKilometres: Double

    public init(_ p: SatelliteTopocentric) {
        instant = p.instant
        altitudeDegrees = p.altitudeDegrees
        azimuthDegrees = p.azimuthDegrees
        rangeKilometres = p.rangeKilometres
    }

    public var date: Date { instant.date }
}

/// The part of a pass during which the satellite is sunlit, the observer's sky is dark and the satellite is at least
/// `minimumVisibleAltitudeDegrees` high.
public struct SatelliteVisibleSegment: Sendable, Hashable {
    public enum Boundary: String, Sendable, Hashable, Codable {
        /// Crosses the minimum visible altitude (or the horizon).
        case altitude
        /// Leaves or enters the Earth's shadow.
        case earthShadow
        /// The observer's sky gets dark or light.
        case twilight
    }

    public var start: SatellitePassEvent
    /// Highest point within the segment.
    public var maximum: SatellitePassEvent
    public var end: SatellitePassEvent
    public var startReason: Boundary
    public var endReason: Boundary

    public var duration: TimeInterval { (end.instant.jdUTC - start.instant.jdUTC) * 86_400 }
}

public struct SatellitePass: Sendable, Hashable, Identifiable {
    public var noradID: Int
    public var satelliteName: String
    public var rise: SatellitePassEvent
    public var culmination: SatellitePassEvent
    public var set: SatellitePassEvent
    public var sunlitAtCulmination: Bool
    public var sunAltitudeAtCulminationDegrees: Double
    /// nil when no part of the pass is visible, or when visibility was not computed.
    public var visible: SatelliteVisibleSegment?

    /// Unique within one prediction run; refined times differ by hundredths of a second between searches started at
    /// different instants, so compare passes from separate runs by time with a tolerance.
    public var id: String { "\(noradID)@\(rise.instant.jdUTC)" }
    public var maxAltitudeDegrees: Double { culmination.altitudeDegrees }
    public var isVisible: Bool { visible != nil }
    public var duration: TimeInterval { (set.instant.jdUTC - rise.instant.jdUTC) * 86_400 }
}

/// Rise / culmination / set search for SGP4 satellites, plus the visible portion of each pass.
///
/// Altitudes are sampled at ≤ `maximumStepSeconds` (and ≤ period/100) wherever the satellite could be above the
/// horizon; elsewhere the scan skips ahead by the time the satellite needs to reach the visibility cone at its
/// maximum angular rate. Every sampled altitude maximum is refined by golden-section search, so passes shorter than
/// the step are not missed; rises and sets are then bisected between bracketing samples.
public struct SatellitePassPredictor: Sendable {
    public var configuration: SatellitePassConfiguration

    public init(configuration: SatellitePassConfiguration = SatellitePassConfiguration()) {
        self.configuration = configuration
    }

    /// Complete passes (rise, culmination and set all inside `[start, end]`) in time order.
    public func passes(of satellite: TrackedSatellite, observer: SatelliteObserver, from start: AstroInstant,
                       to end: AstroInstant, includeVisibility: Bool = true) throws -> [SatellitePass] {
        let scan = PassScan(satellite: satellite, observer: observer, start: start, configuration: configuration)
        var passes: [SatellitePass] = []
        for window in try scan.passWindows(durationSeconds: (end.jdUTC - start.jdUTC) * 86_400) {
            let culmination = try scan.topocentric(window.culmination)
            let sun = try SatelliteFrames.sunITRSKilometres(at: culmination.instant)
            var pass = SatellitePass(
                noradID: satellite.noradID, satelliteName: satellite.name,
                rise: SatellitePassEvent(try scan.topocentric(window.rise)),
                culmination: SatellitePassEvent(culmination),
                set: SatellitePassEvent(try scan.topocentric(window.set)),
                sunlitAtCulmination: EarthShadow.isSunlit(satelliteKilometres: culmination.itrsKilometres, sunKilometres: sun),
                sunAltitudeAtCulminationDegrees: observer.sunAltitudeDegrees(sunITRSKilometres: sun),
                visible: nil)
            if includeVisibility {
                pass.visible = try scan.visibleSegment(rise: window.rise, culmination: window.culmination, set: window.set)
            }
            passes.append(pass)
        }
        return passes
    }

    public func passes(of satellite: TrackedSatellite, observer: SatelliteObserver, from start: Date, to end: Date,
                       includeVisibility: Bool = true) throws -> [SatellitePass] {
        try passes(of: satellite, observer: observer, from: AstroInstant(date: start), to: AstroInstant(date: end),
                   includeVisibility: includeVisibility)
    }

    /// The visible portion of a pass (recomputed; `pass.visible` already holds it when visibility was included).
    public func visibleSegment(of pass: SatellitePass, satellite: TrackedSatellite,
                               observer: SatelliteObserver) throws -> SatelliteVisibleSegment? {
        let start = pass.rise.instant
        let scan = PassScan(satellite: satellite, observer: observer, start: start, configuration: configuration)
        func seconds(_ e: SatellitePassEvent) -> Double { (e.instant.jdUTC - start.jdUTC) * 86_400 }
        return try scan.visibleSegment(rise: 0, culmination: seconds(pass.culmination), set: seconds(pass.set))
    }

    /// First pass whose visible portion peaks at least `minimumMaxAltitudeDegrees` high, lasts at least
    /// `minimumDurationSeconds` and has not ended by `now`, searching `withinDays` ahead. With `includeInProgress`, a
    /// pass that rose up to `lookbackSeconds` before `now` and is still visible is returned.
    public func nextVisiblePass(of satellite: TrackedSatellite, observer: SatelliteObserver, after now: AstroInstant,
                                withinDays days: Double = 5, minimumMaxAltitudeDegrees: Double = 10,
                                minimumDurationSeconds: Double = 0, includeInProgress: Bool = true,
                                lookbackSeconds: Double = 1_800) throws -> SatellitePass? {
        let start = includeInProgress ? now.adding(seconds: -lookbackSeconds) : now
        let candidates = try passes(of: satellite, observer: observer, from: start, to: now.adding(seconds: days * 86_400),
                                    includeVisibility: false)
        for var pass in candidates where pass.set.instant.jdUTC > now.jdUTC && pass.maxAltitudeDegrees >= minimumMaxAltitudeDegrees {
            if !includeInProgress && pass.rise.instant.jdUTC < now.jdUTC { continue }
            guard let segment = try visibleSegment(of: pass, satellite: satellite, observer: observer),
                  segment.maximum.altitudeDegrees >= minimumMaxAltitudeDegrees,
                  segment.duration >= minimumDurationSeconds,
                  segment.end.instant.jdUTC > now.jdUTC else { continue }
            pass.visible = segment
            return pass
        }
        return nil
    }

    public func nextVisiblePass(of satellite: TrackedSatellite, observer: SatelliteObserver, now: Date,
                                withinDays days: Double = 5, minimumMaxAltitudeDegrees: Double = 10,
                                minimumDurationSeconds: Double = 0) throws -> SatellitePass? {
        try nextVisiblePass(of: satellite, observer: observer, after: AstroInstant(date: now), withinDays: days,
                            minimumMaxAltitudeDegrees: minimumMaxAltitudeDegrees,
                            minimumDurationSeconds: minimumDurationSeconds)
    }
}

/// Search state for one satellite / observer / window start. Times are seconds after `start`.
struct PassScan {
    struct Window {
        var rise: Double
        var culmination: Double
        var set: Double
        var maxAltitude: Double
    }

    struct Conditions {
        var highEnough: Bool
        var sunlit: Bool
        var dark: Bool
        var all: Bool { highEnough && sunlit && dark }
    }

    let satellite: TrackedSatellite
    let observer: SatelliteObserver
    let start: AstroInstant
    let configuration: SatellitePassConfiguration

    func instant(_ s: Double) -> AstroInstant {
        AstroInstant(jdUTC: start.jdUTC + s / 86_400, ut1MinusUTC: start.ut1MinusUTC)
    }

    func topocentric(_ s: Double) throws -> SatelliteTopocentric {
        try satellite.topocentric(at: instant(s), observer: observer)
    }

    func altitude(_ s: Double) throws -> Double { try topocentric(s).altitudeDegrees }

    /// Seconds the satellite certainly stays below the horizon, from the geocentric angle between it and the observer
    /// (spherical-Earth visibility cone at apogee plus 2° for the ellipsoid and observer height).
    func safeSkip(itrs r: SIMD3<Double>, coneHalfAngle: Double, maxAngularRate: Double) -> Double {
        let psi = Angle.separation(r, observer.itrsKilometres)
        return psi > coneHalfAngle ? (psi - coneHalfAngle) / maxAngularRate : 0
    }

    func passWindows(durationSeconds total: Double) throws -> [Window] {
        guard total > 0 else { return [] }
        let horizon = configuration.horizonDegrees
        let record = satellite.record
        let period = 86_400 / record.meanMotion
        let step = max(1, min(configuration.maximumStepSeconds, period / 100))

        let e = record.eccentricity
        let meanRate = 2 * Double.pi / period
        let maxAngularRate = 1.2 * (meanRate * (1 + e) * (1 + e) / pow(1 - e * e, 1.5) + 7.292_115e-5)
        let semiMajorAxis = cbrt(398_600.8 / (meanRate * meanRate))
        let apogee = semiMajorAxis * (1 + e) * 1.02 + 50
        let h = Angle.radians(horizon)
        let cosine = simd_length(observer.itrsKilometres) * cos(h) / apogee
        let coneHalfAngle = cosine < 1 ? acos(cosine) - h + Angle.radians(2) : .infinity

        var times: [Double] = []
        var altitudes: [Double] = []
        var s = 0.0
        while true {
            let position = try topocentric(s)
            times.append(s)
            altitudes.append(position.altitudeDegrees)
            if s >= total { break }
            let skip = coneHalfAngle.isFinite
                ? safeSkip(itrs: position.itrsKilometres, coneHalfAngle: coneHalfAngle, maxAngularRate: maxAngularRate) : 0
            s = min(total, s + (skip > 2 * step ? skip - step : step))
        }

        var windows: [Window] = []
        let n = times.count
        guard n >= 2 else { return [] }
        for i in 0..<n {
            let previous = i > 0 ? altitudes[i - 1] : -.infinity
            let next = i < n - 1 ? altitudes[i + 1] : -.infinity
            guard altitudes[i] > previous, altitudes[i] >= next, altitudes[i] > horizon - 30 else { continue }
            let peak = try goldenSectionMaximum(times[max(i - 1, 0)], times[min(i + 1, n - 1)])
            guard peak.value >= horizon else { continue }

            guard let before = horizonBracket(from: peak.s, times: times, altitudes: altitudes, direction: -1),
                  let after = horizonBracket(from: peak.s, times: times, altitudes: altitudes, direction: +1)
            else { continue }
            let rise = try crossing(below: before.below, above: before.above)
            let set = try crossing(below: after.below, above: after.above)
            if let last = windows.last, abs(last.rise - rise) < 1 {
                if peak.value > last.maxAltitude {
                    windows[windows.count - 1] = Window(rise: rise, culmination: peak.s, set: set, maxAltitude: peak.value)
                }
                continue
            }
            windows.append(Window(rise: rise, culmination: peak.s, set: set, maxAltitude: peak.value))
        }
        return windows
    }

    /// Walking from the peak towards the window edge (`direction` −1 = earlier, +1 = later), the first sample below
    /// the horizon and the nearest above-horizon time inside it; nil if the window edge is reached first.
    func horizonBracket(from peak: Double, times: [Double], altitudes: [Double],
                        direction: Int) -> (below: Double, above: Double)? {
        var above = peak
        var j = direction < 0 ? (times.lastIndex { $0 < peak } ?? -1) : (times.firstIndex { $0 > peak } ?? times.count)
        while j >= 0 && j < times.count {
            if altitudes[j] < configuration.horizonDegrees { return (times[j], above) }
            above = times[j]
            j += direction
        }
        return nil
    }

    /// Bisection of the horizon crossing between a time below and a time above it.
    func crossing(below: Double, above: Double) throws -> Double {
        var lo = below, hi = above
        while abs(hi - lo) > configuration.riseSetToleranceSeconds {
            let mid = (lo + hi) / 2
            if try altitude(mid) < configuration.horizonDegrees { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    func goldenSectionMaximum(_ a0: Double, _ b0: Double) throws -> (s: Double, value: Double) {
        let r = (5.0.squareRoot() - 1) / 2
        var a = a0, b = b0
        var c = b - r * (b - a), d = a + r * (b - a)
        var fc = try altitude(c), fd = try altitude(d)
        while b - a > configuration.culminationToleranceSeconds {
            if fc > fd {
                b = d; d = c; fd = fc
                c = b - r * (b - a); fc = try altitude(c)
            } else {
                a = c; c = d; fc = fd
                d = a + r * (b - a); fd = try altitude(d)
            }
        }
        let s = (a + b) / 2
        return (s, try altitude(s))
    }

    func conditions(_ s: Double) throws -> Conditions {
        let position = try topocentric(s)
        let sun = try SatelliteFrames.sunITRSKilometres(at: position.instant)
        return Conditions(
            highEnough: position.altitudeDegrees >= configuration.minimumVisibleAltitudeDegrees,
            sunlit: EarthShadow.isSunlit(satelliteKilometres: position.itrsKilometres, sunKilometres: sun),
            dark: observer.sunAltitudeDegrees(sunITRSKilometres: sun) < configuration.darkSkySunAltitudeDegrees)
    }

    func visibleSegment(rise: Double, culmination: Double, set: Double) throws -> SatelliteVisibleSegment? {
        let c = configuration
        guard try altitude(culmination) >= c.minimumVisibleAltitudeDegrees else { return nil }
        let sunAltitudes = try [rise, culmination, set].map { try observer.sunAltitudeDegrees(at: instant($0)) }
        guard sunAltitudes.contains(where: { $0 < c.darkSkySunAltitudeDegrees + 0.5 }) else { return nil }

        var segments: [(start: Double, startReason: SatelliteVisibleSegment.Boundary,
                        end: Double, endReason: SatelliteVisibleSegment.Boundary)] = []
        var openStart: (s: Double, reason: SatelliteVisibleSegment.Boundary)?
        var previous = (s: rise, conditions: try conditions(rise))
        if previous.conditions.all { openStart = (rise, .altitude) }
        let step = max(0.5, c.visibilityStepSeconds)
        var s = rise
        while s < set {
            s = min(set, s + step)
            let current = (s: s, conditions: try conditions(s))
            if current.conditions.all != previous.conditions.all {
                let boundary = try refineBoundary(insideAt: current.conditions.all ? current.s : previous.s,
                                                  outsideAt: current.conditions.all ? previous.s : current.s)
                if current.conditions.all {
                    openStart = (boundary.s, boundary.reason)
                } else if let open = openStart {
                    segments.append((open.s, open.reason, boundary.s, boundary.reason))
                    openStart = nil
                }
            }
            previous = current
        }
        if let open = openStart { segments.append((open.s, open.reason, set, .altitude)) }

        func peak(_ a: Double, _ b: Double) -> Double { min(max(culmination, a), b) }
        let best = try segments.max { try altitude(peak($0.start, $0.end)) < altitude(peak($1.start, $1.end)) }
        guard let best else { return nil }
        return SatelliteVisibleSegment(
            start: SatellitePassEvent(try topocentric(best.start)),
            maximum: SatellitePassEvent(try topocentric(peak(best.start, best.end))),
            end: SatellitePassEvent(try topocentric(best.end)),
            startReason: best.startReason, endReason: best.endReason)
    }

    /// Bisects the visibility boundary; the reason is the condition that fails on the outside.
    func refineBoundary(insideAt inside: Double, outsideAt outside: Double) throws -> (s: Double, reason: SatelliteVisibleSegment.Boundary) {
        var good = inside, bad = outside
        var badConditions = try conditions(bad)
        while abs(good - bad) > configuration.riseSetToleranceSeconds {
            let mid = (good + bad) / 2
            let m = try conditions(mid)
            if m.all { good = mid } else { bad = mid; badConditions = m }
        }
        let reason: SatelliteVisibleSegment.Boundary =
            !badConditions.highEnough ? .altitude : (!badConditions.sunlit ? .earthShadow : .twilight)
        return ((good + bad) / 2, reason)
    }
}
