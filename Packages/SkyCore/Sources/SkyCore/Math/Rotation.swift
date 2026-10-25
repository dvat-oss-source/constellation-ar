import simd

/// Passive (frame) rotations as used in IAU/SOFA conventions: `rx(a)` rotates the coordinate frame by `a` about x,
/// so a fixed vector's components change as `v' = rx(a) * v`.
public enum Rotation {
    @inlinable public static func rx(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(rows: [
            SIMD3(1, 0, 0),
            SIMD3(0, c, s),
            SIMD3(0, -s, c),
        ])
    }

    @inlinable public static func ry(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(rows: [
            SIMD3(c, 0, -s),
            SIMD3(0, 1, 0),
            SIMD3(s, 0, c),
        ])
    }

    @inlinable public static func rz(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(rows: [
            SIMD3(c, s, 0),
            SIMD3(-s, c, 0),
            SIMD3(0, 0, 1),
        ])
    }
}

public extension SIMD3 where Scalar == Double {
    /// Unit vector from right ascension / longitude `lon` and declination / latitude `lat`, both in radians.
    @inlinable static func unit(lon: Double, lat: Double) -> SIMD3<Double> {
        let cl = cos(lat)
        return SIMD3(cl * cos(lon), cl * sin(lon), sin(lat))
    }

    /// (longitude in [0, 2π), latitude in [-π/2, π/2]) in radians.
    @inlinable var lonLat: (lon: Double, lat: Double) {
        let lon = Angle.wrapTwoPi(atan2(y, x))
        let lat = atan2(z, (x * x + y * y).squareRoot())
        return (lon, lat)
    }

    @inlinable var normalized: SIMD3<Double> { simd_normalize(self) }
}
