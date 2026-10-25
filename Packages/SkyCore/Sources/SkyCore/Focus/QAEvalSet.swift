import Foundation

/// `Data/test/qa_eval.json`: 30 questions over 5 constellations; 25 are answerable from the passages, 5 are not covered.
public struct QAEvalSet: Sendable, Codable {
    public struct Question: Sendable, Codable, Hashable {
        public var id: String
        /// IAU abbreviation.
        public var constellation: String
        public var question: String
        public var answerable: Bool
        /// Answerable: words or numbers a correct answer contains (case-insensitive); each occurs in the supporting passages.
        public var keywords: [String]
        /// Answerable: passage ids that contain the answer.
        public var supportingPassages: [String]
        /// Unanswerable: "not in sources", the expected answer.
        public var expected: String?
        /// Unanswerable: terms that appear in none of the constellation's passages.
        public var absentTerms: [String]
    }

    public var version: Int
    public var constellations: [String]
    public var questions: [Question]

    public init(url: URL) throws { self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}
