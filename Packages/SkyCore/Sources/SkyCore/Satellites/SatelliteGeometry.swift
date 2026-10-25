import Foundation
import SatelliteKit
import simd

/// A WGS84 observer with its Earth-fixed position and horizon matrix precomputed.
public struct SatelliteObserver: Sendable {
    public let location: GeoLocation
    /// Earth-fixed (ITRS) position, km.
    public let itrsKilometres: SIMD3<Double>
    public let itrsToENU: simd_double3x3

    public init(location: GeoLocation) {
        self.location = location
        self.itrsKilometres = location.itrsKilometres
        self.itrsToENU = location.itrsToENU
    }

    /// Airless topocentric direction and range of an Earth-fixed position.
    public func topocentric(itrsKilometres r: SIMD3<Double>, at instant: AstroInstant) -> SatelliteTopocentric {
        let local = itrsToENU * (r - itrsKilometres)
        let range = simd_length(local)
        let enu = local / range
        let h = HorizontalCoordinates(enu: enu)
        return SatelliteTopocentric(instant: instant, itrsKilometres: r, enu: enu, rangeKilometres: range,
                                    altitudeDegrees: Angle.degrees(h.altitude), azimuthDegrees: Angle.degrees(h.azimuth))
    }

    /// Airless topocentric altitude of the Sun, degrees.
    public func sunAltitudeDegrees(sunITRSKilometres sun: SIMD3<Double>) -> Double {
        Angle.degrees(HorizontalCoordinates(enu: itrsToENU * (sun - itrsKilometres)).altitude)
    }

    public func sunAltitudeDegrees(at instant: AstroInstant) throws -> Double {
        sunAltitudeDegrees(sunITRSKilometres: try SatelliteFrames.sunITRSKilometres(at: instant))
    }

    /// Whether the sky is dark enough to see satellites (Sun below `sunAltitudeDegrees`, civil dusk by default).
    public func isDark(at instant: AstroInstant, sunAltitudeDegrees threshold: Double = -6) throws -> Bool {
        try sunAltitudeDegrees(at: instant) < threshold
    }
}

public struct SatelliteTopocentric: Sendable, Hashable {
    public var instant: AstroInstant
    /// Geocentric pseudo Earth-fixed position (TEME rotated by GMST 1982, polar motion ignored), km.
    public var itrsKilometres: SIMD3<Double>
    /// Unit East/North/Up direction from the observer (airless, no light-time).
    public var enu: SIMD3<Double>
    public var rangeKilometres: Double
    public var altitudeDegrees: Double
    /// From north through east, [0, 360).
    public var azimuthDegrees: Double

    public var horizontal: HorizontalCoordinates {
        HorizontalCoordinates(altitude: Angle.radians(altitudeDegrees), azimuth: Angle.radians(azimuthDegrees))
    }
}

/// Topocentric position plus illumination: everything needed to decide whether a satellite can be seen.
public struct SatelliteObservation: Sendable, Hashable {
    public var position: SatelliteTopocentric
    public var isSunlit: Bool
    /// Airless altitude of the Sun at the observer, degrees.
    public var sunAltitudeDegrees: Double

    public func isVisible(minimumAltitudeDegrees: Double = 10, darkSkySunAltitudeDegrees: Double = -6) -> Bool {
        isSunlit && sunAltitudeDegrees < darkSkySunAltitudeDegrees && position.altitudeDegrees >= minimumAltitudeDegrees
    }
}

public enum SatelliteFrames {
    static let kilometresPerAU = 149_597_870.7

    /// TEME → pseudo Earth-fixed: frame rotation by IAU 1982 GMST (Vallado 2006; Skyfield's `TEME_to_ITRF` without
    /// polar motion).
    public static func temeToITRS(at instant: AstroInstant) -> simd_double3x3 {
        Rotation.rz(EarthOrientation.gmst1982(daysUT1: instant.daysUT1))
    }

