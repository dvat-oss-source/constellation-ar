import SwiftUI

private struct StylePaletteKey: EnvironmentKey {
    static let defaultValue = StyleTokens.palette(.night)
}

extension EnvironmentValues {
    var stylePalette: StylePalette {
        get { self[StylePaletteKey.self] }
        set { self[StylePaletteKey.self] = newValue }
    }
}

extension StylePalette {
    var textColor: Color { StyleTokens.color(text) }
    var secondaryColor: Color { StyleTokens.color(secondaryText) }
    var glowColor: Color { StyleTokens.color(panelGlow) }
    var lightColor: Color { StyleTokens.color(light) }
}

extension StyleTokens {
    static var panelAnimation: Animation {
        .timingCurve(panelCurve.x1, panelCurve.y1, panelCurve.x2, panelCurve.y2, duration: panelFade)
    }
}

/// Rounded translucent indigo panel with a thin rim and a soft inner glow; opaque under Reduce Transparency.
private struct SkyPanelModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.stylePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.textColor)
            .background {
                shape
                    .fill(StyleTokens.color(palette.panel, opacity: reduceTransparency ? 1 : StyleTokens.panelFillOpacity))
                    .overlay {
                        shape.stroke(palette.glowColor.opacity(StyleTokens.panelRimOpacity * 0.7), lineWidth: StyleTokens.panelInnerGlowRadius)
                            .blur(radius: StyleTokens.panelInnerGlowRadius * 0.6)
                            .clipShape(shape)
                    }
                    .overlay { shape.strokeBorder(palette.glowColor.opacity(StyleTokens.panelRimOpacity), lineWidth: 0.75) }
            }
    }
}

extension View {
    func skyPanel(cornerRadius: CGFloat = StyleTokens.panelCornerRadius) -> some View {
        modifier(SkyPanelModifier(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func skyCapsule() -> some View {
        modifier(SkyPanelModifier(shape: Capsule()))
    }

    func skyCircle() -> some View {
        modifier(SkyPanelModifier(shape: Circle()))
    }
}
