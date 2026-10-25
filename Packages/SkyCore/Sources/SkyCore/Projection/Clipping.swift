import Foundation
import simd

/// The visible part of a sky segment A→B, as view points plus the parameters `t ∈ [0, 1]` along the 3D chord
/// A + t·(B − A) where it starts and ends (so partial-progress drawing stays attached to the stars).
public struct ClippedSegment: Sendable, Hashable {
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>
    public var startT: Double
    public var endT: Double
    /// Camera-space depths at `start` and `end`, needed to map chord parameters to screen positions.
    public var startDepth: Double
    public var endDepth: Double

    /// Sub-segment covering chord parameters [t0, t1] ∩ [startT, endT] (for drawing a fraction of the line).
    public func restricted(to t0: Double, _ t1: Double) -> ClippedSegment? {
        let lo = max(t0, startT), hi = min(t1, endT)
        guard hi > lo, endT > startT else { return nil }
        func at(_ t: Double) -> (point: SIMD2<Double>, depth: Double) {
            let mu = (t - startT) / (endT - startT)
            let depth = startDepth + (endDepth - startDepth) * mu
            return (start + (end - start) * (mu * endDepth / depth), depth)
        }
        let a = at(lo), b = at(hi)
        return ClippedSegment(start: a.point, end: b.point, startT: lo, endT: hi, startDepth: a.depth, endDepth: b.depth)
    }
}

extension Projector {
    /// Clips the straight chord between two directions (ENU) against the camera's near plane, projects the
    /// visible part, then clips it to the view expanded by `guardBand` points. Segments partly behind the camera
    /// keep their visible portion instead of being dropped.
    ///
    /// The returned `startT/endT` are chord parameters (perspective-correct), not screen fractions.
    public func clipSegment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, guardBand: Double = 64) -> ClippedSegment? {
        let ca = camera(enu: simd_normalize(a)), cb = camera(enu: simd_normalize(b))
        var t0 = 0.0, t1 = 1.0
        let za = ca.z - nearZ, zb = cb.z - nearZ
        if za <= 0 && zb <= 0 { return nil }
        if za <= 0 { t0 = za / (za - zb) }
        if zb <= 0 { t1 = za / (za - zb) }
        let p0c = ca + (cb - ca) * t0, p1c = ca + (cb - ca) * t1
        let s0 = mapping.screen(fromPixel: pixelUnchecked(camera: p0c))
        let s1 = mapping.screen(fromPixel: pixelUnchecked(camera: p1c))

        guard let (u0, u1) = Self.liangBarsky(s0, s1, min: SIMD2(-guardBand, -guardBand),
                                              max: mapping.viewSize + SIMD2(guardBand, guardBand)) else { return nil }
        let z0 = p0c.z, z1 = p1c.z
        func lambda(_ s: Double) -> Double { s * z0 / ((1 - s) * z1 + s * z0) }
        let l0 = lambda(u0), l1 = lambda(u1)
        return ClippedSegment(start: s0 + (s1 - s0) * u0, end: s0 + (s1 - s0) * u1,
                              startT: t0 + (t1 - t0) * l0, endT: t0 + (t1 - t0) * l1,
                              startDepth: z0 + (z1 - z0) * l0, endDepth: z0 + (z1 - z0) * l1)
    }

    /// Screen-space Liang–Barsky; returns the parameter interval of the segment inside the rectangle.
    static func liangBarsky(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, min lo: SIMD2<Double>, max hi: SIMD2<Double>)
        -> (Double, Double)? {
        let d = p1 - p0
        var u0 = 0.0, u1 = 1.0
        let checks: [(Double, Double)] = [
            (-d.x, p0.x - lo.x), (d.x, hi.x - p0.x),
            (-d.y, p0.y - lo.y), (d.y, hi.y - p0.y),
        ]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { u0 = Swift.max(u0, r) } else { u1 = Swift.min(u1, r) }
                if u0 > u1 { return nil }
            }
        }
        return (u0, u1)
    }

    /// Projects a polyline of directions into one or more visible screen polylines (broken where clipped).
    public func clipPolyline(_ points: [SIMD3<Double>], guardBand: Double = 64) -> [[SIMD2<Double>]] {
        var result: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []
        for i in 0..<max(points.count - 1, 0) {
            guard let seg = clipSegment(points[i], points[i + 1], guardBand: guardBand) else {
                if current.count > 1 { result.append(current) }
                current = []
                continue
            }
            if current.isEmpty || seg.startT > 1e-9 || simd_distance(current.last!, seg.start) > 1e-6 {
                if current.count > 1 { result.append(current) }
                current = [seg.start]
            }
            current.append(seg.end)
            if seg.endT < 1 - 1e-9 {
                result.append(current)
                current = []
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    /// Clips a closed polygon of directions against the near plane (Sutherland–Hodgman in camera space) and
    /// projects it. Returns nil if fully behind the camera. Screen clipping is left to the rasteriser.
    public func clipPolygon(_ points: [SIMD3<Double>]) -> [SIMD2<Double>]? {
        let cam = points.map { camera(enu: simd_normalize($0)) }
        guard !cam.isEmpty else { return nil }
        var out: [SIMD3<Double>] = []
        for i in 0..<cam.count {
            let a = cam[i], b = cam[(i + 1) % cam.count]
            let ina = a.z > nearZ, inb = b.z > nearZ
            if ina { out.append(a) }
            if ina != inb {
                let t = (nearZ - a.z) / (b.z - a.z)
                var p = a + (b - a) * t
                p.z = nearZ
                out.append(p)
            }
        }
        guard out.count >= 3 else { return nil }
        return out.map { mapping.screen(fromPixel: pixelUnchecked(camera: $0)) }
    }
}
