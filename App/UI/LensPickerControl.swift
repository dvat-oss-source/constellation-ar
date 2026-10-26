import SwiftUI

struct LensPickerControl: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.showsLensPicker {
            Picker("Lens", selection: $model.selectedCaptureLens) {
                ForEach(model.availableCaptureLenses, id: \.self) { lens in
                    Text(lens.label).tag(lens)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            .skyPanel(cornerRadius: 14)
            .accessibilityIdentifier("lensPicker")
        }
    }
}
