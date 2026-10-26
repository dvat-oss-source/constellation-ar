import Observation
import SwiftUI

enum SkyLayer: String, CaseIterable, Identifiable, Sendable {
    case milkyWay = "Milky Way"
    case artwork = "Artwork"
    case illustrated = "Illustrated sky"
    case lines = "Constellation lines"
    case asterisms = "Asterisms"
    case stars = "Stars"
    case deepSky = "Deep-sky objects"
    case planets = "Planets, Sun and Moon"
    case satellites = "Satellites"
    case labels = "Labels"

    var id: Self { self }

    /// Day shows lines, planets/Sun/Moon and satellites; night shows everything.
    func isOnByDefault(night: Bool) -> Bool {
        if self == .illustrated { return false }
        return night || self == .lines || self == .planets || self == .satellites
    }
}

/// Layer toggles. A layer follows the day/night default until the user flips it.
@MainActor
@Observable
final class LayerSettings {
    private static let persistenceKey = "layerOverrides"
    private(set) var overrides: [SkyLayer: Bool] = [:]

    init() { restore() }

    func isOn(_ layer: SkyLayer, night: Bool) -> Bool {
        overrides[layer] ?? layer.isOnByDefault(night: night)
    }

    func set(_ layer: SkyLayer, on: Bool, night: Bool) {
        overrides[layer] = on == layer.isOnByDefault(night: night) ? nil : on
        persist()
    }

    func useDefaults() {
        overrides = [:]
        persist()
    }

    var hasOverrides: Bool { !overrides.isEmpty }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.persistenceKey)
    }

    private func restore() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.persistenceKey) as? [String: Bool] else { return }
        overrides = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            SkyLayer(rawValue: key).map { ($0, value) }
        })
    }
}

struct LayerPanel: View {
    @Environment(\.stylePalette) private var palette
    @Bindable var model: AppModel

    var body: some View {
        let night = model.lightingBlend >= 0.5
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Layers").font(.title3.weight(.semibold))
                Text(night ? "night defaults" : "day defaults").font(.caption).foregroundStyle(palette.secondaryColor)
                Spacer()
                Button("Close") { model.showLayers = false }
            }
            ForEach(SkyLayer.allCases) { layer in
                Toggle(layer.rawValue, isOn: Binding(
                    get: { model.layers.isOn(layer, night: night) },
                    set: { model.layers.set(layer, on: $0, night: night) }))
                    .font(.subheadline)
            }
            if model.layers.hasOverrides {
                Button("Use \(night ? "night" : "day") defaults") { model.layers.useDefaults() }
                    .font(.footnote)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .skyPanel()
        .padding(.horizontal, 8)
    }
}
