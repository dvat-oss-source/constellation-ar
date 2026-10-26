import Foundation

/// A stable-ID slice of one pinned source text (`Data/passages.json`).
public struct Passage: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        case wiki, allen, aratus
    }

    /// "<constellation>-<wiki|allen|aratus>-<n>", e.g. "Ori-wiki-12".
    public var id: String
    /// IAU abbreviation.
    public var constellation: String
    public var source: Source
    public var heading: String
    public var text: String

    public init(id: String, constellation: String, source: Source, heading: String, text: String) {
        self.id = id
        self.constellation = constellation
        self.source = source
        self.heading = heading
        self.text = text
    }
}

public struct PassageSourceInfo: Sendable, Hashable, Codable {
    public var key: Passage.Source
    public var title: String
    public var url: String
    public var licence: String
    public var revision: String?
}

public struct PassageLibrary: Sendable {
    public let passages: [Passage]
    public let sources: [String: [PassageSourceInfo]]
    private let indexByID: [String: Int]
    private let indicesByConstellation: [String: [Int]]

    public init(passages: [Passage], sources: [String: [PassageSourceInfo]] = [:]) {
        self.passages = passages
        self.sources = sources
        var byID: [String: Int] = [:]
        var byConstellation: [String: [Int]] = [:]
        for (i, p) in passages.enumerated() {
            byID[p.id] = i
            byConstellation[p.constellation, default: []].append(i)
        }
        indexByID = byID
        indicesByConstellation = byConstellation
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        struct Raw: Decodable {
            struct P: Decodable {
                var id: String
                var s: Passage.Source
                var h: String
                var t: String
            }
            var sources: [String: [PassageSourceInfo]]
            var passages: [String: [P]]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var list: [Passage] = []
        for (cid, items) in raw.passages.sorted(by: { $0.key < $1.key }) {
            for p in items { list.append(Passage(id: p.id, constellation: cid, source: p.s, heading: p.h, text: p.t)) }
        }
        self.init(passages: list, sources: raw.sources)
    }

    public func passage(id: String) -> Passage? { indexByID[id].map { passages[$0] } }

    public func passages(for constellation: String) -> [Passage] {
        (indicesByConstellation[constellation] ?? []).map { passages[$0] }
    }
}

/// Lower-cased, diacritic-folded word tokens with a short stop list, trailing-"s" folding and no single ASCII letters.
public enum PassageTokenizer {
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "have", "in", "is", "it", "its", "of", "on",
        "or", "that", "the", "their", "this", "to", "was", "were", "which", "with", "what", "who", "when", "where", "how",
        "does", "do", "did", "he", "she", "his", "her", "they", "them", "these", "those", "there",
    ]

    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let lone = current.count == 1 && current.first!.isASCII && current.first!.isLetter
            if !stopWords.contains(current) && !lone {
                out.append(current.count > 3 && current.hasSuffix("s") && !current.hasSuffix("ss") ? String(current.dropLast()) : current)
            }
            current = ""
        }
        for ch in folded {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return out
    }
}

/// Okapi BM25 over passages (pure Swift, in memory).
public struct BM25Index: Sendable {
    public struct Hit: Sendable, Hashable {
        public var passage: Passage
        public var score: Double
    }

    public let passages: [Passage]
    public let k1: Double
    public let b: Double
    private let postings: [String: [(doc: Int, tf: Int)]]
    private let lengths: [Int]
    private let averageLength: Double

    public init(passages: [Passage], k1: Double = 1.5, b: Double = 0.75) {
        self.passages = passages
        self.k1 = k1
        self.b = b
        var post: [String: [(Int, Int)]] = [:]
        var lens: [Int] = []
        for (i, p) in passages.enumerated() {
            let tokens = PassageTokenizer.tokens(p.heading + " " + p.text)
            lens.append(tokens.count)
            var counts: [String: Int] = [:]
            for t in tokens { counts[t, default: 0] += 1 }
            for (t, c) in counts { post[t, default: []].append((i, c)) }
        }
        postings = post.mapValues { $0.map { (doc: $0.0, tf: $0.1) } }
        lengths = lens
        averageLength = lens.isEmpty ? 0 : Double(lens.reduce(0, +)) / Double(lens.count)
    }

    /// Top `limit` passages for the query, best first; ties broken by passage id. Only passages of `constellation`
    /// when given. Passages sharing no term with the query are never returned.
    public func search(_ query: String, limit: Int = 5, constellation: String? = nil) -> [Hit] {
        let n = Double(passages.count)
        var scores: [Int: Double] = [:]
        for term in Set(PassageTokenizer.tokens(query)) {
            guard let list = postings[term] else { continue }
            let idf = log(1 + (n - Double(list.count) + 0.5) / (Double(list.count) + 0.5))
            for (doc, tf) in list {
                if let constellation, passages[doc].constellation != constellation { continue }
                let f = Double(tf)
                let norm = k1 * (1 - b + b * Double(lengths[doc]) / max(averageLength, 1))
                scores[doc, default: 0] += idf * f * (k1 + 1) / (f + norm)
            }
        }
        return scores.sorted { a, c in a.value != c.value ? a.value > c.value : passages[a.key].id < passages[c.key].id }
            .prefix(limit).map { Hit(passage: passages[$0.key], score: $0.value) }
    }

    /// Constellation-scoped search first; if fewer than `minFiltered` hits, fills from an unfiltered search (constellation hits kept first).
    public func searchWithConstellationFallback(_ query: String, limit: Int = 5, constellation: String,
                                                minFiltered: Int = 3) -> [Hit] {
        let filtered = search(query, limit: limit, constellation: constellation)
        guard filtered.count < minFiltered else { return filtered }
        var seen = Set(filtered.map(\.passage.id))
        var merged = filtered
        for hit in search(query, limit: max(limit * 2, 8), constellation: nil) {
            guard seen.insert(hit.passage.id).inserted else { continue }
            merged.append(hit)
            if merged.count >= limit { break }
        }
        return merged
    }
}
