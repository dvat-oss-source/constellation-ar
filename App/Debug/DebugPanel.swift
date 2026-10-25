import SwiftUI

struct DebugPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug").font(.headline)
                Spacer()
                Button("Close") { model.showDebug = false }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    controls
                    ForEach(model.debugSections) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title).font(.caption.bold())
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxHeight: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Attitude", selection: $model.attitudeSource) {
                ForEach(AppModel.AttitudeSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Lighting", selection: $model.lightingOverride) {
                ForEach(AppModel.LightingOverride.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Sky only", isOn: $model.skyOnly).disabled(model.cameraStatus != .running)
                Toggle("Red", isOn: $model.redTheme)
            }
            .font(.footnote)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Time offset %+.2f h", model.timeOffsetHours)).font(.footnote.monospacedDigit())
                Slider(value: $model.timeOffsetHours, in: -12...12, step: 0.25)
            }

            if model.capture != nil {
                Picker("Attitude sampled at", selection: $model.captureTimeReference) {
                    ForEach(AppModel.CaptureTimeReference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Night exposure", selection: $model.nightExposureDuration) {
                    ForEach(AppModel.nightExposureChoices, id: \.self) { Text(String(format: "1/%.0f s", 1 / $0)).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Night strategy", selection: $model.nightStrategy) {
                    ForEach(NightExposureStrategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button("Refocus far") { model.refocusFar() }
                    Button(model.nightProbeRunning ? "Probing…" : "Night probe") { model.runNightProbe() }
                        .disabled(model.nightProbeRunning)
                    Button("Reset align") { model.alignment.reset() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
    }
}
