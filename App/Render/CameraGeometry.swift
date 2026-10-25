import SkyCore
import simd

/// Camera and display geometry for one frame (no sky math).
///
/// Frames: device (X right, Y toward the top of the phone, Z out of the screen); camera (x right and y down in the
/// native landscape buffer, z along the rear camera's view = device −Z); sensor pixels (buffer, origin upper-left);
/// screen pixels (portrait drawable, origin upper-left). All projection for drawing, tap-to-align and the screen-centre
/// lookup goes through SkyCore's `Projector`, built from `intrinsics` and `mapping`; the matrices here only feed the
/// shaders and are derived from the same `mapping`.
struct CameraGeometry: Sendable {
    let intrinsics: CameraIntrinsics
    let drawableSize: SIMD2<Double>
    let mapping: ScreenMapping
    /// Homogeneous sensor px → screen px: the buffer rotated 90° clockwise and aspect-filled into the drawable.
    let screenFromSensor: simd_double3x3
    let sensorFromScreen: simd_double3x3
    /// Screen pixels per sensor pixel.
    let scale: Double

    init(intrinsics: CameraIntrinsics, drawableSize: SIMD2<Double>) {
        self.intrinsics = intrinsics
        self.drawableSize = drawableSize
        mapping = ScreenMapping.portraitAspectFill(bufferWidth: intrinsics.referenceSize.x, bufferHeight: intrinsics.referenceSize.y,
                                                   viewWidth: drawableSize.x, viewHeight: drawableSize.y)
        scale = mapping.scale
        let l = mapping.linear, o = mapping.offset
        screenFromSensor = simd_double3x3(rows: [SIMD3(l[0][0], l[1][0], o.x), SIMD3(l[0][1], l[1][1], o.y), SIMD3(0, 0, 1)])
        sensorFromScreen = screenFromSensor.inverse
    }

    /// The intrinsics in SkyCore's type (the app's own `CameraIntrinsics` carries the measured/nominal flag).
    var skyIntrinsics: SkyCore.CameraIntrinsics {
        SkyCore.CameraIntrinsics(fx: intrinsics.fx, fy: intrinsics.fy, cx: intrinsics.cx, cy: intrinsics.cy,
                                 bufferWidth: intrinsics.referenceSize.x, bufferHeight: intrinsics.referenceSize.y)
    }

    var intrinsicMatrix: simd_double3x3 {
        simd_double3x3(rows: [SIMD3(intrinsics.fx, 0, intrinsics.cx), SIMD3(0, intrinsics.fy, intrinsics.cy), SIMD3(0, 0, 1)])
    }

    /// Radians per screen pixel at the centre (for drag-to-look and pixel-size tolerances).
    var radiansPerPixel: Double { 1 / (intrinsics.fy * scale) }

    /// Homogeneous screen px → unnormalised reference-frame ray, for per-pixel sky shading.
    func referenceFromScreen(deviceFromReference r: simd_double3x3) -> simd_double3x3 {
        r.transpose * CameraPose.deviceToCamera.transpose * intrinsicMatrix.inverse * sensorFromScreen
    }
}
