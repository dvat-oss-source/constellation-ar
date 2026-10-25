import Foundation
import simd

public struct SatelliteTrackPoint: Sendable, Hashable {
    /// Seconds relative to the reference instant (negative = past).
    public var offsetSeconds: Double
    public var position: SatelliteTopocentric
    public var isSunlit: Bool

    public var enu: SIMD3<Double> { position.enu }
}

public extension TrackedSatellite {
    /// Sampled sky track around `instant` (from `pastSeconds` before to `futureSeconds` after) for drawing a short
    /// predicted path. Points below the horizon are kept so a renderer can clip the line itself. The Sun is evaluated
    /// once at `instant` (it moves < 0.01° in a few minutes).
    func predictedPath(observer: SatelliteObserver, around instant: AstroInstant, pastSeconds: Double = 60,
                       futureSeconds: Double = 180, stepSeconds: Double = 10) throws -> [SatelliteTrackPoint] {
        let step = max(0.1, stepSeconds)
        let sun = try SatelliteFrames.sunITRSKilometres(at: instant)
        let count = Int(((pastSeconds + futureSeconds) / step).rounded(.down))
        return try (0...max(0, count)).map { k in
            let offset = min(-pastSeconds + Double(k) * step, futureSeconds)
            let position = try topocentric(at: instant.adding(seconds: offset), observer: observer)
            return SatelliteTrackPoint(
                offsetSeconds: offset, position: position,
                isSunlit: EarthShadow.isSunlit(satelliteKilometres: position.itrsKilometres, sunKilometres: sun))
        }
    }

    func predictedPath(observer: SatelliteObserver, now: Date, pastSeconds: Double = 60, futureSeconds: Double = 180,
                       stepSeconds: Double = 10) throws -> [SatelliteTrackPoint] {
        try predictedPath(observer: observer, around: AstroInstant(date: now), pastSeconds: pastSeconds,
                          futureSeconds: futureSeconds, stepSeconds: stepSeconds)
    }
}

public enum CompassDirection {
    static let eightPoints = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    static let sixteenPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// Compass point for an azimuth measured from north through east; `points` is 8 or 16.
    public static func name(azimuthDegrees: Double, points: Int = 8) -> String {
        let names = points == 16 ? sixteenPoints : eightPoints
        let sector = 360.0 / Double(names.count)
        var a = azimuthDegrees.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return names[Int((a / sector).rounded()) % names.count]
    }
}

/// Compact description of a satellite pass for prompts and UI. Start/end are the visible portion when the pass is
/// visible, otherwise the horizon rise and set.
public struct SatellitePassSummary: Sendable, Hashable, Codable {
    public var satelliteName: String
    public var noradID: Int
    public var start: Date
    public var maximum: Date
    public var end: Date
    public var startAltitudeDegrees: Double
    public var maxAltitudeDegrees: Double
    public var endAltitudeDegrees: Double
    public var startDirection: String
    public var maxDirection: String
    public var endDirection: String
    public var isVisible: Bool
    /// Why the visible portion begins / ends ("altitude", "earthShadow", "twilight"); nil for invisible passes.
    public var startReason: String?
    public var endReason: String?
    /// Visual magnitude; nil because SkyCore has no standard-magnitude model for satellites.
    public var magnitude: Double?
    /// Age of the element set at the pass maximum, days.
    public var elementAgeDays: Double?

    public init(pass: SatellitePass, elementEpoch: Date? = nil, compassPoints: Int = 8) {
        let segment = pass.visible
        let start = segment?.start ?? pass.rise
        let peak = segment?.maximum ?? pass.culmination
        let end = segment?.end ?? pass.set
        satelliteName = pass.satelliteName
        noradID = pass.noradID
        self.start = start.date
        maximum = peak.date
        self.end = end.date
        startAltitudeDegrees = start.altitudeDegrees
        maxAltitudeDegrees = peak.altitudeDegrees
        endAltitudeDegrees = end.altitudeDegrees
        startDirection = CompassDirection.name(azimuthDegrees: start.azimuthDegrees, points: compassPoints)
        maxDirection = CompassDirection.name(azimuthDegrees: peak.azimuthDegrees, points: compassPoints)
        endDirection = CompassDirection.name(azimuthDegrees: end.azimuthDegrees, points: compassPoints)
        isVisible = segment != nil
        startReason = segment?.startReason.rawValue
        endReason = segment?.endReason.rawValue
        magnitude = nil
        elementAgeDays = elementEpoch.map { peak.date.timeIntervalSince($0) / 86_400 }
    }

    public var durationSeconds: TimeInterval { end.timeIntervalSince(start) }

    /// One-paragraph plain-text description (UTC ISO 8601 times) for an LLM prompt.
    public var promptText: String {
        func time(_ d: Date) -> String { d.formatted(.iso8601) }
        func deg(_ x: Double) -> String { "\(Int(x.rounded()))°" }
        var text = "\(satelliteName) (NORAD \(noradID)) "
        text += isVisible ? "visible pass" : "pass (not visible: in Earth's shadow, daylight, or too low)"
        text += ": starts \(time(start)) at \(deg(startAltitudeDegrees)) \(startDirection)"
        if let startReason { text += " (\(startReason))" }
        text += ", highest \(time(maximum)) at \(deg(maxAltitudeDegrees)) \(maxDirection)"
        text += ", ends \(time(end)) at \(deg(endAltitudeDegrees)) \(endDirection)"
        if let endReason { text += " (\(endReason))" }
        text += "; duration \(Int(durationSeconds.rounded())) s; magnitude "
        text += magnitude.map { String(format: "%.1f", $0) } ?? "unknown"
        if let elementAgeDays { text += String(format: "; orbital elements %.1f days old", elementAgeDays) }
        return text + "."
    }
}

public extension SatellitePassPredictor {
    /// Summary of the ISS's next visible pass, or nil if the data has no ISS or no visible pass within `withinDays`.
    func nextISSPassSummary(satellites: [TrackedSatellite], location: GeoLocation, now: Date,
                            withinDays days: Double = 5, minimumDurationSeconds: Double = 0) throws -> SatellitePassSummary? {
        guard let iss = satellites.first(where: \.isISS) else { return nil }
        guard let pass = try nextVisiblePass(of: iss, observer: SatelliteObserver(location: location), now: now,
                                             withinDays: days,
                                             minimumMaxAltitudeDegrees: configuration.minimumVisibleAltitudeDegrees,
                                             minimumDurationSeconds: minimumDurationSeconds)
        else { return nil }
        return SatellitePassSummary(pass: pass, elementEpoch: iss.epoch)
    }
}
