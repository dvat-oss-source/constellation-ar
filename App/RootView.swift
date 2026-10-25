import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLaunchInfo = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let driver = model.driver {
                SkyView(driver: driver).ignoresSafeArea()
            } else {
                Text(model.setupError ?? "Starting…").foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                if model.effectiveAttitudeSource == .motion { AccuracyBadge(model: model) }
                hints
                if model.showLayers { LayerPanel(model: model).transition(.opacity) }
                Spacer()
                if let info = model.objectInfo {
                    ObjectInfoCard(info: info) { model.showInfo(nil) }.transition(.opacity)
                }
                if model.showSatellites {
                    SatellitePanel(tracker: model.satellites) { model.showSatellites = false }.transition(.opacity)
                }
                if let card = model.card, !model.showDebug {
                    ConstellationCard(card: card, narrator: model.narrator, hasDeepDiveKey: AppInfo.hasVertexAPIKey) { model.askDeepDive() }
                        .id(card.id)
                        .transition(.opacity)
                }
                if model.effectiveAttitudeSource != .motion {
                    skyControls
                }
                controlBar
            }
            .padding()

            if showLaunchInfo {
                launchInfo.transition(.opacity)
            }
            if model.showDebug {
                DebugPanel(model: model)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await model.activate() }
            case .background: model.deactivate()
            default: break
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showLaunchInfo = false }
        }
    }

    @ViewBuilder private var hints: some View {
        if model.effectiveAttitudeSource == .motion, model.headingQuality.needsFigure8 {
            Banner(systemImage: "infinity", text: "Compass needs calibrating: wave the phone in a figure-8.")
        }
        if model.alignment.suggestsRealign, !model.headingQuality.needsFigure8 {
            Banner(systemImage: "scope", text: "Heading accuracy dropped. Tap a bright star, the Moon or the Sun marker to re-align.")
        }
        if let error = model.skyDataError {
            Banner(systemImage: "exclamationmark.triangle", text: error)
        }
        if model.observer == nil {
            Banner(systemImage: "location.slash", text: "Waiting for your location to place the sky.")
        }
        if model.cameraStatus == .denied {
            Banner(systemImage: "camera.fill", text: "Camera access is off, so the sky is drawn without the camera. Allow it in Settings.")
        }
    }

    private var launchInfo: some View {
        VStack(spacing: 6) {
            Text(AppInfo.name).font(.title2.bold())
            Text("\(AppInfo.version) (\(AppInfo.build)) \(AppInfo.configuration)").font(.footnote)
            Text("Vertex key \(AppInfo.hasVertexAPIKey ? "present" : "missing")").font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
    }

    private var skyControls: some View {
        VStack(spacing: 6) {
            HStack {
                Text(model.attitudeSource == .fixed ? "Fixed sky preset" : String(format: "Time %+.1f h", model.timeOffsetHours))
                    .font(.footnote.monospacedDigit())
                Spacer()
                Toggle("Fixed sky", isOn: Binding(
                    get: { model.attitudeSource == .fixed },
                    set: { model.attitudeSource = $0 ? .fixed : (model.isSimulator ? .drag : .motion) }))
                    .toggleStyle(.button)
                    .font(.footnote)
            }
            Slider(value: $model.timeOffsetHours, in: -12...12, step: 0.25)
                .disabled(model.attitudeSource == .fixed)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            if model.cameraStatus == .running {
                RoundButton(systemImage: model.skyOnly ? "camera" : "sparkles", label: model.skyOnly ? "Show camera" : "Sky only") {
                    model.skyOnly.toggle()
                }
            }
            RoundButton(systemImage: model.redTheme ? "moon.fill" : "moon", label: "Red theme") {
                model.redTheme.toggle()
            }
            RoundButton(systemImage: "square.3.layers.3d", label: "Layers") {
                withAnimation { model.showLayers.toggle() }
            }
            RoundButton(systemImage: "dot.radiowaves.up.forward", label: "Satellites") {
                withAnimation { model.showSatellites.toggle() }
            }
            Spacer()
            RoundButton(systemImage: "ladybug", label: "Debug") {
                model.showDebug.toggle()
            }
        }
    }
}

/// The heading filter's current one-sigma pointing accuracy.
private struct AccuracyBadge: View {
    let model: AppModel

    var body: some View {
        let alignment = model.alignment
        HStack {
            Spacer()
            Text(String(format: "±%.1f°", alignment.accuracyDegrees) + (alignment.isAligned ? "" : " compass"))
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .accessibilityIdentifier("accuracyReadout")
    }
}

private struct Banner: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.5), in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }
}
