import AstronomyKit
import Foundation
import simd

/// Observer position on the WGS84 ellipsoid. Angles in degrees, height in metres.
public struct GeoLocation: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }

    var latitudeRadians: Double { Angle.radians(latitude) }
    var longitudeRadians: Double { Angle.radians(longitude) }

    /// Earth-fixed (ITRS) position in km.
    public var itrsKilometres: SIMD3<Double> {
        let a = 6378.137, f = 1 / 298.257223563
        let e2 = f * (2 - f)
        let phi = latitudeRadians, lam = longitudeRadians
        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let h = height / 1000
        return SIMD3((n + h) * cos(phi) * cos(lam), (n + h) * cos(phi) * sin(lam), (n * (1 - e2) + h) * sin(phi))
    }

    /// Rotation taking an Earth-fixed (ITRS) vector to local East/North/Up.
    public var itrsToENU: simd_double3x3 {
        let phi = latitudeRadians, lam = longitudeRadians
        return simd_double3x3(rows: [
            SIMD3(-sin(lam), cos(lam), 0),
            SIMD3(-sin(phi) * cos(lam), -sin(phi) * sin(lam), cos(phi)),
            SIMD3(cos(phi) * cos(lam), cos(phi) * sin(lam), sin(phi)),
        ])
    }

    var astronomyKitObserver: AstronomyKit.Observer {
        AstronomyKit.Observer(latitude: latitude, longitude: longitude, height: height)
    }
}

/// Horizontal coordinates. Azimuth from north through east. Radians.
public struct HorizontalCoordinates: Sendable, Hashable {
    public var altitude: Double
    public var azimuth: Double

    public init(altitude: Double, azimuth: Double) {
        self.altitude = altitude
        self.azimuth = azimuth
    }

    public init(enu v: SIMD3<Double>) {
        altitude = atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot())
        azimuth = Angle.wrapTwoPi(atan2(v.x, v.y))
    }

    public var enu: SIMD3<Double> {
        let ca = cos(altitude)
        return SIMD3(ca * sin(azimuth), ca * cos(azimuth), sin(altitude))
    }
}

/// Per-session sky transform: one bias-precession-nutation matrix and one Earth velocity for annual aberration,
/// computed once (both change by < 0.4″ per day), plus per-frame sidereal time in Double.
public struct SkySession: Sendable {
    public static let speedOfLightAUPerDay = 173.1446326846693

    public let epoch: AstroInstant
    public let location: GeoLocation
    /// ICRS → true equator and equinox of date.
    public let biasPrecessionNutation: simd_double3x3
    /// Earth's barycentric velocity divided by c, ICRS axes. Zero disables aberration.
    public let earthVelocityOverC: SIMD3<Double>
    let equationOfEquinoxes: Double

    public init(epoch: AstroInstant, location: GeoLocation, includeNutation: Bool = true, includeAberration: Bool = true) {
        let t = epoch.centuriesTT
        let n = EarthOrientation.nutation(centuriesTT: t)
        let epsA = EarthOrientation.meanObliquity(centuriesTT: t)
        let beta = includeAberration ? Self.earthVelocityOverC(at: epoch) : .zero
        self.init(
            epoch: epoch,
            location: location,
            biasPrecessionNutation: includeNutation
                ? EarthOrientation.biasPrecessionNutation(centuriesTT: t)
                : EarthOrientation.biasPrecession(centuriesTT: t),
            earthVelocityOverC: beta,
            equationOfEquinoxes: includeNutation ? EarthOrientation.equationOfEquinoxes(n, meanObliquity: epsA) : 0
        )
    }

    public init(date: Date, location: GeoLocation) {
        self.init(epoch: AstroInstant(date: date), location: location)
    }

    init(epoch: AstroInstant, location: GeoLocation, biasPrecessionNutation: simd_double3x3,
         earthVelocityOverC: SIMD3<Double>, equationOfEquinoxes: Double) {
        self.epoch = epoch
        self.location = location
        self.biasPrecessionNutation = biasPrecessionNutation
        self.earthVelocityOverC = earthVelocityOverC
        self.equationOfEquinoxes = equationOfEquinoxes
    }

