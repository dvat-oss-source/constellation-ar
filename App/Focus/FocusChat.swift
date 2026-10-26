import Foundation
import Observation
import SkyCore

struct FocusChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var verificationLabel: String?
}

enum FocusChatPrompt {
    static let systemAddendum = """
    Answer in plain sentences, about 120 words, no markdown lists. When you use a passage below, cite it as [P:passage-id]. \
    Quote only text that appears in the passages. Prefer citing [P:facts] for tonight's sky numbers and [P:card] for the narration summary. \
    If the answer is not supported by any passage below, reply exactly: Not in sources.
    """

    static func build(constellationName: String, facts: ConstellationFacts, narration: NarrationFile.Card?,
                      passages: [Passage], history: [FocusChatMessage], question: String) -> String {
        var parts: [String] = ["Constellation: \(constellationName) (\(facts.id))", systemAddendum, "", "Source passages (cite with [P:id]):"]
        for p in passages {
            parts.append("[\(p.id)] \(p.heading): \(p.text.prefix(900))")
        }
        if !history.isEmpty {
            parts += ["", "Conversation so far:"]
            for m in history.suffix(6) {
                parts.append(m.role == .user ? "Visitor: \(m.text)" : "Guide: \(m.text)")
            }
        }
        parts += ["", "Visitor question: \(question)"]
        return parts.joined(separator: "\n")
    }

    static func buildGeneralKnowledge(constellationName: String, history: [FocusChatMessage], question: String) -> String {
        var parts = [
            "Answer briefly (at most 4 sentences) from general astronomy knowledge about \(constellationName).",
            "Plain sentences, no markdown lists. No citations required.",
        ]
        if !history.isEmpty {
            parts += ["", "Conversation so far:"]
            for m in history.suffix(6) {
                parts.append(m.role == .user ? "Visitor: \(m.text)" : "Guide: \(m.text)")
            }
        }
        parts += ["", "Visitor question: \(question)"]
        return parts.joined(separator: "\n")
    }

    static func contextPassages(facts: ConstellationFacts, narration: NarrationFile.Card?) -> [Passage] {
        var list: [Passage] = [
            Passage(id: "facts", constellation: facts.id, source: .wiki, heading: "Computed sky facts", text: factsDocument(facts)),
        ]
        if let narration {
            var cardParts = [narration.summary, narration.howToFind]
            if let myth = narration.mythology, !myth.isEmpty { cardParts.append(myth) }
            list.append(Passage(id: "card", constellation: facts.id, source: .wiki, heading: "Narration card",
                                text: cardParts.joined(separator: "\n\n")))
        }
        return list
    }

    static func retrievePassages(bm25: BM25Index?, query: String, constellationID: String, limit: Int = 4) -> [Passage] {
        guard let bm25 else { return [] }
        return bm25.searchWithConstellationFallback(query, limit: limit, constellation: constellationID).map(\.passage)
    }

