import Foundation
import AVFoundation
import ImageIO
import simd
import SkyCore
import XCTest
@testable import ConstellationAR

final class CameraFormatPolicyTests: XCTestCase {
    private func format(_ width: Int32 = 1920, _ height: Int32 = 1080, fps: Double = 60,
                        fov: Float = 100, binned: Bool = false) -> CameraFormatRank {
        CameraFormatRank(width: width, height: height, fov: fov, fps: fps, isBinned: binned, fullRange: true)
    }

    func testSecondaryCamerasKeep1080DetailInsteadOf720HighSpeed() {
        let detail = format(), highSpeed = format(1280, 720, fps: 120, binned: true)
        for lens in [CaptureLens.ultraWide, .telephoto] {
            XCTAssertTrue(detail.isPreferred(to: highSpeed, lens: lens))
            XCTAssertFalse(highSpeed.isPreferred(to: detail, lens: lens))
            XCTAssertEqual(CameraFormatRank.dayFrameRate(lens: lens, maximum: 120), 60)
            XCTAssertEqual(CameraFormatRank.dayFrameRate(lens: lens, maximum: 30), 30)
        }
    }

    func testNightDefaultsKeepAutomaticISOInsteadOfForcingMaximumGain() {
        XCTAssertEqual(ExposureController().nightStrategy, .shutterPriority)
    }

    func testMainCameraRetainsHighSpeedRankingAndRate() {
        XCTAssertTrue(format(1280, 720, fps: 120, binned: true).isPreferred(to: format(), lens: .wide))
        XCTAssertTrue(format(fps: 120, binned: true).isPreferred(to: format(fps: 60), lens: .wide))
        XCTAssertEqual(CameraFormatRank.dayFrameRate(lens: .wide, maximum: 240), 120)
        XCTAssertEqual(CameraFormatRank.dayFrameRate(lens: .wide, maximum: 60), 60)
    }

    func testSecondaryAvoidsBinningWhenResolutionAndFieldOfViewMatch() {
        XCTAssertTrue(format(fps: 60).isPreferred(to: format(fps: 120, binned: true), lens: .telephoto))
        XCTAssertTrue(format(fps: 60).isPreferred(to: format(fps: 30), lens: .ultraWide))
        XCTAssertFalse(format(fps: 120).isPreferred(to: format(fps: 60), lens: .ultraWide))
    }

    func testFieldOfViewAndPortraitAspectFillStayConsistent() {
        for lens in CaptureLens.allCases {
            XCTAssertTrue(format(1280, 720, fov: 110).isPreferred(to: format(fov: 100), lens: lens))
            XCTAssertTrue(format().isPreferred(to: format(1920, 1440), lens: lens))
            XCTAssertFalse(format().isPreferred(to: format(), lens: lens))
        }
    }
}

final class CameraQualityRecordingTests: XCTestCase {
    func testFullFrameKeepsColorAndDeliveryMetadataBeforeRendering() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<2 {
            for x in 0..<2 {
                let i = y * stride + x * 4
                base[i] = 8; base[i + 1] = 16; base[i + 2] = 224; base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let recorder = SessionRecorder()
        let folder = try recorder.start(config: SessionConfig(smallEvery: 0, fullEvery: 1), meta: [:])
        defer { try? FileManager.default.removeItem(at: folder) }
        recorder.record(frame: RecordedFrame(pixelBuffer: pixels, sequence: 42, hostTime: 10, pts: 9.5,
                                             exposureDuration: 1.0 / 60, iso: 200, lensPosition: 0.7, intrinsics: nil,
                                             deliveredAt: 10.02, sampleDuration: .nan,
                                             captureStateAtDelivery: ["deviceType": "test telephoto", "zoomFactor": 1.0]))
        _ = recorder.stop()
        let line = try Data(contentsOf: folder.appending(path: "frames.jsonl"))
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(row["deliveredAt"] as? Double, 10.02)
        XCTAssertNil(row["sampleDuration"], "invalid CMTime must not discard the whole JSON row")
        XCTAssertEqual((row["captureStateAtDelivery"] as? [String: Any])?["deviceType"] as? String, "test telephoto")
        let png = try XCTUnwrap(row["colorPNG"] as? String)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(folder.appending(path: png) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        var rgba = [UInt8](repeating: 0, count: 16)
        let decoded = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 2, height: 2, bitsPerComponent: 8,
                                          bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
            return true
        }
        XCTAssertTrue(decoded)
        XCTAssertEqual(Array(rgba.prefix(4)), [224, 16, 8, 255], "BGRA copy must preserve channels, not save grayscale or swap red and blue")
    }
}

private struct StubStreamer: LineStreamer {
    var status = 200
    var lines: [String]
    var failure: (any Error)?

    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, any Error>) {
        let lines = lines, failure = failure
        return (status, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: failure)
        })
    }
}

