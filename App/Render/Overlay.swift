import Foundation
import SkyCore
import simd

/// A round marker (star, planet, DSO, satellite). Screen pixels, origin upper-left. Layout matches `PointInstance`
/// in Shaders.metal (32 bytes) so arrays are copied to the GPU as-is.
struct OverlayPoint: Sendable {
    var position: SIMD2<Float>
    var radius: Float
    /// 0 = round marker with a soft halo. A Moon disc is `±(1 + illuminatedFraction)`: positive waxing (lit side
    /// on the right), negative waning.
    var style: Float
    /// Straight (non-premultiplied) RGBA.
    var color: SIMD4<Float>

    init(position: SIMD2<Float>, radius: Float, color: SIMD4<Float>, style: Float = 0) {
        self.position = position
        self.radius = radius
        self.color = color
        self.style = style
    }

    static func moonStyle(illuminatedFraction f: Double, waxing: Bool) -> Float {
        Float(1 + min(max(f, 0), 1)) * (waxing ? 1 : -1)
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

/// Text anchored at a screen point; drawn by the renderer from a cached glyph atlas.
struct OverlayLabel: Sendable {
    var text: String
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    /// Points (multiply by the context's contentScale for pixels).
    var fontSize: Float
    /// Which point of the text box sits on `position`: (0.5, 0.5) centres it, (0, 0.5) starts it at `position`.
    var anchor: SIMD2<Float> = SIMD2(0.5, 0.5)
    var bold = false
}

struct OverlayMeshVertex: Sendable {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

/// A textured triangle list (constellation artwork). `textureID` names a PNG in the bundle's artwork folder.
struct OverlayMesh: Sendable {
    var textureID: String
    var vertices: [OverlayMeshVertex]
    var alpha: Float
}

/// The Milky Way is shaded per pixel from an equirectangular ICRS level map.
struct OverlayMilkyWay: Sendable {
    /// Homogeneous screen px → ICRS ray.
    var icrsFromScreen: simd_float3x3
    var intensity: Float
}

/// Batches are drawn in array order (back → front), e.g. Milky Way, artwork, lines, asterisms, stars, deep-sky,
/// planets, satellites, labels.
enum OverlayBatch: Sendable {
    case segments([OverlaySegment])
    case points([OverlayPoint])
    case labels([OverlayLabel])
    case mesh(OverlayMesh)
    case milkyWay(OverlayMilkyWay)
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

    mutating func add(_ mesh: OverlayMesh) {
        if mesh.vertices.count >= 3 { batches.append(.mesh(mesh)) }
    }

    mutating func add(_ milkyWay: OverlayMilkyWay) {
        batches.append(.milkyWay(milkyWay))
    }
}

/// Everything an overlay provider needs to place sky objects on the current frame.
struct OverlayContext: Sendable {
    /// Host time (CACurrentMediaTime base) the attitude belongs to: the camera frame's capture time, or the
    /// display time in sky-only mode.
    var hostTime: Double
    /// When this frame will be shown; animations and the lock state run on this clock.
    var displayTime: Double
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
    /// ENU → camera → pixel → screen, from `deviceFromReference` and the frame's intrinsics.
    let projector: Projector

    init(hostTime: Double, displayTime: Double, skyDate: Date, observer: ObserverLocation?, deviceFromReference: simd_double3x3,
         camera: CameraGeometry, lighting: Double, isSkyOnly: Bool, contentScale: Double) {
        self.hostTime = hostTime
        self.displayTime = displayTime
        self.skyDate = skyDate
        self.observer = observer
        self.deviceFromReference = deviceFromReference
        self.camera = camera
        self.lighting = lighting
        self.isSkyOnly = isSkyOnly
        self.contentScale = contentScale
        projector = Projector(pose: CameraPose(referenceToDevice: deviceFromReference),
                              intrinsics: camera.skyIntrinsics, mapping: camera.mapping)
    }

    /// Ray through the centre of the screen in the reference frame.
    var viewDirection: SIMD3<Double> { Self.reference(enu: projector.ray(screenPoint: projector.viewCenter)) }

    func screenPoint(reference v: SIMD3<Double>) -> SIMD2<Double>? {
        projector.screenPoint(enu: Self.enu(reference: v))
    }

    func segment(reference a: SIMD3<Double>, _ b: SIMD3<Double>) -> (a: SIMD2<Double>, b: SIMD2<Double>, phase: Double)? {
        let ea = Self.enu(reference: a), eb = Self.enu(reference: b)
        guard let clipped = projector.clipSegment(ea, eb) else { return nil }
        var phase = 0.0
        if clipped.startT > 0, let origin = projector.screenPoint(enu: ea) { phase = simd_distance(clipped.start, origin) }
        return (clipped.start, clipped.end, phase)
    }

    /// Unit reference-frame ray under a screen pixel (e.g. a tap).
    func referenceDirection(screen p: SIMD2<Double>) -> SIMD3<Double> {
        Self.reference(enu: projector.ray(screenPoint: p))
    }

    /// Homogeneous screen px → unnormalised ENU ray, for per-pixel shading.
    var enuFromScreen: simd_double3x3 {
        let l = camera.mapping.linear.inverse, o = camera.mapping.offset
        let t = -(l * o)
        let pixelFromScreen = simd_double3x3(rows: [SIMD3(l[0][0], l[1][0], t.x), SIMD3(l[0][1], l[1][1], t.y), SIMD3(0, 0, 1)])
        return projector.enuToCamera.transpose * camera.intrinsicMatrix.inverse * pixelFromScreen
    }

    static func enu(reference v: SIMD3<Double>) -> SIMD3<Double> { CameraPose.enuToReference.transpose * v }
    static func reference(enu v: SIMD3<Double>) -> SIMD3<Double> { CameraPose.enuToReference * v }

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
