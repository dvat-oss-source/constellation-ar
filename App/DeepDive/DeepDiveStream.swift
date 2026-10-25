import Foundation

/// Incremental Server-Sent Events parser: feed it lines (without the terminating newline); an event is complete at a
/// blank line. A `data:` line that arrives while the previous event's data is already a complete JSON value starts a
/// new event, so streams that omit the blank separator still parse.
struct SSEParser: Sendable {
    private var dataLines: [String] = []

    mutating func feed(line raw: String) -> [String] {
        var line = Substring(raw)
        if line.hasSuffix("\r") { line = line.dropLast() }
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") || !line.hasPrefix("data:") { return [] }
        var value = line.dropFirst(5)
        if value.first == " " { value = value.dropFirst() }
        var events: [String] = []
        if !dataLines.isEmpty, Self.isCompleteJSON(dataLines.joined(separator: "\n")) { events = flush() }
        dataLines.append(String(value))
        return events
    }

    mutating func finish() -> [String] { flush() }

    private mutating func flush() -> [String] {
        defer { dataLines = [] }
        return dataLines.isEmpty ? [] : [dataLines.joined(separator: "\n")]
    }

    private static func isCompleteJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }
}

/// What one streamed `generateContent` event means.
enum GeminiChunk: Equatable, Sendable {
    case text(String)
    case finished(reason: String)
    case error(String)
}

enum GeminiStream {
    /// Text parts of the first candidate (thought parts skipped), a finish reason, or the API's error message.
    static func decode(event payload: String) -> [GeminiChunk] {
        guard payload != "[DONE]", let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { return [] }
        let root = (object as? [String: Any]) ?? (object as? [[String: Any]])?.first ?? [:]
        if let error = root["error"] as? [String: Any] {
            return [.error(errorMessage(error))]
        }
        var chunks: [GeminiChunk] = []
        let candidates = root["candidates"] as? [[String: Any]] ?? []
        if let candidate = candidates.first {
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts where (part["thought"] as? Bool) != true {
                if let text = part["text"] as? String, !text.isEmpty { chunks.append(.text(text)) }
            }
            if let reason = candidate["finishReason"] as? String, reason != "FINISH_REASON_UNSPECIFIED" {
                chunks.append(.finished(reason: reason))
            }
        } else if let feedback = root["promptFeedback"] as? [String: Any], let block = feedback["blockReason"] as? String {
            chunks.append(.error("The request was blocked (\(block))."))
        }
        return chunks
    }

    static func errorMessage(_ error: [String: Any]) -> String {
        let message = (error["message"] as? String) ?? (error["status"] as? String) ?? "unknown error"
        if let status = error["status"] as? String, (error["message"] as? String) != nil { return "\(status): \(message)" }
        return message
    }

    /// Message for a non-200 response body (a JSON error object, an array holding one, or plain text).
    static func httpErrorMessage(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            let root = (object as? [String: Any]) ?? (object as? [[String: Any]])?.first ?? [:]
            if let error = root["error"] as? [String: Any] { return "HTTP \(status), \(errorMessage(error))" }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HTTP \(status)" : "HTTP \(status), \(String(trimmed.prefix(200)))"
    }
}
