import Foundation
import simd

/// Pinhole intrinsics in pixels of the native (landscape) sensor buffer, origin upper-left, +v down.
public struct CameraIntrinsics: Sendable, Hashable, Codable {
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public var bufferWidth: Double, bufferHeight: Double

    public init(fx: Double, fy: Double, cx: Double, cy: Double, bufferWidth: Double, bufferHeight: Double) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.bufferWidth = bufferWidth; self.bufferHeight = bufferHeight
    }

    /// From AVFoundation's column-major `matrix_float3x3` [[fx,0,0],[0,fy,0],[cx,cy,1]].
    public init(matrix k: simd_float3x3, bufferWidth: Double, bufferHeight: Double) {
        self.init(fx: Double(k.columns.0.x), fy: Double(k.columns.1.y),
                  cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
                  bufferWidth: bufferWidth, bufferHeight: bufferHeight)
    }

    /// Synthetic intrinsics for a horizontal (long-side) field of view, principal point centred.
    public static func fieldOfView(horizontalDegrees: Double, bufferWidth: Double, bufferHeight: Double) -> CameraIntrinsics {
        let f = (bufferWidth / 2) / tan(Angle.radians(horizontalDegrees) / 2)
        return CameraIntrinsics(fx: f, fy: f, cx: bufferWidth / 2, cy: bufferHeight / 2,
                                bufferWidth: bufferWidth, bufferHeight: bufferHeight)
    }
}

/// Affine map from sensor-buffer pixels to view points: `screen = linear * pixel + offset`.
public struct ScreenMapping: Sendable {
    public var linear: simd_double2x2
    public var offset: SIMD2<Double>
    public var viewSize: SIMD2<Double>

    public init(linear: simd_double2x2, offset: SIMD2<Double>, viewSize: SIMD2<Double>) {
        self.linear = linear
        self.offset = offset
        self.viewSize = viewSize
    }

    /// The native landscape buffer rotated 90° clockwise to portrait, then aspect-filled (centred, cropped) into
    /// a portrait view of `viewWidth × viewHeight` points.
    public static func portraitAspectFill(bufferWidth wb: Double, bufferHeight hb: Double,
                                          viewWidth w: Double, viewHeight h: Double) -> ScreenMapping {
        let s = max(w / hb, h / wb)
        return ScreenMapping(
            linear: simd_double2x2(columns: (SIMD2(0, s), SIMD2(-s, 0))),
            offset: SIMD2(s * hb / 2 + w / 2, h / 2 - s * wb / 2),
            viewSize: SIMD2(w, h)
        )
    }

    /// Identity mapping (screen = buffer pixels), for tests and landscape debug views.
    public static func identity(bufferWidth: Double, bufferHeight: Double) -> ScreenMapping {
        ScreenMapping(linear: matrix_identity_double2x2, offset: .zero, viewSize: SIMD2(bufferWidth, bufferHeight))
    }

    @inlinable public func screen(fromPixel p: SIMD2<Double>) -> SIMD2<Double> { linear * p + offset }
    @inlinable public func pixel(fromScreen s: SIMD2<Double>) -> SIMD2<Double> { linear.inverse * (s - offset) }

    /// Points per pixel.
    public var scale: Double { abs(linear.determinant).squareRoot() }
}

/// Orientation chain ENU → Core Motion reference (X north, Y west, Z up) → heading correction → device → camera.
public struct CameraPose: Sendable {
    /// ENU (E, N, U) → Core Motion `.xTrueNorthZVertical` reference (N, −E, U).
    public static let enuToReference = simd_double3x3(rows: [
        SIMD3(0, 1, 0),
        SIMD3(-1, 0, 0),
        SIMD3(0, 0, 1),
    ])
    /// Device (X right, Y top, Z out of screen) → camera (x image-right, y image-down, z forward) for the rear
    /// camera's native landscape buffer, whose image-up is device +X.
    public static let deviceToCamera = simd_double3x3(rows: [
        SIMD3(0, -1, 0),
        SIMD3(-1, 0, 0),
        SIMD3(0, 0, -1),
    ])

    public var referenceToDevice: simd_double3x3
    public var headingCorrection: HeadingCorrection

