import AVFoundation
import CoreVideo
import ImageIO
import Metal
import QuartzCore
import Synchronization
import simd

/// Pinhole intrinsics in pixels of the delivered (native landscape) buffer, origin at its upper-left corner.
struct CameraIntrinsics: Sendable, Equatable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    /// Buffer width/height the intrinsics refer to (landscape: width > height).
    var referenceSize: SIMD2<Double>
    /// False when derived from a nominal field of view instead of Apple's per-frame lens data.
    var isMeasured: Bool

    init(fx: Double, fy: Double, cx: Double, cy: Double, referenceSize: SIMD2<Double>, isMeasured: Bool) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.referenceSize = referenceSize
        self.isMeasured = isMeasured
    }

    init(matrix m: simd_float3x3, referenceSize: SIMD2<Double>) {
        self.init(fx: Double(m.columns.0.x), fy: Double(m.columns.1.y),
                  cx: Double(m.columns.2.x), cy: Double(m.columns.2.y),
                  referenceSize: referenceSize, isMeasured: true)
    }

    /// Square pixels, principal point at the centre, `longAxisFOV` across the buffer width.
    static func nominal(size: SIMD2<Double>, longAxisFOVDegrees: Double) -> CameraIntrinsics {
        let f = (size.x / 2) / tan(longAxisFOVDegrees * .pi / 360)
        return CameraIntrinsics(fx: f, fy: f, cx: size.x / 2, cy: size.y / 2, referenceSize: size, isMeasured: false)
    }

    /// Angle across the buffer's long (width) and short (height) axes.
    var fieldOfViewDegrees: SIMD2<Double> {
        SIMD2(2 * atan(referenceSize.x / (2 * fx)), 2 * atan(referenceSize.y / (2 * fy))) * 180 / .pi
    }

    /// The same lens at another buffer resolution.
    func scaled(to size: SIMD2<Double>) -> CameraIntrinsics {
        let s = size / referenceSize
        return CameraIntrinsics(fx: fx * s.x, fy: fy * s.y, cx: cx * s.x, cy: cy * s.y, referenceSize: size, isMeasured: isMeasured)
    }
}

// CVMetalTexture and MTLTexture have no Sendable conformance in the iOS 27 SDK. A frame is immutable
// after the capture queue creates it and its texture is only read by the GPU afterwards.
struct CameraFrame: @unchecked Sendable {
    let texture: any MTLTexture
    let backing: CVMetalTexture
    /// The pixels behind `texture` (BGRA), for tap snapping.
    let pixelBuffer: CVPixelBuffer
    /// Native landscape buffer size in pixels.
    let size: SIMD2<Int>
    /// Presentation timestamp converted to the host clock (seconds, same base as CACurrentMediaTime and CMLogItem.timestamp).
    let hostTime: Double
    let intrinsics: CameraIntrinsics?
    let exposureDuration: Double?
    let iso: Double?
    let sequence: UInt64
}

struct FrameStatistics: Sendable {
    var frames: UInt64 = 0
    var dropped: UInt64 = 0
    var framesWithIntrinsics: UInt64 = 0
    var framesPerSecond: Double = 0
    /// Host time at delivery minus the frame's host timestamp.
    var deliveryLatency: Double = 0
    var lastHostTime: Double = 0
    var lastSize: SIMD2<Int> = .zero
    var lastIntrinsics: CameraIntrinsics?
    var lastExposureDuration: Double?
    var lastISO: Double?
}

/// Sample-buffer delegate: turns each frame into a Metal texture plus timing and lens metadata.
final class VideoFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    // Not Sendable in the SDK; only touched from the video data output's serial queue.
    private nonisolated(unsafe) let textureCache: CVMetalTextureCache
    private let syncClock = Mutex<CMClock?>(nil)
    private let latest = Mutex<CameraFrame?>(nil)
    private let stats = Mutex(FrameStatistics())
    private let recorder = Mutex<SessionRecorder?>(nil)
    private let lensPosition = Mutex<Float?>(nil)

    init?(metalDevice: any MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        textureCache = cache
    }

    /// Timestamps are on the session's synchronization clock; without one they are taken as host time.
    func setSynchronizationClock(_ clock: CMClock?) {
        syncClock.withLock { $0 = clock }
    }

    func setRecorder(_ recorder: SessionRecorder?) {
        self.recorder.withLock { $0 = recorder }
    }

    func setLensPosition(_ position: Float) {
        lensPosition.withLock { $0 = position }
    }

    /// The newest frame not yet taken, or nil if none arrived since the last call.
    func takeLatest() -> CameraFrame? {
        latest.withLock { slot in
            let frame = slot
            slot = nil
            return frame
        }
    }

    var statistics: FrameStatistics { stats.withLock { $0 } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime: Double
        if let clock = syncClock.withLock({ $0 }) {
            hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
        } else {
            hostTime = pts.seconds
        }
        let size = SIMD2(width, height)
        let intrinsics = Self.intrinsics(of: sampleBuffer, size: size)
        let (exposure, iso) = Self.exposure(of: sampleBuffer)
        let deliveredAt = CACurrentMediaTime()

        let sequence = stats.withLock { s -> UInt64 in
            if s.lastHostTime > 0, hostTime > s.lastHostTime {
                let instantaneous = 1 / (hostTime - s.lastHostTime)
                s.framesPerSecond = s.framesPerSecond == 0 ? instantaneous : s.framesPerSecond * 0.9 + instantaneous * 0.1
            }
            s.frames += 1
            if intrinsics != nil { s.framesWithIntrinsics += 1 }
            s.deliveryLatency = deliveredAt - hostTime
            s.lastHostTime = hostTime
            s.lastSize = size
            s.lastIntrinsics = intrinsics ?? s.lastIntrinsics
            s.lastExposureDuration = exposure
            s.lastISO = iso
            return s.frames
        }

        let frame = CameraFrame(texture: texture, backing: cvTexture, pixelBuffer: pixelBuffer, size: size, hostTime: hostTime,
                                intrinsics: intrinsics, exposureDuration: exposure, iso: iso, sequence: sequence)
        if let recorder = recorder.withLock({ $0 }), recorder.isRecording {
            recorder.record(frame: RecordedFrame(pixelBuffer: pixelBuffer, sequence: sequence, hostTime: hostTime, pts: pts.seconds,
                                                 exposureDuration: exposure, iso: iso, lensPosition: lensPosition.withLock { $0 },
                                                 intrinsics: intrinsics))
        }
        latest.withLock { $0 = frame }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stats.withLock { $0.dropped += 1 }
    }

    private static func intrinsics(of sampleBuffer: CMSampleBuffer, size: SIMD2<Int>) -> CameraIntrinsics? {
        guard let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
              data.count >= MemoryLayout<simd_float3x3>.size else { return nil }
        let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
        return CameraIntrinsics(matrix: matrix, referenceSize: SIMD2(Double(size.x), Double(size.y)))
    }

    private static func exposure(of sampleBuffer: CMSampleBuffer) -> (Double?, Double?) {
        guard let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any] else {
            return (nil, nil)
        }
        let duration = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        return (duration, iso)
    }
}
