import Foundation
import simd

public enum StarAppearance {
    /// Disc radius `k·(limit − vmag)`, clamped at `minimum`.
    @inlinable public static func radius(vmag: Double, k: Double, limitingMagnitude: Double = 6.5, minimum: Double = 0) -> Double {
        max(minimum, k * (limitingMagnitude - vmag))
    }

    /// Effective temperature from B−V (Ballesteros 2012).
    public static func temperature(bv: Double) -> Double {
        4600 * (1 / (0.92 * bv + 1.7) + 1 / (0.92 * bv + 0.62))
    }

    /// Linear-sRGB tint (max component 1) of a blackbody at the star's B−V temperature, blended toward white by
    /// `1 − saturation`. Unknown B−V (NaN) gives white.
    public static func tint(bv: Float, saturation: Double = 1) -> SIMD3<Float> {
        guard bv.isFinite else { return SIMD3(1, 1, 1) }
        let t = min(max(temperature(bv: Double(min(max(bv, -0.4), 2.0))), 1667), 25_000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        var rgb = SIMD3(
            3.2406 * X - 1.5372 * Y - 0.4986 * Z,
            -0.9689 * X + 1.8758 * Y + 0.0415 * Z,
            0.0557 * X - 0.2040 * Y + 1.0570 * Z
        )
        rgb = simd_max(rgb, .zero)
        rgb /= max(rgb.max(), 1e-9)
        let s = min(max(saturation, 0), 1)
        return SIMD3<Float>(rgb * s + SIMD3(repeating: 1 - s))
    }
}

public struct StarLabel: Sendable, Hashable {
    public var hip: Int
    public var name: String
    public var vmag: Float
    public var direction: SIMD3<Double>
}

public enum SkyLabels {
    /// Named stars flagged for labelling (names.json `label: true`), brightest first, at most `limit`.
    public static func starLabels(names: StarNames, catalog: StarCatalog, limit: Int = 50) -> [StarLabel] {
        names.stars.compactMap { n -> StarLabel? in
            guard n.label == true, let s = catalog.star(hip: n.hip) else { return nil }
            return StarLabel(hip: n.hip, name: n.name, vmag: s.vmag, direction: s.directionDouble)
        }
        .sorted { $0.vmag < $1.vmag }
        .prefix(limit)
        .map { $0 }
    }

    /// Mean direction of a figure's stars (ICRS), a reasonable constellation-name anchor.
    public static func figureCentroid(_ figure: ConstellationFigure, catalog: StarCatalog) -> SIMD3<Double>? {
        let v = figure.starHips.compactMap { catalog.star(hip: $0)?.directionDouble }
        guard !v.isEmpty else { return nil }
        let sum = v.reduce(SIMD3<Double>.zero, +)
        return simd_length(sum) > 1e-9 ? simd_normalize(sum) : nil
    }
}
