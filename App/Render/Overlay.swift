import Foundation
import simd

/// A round marker (star, planet, DSO, satellite). Screen pixels, origin upper-left. Layout matches `PointInstance`
/// in Shaders.metal (32 bytes) so arrays are copied to the GPU as-is.
struct OverlayPoint: Sendable {
    var position: SIMD2<Float>
    var radius: Float
    private var padding: Float = 0
    /// Straight (non-premultiplied) RGBA.
    var color: SIMD4<Float>

    init(position: SIMD2<Float>, radius: Float, color: SIMD4<Float>) {
        self.position = position
        self.radius = radius
        self.color = color
    }
}

/// A thick screen-space line with round caps. Layout matches `SegmentInstance` in Shaders.metal (80 bytes).
struct OverlaySegment: Sendable {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var color: SIMD4<Float>
    var outlineColor: SIMD4<Float>
    /// Core line width in pixels.
    var width: Float
    /// Extra dark rim on each side, pixels (0 = none).
    var outlineWidth: Float
    /// 0…1; the halo extends up to 4× the line width.
    var glow: Float
    /// Dash period in pixels, 0 = solid.
    var dashPeriod: Float
    /// Offset into the dash pattern so clipped segments keep a stable pattern.
    var dashPhase: Float
    private var padding: (Float, Float, Float) = (0, 0, 0)

    init(a: SIMD2<Float>, b: SIMD2<Float>, width: Float, color: SIMD4<Float>,
         outlineWidth: Float = 0, outlineColor: SIMD4<Float> = SIMD4(0, 0, 0, 0.75),
         glow: Float = 0, dashed: Bool = false, dashPhase: Float = 0) {
        self.a = a
        self.b = b
        self.color = color
        self.outlineColor = outlineColor
        self.width = width
        self.outlineWidth = outlineWidth
        self.glow = glow
        self.dashPeriod = dashed ? max(width * 6, 12) : 0
        self.dashPhase = dashPhase
    }

    var dashed: Bool { dashPeriod > 0 }
}

/// Text anchored at a screen point. Carried through the pipeline; the renderer does not draw labels yet.
struct OverlayLabel: Sendable {
    var text: String
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    /// Points (multiply by the context's contentScale for pixels).
    var fontSize: Float
}

/// Batches are drawn in array order (back → front), e.g. lines, asterisms, stars, deep-sky, planets, satellites, labels.
enum OverlayBatch: Sendable {
    case segments([OverlaySegment])
    case points([OverlayPoint])
    case labels([OverlayLabel])
}

struct OverlayFrame: Sendable {
    var batches: [OverlayBatch] = []

    mutating func add(_ segments: [OverlaySegment]) {
        if !segments.isEmpty { batches.append(.segments(segments)) }
    }

    mutating func add(_ points: [OverlayPoint]) {
        if !points.isEmpty { batches.append(.points(points)) }
    }

    mutating func add(_ labels: [OverlayLabel]) {
        if !labels.isEmpty { batches.append(.labels(labels)) }
    }
}

/// Everything an overlay provider needs to place sky objects on the current frame.
struct OverlayContext: Sendable {
    /// Host time (CACurrentMediaTime base) the attitude belongs to: the camera frame's capture time, or the
    /// display time in sky-only mode.
    var hostTime: Double
    /// Date to compute the sky for (wall clock + time offset, or the fixed-sky preset).
    var skyDate: Date
    var observer: ObserverLocation?
    /// Core Motion reference (X north, Y west, Z up) → device frame, tap-to-align correction included.
    var deviceFromReference: simd_double3x3
    var camera: CameraGeometry
    /// 0 = day … 1 = night.
    var lighting: Double
    var isSkyOnly: Bool
    /// Screen pixels per point.
    var contentScale: Double

    var cameraFromReference: simd_double3x3 { CameraGeometry.cameraFromDevice * deviceFromReference }

    /// Optical axis (centre of the camera image) in the reference frame.
    var viewDirection: SIMD3<Double> { deviceFromReference.transpose * SIMD3(0, 0, -1) }

    func screenPoint(reference v: SIMD3<Double>) -> SIMD2<Double>? {
        camera.project(camera: cameraFromReference * v)
    }

    func segment(reference a: SIMD3<Double>, _ b: SIMD3<Double>) -> (a: SIMD2<Double>, b: SIMD2<Double>, phase: Double)? {
        let m = cameraFromReference
        return camera.segment(camera: m * a, m * b)
    }

    /// Unit reference-frame ray under a screen pixel (e.g. a tap).
    func referenceDirection(screen p: SIMD2<Double>) -> SIMD3<Double> {
        deviceFromReference.transpose * camera.deviceRay(screen: p)
    }

    /// Horizon (ENU) direction → Core Motion reference: (E, N, U) ↦ (N, −E, U).
    static func referenceDirection(azimuthDegrees az: Double, altitudeDegrees alt: Double) -> SIMD3<Double> {
        let a = az * .pi / 180, h = alt * .pi / 180
        return SIMD3(cos(a) * cos(h), -sin(a) * cos(h), sin(h))
    }

    /// Azimuth (degrees east of north, 0…360) and altitude of a reference-frame direction.
    static func horizontal(reference v: SIMD3<Double>) -> (azimuth: Double, altitude: Double) {
        let u = normalize(v)
        var az = atan2(-u.y, u.x) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, asin(max(-1, min(1, u.z))) * 180 / .pi)
    }
}

typealias OverlayProvider = @MainActor (OverlayContext) -> OverlayFrame
