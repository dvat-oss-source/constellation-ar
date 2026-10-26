import SkyCore
import simd

/// Day/night look shared by the sky layers. `night` is 0 (day) … 1 (night); `px` is screen pixels per point.
struct SkyStyle {
    let night: Float
    let px: Float

    private var palette: StylePalette { StyleTokens.blended(lighting: Double(night), red: false) }
    private func encoded(_ c: SIMD3<Float>, _ alpha: Float) -> SIMD4<Float> { SIMD4(StyleTokens.encode(c), alpha) }

    var lineWidth: Float { (StyleTokens.restingLineWidth + 0.35 * (1 - night)) * px }
    var litLineWidth: Float { (StyleTokens.litLineWidth + 0.35 * (1 - night)) * px }
    /// Dark rim that keeps lines readable against a bright sky.
    var lineOutline: Float { (1 - night) * StyleTokens.dayUnderglowWidth * px }
    var restingLineColor: SIMD4<Float> { encoded(palette.line, 0.42 + 0.5 * (1 - night)) }
    var highlightColor: SIMD4<Float> { encoded(palette.core, 1) }
    var labelColor: SIMD4<Float> { encoded(palette.label, 0.9) }
}

enum SkySymbols {
    static func color(for kind: DeepSkyObject.Kind) -> SIMD4<Float> {
        switch kind {
        case .galaxy: SIMD4(1.0, 0.72, 0.5, 0.9)
        case .openCluster, .starGroup: SIMD4(1.0, 0.92, 0.55, 0.9)
        case .globularCluster: SIMD4(1.0, 0.85, 0.5, 0.9)
        case .planetaryNebula: SIMD4(0.55, 0.95, 1.0, 0.9)
        case .nebula, .clusterWithNebula: SIMD4(0.55, 1.0, 0.7, 0.9)
        case .supernovaRemnant: SIMD4(1.0, 0.6, 0.75, 0.9)
        case .other: SIMD4(0.8, 0.8, 0.8, 0.8)
        }
    }

    /// Type symbol centred on `c` (pixels): galaxy = tilted ellipse, open cluster = dashed circle, globular = circle
    /// with a cross, planetary nebula = circle with four ticks, nebula = square, remnant = diamond.
    /// `majorAxis` is the unit screen direction of the galaxy's long axis.
    static func segments(kind: DeepSkyObject.Kind, center c: SIMD2<Float>, radius r: Float, axisRatio: Float,
                         majorAxis: SIMD2<Float>, width: Float, color: SIMD4<Float>) -> [OverlaySegment] {
        func seg(_ a: SIMD2<Float>, _ b: SIMD2<Float>, dashed: Bool = false) -> OverlaySegment {
            OverlaySegment(a: a, b: b, width: width, color: color, outlineWidth: 0, dashed: dashed)
        }
        func ring(radiusX: Float, radiusY: Float, axis: SIMD2<Float>, dashed: Bool) -> [OverlaySegment] {
            let n = 20
            let minor = SIMD2<Float>(-axis.y, axis.x)
            let points = (0...n).map { k -> SIMD2<Float> in
                let t = Float(k) / Float(n) * 2 * .pi
                return c + axis * (cos(t) * radiusX) + minor * (sin(t) * radiusY)
            }
            return (0..<n).map { seg(points[$0], points[$0 + 1], dashed: dashed) }
        }
        let axis = majorAxis
        switch kind {
        case .galaxy:
            return ring(radiusX: r, radiusY: r * max(axisRatio, 0.35), axis: axis, dashed: false)
        case .openCluster, .starGroup:
            return ring(radiusX: r, radiusY: r, axis: SIMD2(1, 0), dashed: true)
        case .globularCluster:
            return ring(radiusX: r, radiusY: r, axis: SIMD2(1, 0), dashed: false)
                + [seg(c - SIMD2(r * 1.4, 0), c + SIMD2(r * 1.4, 0)), seg(c - SIMD2(0, r * 1.4), c + SIMD2(0, r * 1.4))]
        case .planetaryNebula:
            var out = ring(radiusX: r * 0.7, radiusY: r * 0.7, axis: SIMD2(1, 0), dashed: false)
            for d in [SIMD2<Float>(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)] {
                out.append(seg(c + d * (r * 0.9), c + d * (r * 1.5)))
            }
            return out
        case .nebula, .clusterWithNebula, .other:
            let h = r * 0.9
            let p = [c + SIMD2(-h, -h), c + SIMD2(h, -h), c + SIMD2(h, h), c + SIMD2(-h, h)]
            return (0..<4).map { seg(p[$0], p[($0 + 1) % 4]) }
        case .supernovaRemnant:
            let p = [c + SIMD2(0, -r), c + SIMD2(r, 0), c + SIMD2(0, r), c + SIMD2(-r, 0)]
            return (0..<4).map { seg(p[$0], p[($0 + 1) % 4]) }
        }
    }
}

/// Constellation label anchor from visible stick-figure geometry (same horizon/clip rules as constellation lines).
enum FigureLabels {
    struct Anchor {
        var position: SIMD2<Float>
        /// 1 when part of the drawn figure is above the horizon, fading toward 0 as the highest drawn point sinks to −0.02.
        var visibility: Float
    }

