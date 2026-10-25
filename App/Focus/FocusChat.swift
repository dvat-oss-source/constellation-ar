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
    Quote only text that appears in the passages. If the answer is not supported, reply exactly: Not in sources.
    """

    static func build(constellationName: String, facts: ConstellationFacts, narration: NarrationFile.Card?,
                      passages: [Passage], history: [FocusChatMessage], question: String) -> String {
        var parts: [String] = ["Constellation: \(constellationName) (\(facts.id))", systemAddendum, "", "Computed facts:", factsSummary(facts)]
        if let narration {
            parts += ["", "Narration summary:", narration.summary, "How to find:", narration.howToFind]
            if let myth = narration.mythology { parts += ["Mythology:", myth] }
        }
        if !passages.isEmpty {
            parts += ["", "Source passages (cite with [P:id]):"]
            for p in passages {
                parts.append("[\(p.id)] \(p.heading): \(p.text.prefix(900))")
            }
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

    private static func factsSummary(_ f: ConstellationFacts) -> String {
        var lines = [
            String(format: "Now: alt %.1f°, az %.1f°, visible now: %@", f.altitudeDegrees, f.azimuthDegrees, f.isVisibleNow ? "yes" : "no"),
            "Visibility: \(f.visibility.rawValue)",
            String(format: "Transit tonight %.1f° at %@", f.transitAltitudeDegrees, f.transit.formatted(date: .omitted, time: .shortened)),
        ]
        if let rise = f.rise { lines.append("Rise: \(rise.formatted(date: .omitted, time: .shortened))") }
        if let set = f.set { lines.append("Set: \(set.formatted(date: .omitted, time: .shortened))") }
        if !f.brightestStars.isEmpty {
            lines.append("Bright stars: " + f.brightestStars.prefix(5).map {
                String(format: "%@ mag %.2f", $0.displayName, $0.vmag)
            }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class FocusChatModel: Observable {
    var messages: [FocusChatMessage] = []
    var draft = ""
    var isStreaming = false
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        messages = []
        draft = ""
        isStreaming = false
    }

    func send(constellationID: String, constellationName: String, facts: ConstellationFacts, narration: NarrationFile.Card?,
              resources: FocusResources, context: OverlayContext, engine: SkyEngine) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        draft = ""
        messages.append(FocusChatMessage(role: .user, text: question))
        isStreaming = true
        let passages = resources.bm25?.search(question, limit: 4, constellation: constellationID).map(\.passage) ?? []
        let prompt = FocusChatPrompt.build(constellationName: constellationName, facts: facts, narration: narration,
                                             passages: passages, history: messages.dropLast(), question: question)
        let cacheKey = "chat:\(question.lowercased())"
        let client = DeepDiveClient(cache: .applicationSupport(), modelID: AppInfo.gemmaModelID, apiKey: AppInfo.vertexAPIKey,
                                    projectID: AppInfo.gcpProjectID, location: AppInfo.gemmaLocation)
        task?.cancel()
        task = Task {
            var assistant = FocusChatMessage(role: .assistant, text: "")
            messages.append(assistant)
            let index = messages.count - 1
            for await update in client.ask(constellationID: constellationID, question: cacheKey, prompt: prompt) {
                guard !Task.isCancelled else { return }
                switch update {
                case .text(let text):
                    assistant.text = text
                    messages[index] = assistant
                case .finished:
                    assistant.verificationLabel = Self.verifyLabel(text: assistant.text, resources: resources)
                    messages[index] = assistant
                    isStreaming = false
                case .cached(let text, _):
                    assistant.text = text
                    assistant.verificationLabel = Self.verifyLabel(text: text, resources: resources)
                    messages[index] = assistant
                    isStreaming = false
                case .failed(let message):
                    assistant.text = message
                    assistant.verificationLabel = nil
                    messages[index] = assistant
                    isStreaming = false
                }
            }
        }
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
