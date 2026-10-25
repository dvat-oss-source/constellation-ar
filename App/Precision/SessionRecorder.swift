import Accelerate
import CoreMotion
import Foundation
import ImageIO
import QuartzCore
import Synchronization
import UniformTypeIdentifiers
import simd

/// What the camera receiver hands over for each frame.
struct RecordedFrame {
    let pixelBuffer: CVPixelBuffer
    let sequence: UInt64
    let hostTime: Double
    let pts: Double
    let exposureDuration: Double?
    let iso: Double?
    let lensPosition: Float?
    let intrinsics: CameraIntrinsics?
}

/// Lets a long-lived closure reach whichever recorder is currently attached.
final class RecorderSlot: Sendable {
    private let value = Mutex<SessionRecorder?>(nil)
    var current: SessionRecorder? { value.withLock { $0 } }
    func set(_ recorder: SessionRecorder?) { value.withLock { $0 = recorder } }
}

struct SessionConfig: Sendable, Equatable {
    /// Every Nth camera frame is stored 4× downsampled (0 = never).
    var smallEvery = 2
    /// Every Nth camera frame is stored at full resolution, as raw luminance and PNG (0 = never).
    var fullEvery = 0

    static let smallChoices = [0, 1, 2, 4, 8]
    static let fullChoices = [0, 8, 30, 120]
}

/// Writes a session folder under Documents/Sessions/ (shared through Finder):
///
/// - `meta.json`: format version, device, clocks, configuration, calibration in force, motion column names.
/// - `motion.f64`: little-endian Float64 rows of `SessionRecorder.motionColumns`, one per CMDeviceMotion.
/// - `frames.jsonl`: one JSON object per camera frame (host time, PTS, exposure, ISO, lens position, intrinsics, stored files).
/// - `location.jsonl`, `predictions.jsonl` (overlay star positions in full-resolution buffer pixels), `taps.jsonl`.
/// - `platesolves.jsonl`: the in-app plate solver's result per frame (StarFix fields plus `seq`, `t`, `full`, `outcome`).
/// - `frames/s<seq>.y8` (4× downsampled luminance) and `frames/f<seq>.y8` + `.png` (full resolution).
final class SessionRecorder: Sendable {
    static let motionColumns = ["t", "qx", "qy", "qz", "qw", "rotX", "rotY", "rotZ", "gravX", "gravY", "gravZ", "accX", "accY", "accZ",
                                "magX", "magY", "magZ", "magAccuracy", "heading", "receivedAt"]
    static let downsample = 4

    private struct State {
        var folder: URL?
        var config = SessionConfig()
        var motion = Data()
        var motionRows = 0
        var frames = 0
        var storedSmall = 0
        var storedFull = 0
        var handles: [String: FileHandle] = [:]
        var startedAt = Date()
        var startHost = 0.0
        var firstFrameHost: Double?
        var lastFrameHost: Double?
        var pending: [PredictionRequest] = []
        var recentFull: [UInt64] = []
    }

    /// A stored frame that still needs the overlay's predicted star positions (computed on the main actor).
    struct PredictionRequest: Sendable {
        var sequence: UInt64
        var hostTime: Double
        var exposure: Double?
        var intrinsics: CameraIntrinsics?
        var width: Int
        var height: Int
        var isFull: Bool
    }

    struct Summary: Sendable {
        var name: String
        var seconds: Double
        var motionRows: Int
        var frames: Int
        var storedSmall: Int
        var storedFull: Int
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ConstellationAR.recorder", qos: .utility)

    var isRecording: Bool { state.withLock { $0.folder != nil } }

    var status: String? {
        state.withLock { s in
            guard s.folder != nil else { return nil }
            let seconds = Int(Date().timeIntervalSince(s.startedAt))
            return "recording \(seconds) s: \(s.motionRows) motion rows, \(s.frames) frames (\(s.storedSmall) small, \(s.storedFull) full)"
        }
    }

    static var sessionsDirectory: URL {
        URL.documentsDirectory.appending(path: "Sessions", directoryHint: .isDirectory)
    }

