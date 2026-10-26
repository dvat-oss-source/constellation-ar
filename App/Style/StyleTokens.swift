import SwiftUI
import simd

/// Visual language: warm cream light on a deep blue-violet night. Colours are linear Display P3.
enum StyleVariant: Sendable {
    case day, twilight, night, redNight
}

struct CubicBezier: Sendable {
    var x1: Double, y1: Double, x2: Double, y2: Double

    static let easeOut = CubicBezier(x1: 0.22, y1: 1, x2: 0.36, y2: 1)
    static let easeInOut = CubicBezier(x1: 0.4, y1: 0, x2: 0.2, y2: 1)

    var animation: UnitCurve { UnitCurve.bezier(startControlPoint: UnitPoint(x: x1, y: y1), endControlPoint: UnitPoint(x: x2, y: y2)) }
}

struct StylePalette: Sendable {
    var skyZenith: SIMD3<Float>
    var skyHorizon: SIMD3<Float>
    var ground: SIMD3<Float>
    /// The warm light every star, line and glow is made of.
    var light: SIMD3<Float>
    /// Hotter core colour at the centre of stars and lines.
    var core: SIMD3<Float>
    /// Resting (unlit) constellation lines.
    var line: SIMD3<Float>
    var label: SIMD3<Float>
    /// Panel fill and rim.
    var panel: SIMD3<Float>
    var panelGlow: SIMD3<Float>
    var text: SIMD3<Float>
    var secondaryText: SIMD3<Float>
}

enum StyleTokens {
    static func palette(_ variant: StyleVariant) -> StylePalette {
        switch variant {
        case .day:
            StylePalette(skyZenith: SIMD3(0.0, 0.198, 0.527), skyHorizon: SIMD3(0.08, 0.33, 0.68), ground: SIMD3(0.12, 0.10, 0.11),
                         light: SIMD3(1.0, 0.337, 0.074), core: SIMD3(1.0, 1.0, 1.0), line: SIMD3(1.0, 1.0, 1.0),
                         label: SIMD3(1.0, 1.0, 1.0), panel: SIMD3(0.0006, 0.0033, 0.0107), panelGlow: SIMD3(0.745, 0.93, 1.0),
                         text: SIMD3(1.0, 1.0, 1.0), secondaryText: SIMD3(0.75, 0.82, 0.90))
        case .twilight:
            StylePalette(skyZenith: SIMD3(0.002, 0.012, 0.09), skyHorizon: SIMD3(0.10, 0.08, 0.22), ground: SIMD3(0.02, 0.02, 0.04),
                         light: SIMD3(1.0, 0.40, 0.09), core: SIMD3(1.0, 1.0, 1.0), line: SIMD3(0.94, 0.98, 1.0),
                         label: SIMD3(1.0, 1.0, 1.0), panel: SIMD3(0.0006, 0.0033, 0.0107), panelGlow: SIMD3(0.745, 0.93, 1.0),
                         text: SIMD3(1.0, 1.0, 1.0), secondaryText: SIMD3(0.75, 0.82, 0.90))
        case .night:
            StylePalette(skyZenith: SIMD3(0.0006, 0.0006, 0.0086), skyHorizon: SIMD3(0.0003, 0.0015, 0.041), ground: SIMD3(0.0004, 0.0004, 0.002),
                         light: SIMD3(1.0, 0.479, 0.114), core: SIMD3(1.0, 1.0, 1.0), line: SIMD3(0.88, 0.95, 1.0),
                         label: SIMD3(0.96, 0.98, 1.0), panel: SIMD3(0.0006, 0.0033, 0.0107), panelGlow: SIMD3(0.745, 0.93, 1.0),
                         text: SIMD3(1.0, 1.0, 1.0), secondaryText: SIMD3(0.75, 0.82, 0.90))
        case .redNight:
            StylePalette(skyZenith: SIMD3(0.002, 0, 0), skyHorizon: SIMD3(0.020, 0, 0), ground: SIMD3(0.004, 0, 0),
                         light: SIMD3(0.90, 0, 0), core: SIMD3(1.0, 0, 0), line: SIMD3(0.80, 0, 0),
                         label: SIMD3(0.95, 0, 0), panel: SIMD3(0.03, 0, 0), panelGlow: SIMD3(0.60, 0, 0),
                         text: SIMD3(1.0, 0, 0), secondaryText: SIMD3(0.65, 0, 0))
        }
    }

