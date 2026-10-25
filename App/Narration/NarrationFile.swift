import Foundation

/// `Data/narration.json`, generated offline; absent until the generator has run.
struct NarrationFile: Codable, Sendable {
    struct Quote: Codable, Sendable, Hashable {
        var text: String
        var source: String?
    }

    struct StarEntry: Codable, Sendable, Hashable {
        var hip: Int?
        var name: String
        var vmag: Double?
        var distanceLy: Double?
    }

    struct Source: Codable, Sendable, Hashable {
        var title: String
        var url: String?
        var licence: String?
    }

    struct Card: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var summary: String
        var howToFind: String
        var mythology: String?
        var quotes: [Quote]?
        var brightestStars: [StarEntry]?
        var sources: [Source]?
    }

    var version: Int?
    var model: String?
    var generated: String?
    var cards: [Card]

    func card(id: String) -> Card? { cards.first { $0.id == id } }

    static func load(bundle: Bundle = .main) -> NarrationFile? {
        guard let url = bundle.url(forResource: "narration", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NarrationFile.self, from: data)
    }
}