    private static func factsDocument(_ f: ConstellationFacts) -> String {
        var lines = [
            "Constellation \(f.name) (\(f.id))",
            String(format: "Now: alt %.1f°, az %.1f°, visible now: %@", f.altitudeDegrees, f.azimuthDegrees, f.isVisibleNow ? "yes" : "no"),
            "Visibility: \(f.visibility.rawValue)",
            String(format: "Transit tonight %.1f° at %@", f.transitAltitudeDegrees, f.transit.formatted(date: .omitted, time: .shortened)),
        ]
        if let rise = f.rise { lines.append("Rise: \(rise.formatted(date: .omitted, time: .shortened))") }
        if let set = f.set { lines.append("Set: \(set.formatted(date: .omitted, time: .shortened))") }
        if !f.brightestStars.isEmpty {
            lines.append("Bright stars: " + f.brightestStars.prefix(5).map { star in
                var s = String(format: "%@ mag %.2f", star.displayName, star.vmag)
                if let ly = star.distanceLightYears { s += String(format: ", %.0f ly", ly) }
                return s
            }.joined(separator: "; "))
        }
        if !f.deepSkyObjects.isEmpty {
            lines.append("Deep-sky (\(f.deepSkyTotal)): " + f.deepSkyObjects.prefix(6).map { o in
                o.displayName + (o.mag.map { String(format: ", mag %.1f", $0) } ?? "")
            }.joined(separator: "; "))
        }
        if !f.bodies.isEmpty {
            lines.append("Planets & Moon: " + f.bodies.map { "\($0.body.name), mag \(String(format: "%.1f", $0.magnitude))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class FocusChatModel: Observable {
    var messages: [FocusChatMessage] = []
    var draft = ""
    var isStreaming = false
    var statusText: String?
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        messages = []
        draft = ""
        isStreaming = false
        statusText = nil
    }

    func send(constellationID: String, constellationName: String, facts: ConstellationFacts, narration: NarrationFile.Card?,
              resources: FocusResources, context: OverlayContext, engine: SkyEngine) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        draft = ""
        messages.append(FocusChatMessage(role: .user, text: question))
        isStreaming = true
        statusText = "Searching sources…"
        let retrieved = FocusChatPrompt.retrievePassages(bm25: resources.bm25, query: question, constellationID: constellationID)
        let passages = FocusChatPrompt.contextPassages(facts: facts, narration: narration) + retrieved
        let history = Array(messages.dropLast())
        let prompt = FocusChatPrompt.build(constellationName: constellationName, facts: facts, narration: narration,
                                           passages: passages, history: history, question: question)
        let client = makeClient()
        task?.cancel()
        task = Task {
            var assistant = FocusChatMessage(role: .assistant, text: "")
            messages.append(assistant)
            let index = messages.count - 1
            let grounded = await stream(client: client, constellationID: constellationID, cacheKey: "chat:\(question.lowercased())",
                                        prompt: prompt, messageIndex: index, assistant: &assistant)
            guard !Task.isCancelled else { return }
            if Self.isNotInSources(grounded, resources: resources) {
                statusText = "Answering from general knowledge…"
                assistant.text = ""
                messages[index] = assistant
                let fallbackPrompt = FocusChatPrompt.buildGeneralKnowledge(constellationName: constellationName,
                                                                             history: history, question: question)
                _ = await stream(client: client, constellationID: constellationID, cacheKey: "chat-fallback:\(question.lowercased())",
                                 prompt: fallbackPrompt, messageIndex: index, assistant: &assistant)
                assistant.verificationLabel = "unverified · general knowledge"
                messages[index] = assistant
            } else {
                assistant.verificationLabel = Self.verifyLabel(text: assistant.text, resources: resources)
                messages[index] = assistant
            }
            statusText = nil
            isStreaming = false
        }
    }

    private func makeClient() -> DeepDiveClient {
        DeepDiveClient(cache: .applicationSupport(), modelID: AppInfo.gemmaModelID, apiKey: AppInfo.vertexAPIKey,
                       projectID: AppInfo.gcpProjectID, location: AppInfo.gemmaLocation)
    }

    private func stream(client: DeepDiveClient, constellationID: String, cacheKey: String, prompt: String,
                      messageIndex: Int, assistant: inout FocusChatMessage) async -> String {
        var final = assistant.text
        for await update in client.ask(constellationID: constellationID, question: cacheKey, prompt: prompt) {
            guard !Task.isCancelled else { break }
            switch update {
            case .text(let text):
                final = text
                assistant.text = text
                messages[messageIndex] = assistant
            case .finished:
                final = assistant.text
            case .cached(let text, _):
                final = text
                assistant.text = text
                messages[messageIndex] = assistant
            case .failed(let message):
                final = message
                assistant.text = message
                assistant.verificationLabel = nil
                messages[messageIndex] = assistant
            }
        }
        return final
    }

    private static func isNotInSources(_ text: String, resources: FocusResources) -> Bool {
        if let verifier = resources.verifier { return verifier.verify(text).isNotInSources }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .lowercased()
        return trimmed == "not in sources"
    }

    private static func verifyLabel(text: String, resources: FocusResources) -> String {
        guard let verifier = resources.verifier else {
            return "unverified (no source check)"
        }
        let result = verifier.verify(text)
        if result.verified { return "verified" }
        let reason = result.issues.first.map { "\($0.kind.rawValue): \($0.detail)" } ?? "citation check failed"
        return "unverified: \(reason)"
    }
}