    /// Centroid of the on-screen (guard-band clipped) segment ends, preferring ends above the horizon.
    static func anchor(figure: FigureRender, enu: [SIMD3<Double>], projector: Projector) -> Anchor? {
        var skySum = SIMD2<Double>.zero, allSum = SIMD2<Double>.zero
        var skyCount = 0, allCount = 0
        var maxZ = -1.0
        func accumulate(_ point: SIMD2<Double>, z: Double) {
            maxZ = max(maxZ, z)
            allSum += point
            allCount += 1
            if z >= 0 {
                skySum += point
                skyCount += 1
            }
        }
        for (a, b) in figure.pairs {
            let pa = enu[a], pb = enu[b]
            if pa.z < -0.02 && pb.z < -0.02 { continue }
            guard let clip = projector.clipSegment(pa, pb) else { continue }
            let za = simd_normalize(pa).z, zb = simd_normalize(pb).z
            accumulate(clip.start, z: za + (zb - za) * clip.startT)
            accumulate(clip.end, z: za + (zb - za) * clip.endT)
        }
        guard allCount > 0 else { return nil }
        let position = skyCount > 0 ? skySum / Double(skyCount) : allSum / Double(allCount)
        let visibility = skyCount > 0 ? 1 : Float(min(1, max(0, (maxZ + 0.02) / 0.02)))
        return Anchor(position: SIMD2<Float>(position), visibility: visibility)
    }
}

/// Greedy label placement: higher priority first; constellation names stay on-screen and shift rather than drop.
struct LabelPlacer {
    private struct Candidate {
        var label: OverlayLabel
        var priority: Float
        var fallbacks: [SIMD2<Float>]
        /// Try many offsets and clamp into the safe rect instead of dropping (constellation names).
        var required: Bool
    }

    private var candidates: [Candidate] = []
    /// Pixels; labels never extend above the top bar, past the sides, or under the bottom card/control bar.
    private let safeMin: SIMD2<Float>
    private let safeMax: SIMD2<Float>
    private let scale: Float

    /// Points, nearest first, tried for required labels before they are forced in.
    private static let requiredOffsets: [SIMD2<Float>] = {
        var out: [SIMD2<Float>] = []
        for dy in stride(from: Float(-78), through: Float(78), by: 26) {
            for dx in stride(from: Float(-80), through: Float(80), by: 40) { out.append(SIMD2(dx, dy)) }
        }
        return out.sorted { simd_length_squared($0) < simd_length_squared($1) }
    }()

    init(viewport: SIMD2<Double>, contentScale: Double, bottomInsetPoints: Float = 168, topInsetPoints: Float = 44,
         sideInsetPoints: Float = 6) {
        scale = Float(contentScale)
        safeMin = SIMD2(sideInsetPoints, topInsetPoints) * scale
        safeMax = SIMD2<Float>(viewport) - SIMD2(sideInsetPoints, bottomInsetPoints) * scale
    }

    mutating func add(_ label: OverlayLabel, priority: Float, fallbacks: [SIMD2<Float>] = [], required: Bool = false) {
        candidates.append(Candidate(label: label, priority: priority, fallbacks: fallbacks, required: required))
    }

    private func offsets(for candidate: Candidate) -> [SIMD2<Float>] {
        candidate.required ? Self.requiredOffsets : [SIMD2<Float>.zero] + candidate.fallbacks
    }

    private func clampOrigin(_ origin: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(min(max(origin.x, safeMin.x), max(safeMin.x, safeMax.x - size.x)),
              min(max(origin.y, safeMin.y), max(safeMin.y, safeMax.y - size.y)))
    }

    func place() -> [OverlayLabel] {
        var placed: [(min: SIMD2<Float>, max: SIMD2<Float>)] = []
        var result: [OverlayLabel] = []
        for candidate in candidates.sorted(by: { $0.priority > $1.priority }) {
            var l = candidate.label
            let size = SIMD2(Float(l.text.count) * l.fontSize * 0.56 + 6, l.fontSize * 1.3) * scale
            let home = l.position
            var accepted = false
            for offset in offsets(for: candidate) {
                l.position = home + offset * scale
                var origin = l.position - size * l.anchor
                if candidate.required {
                    origin = clampOrigin(origin, size: size)
                    l.position = origin + size * l.anchor
                } else if origin.x < safeMin.x || origin.y < safeMin.y || origin.x + size.x > safeMax.x || origin.y + size.y > safeMax.y {
                    continue
                }
                let box = (min: origin, max: origin + size)
                if placed.contains(where: { $0.min.x < box.max.x && $0.max.x > box.min.x && $0.min.y < box.max.y && $0.max.y > box.min.y }) {
                    continue
                }
                placed.append(box)
                result.append(l)
                accepted = true
                break
            }
            if !accepted, candidate.required {
                let origin = clampOrigin(home - size * l.anchor, size: size)
                l.position = origin + size * l.anchor
                placed.append((min: origin, max: origin + size))
                result.append(l)
            }
        }
        return result
    }
}
