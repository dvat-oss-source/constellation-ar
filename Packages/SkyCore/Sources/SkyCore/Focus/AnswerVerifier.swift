import Foundation

/// Citation syntax of grounded answers: `[P:<passage id>]`, e.g. "Rigel is the left foot of the hunter [P:Ori-wiki-7]."
/// Several citations are written one after another: `[P:Ori-wiki-7][P:Ori-allen-3]`.
public enum Citation {
    static let regex = try! NSRegularExpression(
        pattern: #"\[P:((?:[A-Za-z]{2,3}-(?:wiki|allen|aratus)-\d+)|facts|card))\]"#)

    /// Cited ids in order of appearance, duplicates removed.
    public static func ids(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>(), out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// The text with every `[P:...]` removed.
    public static func stripped(from text: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// Anything that looks like a citation but is not valid `[P:id]` syntax (e.g. `[P:Ori]`, `[P: Ori-wiki-1]`).
    static let looseRegex = try! NSRegularExpression(pattern: #"\[\s*P\s*:[^\]]*\]"#)
}

/// The catalogue as the verifier needs it: star mentions in text and each star's catalogue magnitude and distance.
public struct StarFactIndex: Sendable {
    public struct Mention: Sendable, Hashable {
        public var hip: Int
        /// UTF-16 range in the searched string.
        public var location: Int
        public var length: Int
        var end: Int { location + length }
    }

    static let maxAliasTokens = 5
    static let greekNames: [Character: String] = [
        "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "epsilon", "ζ": "zeta", "η": "eta", "θ": "theta",
        "ι": "iota", "κ": "kappa", "λ": "lambda", "μ": "mu", "ν": "nu", "ξ": "xi", "ο": "omicron", "π": "pi",
        "ρ": "rho", "σ": "sigma", "τ": "tau", "υ": "upsilon", "φ": "phi", "χ": "chi", "ψ": "psi", "ω": "omega",
    ]
    static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
    ]
    static let tokenRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    let aliases: [String: Int]
    let stars: [Int: (vmag: Double, parallaxMas: Double)]

    public init(catalog: StarCatalog, names: StarNames, designations: StarDesignations, constellations: [ConstellationInfo]) {
        var stars: [Int: (Double, Double)] = [:]
        for s in catalog.stars { stars[s.hip] = (Double(s.vmag), Double(s.parallaxMas)) }
        var aliases: [String: Int] = [:]
        func add(_ alias: String, _ hip: Int) {
            let key = Self.tokens(alias).map(\.text).joined(separator: " ")
            guard !key.isEmpty, Self.tokens(alias).count <= Self.maxAliasTokens else { return }
            if let existing = aliases[key], let a = stars[existing], let b = stars[hip], a.0 <= b.0 { return }
            aliases[key] = hip
        }
        for n in names.stars where stars[n.hip] != nil { add(n.name, n.hip) }
        let genitives = Dictionary(constellations.compactMap { c in c.genitive.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        for (hip, d) in designations.byHip where stars[hip] != nil {
            guard let space = d.lastIndex(of: " ") else { continue }
            let lead = String(d[..<space]), tail = String(d[d.index(after: space)...])
            add(d, hip)
            if lead == "HR" { continue }
            var plain = lead
            if let first = lead.first, let name = Self.greekNames[first] {
                plain = name + lead.dropFirst().map { String(Self.superscripts[$0] ?? $0) }.joined()
                add(plain + " " + tail, hip)
            }
            if let g = genitives[tail] {
                add(lead + " " + g, hip)
                add(plain + " " + g, hip)
            }
        }
        self.aliases = aliases
        self.stars = stars
    }

    static func tokens(_ text: String) -> [(text: String, range: NSRange)] {
        let folded = text.lowercased()
        let ns = folded as NSString
        return tokenRegex.matches(in: folded, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range).map { String(superscripts[$0] ?? $0) }.joined(), $0.range)
        }
    }

    /// Star names and designations found in `text`, longest alias first at each position, in order.
    public func mentions(in text: String) -> [Mention] {
        let toks = Self.tokens(text)
        var out: [Mention] = []
        var i = 0
        while i < toks.count {
            var matched = false
            for n in stride(from: min(Self.maxAliasTokens, toks.count - i), through: 1, by: -1) {
                let key = toks[i..<(i + n)].map(\.text).joined(separator: " ")
                if let hip = aliases[key] {
                    let start = toks[i].range.location
                    out.append(Mention(hip: hip, location: start, length: toks[i + n - 1].range.upperBound - start))
                    i += n
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        return out
    }

    public func vmag(hip: Int) -> Double? { stars[hip]?.vmag }

    /// 1000 / parallax in light-years, nil without a positive parallax.
    public func distanceLightYears(hip: Int) -> Double? {
        guard let p = stars[hip]?.parallaxMas, p > 0 else { return nil }
        return 3261.563777 / p
    }
}

public struct VerificationIssue: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case noCitation, malformedCitation, unknownCitation, quoteNotFound, quoteNotInCitedPassage
        case magnitudeMismatch, distanceMismatch, distanceUnverifiable
    }

    public var kind: Kind
    public var detail: String
}

public struct VerificationResult: Sendable, Hashable {
    public var verified: Bool
    public var issues: [VerificationIssue]
    public var citedIDs: [String]
    public var quotesChecked: Int
    /// Magnitude and distance claims that were attributed to a star and compared with the catalogue.
    public var numbersChecked: Int
    /// The answer is the "not in sources" sentinel.
    public var isNotInSources: Bool
}

/// Checks a model answer against the passages and the catalogue. Rules:
/// - at least one valid `[P:id]` citation unless the answer is exactly "Not in sources.";
/// - every cited id exists in the library;
/// - every quoted span ("..." or curly quotes) appears word for word in a cited passage after the same normalisation as
///   `tools/generate_narration.py` (Unicode NFC, whitespace, quote style, dash style; case-sensitive);
/// - every magnitude ("magnitude 0.5", "mag 0.5", "0.5 magnitude") and distance ("548 light-years", "170 pc") claim
///   that follows a star name or designation in the same sentence matches the catalogue: |Δ V| ≤ `magnitudeTolerance`,
///   |Δ d| ≤ `distanceRelativeTolerance` × catalogue distance. "Absolute magnitude" is ignored. Claims with no star in
///   their sentence are not checked.
public struct AnswerVerifier: Sendable {
    public static let notInSourcesAnswer = "Not in sources."
    /// App-computed context ids (`FocusChatPrompt`); valid citations but not checked against `passages.json`.
    public static let syntheticPassageIDs: Set<String> = ["facts", "card"]

    public let library: PassageLibrary
    public let stars: StarFactIndex
    public let magnitudeTolerance: Double
    public let distanceRelativeTolerance: Double

    public init(library: PassageLibrary, stars: StarFactIndex, magnitudeTolerance: Double = 0.15,
                distanceRelativeTolerance: Double = 0.10) {
        self.library = library
        self.stars = stars
        self.magnitudeTolerance = magnitudeTolerance
        self.distanceRelativeTolerance = distanceRelativeTolerance
    }

    // MARK: Normalisation (mirror of tools/generate_narration.py `normalize`)

    static let quoteMap: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201a}": "'", "\u{201b}": "'", "\u{2032}": "'", "\u{00b4}": "'",
        "\u{201c}": "\"", "\u{201d}": "\"", "\u{201e}": "\"", "\u{201f}": "\"", "\u{2033}": "\"", "\u{00ab}": "\"", "\u{00bb}": "\"",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-", "\u{2014}": "-", "\u{2015}": "-", "\u{2212}": "-",
    ]
    static let doubleDash = try! NSRegularExpression(pattern: #"\s*-\s*-\s*"#)
    static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    static let dashSpace = try! NSRegularExpression(pattern: #" ?- ?"#)

    /// Only whitespace, quote-style and dash-style differences are forgiven (plus Unicode NFC).
    public static func normalize(_ text: String) -> String {
        var t = String(text.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return quoteMap[c] ?? c
        })
        func replace(_ re: NSRegularExpression, _ template: String) {
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: template)
        }
        replace(doubleDash, " - ")
        replace(whitespace, " ")
        replace(dashSpace, "-")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let doubleQuoted = try! NSRegularExpression(pattern: "[\"\u{201c}\u{201e}]([^\"\u{201c}\u{201d}\u{201e}]+)[\"\u{201d}]")
    static let singleQuoted = try! NSRegularExpression(pattern: "(?<![A-Za-z])\u{2018}(.+?)\u{2019}(?![A-Za-z])")

    /// Quoted spans as `tools/generate_narration.py` finds them.
    public static func quotedSpans(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return (doubleQuoted.matches(in: text, range: range) + singleQuoted.matches(in: text, range: range))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Numbers

    static let number = #"([+\-\u2212\u2013]?\d+(?:\.\d+)?)"#
    static let magnitudePatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\bmagnitudes?\s*(?:of|is|was|at|=|:)?\s*"# + number, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"\bmag\.?\s*(?:of|=|:)?\s*"# + number, options: .caseInsensitive),
        try! NSRegularExpression(pattern: number + #"\s*(?:apparent |visual )?magnitude\b"#, options: .caseInsensitive),
    ]
    static let distancePattern = try! NSRegularExpression(
        pattern: #"(\d[\d,]*(?:\.\d+)?)(?:\s*[±]\s*[\d.,]+)?\s*(light[- ]?years?|ly\b|parsecs?\b|pc\b)"#, options: .caseInsensitive)
    static let sentenceSplit = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z"\x{201c}\x{2018}(\[])|\n+"#)

    struct Claim {
        enum Kind { case magnitude(Double), distanceLY(Double, text: String) }
        var kind: Kind
        var location: Int
        var snippet: String
    }

    static func parseNumber(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-"))
    }

    static func claims(in sentence: String) -> [Claim] {
        let ns = sentence as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Claim] = []
        var seenLocations = Set<Int>()
        for re in magnitudePatterns {
            for m in re.matches(in: sentence, range: full) {
                let numberRange = m.range(at: 1)
                guard seenLocations.insert(numberRange.location).inserted, let value = parseNumber(ns.substring(with: numberRange)) else { continue }
                let before = ns.substring(with: NSRange(location: max(0, m.range.location - 9), length: min(9, m.range.location))).lowercased()
                if before.hasSuffix("absolute ") { continue }
                out.append(Claim(kind: .magnitude(value), location: m.range.location, snippet: ns.substring(with: m.range)))
            }
        }
        for m in distancePattern.matches(in: sentence, range: full) {
            guard let value = parseNumber(ns.substring(with: m.range(at: 1))) else { continue }
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            let ly = unit.hasPrefix("p") ? value * 3.26156 : value
            out.append(Claim(kind: .distanceLY(ly, text: ns.substring(with: m.range)), location: m.range.location,
                             snippet: ns.substring(with: m.range)))
        }
        return out.sorted { $0.location < $1.location }
    }

    // MARK: Verification

    public func verify(_ answer: String) -> VerificationResult {
        var issues: [VerificationIssue] = []
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentinel = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!")).lowercased()
        if sentinel == "not in sources" {
            return VerificationResult(verified: true, issues: [], citedIDs: [], quotesChecked: 0, numbersChecked: 0, isNotInSources: true)
        }

        let ids = Citation.ids(in: answer)
        let ns = answer as NSString
        let loose = Citation.looseRegex.matches(in: answer, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        for text in loose where Citation.ids(in: text).isEmpty {
            issues.append(VerificationIssue(kind: .malformedCitation, detail: "\(text) is not valid citation syntax [P:<id>]"))
        }
        if ids.isEmpty && issues.isEmpty {
            issues.append(VerificationIssue(kind: .noCitation, detail: "the answer cites no passage"))
        }
        var cited: [Passage] = []
        for id in ids {
            if Self.syntheticPassageIDs.contains(id) { continue }
            if let p = library.passage(id: id) { cited.append(p) } else {
                issues.append(VerificationIssue(kind: .unknownCitation, detail: "cited passage \(id) does not exist"))
            }
        }

        let body = Citation.stripped(from: answer)
        var quotesChecked = 0
        let citedText = cited.map { Self.normalize($0.text) }
        for span in Self.quotedSpans(in: body) {
            quotesChecked += 1
            let n = Self.normalize(span)
            if citedText.contains(where: { $0.contains(n) }) { continue }
            let elsewhere = library.passages.first { $0.constellation == (cited.first?.constellation ?? $0.constellation) && Self.normalize($0.text).contains(n) }
            if let elsewhere {
                issues.append(VerificationIssue(kind: .quoteNotInCitedPassage,
                                                detail: "\"\(span)\" is not in the cited passages (it is in \(elsewhere.id))"))
            } else {
                issues.append(VerificationIssue(kind: .quoteNotFound, detail: "\"\(span)\" is not word for word in any passage"))
            }
        }

        var numbersChecked = 0
        let bodyNS = body as NSString
        let sentences = Self.sentenceRanges(body)
        for range in sentences {
            let sentence = bodyNS.substring(with: range)
            let claims = Self.claims(in: sentence)
            if claims.isEmpty { continue }
            let mentions = stars.mentions(in: sentence)
            for claim in claims {
                let before = mentions.last { $0.end <= claim.location }
                guard let mention = before ?? mentions.first(where: { $0.location >= claim.location }) else { continue }
                numbersChecked += 1
                let hip = mention.hip
                switch claim.kind {
                case let .magnitude(claimed):
                    if let v = stars.vmag(hip: hip), abs(claimed - v) > magnitudeTolerance {
                        issues.append(VerificationIssue(kind: .magnitudeMismatch, detail: String(
                            format: "\"%@\": catalogue V = %.2f for HIP %d, claimed %.2f (tolerance %.2f)", claim.snippet, v, hip, claimed, magnitudeTolerance)))
                    }
                case let .distanceLY(claimed, text):
                    guard let d = stars.distanceLightYears(hip: hip) else {
                        issues.append(VerificationIssue(kind: .distanceUnverifiable, detail: "\"\(text)\": HIP \(hip) has no catalogue parallax"))
                        continue
                    }
                    if abs(claimed - d) > distanceRelativeTolerance * d {
                        issues.append(VerificationIssue(kind: .distanceMismatch, detail: String(
                            format: "\"%@\": catalogue distance %.0f ly for HIP %d, claimed %.0f ly (tolerance %.0f%%)", text, d, hip, claimed,
                            distanceRelativeTolerance * 100)))
                    }
                }
            }
        }
        return VerificationResult(verified: issues.isEmpty, issues: issues, citedIDs: ids, quotesChecked: quotesChecked,
                                  numbersChecked: numbersChecked, isNotInSources: false)
    }

    static func sentenceRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        for m in sentenceSplit.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            ranges.append(NSRange(location: start, length: m.range.location - start))
            start = m.range.upperBound
        }
        ranges.append(NSRange(location: start, length: ns.length - start))
        return ranges.filter { $0.length > 0 }
    }
}