    /// Earth barycentric velocity / c from AstronomyKit (VSOP87), J2000 equatorial axes (ICRS to 23 mas).
    public static func earthVelocityOverC(at instant: AstroInstant) -> SIMD3<Double> {
        let time = AstroTime(tt: instant.daysTT)
        guard let state = try? CelestialBody.earth.barycentricState(at: time) else { return .zero }
        return SIMD3(state.velocity.x, state.velocity.y, state.velocity.z) / speedOfLightAUPerDay
    }

    // MARK: Catalog → apparent

    /// Relativistic annual aberration of a unit direction (SOFA iauAb without light deflection).
    @inlinable public static func aberrate(_ p: SIMD3<Double>, beta v: SIMD3<Double>) -> SIMD3<Double> {
        let bm1 = (1 - simd_length_squared(v)).squareRoot()
        let pdv = simd_dot(p, v)
        let w1 = 1 + pdv / (1 + bm1)
        return simd_normalize(bm1 * p + w1 * v)
    }

    /// ICRS astrometric unit vector → apparent direction referred to the true equator and equinox of date.
    @inlinable public func apparentOfDate(icrs p: SIMD3<Double>) -> SIMD3<Double> {
        biasPrecessionNutation * Self.aberrate(p, beta: earthVelocityOverC)
    }

    /// Exact inverse of `apparentOfDate(icrs:)` (aberration inverted by fixed-point iteration to < 1e-15 rad).
    public func icrs(fromApparentOfDate q: SIMD3<Double>) -> SIMD3<Double> {
        let target = biasPrecessionNutation.transpose * simd_normalize(q)
        var p = target
        for _ in 0..<6 {
            let err = Self.aberrate(p, beta: earthVelocityOverC) - target
            p = simd_normalize(p - err)
        }
        return p
    }

    // MARK: Sidereal time / horizon

    public func gast(at instant: AstroInstant) -> Double {
        Angle.wrapTwoPi(EarthOrientation.gmst(daysUT1: instant.daysUT1, centuriesTT: instant.centuriesTT) + equationOfEquinoxes)
    }

    /// Local apparent sidereal time, radians.
    public func localSiderealTime(at instant: AstroInstant) -> Double {
        Angle.wrapTwoPi(gast(at: instant) + location.longitudeRadians)
    }

    /// True-of-date equatorial → topocentric East/North/Up (airless; stellar diurnal parallax neglected).
    public func horizonMatrix(at instant: AstroInstant) -> simd_double3x3 {
        Self.horizonMatrix(localSiderealTime: localSiderealTime(at: instant), latitude: location.latitudeRadians)
    }

    public static func horizonMatrix(localSiderealTime lst: Double, latitude phi: Double) -> simd_double3x3 {
        let local = simd_double3x3(rows: [
            SIMD3(0, 1, 0),
            SIMD3(-sin(phi), 0, cos(phi)),
            SIMD3(cos(phi), 0, sin(phi)),
        ])
        return local * Rotation.rz(lst)
    }

    /// ICRS → ENU in one matrix for the given instant; apply `aberrate` first (or use `enu(icrs:at:)`).
    public func icrsToENU(at instant: AstroInstant) -> simd_double3x3 {
        horizonMatrix(at: instant) * biasPrecessionNutation
    }

    /// Airless topocentric ENU direction of a catalog star.
    public func enu(icrs p: SIMD3<Double>, at instant: AstroInstant) -> SIMD3<Double> {
        horizonMatrix(at: instant) * apparentOfDate(icrs: p)
    }

    /// Precomputes per-session apparent directions (aberration applied, ICRS axes) so a renderer only needs
    /// the per-frame matrix `icrsToENU(at:)`.
    public func aberrated(_ directions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        directions.map { d in
            SIMD3<Float>(Self.aberrate(SIMD3<Double>(d).normalized, beta: earthVelocityOverC))
        }
    }

    /// Hour angle (radians, (-π, π]) and declination of a true-of-date direction.
    public func hourAngleDeclination(ofDate v: SIMD3<Double>, at instant: AstroInstant) -> (hourAngle: Double, declination: Double) {
        let (ra, dec) = v.lonLat
        return (Angle.wrapPi(localSiderealTime(at: instant) - ra), dec)
    }
}
