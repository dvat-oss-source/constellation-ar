import Foundation

enum AppInfo {
    static let name = "ConstellationAR"

    static var version: String { string("CFBundleShortVersionString") ?? "?" }
    static var build: String { string("CFBundleVersion") ?? "?" }

    static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    static var buildDate: Date? {
        guard let url = Bundle.main.executableURL else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static var gemmaModelID: String? { string("GemmaModelID") }

    /// The key itself; never log or display it.
    static var vertexAPIKey: String? { string("VertexAPIKey") }

    static var hasVertexAPIKey: Bool { vertexAPIKey != nil }

    static var summary: String {
        let date = buildDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown date"
        return "\(name) \(version) (\(build)) \(configuration), built \(date)"
    }

    private static func string(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting leaves either an empty string or the literal "$(NAME)" behind.
        if value.isEmpty || value.hasPrefix("$(") { return nil }
        return value
    }
}
