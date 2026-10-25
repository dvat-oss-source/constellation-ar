import Foundation
import simd

/// Re-projects a camera frame captured at one attitude so that it lines up with the sky drawn at another:
/// a pure-rotation homography `K·R·K⁻¹`, plus a first-order rolling-shutter term (each buffer row was exposed at its own
/// instant, and the rotation between rows is taken as constant over the readout).
///
/// The shader runs `sensorPixel(forDisplayPixel:)` per fragment, with `cameraFromDisplay`, `rowRotation` and the
/// intrinsics as uniforms.
public struct FrameWarp: Sendable {
    /// Display-time camera ray → camera ray at the frame's reference (centre-row) time.
    public var cameraFromDisplay: simd_double3x3
    /// Camera-frame rotation vector accumulated over the whole readout, top row to bottom row (zero = global shutter).
    public var rowRotation: SIMD3<Double>
    public var intrinsics: CameraIntrinsics

    public init(cameraFromDisplay: simd_double3x3, rowRotation: SIMD3<Double>, intrinsics: CameraIntrinsics) {
        self.cameraFromDisplay = cameraFromDisplay
        self.rowRotation = rowRotation
        self.intrinsics = intrinsics
    }

    /// `attitude(t)` is the device attitude (`deviceFromReference`, everything the renderer applies included) at host time
    /// `t`; `frameTime` is when the frame's centre row was exposed. `readoutSeconds` is signed (see `TimingCalibration`).
    public init(frameTime: Double, displayAttitude: simd_quatd, readoutSeconds: Double,
                intrinsics: CameraIntrinsics, attitude: (Double) -> simd_quatd) {
        let d = CameraPose.deviceToCamera
        let reference = attitude(frameTime)
        let relative = simd_double3x3(reference) * simd_double3x3(displayAttitude).transpose
        cameraFromDisplay = d * relative * d.transpose
        if readoutSeconds == 0 {
            rowRotation = .zero
        } else {
            let top = attitude(frameTime - readoutSeconds / 2), bottom = attitude(frameTime + readoutSeconds / 2)
            rowRotation = d * Rotations.rotationVector((bottom * top.inverse).normalized)
        }
        self.intrinsics = intrinsics
    }

    /// Where in the captured frame (buffer pixels) the content shown at `display` (buffer-pixel frame of the display
    /// attitude) comes from.
    public func sensorPixel(forDisplayPixel display: SIMD2<Double>) -> SIMD2<Double> {
        let i = intrinsics
        let ray = cameraFromDisplay * SIMD3((display.x - i.cx) / i.fx, (display.y - i.cy) / i.fy, 1)
        var pixel = SIMD2(i.fx * ray.x / ray.z + i.cx, i.fy * ray.y / ray.z + i.cy)
        guard simd_length(rowRotation) > 0 else { return pixel }
        for _ in 0..<3 {
            let s = pixel.y / i.bufferHeight - 0.5
            let c = Rotations.quaternion(rotationVector: rowRotation * s).act(ray)
            pixel = SIMD2(i.fx * c.x / c.z + i.cx, i.fy * c.y / c.z + i.cy)
        }
        return pixel
    }

    /// Display pixel where content captured at `sensor` should be drawn (the inverse of `sensorPixel`).
    public func displayPixel(forSensorPixel sensor: SIMD2<Double>) -> SIMD2<Double> {
        let i = intrinsics
        let s = sensor.y / i.bufferHeight - 0.5
        let rowCorrected = Rotations.quaternion(rotationVector: rowRotation * s)
        let ray = SIMD3((sensor.x - i.cx) / i.fx, (sensor.y - i.cy) / i.fy, 1)
        let atReference = rowCorrected.inverse.act(ray)
        let display = cameraFromDisplay.transpose * atReference
        return SIMD2(i.fx * display.x / display.z + i.cx, i.fy * display.y / display.z + i.cy)
    }
}
