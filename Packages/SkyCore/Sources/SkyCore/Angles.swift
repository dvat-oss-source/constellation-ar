import Foundation
import simd

public enum Angle {
    public static let degreesPerRadian = 180.0 / Double.pi
    public static let radiansPerDegree = Double.pi / 180.0
    public static let radiansPerArcsecond = Double.pi / (180.0 * 3600.0)

    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * radiansPerDegree }
    @inlinable public static func degrees(_ radians: Double) -> Double { radians * degreesPerRadian }

    /// Wraps to [0, 2π).
    @inlinable public static func wrapTwoPi(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 2 * .pi)
        return r < 0 ? r + 2 * .pi : r
    }

    /// Wraps to (-π, π].
    @inlinable public static func wrapPi(_ x: Double) -> Double {
        let r = wrapTwoPi(x)
        return r > .pi ? r - 2 * .pi : r
    }

    /// Angle between two unit (or non-zero) vectors, numerically stable for small and large separations.
    @inlinable public static func separation(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(simd_length(simd_cross(a, b)), simd_dot(a, b))
    }
}
