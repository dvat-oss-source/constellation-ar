import Foundation
import simd

/// Saemundsson (1986) refraction, true → apparent altitude, scaled for pressure and temperature.
///
/// The formula is non-monotonic below about −3°, so below −1° true altitude the correction is tapered linearly
/// to zero at −5°; that keeps true → apparent strictly increasing and therefore exactly invertible.
public struct Refraction: Sendable, Hashable, Codable {
    public var pressureMillibar: Double
    public var temperatureCelsius: Double

    public static let standard = Refraction(pressureMillibar: 1010, temperatureCelsius: 10)
    public static let none = Refraction(pressureMillibar: 0, temperatureCelsius: 10)

    public init(pressureMillibar: Double, temperatureCelsius: Double) {
        self.pressureMillibar = pressureMillibar
        self.temperatureCelsius = temperatureCelsius
    }

    var scale: Double { (pressureMillibar / 1010) * (283 / (273 + temperatureCelsius)) }

    static let taperStart = -1.0
    static let taperEnd = -5.0

    /// Saemundsson in degrees for true altitude `h` degrees, offset so R(90°) = 0.
    static func saemundssonDegrees(_ h: Double) -> Double {
        let arcmin = 1.02 / tan(Angle.radians(h + 10.3 / (h + 5.11))) + 0.0019279
        return arcmin / 60
    }

    /// Apparent − true altitude in radians for a true (airless) altitude in radians.
    public func correction(trueAltitude: Double) -> Double {
        let scale = self.scale
        guard scale > 0 else { return 0 }
        let h = Angle.degrees(trueAltitude)
        let r: Double
        if h >= Self.taperStart {
            r = Self.saemundssonDegrees(min(h, 90))
        } else if h > Self.taperEnd {
            r = Self.saemundssonDegrees(Self.taperStart) * (h - Self.taperEnd) / (Self.taperStart - Self.taperEnd)
        } else {
            r = 0
        }
        return Angle.radians(max(r, 0) * scale)
    }

    public func apparentAltitude(trueAltitude h: Double) -> Double {
        h + correction(trueAltitude: h)
    }

    /// Exact numeric inverse of `apparentAltitude(trueAltitude:)` (Newton with bisection fallback, |residual| < 1e-14 rad).
    public func trueAltitude(apparentAltitude a: Double) -> Double {
        guard scale > 0 else { return a }
        var lo = a - Angle.radians(2), hi = a
        var h = a - correction(trueAltitude: a)
        for _ in 0..<60 {
            let f = apparentAltitude(trueAltitude: h) - a
            if abs(f) < 1e-15 { break }
            if f > 0 { hi = min(hi, h) } else { lo = max(lo, h) }
            let dh = 1e-7
            let deriv = (apparentAltitude(trueAltitude: h + dh) - apparentAltitude(trueAltitude: h - dh)) / (2 * dh)
            var next = h - f / deriv
            if !(next > lo && next < hi) || !deriv.isFinite { next = 0.5 * (lo + hi) }
            h = next
        }
        return h
    }

    /// Refracts an ENU direction (keeps azimuth).
    public func apparent(enu v: SIMD3<Double>) -> SIMD3<Double> {
        var hc = HorizontalCoordinates(enu: v)
        hc.altitude = apparentAltitude(trueAltitude: hc.altitude)
        return hc.enu
    }

    /// Removes refraction from an apparent ENU direction (keeps azimuth).
    public func unrefracted(enu v: SIMD3<Double>) -> SIMD3<Double> {
        var hc = HorizontalCoordinates(enu: v)
        hc.altitude = trueAltitude(apparentAltitude: hc.altitude)
        return hc.enu
    }
}
