import Foundation
import simd

/// Constellation borders as drawable polylines.
///
/// Each edge is a meridian (a great-circle arc) or a parallel of the B1875 equator (a small circle, not a great
/// circle), so edges are sampled along those curves at most `maxStepDegrees` apart and returned as ICRS (J2000)
/// unit vectors: apply `SkySession.apparentOfDate(icrs:)` and the horizon matrix like any catalogue direction.
public struct BoundaryGeometry: Sendable {
    public let maxStepDegrees: Double
    /// Closed rings (first point repeated last) per constellation id; Serpens has two.
    public let rings: [String: [[SIMD3<Double>]]]

    public init(boundaries: ConstellationBoundaries, maxStepDegrees: Double = 0.5) {
        self.maxStepDegrees = maxStepDegrees
        let fromB1875 = boundaries.toB1875.transpose
        var out: [String: [[SIMD3<Double>]]] = [:]
        for polygon in boundaries.polygons {
            out[polygon.constellation, default: []].append(
                Self.ring(polygon.vertices, step: maxStepDegrees).map { simd_normalize(fromB1875 * $0) })
        }
        rings = out
    }

    /// Closed polylines of one constellation's border (empty for an unknown id).
    public func polylines(for id: String) -> [[SIMD3<Double>]] { rings[id] ?? [] }

    /// B1875 unit vectors along the polygon, densified edge by edge.
    static func ring(_ vertices: [SIMD2<Double>], step: Double) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            let samples: [SIMD3<Double>]
            if a.y == b.y {
                var dRA = (b.x - a.x).truncatingRemainder(dividingBy: 24)
                if dRA < 0 { dRA += 24 }
                if dRA > 12 { dRA -= 24 }
                let arc = abs(dRA) * 15 * cos(Angle.radians(a.y))
                let n = max(1, Int((arc / step).rounded(.up)))
                samples = (0...n).map { k in
                    .unit(lon: Angle.radians((a.x + dRA * Double(k) / Double(n)) * 15), lat: Angle.radians(a.y))
                }
            } else {
                let n = max(1, Int((abs(b.y - a.y) / step).rounded(.up)))
                samples = (0...n).map { k in
                    .unit(lon: Angle.radians(a.x * 15), lat: Angle.radians(a.y + (b.y - a.y) * Double(k) / Double(n)))
                }
            }
            out.append(contentsOf: out.isEmpty ? samples : Array(samples.dropFirst()))
        }
        return out
    }
}