private func event(_ json: String) -> [String] { ["data: \(json)", ""] }

final class SSEParserTests: XCTestCase {
    func testEventsEndAtBlankLines() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(line: "data: {\"a\":1}"), [])
        XCTAssertEqual(parser.feed(line: ""), ["{\"a\":1}"])
        XCTAssertEqual(parser.feed(line: ": keep-alive"), [])
        XCTAssertEqual(parser.feed(line: "data:{\"b\":2}\r"), [])
        XCTAssertEqual(parser.feed(line: "\r"), ["{\"b\":2}"])
    }

    func testMultiLineDataIsJoinedAndFinishFlushes() {
        var parser = SSEParser()
        _ = parser.feed(line: "data: line one")
        _ = parser.feed(line: "data: line two")
        XCTAssertEqual(parser.finish(), ["line one\nline two"])
        XCTAssertEqual(parser.finish(), [])
    }

    func testNewDataLineAfterCompleteJSONStartsANewEvent() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(line: "data: {\"n\":1}"), [])
        XCTAssertEqual(parser.feed(line: "data: {\"n\":2}"), ["{\"n\":1}"])
        XCTAssertEqual(parser.finish(), ["{\"n\":2}"])
    }

    func testDecodeTextSkipsThoughtsAndReportsFinish() {
        let payload = #"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"Hello "},{"text":"sky"}]},"finishReason":"STOP"}]}"#
        XCTAssertEqual(GeminiStream.decode(event: payload), [.text("Hello "), .text("sky"), .finished(reason: "STOP")])
    }

    func testGemmaEventSequence() {
        let first = #"{"candidates": [{"content": {"role": "assistant","parts": [{"text": ""}]}}],"usageMetadata": {}}"#
        let middle = #"{"candidates": [{"content": {"role": "assistant","parts": [{"text": "Or"}]}}],"usageMetadata": {}}"#
        let last = #"{"candidates": [{"content": {"role": "assistant","parts": [{"text": ""}]},"finishReason": "STOP"}],"usageMetadata": {}}"#
        let usage = #"{"usageMetadata": {"promptTokenCount": 12,"candidatesTokenCount": 3,"totalTokenCount": 15}}"#
        XCTAssertEqual(GeminiStream.decode(event: first), [])
        XCTAssertEqual(GeminiStream.decode(event: middle), [.text("Or")])
        XCTAssertEqual(GeminiStream.decode(event: last), [.finished(reason: "STOP")])
        XCTAssertEqual(GeminiStream.decode(event: usage), [])
    }

    func testDecodeErrorAndBlockedPrompt() {
        XCTAssertEqual(GeminiStream.decode(event: #"{"error":{"code":403,"message":"API key not valid.","status":"PERMISSION_DENIED"}}"#),
                       [.error("PERMISSION_DENIED: API key not valid.")])
        XCTAssertEqual(GeminiStream.decode(event: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#), [.error("The request was blocked (SAFETY).")])
        XCTAssertEqual(GeminiStream.decode(event: "not json"), [])
    }

    func testHTTPErrorMessageParsesJSONArrayAndPlainText() {
        XCTAssertEqual(GeminiStream.httpErrorMessage(status: 429, body: #"[{"error":{"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}]"#),
                       "HTTP 429, RESOURCE_EXHAUSTED: Quota exceeded")
        XCTAssertEqual(GeminiStream.httpErrorMessage(status: 502, body: "Bad gateway\n"), "HTTP 502, Bad gateway")
        XCTAssertEqual(GeminiStream.httpErrorMessage(status: 500, body: ""), "HTTP 500")
    }
}

final class DeepDiveClientTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("deepdive-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func client(_ streamer: StubStreamer, key: String? = "SECRET-KEY") -> DeepDiveClient {
        DeepDiveClient(streamer: streamer, cache: DeepDiveCache(directory: directory), modelID: "gemma-test", apiKey: key)
    }

    private func collect(_ client: DeepDiveClient, id: String = "Ori", question: String = "more") async -> [DeepDiveUpdate] {
        var updates: [DeepDiveUpdate] = []
        for await update in client.ask(constellationID: id, question: question, prompt: "facts") { updates.append(update) }
        return updates
    }

    func testStreamsTextIncrementallyAndCachesTheAnswer() async {
        let lines = event(#"{"candidates":[{"content":{"parts":[{"text":"Orion "}]}}]}"#)
            + event(#"{"candidates":[{"content":{"parts":[{"text":"the hunter."}]},"finishReason":"STOP"}]}"#)
        let updates = await collect(client(StubStreamer(lines: lines)))
        XCTAssertEqual(updates, [.text("Orion "), .text("Orion the hunter."), .finished])
        XCTAssertEqual(DeepDiveCache(directory: directory).answer(constellationID: "Ori", question: "more"), "Orion the hunter.")
        XCTAssertNil(DeepDiveCache(directory: directory).answer(constellationID: "Tau", question: "more"))
        XCTAssertNil(DeepDiveCache(directory: directory).answer(constellationID: "Ori", question: "other question"))
    }

    func testHTTPErrorShowsStatusWithoutTheKey() async {
        let body = [#"{"error":{"message":"Key SECRET-KEY is not valid","status":"PERMISSION_DENIED"}}"#]
        let updates = await collect(client(StubStreamer(status: 403, lines: body)))
        guard case .failed(let message) = updates.last else { return XCTFail("expected a failure, got \(updates)") }
        XCTAssertTrue(message.hasPrefix("HTTP 403"), message)
        XCTAssertFalse(message.contains("SECRET-KEY"), message)
    }

    func testFailureFallsBackToTheSavedAnswer() async {
        DeepDiveCache(directory: directory).store("Saved answer.", constellationID: "Ori", question: "more")
        let offline = StubStreamer(lines: [], failure: URLError(.notConnectedToInternet))
        let updates = await collect(client(offline))
        guard case .cached(let text, let reason) = updates.last else { return XCTFail("expected cached answer, got \(updates)") }
        XCTAssertEqual(text, "Saved answer.")
        XCTAssertTrue(reason.hasPrefix("Offline"), reason)
    }

    func testGemmaStreamEndToEndThroughTheStub() async {
        let lines = event(#"{"candidates": [{"content": {"role": "assistant","parts": [{"text": ""}]}}],"usageMetadata": {}}"#)
            + event(#"{"candidates": [{"content": {"role": "assistant","parts": [{"text": "Or"}]}}],"usageMetadata": {}}"#)
            + event(#"{"candidates": [{"content": {"role": "assistant","parts": [{"text": "ion"}]}}],"usageMetadata": {}}"#)
            + event(#"{"candidates": [{"content": {"role": "assistant","parts": [{"text": ""}]},"finishReason": "STOP"}],"usageMetadata": {}}"#)
            + event(#"{"usageMetadata": {"totalTokenCount": 15}}"#)
        let updates = await collect(client(StubStreamer(lines: lines)))
        XCTAssertEqual(updates, [.text("Or"), .text("Orion"), .finished])
    }

    func testMissingKeyFailsClearlyWithoutRequesting() async {
        let updates = await collect(client(StubStreamer(lines: []), key: nil))
        guard case .failed(let message) = updates.last else { return XCTFail("expected a failure, got \(updates)") }
        XCTAssertTrue(message.contains("Secrets.xcconfig"), message)
    }

    func testEndpointUsesTheProjectScopedLocationWhenAProjectIsSet() {
        XCTAssertEqual(DeepDiveClient.endpoint(modelID: "gemma-test", projectID: "my-proj", location: "global")?.absoluteString,
                       "https://aiplatform.googleapis.com/v1/projects/my-proj/locations/global/publishers/google/models/gemma-test:streamGenerateContent?alt=sse")
        XCTAssertEqual(DeepDiveClient.endpoint(modelID: "gemma-test", projectID: "my-proj", location: nil)?.path,
                       "/v1/projects/my-proj/locations/global/publishers/google/models/gemma-test:streamGenerateContent")
        XCTAssertEqual(DeepDiveClient.endpoint(modelID: "gemma-test", projectID: "", location: "global")?.path,
                       "/v1/publishers/google/models/gemma-test:streamGenerateContent")
    }

    func testRequestKeepsTheKeyInTheHeaderOnly() throws {
        let request = try XCTUnwrap(client(StubStreamer(lines: [])).request(prompt: "p"))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://aiplatform.googleapis.com/v1/publishers/google/models/gemma-test:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "SECRET-KEY")
        XCTAssertFalse(request.url?.absoluteString.contains("SECRET-KEY") ?? true)
        XCTAssertEqual(request.httpMethod, "POST")
    }
}

@MainActor
final class ProjectionAgreementTests: XCTestCase {
    /// The shader path (sky background, Milky Way) and the SkyCore projector used for lines, taps and the centre lookup
    /// must give the same ray for every pixel.
    func testShaderRayMatchesProjectorRay() {
        let size = SIMD2<Double>(1920, 1080)
        let intrinsics = ConstellationAR.CameraIntrinsics(fx: 1500, fy: 1496, cx: 962, cy: 538, referenceSize: size, isMeasured: true)
        let geometry = CameraGeometry(intrinsics: intrinsics, drawableSize: SIMD2(1320, 2868))
        let attitude = LookController.deviceFromReference(azimuth: 123, altitude: 37)
        let context = OverlayContext(hostTime: 0, displayTime: 0, skyDate: Date(), observer: nil, deviceFromReference: attitude,
                                     camera: geometry, lighting: 1, isSkyOnly: true, contentScale: 3)
        let shader = geometry.referenceFromScreen(deviceFromReference: attitude)
        for pixel in [SIMD2<Double>(0, 0), SIMD2(660, 1434), SIMD2(1200, 2700), SIMD2(40, 2000)] {
            let fromShader = simd_normalize(shader * SIMD3(pixel, 1))
            let fromProjector = context.referenceDirection(screen: pixel)
            XCTAssertLessThan(Angle.separation(fromShader, fromProjector), 1e-9)
            let back = try? XCTUnwrap(context.screenPoint(reference: fromProjector))
            XCTAssertLessThan(simd_distance(back ?? .zero, pixel), 1e-6)
            let enu = simd_normalize(context.enuFromScreen * SIMD3(pixel, 1))
            XCTAssertLessThan(Angle.separation(enu, OverlayContext.enu(reference: fromProjector)), 1e-9)
        }
    }

    func testLayerDefaultsFollowDayAndNight() {
        let layers = LayerSettings()
        XCTAssertEqual(SkyLayer.allCases.filter { layers.isOn($0, night: false) }, [.lines, .planets, .satellites])
        XCTAssertEqual(SkyLayer.allCases.filter { layers.isOn($0, night: true) },
                       SkyLayer.allCases.filter { $0 != .illustrated })
        layers.set(.stars, on: true, night: false)
        XCTAssertTrue(layers.isOn(.stars, night: false))
        layers.set(.stars, on: false, night: false)
        XCTAssertFalse(layers.hasOverrides)
    }
}
