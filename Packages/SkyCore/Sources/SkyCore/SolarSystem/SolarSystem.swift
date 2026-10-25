import AstronomyKit
import Foundation
import simd

public enum SolarSystemBody: String, CaseIterable, Sendable, Hashable, Codable {
    case sun, moon, mercury, venus, mars, jupiter, saturn, uranus, neptune

    public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var astronomyKitBody: CelestialBody {
        switch self {
        case .sun: .sun
        case .moon: .moon
        case .mercury: .mercury
        case .venus: .venus
        case .mars: .mars
        case .jupiter: .jupiter
        case .saturn: .saturn
        case .uranus: .uranus
        case .neptune: .neptune
        }
    }

    /// Equatorial radius, km.
    public var radiusKilometres: Double {
        switch self {
        case .sun: 695_700
        case .moon: 1_737.4
        case .mercury: 2_440.5
        case .venus: 6_051.8
        case .mars: 3_396.2
        case .jupiter: 71_492
        case .saturn: 60_268
        case .uranus: 25_559
        case .neptune: 24_764
        }
    }
}

public struct MoonPhaseInfo: Sendable, Hashable, Codable {
    /// Moon−Sun geocentric ecliptic longitude difference, degrees [0, 360): 0 new, 90 first quarter, 180 full.
    public var elongationAngleDegrees: Double
    /// Illuminated fraction of the disc, 0…1.
    public var illuminatedFraction: Double
    public var name: String
    public var isWaxing: Bool { elongationAngleDegrees < 180 }
}

public struct SolarSystemPosition: Sendable, Hashable {
    public var body: SolarSystemBody
    /// Topocentric apparent direction (light-time and aberration corrected), true equator and equinox of date.
    public var ofDate: SIMD3<Double>
    public var distanceAU: Double
    /// Airless topocentric East/North/Up.
    public var enu: SIMD3<Double>
    public var magnitude: Double
    /// Illuminated fraction of the disc (1 for the Sun).
    public var illuminatedFraction: Double
    public var angularDiameterDegrees: Double

    public var horizontal: HorizontalCoordinates { HorizontalCoordinates(enu: enu) }
    public var raHours: Double { Angle.degrees(ofDate.lonLat.lon) / 15 }
    public var decDegrees: Double { Angle.degrees(ofDate.lonLat.lat) }
}

public struct SolarSystemSnapshot: Sendable, Hashable {
    public var instant: AstroInstant
    public var bodies: [SolarSystemPosition]
    public var moonPhase: MoonPhaseInfo
    public var daylight: DaylightState

    public func position(_ body: SolarSystemBody) -> SolarSystemPosition? { bodies.first { $0.body == body } }
}

public enum SolarSystem {
    static let kmPerAU = 149_597_870.7

    static func astroTime(_ instant: AstroInstant) -> AstroTime { AstroTime(ut: instant.daysUT1) }

    /// Topocentric apparent RA/Dec of date via AstronomyKit (Astronomy Engine `Equator(body, time, observer,
    /// ofdate, aberration)`): hours, degrees, AU.
    public static func apparentEquatorial(_ body: SolarSystemBody, at instant: AstroInstant, location: GeoLocation)
        throws -> (raHours: Double, decDegrees: Double, distanceAU: Double) {
        let eq = try body.astronomyKitBody.equatorial(at: astroTime(instant), from: location.astronomyKitObserver,
                                                      equatorDate: .ofDate, aberration: .corrected)
        return (eq.rightAscension, eq.declination, eq.distance)
    }

    public static func position(_ body: SolarSystemBody, at instant: AstroInstant, session: SkySession) throws
        -> SolarSystemPosition {
        let time = astroTime(instant)
        let (ra, dec, dist) = try apparentEquatorial(body, at: instant, location: session.location)
        let v = SIMD3<Double>.unit(lon: Angle.radians(ra * 15), lat: Angle.radians(dec))
        var magnitude = -26.74, fraction = 1.0
        if body != .sun {
            let ill = try body.astronomyKitBody.illumination(at: time)
            magnitude = ill.magnitude
            fraction = ill.phaseFraction
        }
        let diameter = Angle.degrees(2 * asin(min(1, body.radiusKilometres / (dist * kmPerAU))))
        return SolarSystemPosition(body: body, ofDate: v, distanceAU: dist, enu: session.horizonMatrix(at: instant) * v,
                                   magnitude: magnitude, illuminatedFraction: fraction, angularDiameterDegrees: diameter)
    }

    public static func moonPhase(at instant: AstroInstant) throws -> MoonPhaseInfo {
        let time = astroTime(instant)
        let angle = try Moon.phaseAngle(at: time)
        let fraction = try CelestialBody.moon.illumination(at: time).phaseFraction
        return MoonPhaseInfo(elongationAngleDegrees: angle, illuminatedFraction: fraction, name: Moon.phaseName(for: angle))
    }

    public static func snapshot(at instant: AstroInstant, session: SkySession,
                                bodies: [SolarSystemBody] = SolarSystemBody.allCases) throws -> SolarSystemSnapshot {
        let positions = try bodies.map { try position($0, at: instant, session: session) }
        let sun = try positions.first { $0.body == .sun } ?? position(.sun, at: instant, session: session)
        return SolarSystemSnapshot(instant: instant, bodies: positions, moonPhase: try moonPhase(at: instant),
                                   daylight: DaylightState(sunAltitudeDegrees: Angle.degrees(sun.horizontal.altitude)))
    }

    /// Sun's airless altitude in degrees.
    public static func sunAltitudeDegrees(at instant: AstroInstant, session: SkySession) throws -> Double {
        Angle.degrees(try position(.sun, at: instant, session: session).horizontal.altitude)
    }

    /// Geocentric Sun direction in ICRS (J2000) axes, unit vector; used for Earth-shadow tests.
    public static func geocentricSunICRS(at instant: AstroInstant) throws -> SIMD3<Double> {
        let v = try CelestialBody.sun.geocentricPosition(at: AstroTime(tt: instant.daysTT), aberration: .corrected)
        return simd_normalize(SIMD3(v.x, v.y, v.z))
    }
}