    @discardableResult
    func start(config: SessionConfig, meta: [String: Any]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let folder = Self.sessionsDirectory.appending(path: "session-" + formatter.string(from: Date()), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        var fresh = State()
        fresh.folder = folder
        fresh.config = config
        fresh.startedAt = Date()
        fresh.startHost = CACurrentMediaTime()
        for name in ["motion.f64", "frames.jsonl", "location.jsonl", "predictions.jsonl", "taps.jsonl", "platesolves.jsonl"] {
            let url = folder.appending(path: name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fresh.handles[name] = try FileHandle(forWritingTo: url)
        }
        var full = meta
        full["format"] = 1
        let wallFormatter = ISO8601DateFormatter()
        wallFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        full["startedWallClock"] = wallFormatter.string(from: fresh.startedAt)
        full["startedHostTime"] = fresh.startHost
        full["motionColumns"] = Self.motionColumns
        full["smallFrame"] = ["downsample": Self.downsample, "file": "frames/s<seq>.y8", "layout": "uint8 luminance, row-major"]
        full["fullFrame"] = ["file": "frames/f<seq>.y8", "png": "frames/f<seq>.png"]
        full["smallEvery"] = config.smallEvery
        full["fullEvery"] = config.fullEvery
        try JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appending(path: "meta.json"))
        state.withLock { $0 = fresh }
        return folder
    }

    /// Flushes everything and closes the files; `finalMeta` is merged into meta.json (e.g. the settled rotation convention).
    @discardableResult
    func stop(finalMeta: [String: Any] = [:]) -> Summary? {
        let taken: State? = state.withLock { s in
            guard s.folder != nil else { return nil }
            if !s.motion.isEmpty, let handle = s.handles["motion.f64"] {
                let data = s.motion
                queue.async { try? handle.write(contentsOf: data) }
            }
            let copy = s
            s = State()
            return copy
        }
        guard let taken, let folder = taken.folder else { return nil }
        queue.sync {
            for handle in taken.handles.values { try? handle.close() }
            let metaURL = folder.appending(path: "meta.json")
            if let data = try? Data(contentsOf: metaURL),
               var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                meta.merge(finalMeta) { _, new in new }
                meta["motionRows"] = taken.motionRows
                meta["frames"] = taken.frames
                meta["firstFrameHostTime"] = taken.firstFrameHost
                meta["lastFrameHostTime"] = taken.lastFrameHost
                if let out = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                    try? out.write(to: metaURL)
                }
            }
        }
        return Summary(name: folder.lastPathComponent, seconds: Date().timeIntervalSince(taken.startedAt), motionRows: taken.motionRows,
                       frames: taken.frames, storedSmall: taken.storedSmall, storedFull: taken.storedFull)
    }

    // MARK: Streams

    func record(motion m: CMDeviceMotion, receivedAt: Double) {
        let q = m.attitude.quaternion
        let row: [Double] = [m.timestamp, q.x, q.y, q.z, q.w,
                             m.rotationRate.x, m.rotationRate.y, m.rotationRate.z,
                             m.gravity.x, m.gravity.y, m.gravity.z,
                             m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z,
                             m.magneticField.field.x, m.magneticField.field.y, m.magneticField.field.z,
                             Double(m.magneticField.accuracy.rawValue), m.heading, receivedAt]
        state.withLock { s in
            guard s.folder != nil else { return }
            row.withUnsafeBytes { s.motion.append(contentsOf: $0) }
            s.motionRows += 1
            if s.motionRows % 200 == 0, let handle = s.handles["motion.f64"] {
                let data = s.motion
                s.motion = Data()
                queue.async { try? handle.write(contentsOf: data) }
            }
        }
    }

