import simd

/// Visual test that needs only the attitude: horizon, altitude circles, compass points and the zenith.
enum HorizonOverlay {
    static func frame(_ context: OverlayContext) -> OverlayFrame {
        let px = Float(context.contentScale)
        let night = Float(context.lighting)
        let width = (2.4 - 1.2 * night) * px
        let outline = (1 - night) * 1.5 * px
        let glow = 0.2 + 0.6 * night
        let horizonColor = SIMD4<Float>(0.55, 0.95, 0.7, 0.9)
        let gridColor = SIMD4<Float>(0.6, 0.75, 1.0, 0.45)
        let north = SIMD4<Float>(1.0, 0.35, 0.3, 1)
        let white = SIMD4<Float>(1, 1, 1, 0.95)

        var segments: [OverlaySegment] = []
        func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>, width: Float, color: SIMD4<Float>, glow: Float, dashed: Bool) {
            guard let s = context.segment(reference: a, b) else { return }
            segments.append(OverlaySegment(a: SIMD2<Float>(s.a), b: SIMD2<Float>(s.b), width: width, color: color,
                                           outlineWidth: outline, glow: glow, dashed: dashed, dashPhase: Float(s.phase)))
        }
        func circle(altitude: Double, step: Double, width: Float, color: SIMD4<Float>, glow: Float, dashed: Bool) {
            for az in stride(from: 0.0, to: 360.0, by: step) {
                add(OverlayContext.referenceDirection(azimuthDegrees: az, altitudeDegrees: altitude),
                    OverlayContext.referenceDirection(azimuthDegrees: az + step, altitudeDegrees: altitude),
                    width: width, color: color, glow: glow, dashed: dashed)
            }
        }

        // A great circle projects to a straight line, so the horizon needs only chords (< 180° each) and has
        // no polyline joints where glow halos would overlap.
        circle(altitude: 0, step: 45, width: width, color: horizonColor, glow: glow, dashed: false)
        circle(altitude: 30, step: 5, width: width * 0.6, color: gridColor, glow: 0, dashed: true)
        circle(altitude: 60, step: 5, width: width * 0.6, color: gridColor, glow: 0, dashed: true)

        var points: [OverlayPoint] = []
        for az in stride(from: 0.0, to: 360.0, by: 45) {
            let isCardinal = az.truncatingRemainder(dividingBy: 90) == 0
            let color = az == 0 ? north : white
            let base = OverlayContext.referenceDirection(azimuthDegrees: az, altitudeDegrees: 0)
            let top = OverlayContext.referenceDirection(azimuthDegrees: az, altitudeDegrees: isCardinal ? 8 : 4)
            add(base, top, width: width, color: color, glow: glow, dashed: false)
            if let p = context.screenPoint(reference: base) {
                points.append(OverlayPoint(position: SIMD2<Float>(p), radius: (isCardinal ? 5 : 3) * px, color: color))
            }
        }
        if let zenith = context.screenPoint(reference: SIMD3(0, 0, 1)) {
            points.append(OverlayPoint(position: SIMD2<Float>(zenith), radius: 4 * px, color: gridColor))
        }

        var labels: [OverlayLabel] = []
        for (name, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            if let p = context.screenPoint(reference: OverlayContext.referenceDirection(azimuthDegrees: az, altitudeDegrees: 10)) {
                labels.append(OverlayLabel(text: name, position: SIMD2<Float>(p), color: az == 0 ? north : white, fontSize: 17))
            }
        }

        var frame = OverlayFrame()
        frame.add(segments)
        frame.add(points)
        frame.add(labels)
        return frame
    }
}
