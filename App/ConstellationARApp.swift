import SkyCore
import SwiftUI

@main
struct ConstellationARApp: App {
    @State private var model: AppModel

    init() {
        Self.applyLaunchDefaults()
        let model = AppModel()
        if Self.launchFlag("-illustrated") { model.layers.set(.illustrated, on: true, night: true) }
        _model = State(initialValue: model)
    }

    private static func launchFlag(_ name: String) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return false }
        return args[i + 1].uppercased() == "YES" || args[i + 1] == "1"
    }

    private static func launchValue(after name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func applyLaunchDefaults() {
        let defaults = UserDefaults.standard
        if launchFlag("-fixedSky") { defaults.set(true, forKey: "fixedSky") }
        if let lighting = launchValue(after: "-lighting") { defaults.set(lighting, forKey: "lighting") }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
