import Foundation

/// Day / twilight / night from the Sun's airless altitude.
///
/// Day: altitude > −0.833° (geometric sunrise/sunset incl. standard refraction and semidiameter).
/// Night: altitude < −12° (nautical dusk; all naked-eye stars out under typical suburban skies).
/// `nightFactor` blends 0 → 1 between them with a smoothstep; the twilight sub-phases follow the usual
/// civil (−6°) / nautical (−12°) limits.
public struct DaylightState: Sendable, Hashable, Codable {
    public enum Phase: String, Sendable, Hashable, Codable {
        case day, civilTwilight, nauticalTwilight, night
    }

    public static let dayAltitude = -0.833
    public static let nightAltitude = -12.0
    public static let civilAltitude = -6.0

    public var sunAltitudeDegrees: Double
    public var phase: Phase
    /// 0 in full day, 1 at night.
    public var nightFactor: Double

    public init(sunAltitudeDegrees h: Double) {
        sunAltitudeDegrees = h
        if h > Self.dayAltitude {
            phase = .day
        } else if h > Self.civilAltitude {
            phase = .civilTwilight
        } else if h > Self.nightAltitude {
            phase = .nauticalTwilight
        } else {
            phase = .night
        }
        let x = min(max((Self.dayAltitude - h) / (Self.dayAltitude - Self.nightAltitude), 0), 1)
        nightFactor = x * x * (3 - 2 * x)
    }

    public var isDay: Bool { phase == .day }
    public var isNight: Bool { phase == .night }
}
