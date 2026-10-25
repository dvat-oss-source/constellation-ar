import Foundation
import SkyCore
import simd

enum FocusOverlay {
    /// Soft dashed boundary ring for the pinned constellation.
    @MainActor
    static func boundarySegments(id: String, geometry: BoundaryGeometry, context: OverlayContext, engine: SkyEngine) -> [OverlaySegment] {
        guard let observer = context.observer else { return [] }
        let session = engine.session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        let icrsToENU = session.icrsToENU(at: instant)
        let beta = session.earthVelocityOverC
        let projector = context.projector
        let refraction = engine.refractionForFocus
        let style = SkyStyle(night: Float(context.lighting), px: Float(context.contentScale))
        let color = SIMD4<Float>(0.75, 0.88, 1.0, 0.45 + 0.25 * style.night)
        var dashes: [OverlaySegment] = []
        for ring in geometry.polylines(for: id) {
            var path: [SIMD3<Double>] = []
            for v in ring {
                let enu = refraction.apparent(enu: icrsToENU * SkySession.aberrate(v, beta: beta))
                path.append(enu)
            }
            for line in projector.clipPolyline(path) {
                var travelled: Float = 0
                for k in 0..<(line.count - 1) {
                    let a = SIMD2<Float>(line[k]), b = SIMD2<Float>(line[k + 1])
                    dashes.append(OverlaySegment(a: a, b: b, width: 1.4 * style.px, color: color,
                                                 outlineWidth: style.lineOutline * 0.5, dashed: true, dashPhase: travelled))
                    travelled += simd_distance(a, b)
                }
            }
        }
        return dashes
    }

    @MainActor
    static func outlineSegments(sky: SkyOutline, progress: Double, context: OverlayContext, engine: SkyEngine,
                                redTheme: Bool) -> [OverlaySegment] {
        guard progress > 0, let observer = context.observer else { return [] }
        let session = engine.session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        let icrsToENU = session.icrsToENU(at: instant)
        let beta = session.earthVelocityOverC
        let projector = context.projector
        let refraction = engine.refractionForFocus
        let style = SkyStyle(night: Float(context.lighting), px: Float(context.contentScale))
        let palette = StyleTokens.blended(lighting: context.lighting, red: redTheme)
        let encoded = StyleTokens.encode(palette.light)
        let color = SIMD4<Float>(encoded.x, encoded.y, encoded.z, 0.42 + 0.28 * style.night)
        let width = StyleTokens.restingLineWidth * 0.75 * style.px
        let glow = StyleTokens.litLineGlow * 0.55
        var segments: [OverlaySegment] = []
        for path in sky.partialPaths(progress: progress) {
            var enuPath: [SIMD3<Double>] = []
            for v in path {
                enuPath.append(refraction.apparent(enu: icrsToENU * SkySession.aberrate(v, beta: beta)))
            }
            for line in projector.clipPolyline(enuPath) {
                for k in 0..<(line.count - 1) {
                    let a = SIMD2<Float>(line[k]), b = SIMD2<Float>(line[k + 1])
                    segments.append(OverlaySegment(a: a, b: b, width: width, color: color,
                                                   outlineWidth: style.lineOutline * 0.35, glow: glow))
                }
            }
        }
        return segments
    }
}