    /// Variant for a 0 (day) … 1 (night) lighting blend.
    static func variant(lighting: Double, red: Bool) -> StyleVariant {
        if red { return .redNight }
        if lighting < 0.3 { return .day }
        if lighting < 0.7 { return .twilight }
        return .night
    }

    /// Palette blended across the day → twilight → night ramp, so the sky changes smoothly with the lighting.
    static func blended(lighting: Double, red: Bool) -> StylePalette {
        if red { return palette(.redNight) }
        let t = Float(min(max(lighting, 0), 1))
        let (a, b, f): (StylePalette, StylePalette, Float) = t < 0.5
            ? (palette(.day), palette(.twilight), t / 0.5)
            : (palette(.twilight), palette(.night), (t - 0.5) / 0.5)
        func m(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * f }
        return StylePalette(skyZenith: m(a.skyZenith, b.skyZenith), skyHorizon: m(a.skyHorizon, b.skyHorizon), ground: m(a.ground, b.ground),
                            light: m(a.light, b.light), core: m(a.core, b.core), line: m(a.line, b.line), label: m(a.label, b.label),
                            panel: m(a.panel, b.panel), panelGlow: m(a.panelGlow, b.panelGlow), text: m(a.text, b.text),
                            secondaryText: m(a.secondaryText, b.secondaryText))
    }

    // MARK: Lines (points at 1x; multiplied by the screen scale)
    static let restingLineWidth: Float = 0.85
    static let litLineWidth: Float = 1.25
    /// Glow strength per `OverlaySegment.glow` (the halo reaches 4x the line width at 1).
    static let restingLineGlow: Float = 0.35
    static let litLineGlow: Float = 0.9

    /// Additive constellation art (display-encoded); `applyTheme` in the shader handles red night.
    static let lockArtworkTint = SIMD3<Float>(0.72, 0.84, 1.0)

    static func illustratedArtworkTint(lighting: Double) -> SIMD3<Float> {
        let palette = blended(lighting: lighting, red: false)
        let ivory = SIMD3<Float>(1, 0.96, 0.85)
        let linear = palette.light + (ivory - palette.light) * 0.45
        return encode(linear)
    }
    /// Day keeps a dark rim under the line so it reads over bright sky.
    static let dayUnderglowWidth: Float = 1.1

    // MARK: Stars
    /// Ray length as a multiple of the star radius, and how far the colour is pulled toward the warm light.
    static let sparkleRayLength: Float = 5.5
    static let sparkleRayWidth: Float = 0.11
    static let sparkleCoreSoftness: Float = 1.25
    static let sparkleTintMix: Float = 0.35
    static let twinkleAmount: Float = 0.14
    static let twinkleSpeed: Float = 0.9

    // MARK: Motion
    static let drawIn = CubicBezier.easeOut
    static let panelFade: Double = 0.4
    static let panelCurve = CubicBezier.easeInOut
    static let flashRise: Double = 0.2
    static let flashTotal: Double = 0.45
    static let drawInDuration: Double = 1.6

    // MARK: Panels
    static let panelCornerRadius: CGFloat = 22
    static let panelFillOpacity: Double = 0.5
    static let panelRimOpacity: Double = 0.32
    static let panelInnerGlowRadius: CGFloat = 14

    // MARK: SwiftUI colours
    /// Display-referred value for a linear component (the drawable and SwiftUI both take encoded values).
    static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(max(c.x, 0), 1 / 2.2), pow(max(c.y, 0), 1 / 2.2), pow(max(c.z, 0), 1 / 2.2))
    }

    static func color(_ c: SIMD3<Float>, opacity: Double = 1) -> Color {
        let e = encode(c)
        return Color(.displayP3, red: Double(e.x), green: Double(e.y), blue: Double(e.z), opacity: opacity)
    }
}