    /// Called on the video queue for every camera frame. Returns the sequence number if a luminance frame was stored.
    func record(frame f: RecordedFrame) {
        let decision: (small: Bool, full: Bool)? = state.withLock { s in
            guard s.folder != nil else { return nil }
            s.frames += 1
            s.firstFrameHost = s.firstFrameHost ?? f.hostTime
            s.lastFrameHost = f.hostTime
            let n = s.frames
            let small = s.config.smallEvery > 0 && n % s.config.smallEvery == 0
            let full = s.config.fullEvery > 0 && n % s.config.fullEvery == 0
            if small { s.storedSmall += 1 }
            if full {
                s.storedFull += 1
                s.recentFull.append(f.sequence)
                if s.recentFull.count > 16 { s.recentFull.removeFirst() }
            }
            if small || full {
                s.pending.append(PredictionRequest(sequence: f.sequence, hostTime: f.hostTime, exposure: f.exposureDuration, intrinsics: f.intrinsics,
                                                   width: CVPixelBufferGetWidth(f.pixelBuffer), height: CVPixelBufferGetHeight(f.pixelBuffer), isFull: full))
                if s.pending.count > 60 { s.pending.removeFirst(s.pending.count - 60) }
            }
            return (small, full)
        }
        guard let decision else { return }

        let width = CVPixelBufferGetWidth(f.pixelBuffer), height = CVPixelBufferGetHeight(f.pixelBuffer)
        var files: [String: Any] = [:]
        let name = String(format: "%06llu", f.sequence)
        if decision.small || decision.full, let luma = Self.luminance(of: f.pixelBuffer) {
            if decision.full {
                files["full"] = "frames/f\(name).y8"
                files["png"] = "frames/f\(name).png"
                write(luma, width: width, height: height, name: "f" + name, png: true)
            }
            if decision.small, let small = Self.downsampled(luma, width: width, height: height, factor: Self.downsample) {
                files["small"] = "frames/s\(name).y8"
                files["smallSize"] = [width / Self.downsample, height / Self.downsample]
                write(small, width: width / Self.downsample, height: height / Self.downsample, name: "s" + name, png: false)
            }
        }
        var line: [String: Any] = ["seq": f.sequence, "t": f.hostTime, "pts": f.pts, "size": [width, height]]
        if let e = f.exposureDuration { line["exposure"] = e }
        if let iso = f.iso { line["iso"] = iso }
        if let lens = f.lensPosition { line["lens"] = lens }
        if let i = f.intrinsics { line["K"] = [i.fx, i.fy, i.cx, i.cy] }
        line.merge(files) { _, new in new }
        append(line, to: "frames.jsonl")
    }

    /// Every full-resolution frame waiting for predictions, plus the newest downsampled one.
    func takePredictionRequests() -> [PredictionRequest] {
        state.withLock { s in
            let all = s.pending
            s.pending = []
            let full = all.filter(\.isFull)
            return full + (all.last(where: { !$0.isFull }).map { [$0] } ?? [])
        }
    }

    func recordLocation(_ line: [String: Any]) { append(line, to: "location.jsonl") }
    func recordPredictions(_ line: [String: Any]) { append(line, to: "predictions.jsonl") }
    func recordTap(_ line: [String: Any]) { append(line, to: "taps.jsonl") }
    func recordPlateSolve(_ line: [String: Any]) { append(line, to: "platesolves.jsonl") }

    /// Whether the frame with this sequence number was just stored at full resolution.
    func storedFull(sequence: UInt64) -> Bool { state.withLock { $0.recentFull.contains(sequence) } }

    // MARK: Helpers

    private func append(_ object: [String: Any], to file: String) {
        guard let handle = state.withLock({ $0.handles[file] }),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let line = data
        queue.async { try? handle.write(contentsOf: line) }
    }

    private func write(_ luma: Data, width: Int, height: Int, name: String, png: Bool) {
        guard let folder = state.withLock({ $0.folder }) else { return }
        queue.async {
            try? luma.write(to: folder.appending(path: "frames/\(name).y8"))
            guard png, let provider = CGDataProvider(data: luma as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(folder.appending(path: "frames/\(name).png") as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// Rec. 601 luma of a BGRA buffer.
    static func luminance(of buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var out = Data(count: width * height)
        let status = out.withUnsafeMutableBytes { raw -> vImage_Error in
            var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            // Memory order is B, G, R, A.
            let matrix: [Int16] = [29, 150, 77, 0]
            return vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
        }
        return status == kvImageNoError ? out : nil
    }

    static func downsampled(_ luma: Data, width: Int, height: Int, factor: Int) -> Data? {
        let w = width / factor, h = height / factor
        var out = Data(count: w * h)
        let status = luma.withUnsafeBytes { src -> vImage_Error in
            out.withUnsafeMutableBytes { dst -> vImage_Error in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                return vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return status == kvImageNoError ? out : nil
    }
}
