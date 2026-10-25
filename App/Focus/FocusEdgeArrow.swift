import SwiftUI
import SkyCore
import simd

/// Points toward the pinned constellation when its reference point is off screen.
struct FocusEdgeArrow: View {
    @Environment(\.stylePalette) private var palette
    let screenPoint: SIMD2<Double>?
    let drawableSize: SIMD2<Double>

    var body: some View {
        GeometryReader { geo in
            if let p = screenPoint {
                let size = SIMD2(Double(geo.size.width), Double(geo.size.height))
                let edge = Self.clampedEdgePoint(target: p, in: size, margin: 28)
                let angle = atan2(p.y - edge.y, p.x - edge.x)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(palette.lightColor)
                    .rotationEffect(.radians(angle + .pi / 2))
                    .position(x: edge.x, y: edge.y)
                    .accessibilityLabel("Constellation off screen")
            }
        }
        .allowsHitTesting(false)
    }

    static func referenceScreenPoint(id: String, atlas: ConstellationAtlas, engine: SkyEngine, context: OverlayContext) -> SIMD2<Double>? {
        guard let ref = atlas.referencePoint(of: id), let observer = context.observer else { return nil }
        let session = engine.session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        let icrsToENU = session.icrsToENU(at: instant)
        let beta = session.earthVelocityOverC
        let enu = engine.refractionForFocus.apparent(enu: icrsToENU * SkySession.aberrate(ref, beta: beta))
        return context.projector.screenPoint(enu: enu)
    }

    static func shouldShowArrow(point: SIMD2<Double>?, in size: SIMD2<Double>, margin: Double = 24) -> Bool {
        guard let point else { return false }
        return point.x < margin || point.y < margin || point.x > size.x - margin || point.y > size.y - margin
    }

    private static func clampedEdgePoint(target: SIMD2<Double>, in size: SIMD2<Double>, margin: Double) -> CGPoint {
        let cx = size.x / 2, cy = size.y / 2
        let dx = target.x - cx, dy = target.y - cy
        guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else { return CGPoint(x: cx, y: margin) }
        var t = Double.infinity
        if dx > 0 { t = min(t, (size.x - margin - cx) / dx) }
        if dx < 0 { t = min(t, (margin - cx) / dx) }
        if dy > 0 { t = min(t, (size.y - margin - cy) / dy) }
        if dy < 0 { t = min(t, (margin - cy) / dy) }
        t = max(0, min(t, 1))
        return CGPoint(x: cx + dx * t, y: cy + dy * t)
    }
}
