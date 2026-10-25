import Foundation
import SkyCore

/// Answers saved per constellation + question, so an offline "Tell me more" can still show the last answer.
struct DeepDiveCache: Sendable {
    let directory: URL

    static func applicationSupport() -> DeepDiveCache {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return DeepDiveCache(directory: base.appendingPathComponent("DeepDive", isDirectory: true))
    }

    func fileURL(constellationID: String, question: String) -> URL {
        let id = String(constellationID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return directory.appendingPathComponent("\(id)-\(Self.hash(question)).txt")
    }

    func answer(constellationID: String, question: String) -> String? {
        guard let text = try? String(contentsOf: fileURL(constellationID: constellationID, question: question), encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    func store(_ answer: String, constellationID: String, question: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? answer.write(to: fileURL(constellationID: constellationID, question: question), atomically: true, encoding: .utf8)
    }

    /// FNV-1a: stable across launches (`Hashable` is seeded per process).
    static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}

/// Opens a streaming HTTP request and yields the response body line by line (blank lines included).
protocol LineStreamer: Sendable {
    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, any Error>)
}

struct URLSessionLineStreamer: LineStreamer {
    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    var buffer = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, lines)
    }
}

enum DeepDiveUpdate: Equatable, Sendable {
    /// The whole answer so far.
    case text(String)
    case finished
    /// The request failed; this is the answer saved from an earlier success.
    case cached(text: String, reason: String)
    case failed(String)
}

/// "Tell me more": streams a Gemma answer over SSE and keeps the last good answer for offline use.
struct DeepDiveClient: Sendable {
    static let system = """
    You are a warm, concise planetarium guide talking to someone who is outside right now, looking at the constellation \
    their phone has locked onto. Use only the facts given plus well-established astronomy and mythology; say so if you are \
    unsure. About 150 words, plain sentences, no markdown, no lists. Never suggest looking at the Sun.
    """

    var streamer: any LineStreamer = URLSessionLineStreamer()
    var cache: DeepDiveCache
    var modelID: String?
    var apiKey: String?
    var projectID: String?
    var location: String?

    /// Gemma MaaS is rejected by the plain express URL ("only available via global endpoint"); with a project ID the
    /// project-scoped location URL is used instead, and the express URL is only the fallback.
    static func endpoint(modelID: String, projectID: String? = nil, location: String? = nil) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))
        func encode(_ value: String) -> String? { value.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard let model = encode(modelID) else { return nil }
        if let projectID, !projectID.isEmpty, let project = encode(projectID),
           let place = encode(location?.isEmpty == false ? location! : "global") {
            return URL(string: "https://aiplatform.googleapis.com/v1/projects/\(project)/locations/\(place)/publishers/google/models/\(model):streamGenerateContent?alt=sse")
        }
        return URL(string: "https://aiplatform.googleapis.com/v1/publishers/google/models/\(model):streamGenerateContent?alt=sse")
    }

    func request(prompt: String) -> URLRequest? {
        guard let modelID, let apiKey, let url = Self.endpoint(modelID: modelID, projectID: projectID, location: location) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Self.system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 800],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func prompt(facts: DeepDiveFacts, question: String) -> String {
        "\(question)\n\nFacts about the sky right now:\n\(facts.promptText)"
    }

    func ask(constellationID: String, question: String, prompt: String) -> AsyncStream<DeepDiveUpdate> {
        AsyncStream { continuation in
            let task = Task {
                var text = ""
                do {
                    guard let request = request(prompt: prompt) else {
                        throw StreamFailure("The Vertex API key or Gemma model is not set in Config/Secrets.xcconfig.")
                    }
                    let (status, lines) = try await streamer.open(request)
                    guard status == 200 else {
                        var body = ""
                        for try await line in lines where body.count < 4000 { body += line + "\n" }
                        throw StreamFailure(GeminiStream.httpErrorMessage(status: status, body: body))
                    }
                    var parser = SSEParser()
                    var finishReason: String?
                    func consume(_ events: [String]) throws {
                        for event in events {
                            for chunk in GeminiStream.decode(event: event) {
                                switch chunk {
                                case .text(let piece):
                                    text += piece
                                    continuation.yield(.text(text))
                                case .finished(let reason): finishReason = reason
                                case .error(let message): throw StreamFailure(message)
                                }
                            }
                        }
                    }
                    for try await line in lines { try consume(parser.feed(line: line)) }
                    try consume(parser.finish())
                    guard !text.isEmpty else {
                        throw StreamFailure("The model returned no text" + (finishReason.map { " (\($0))." } ?? "."))
                    }
                    cache.store(text, constellationID: constellationID, question: question)
                    continuation.yield(.finished)
                } catch is CancellationError {
                } catch {
                    let reason = scrub(error is StreamFailure ? "\(error)" : Self.describe(error))
                    if let saved = cache.answer(constellationID: constellationID, question: question) {
                        continuation.yield(.cached(text: saved, reason: reason))
                    } else {
                        continuation.yield(.failed(reason))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                return "Offline: \(urlError.localizedDescription)"
            default: return "Network error: \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    /// Server messages can echo request details; the key must never reach the screen.
    private func scrub(_ message: String) -> String {
        guard let apiKey, !apiKey.isEmpty else { return message }
        return message.replacingOccurrences(of: apiKey, with: "…")
    }
}
