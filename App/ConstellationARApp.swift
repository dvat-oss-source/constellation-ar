import SkyCore
import SwiftUI

@main
struct ConstellationARApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