    /// Geocentric Sun in Earth-fixed axes, km (apparent direction scaled to 1 AU; the < 2 % distance error moves the
    /// shadow edge by < 0.1″).
    public static func sunITRSKilometres(at instant: AstroInstant) throws -> SIMD3<Double> {
        let icrs: SIMD3<Double>
        do {
            icrs = try SolarSystem.geocentricSunICRS(at: instant)
        } catch {
            throw SatelliteError.sunUnavailable("\(error)")
        }
        let trueOfDate = EarthOrientation.biasPrecessionNutation(centuriesTT: instant.centuriesTT) * icrs
        return Rotation.rz(EarthOrientation.gast(instant)) * trueOfDate * kilometresPerAU
    }
}

public enum EarthShadow {
    /// Skyfield's `ERAD` (IERS 2003 equatorial radius); the shadow is a sphere of this radius, not the ellipsoid.
    public static let earthRadiusKilometres = 6378.1366

    /// Skyfield `ICRF.is_sunlit`: intersect the line from the satellite towards the Sun with the Earth sphere; the
    /// satellite is in shadow iff the far intersection lies ahead of it (a miss counts as sunlit). Any common axes.
    public static func isSunlit(satelliteKilometres r: SIMD3<Double>, sunKilometres sun: SIMD3<Double>,
                                earthRadiusKilometres radius: Double = earthRadiusKilometres) -> Bool {
        let earth = -r
        let towardSun = simd_normalize(sun + earth)
        let minusB = 2 * simd_dot(towardSun, earth)
        let c = simd_length_squared(earth) - radius * radius
        let discriminant = minusB * minusB - 4 * c
        guard discriminant >= 0 else { return true }
        let far = (minusB + discriminant.squareRoot()) / 2
        return far <= 0
    }
}

public extension TrackedSatellite {
    /// SGP4 position in the TEME frame, km. `instant.jdUTC` is fed to SGP4 as UTC, as Skyfield does.
    func temeKilometres(at instant: AstroInstant) throws -> SIMD3<Double> {
        do {
            let p = try satellite.position(julianDays: instant.jdUTC)
            return SIMD3(p.x, p.y, p.z)
        } catch {
            throw SatelliteError.propagationFailed(noradID: noradID, minutesFromEpoch: minutesFromEpoch(instant),
                                                   reason: "\(error)")
        }
    }

    /// SGP4 velocity in the TEME frame, km/s.
    func temeVelocity(at instant: AstroInstant) throws -> SIMD3<Double> {
        do {
            let v = try satellite.velocity(julianDays: instant.jdUTC)
            return SIMD3(v.x, v.y, v.z)
        } catch {
            throw SatelliteError.propagationFailed(noradID: noradID, minutesFromEpoch: minutesFromEpoch(instant),
                                                   reason: "\(error)")
        }
    }

    func itrsKilometres(at instant: AstroInstant) throws -> SIMD3<Double> {
        SatelliteFrames.temeToITRS(at: instant) * (try temeKilometres(at: instant))
    }

    func topocentric(at instant: AstroInstant, observer: SatelliteObserver) throws -> SatelliteTopocentric {
        observer.topocentric(itrsKilometres: try itrsKilometres(at: instant), at: instant)
    }

    func isSunlit(at instant: AstroInstant) throws -> Bool {
        EarthShadow.isSunlit(satelliteKilometres: try itrsKilometres(at: instant),
                             sunKilometres: try SatelliteFrames.sunITRSKilometres(at: instant))
    }

    func observation(at instant: AstroInstant, observer: SatelliteObserver) throws -> SatelliteObservation {
        let position = try topocentric(at: instant, observer: observer)
        let sun = try SatelliteFrames.sunITRSKilometres(at: instant)
        return SatelliteObservation(
            position: position,
            isSunlit: EarthShadow.isSunlit(satelliteKilometres: position.itrsKilometres, sunKilometres: sun),
            sunAltitudeDegrees: observer.sunAltitudeDegrees(sunITRSKilometres: sun))
    }

    func minutesFromEpoch(_ instant: AstroInstant) -> Double {
        instant.date.timeIntervalSince(epoch) / 60
    }
}