    public init(referenceToDevice: simd_double3x3, headingCorrection: HeadingCorrection = .identity) {
        self.referenceToDevice = referenceToDevice
        self.headingCorrection = headingCorrection
    }

    public var enuToDevice: simd_double3x3 {
        referenceToDevice * headingCorrection.matrix * Self.enuToReference
    }

    public var enuToCamera: simd_double3x3 { Self.deviceToCamera * enuToDevice }

    /// A pose looking along `forward` (ENU) with the device's top tilted toward `up` (ENU), for tests/simulation.
    public static func looking(at forward: SIMD3<Double>, up: SIMD3<Double> = SIMD3(0, 0, 1)) -> CameraPose {
        let zDev = -simd_normalize(forward)
        var yDev = up - simd_dot(up, zDev) * zDev
        if simd_length(yDev) < 1e-9 { yDev = SIMD3(0, 1, 0) - simd_dot(SIMD3(0, 1, 0), zDev) * zDev }
        yDev = simd_normalize(yDev)
        let xDev = simd_cross(yDev, zDev)
        let enuToDevice = simd_double3x3(rows: [xDev, yDev, zDev])
        return CameraPose(referenceToDevice: enuToDevice * enuToReference.transpose)
    }
}

/// Per-frame projector from airless or apparent ENU directions to view points and back.
public struct Projector: Sendable {
    public let enuToCamera: simd_double3x3
    public let intrinsics: CameraIntrinsics
    public let mapping: ScreenMapping
    /// Camera-space z (for unit vectors) below which a point counts as behind the camera.
    public var nearZ: Double = 1e-3

    public init(pose: CameraPose, intrinsics: CameraIntrinsics, mapping: ScreenMapping) {
        self.enuToCamera = pose.enuToCamera
        self.intrinsics = intrinsics
        self.mapping = mapping
    }

    public init(enuToCamera: simd_double3x3, intrinsics: CameraIntrinsics, mapping: ScreenMapping) {
        self.enuToCamera = enuToCamera
        self.intrinsics = intrinsics
        self.mapping = mapping
    }

    @inlinable public func camera(enu v: SIMD3<Double>) -> SIMD3<Double> { enuToCamera * v }

    @inlinable public func pixel(camera c: SIMD3<Double>) -> SIMD2<Double>? {
        guard c.z > nearZ * simd_length(c) else { return nil }
        return SIMD2(intrinsics.fx * c.x / c.z + intrinsics.cx, intrinsics.fy * c.y / c.z + intrinsics.cy)
    }

    @inlinable func pixelUnchecked(camera c: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(intrinsics.fx * c.x / c.z + intrinsics.cx, intrinsics.fy * c.y / c.z + intrinsics.cy)
    }

    /// Sensor-native pixel, nil if the direction is behind the camera.
    public func pixel(enu v: SIMD3<Double>) -> SIMD2<Double>? { pixel(camera: camera(enu: v)) }

    /// View point, nil if the direction is behind the camera.
    public func screenPoint(enu v: SIMD3<Double>) -> SIMD2<Double>? {
        pixel(enu: v).map(mapping.screen(fromPixel:))
    }

    /// Unit ENU ray through a sensor pixel.
    public func ray(pixel p: SIMD2<Double>) -> SIMD3<Double> {
        let c = SIMD3((p.x - intrinsics.cx) / intrinsics.fx, (p.y - intrinsics.cy) / intrinsics.fy, 1)
        return simd_normalize(enuToCamera.transpose * c)
    }

    /// Unit ENU ray through a view point (e.g. a tap or the screen centre).
    public func ray(screenPoint s: SIMD2<Double>) -> SIMD3<Double> { ray(pixel: mapping.pixel(fromScreen: s)) }

    public var viewCenter: SIMD2<Double> { mapping.viewSize / 2 }

    public func isOnScreen(_ s: SIMD2<Double>, margin: Double = 0) -> Bool {
        s.x >= -margin && s.y >= -margin && s.x <= mapping.viewSize.x + margin && s.y <= mapping.viewSize.y + margin
    }

    /// Angular radius from the view centre to a view corner, radians.
    public var halfDiagonalAngle: Double {
        Angle.separation(ray(screenPoint: viewCenter), ray(screenPoint: .zero))
    }
}
