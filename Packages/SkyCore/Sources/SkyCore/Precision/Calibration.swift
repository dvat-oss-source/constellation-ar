import Foundation
import simd

/// What `tools/analyze_session.py` measures from a recorded pan.
public struct TimingCalibration: Sendable, Codable, Equatable {
    /// Added to a frame's host timestamp (mid-exposure assumed) to get the instant the frame's centre row was exposed.
    public var offsetSeconds: Double
    /// Time from the first (top) to the last (bottom) buffer row; negative when the bottom row is exposed first.
    public var readoutSeconds: Double

    public init(offsetSeconds: Double, readoutSeconds: Double) {
        self.offsetSeconds = offsetSeconds
        self.readoutSeconds = readoutSeconds
    }

    public static let none = TimingCalibration(offsetSeconds: 0, readoutSeconds: 0)
}

/// Residual radial distortion in normalised image coordinates (x/z, y/z relative to the principal point):
/// `p_distorted = p · (1 + k1 r² + k2 r⁴)`.
public struct RadialDistortion: Sendable, Codable, Equatable {
    public var k1: Double
    public var k2: Double

    public init(k1: Double, k2: Double = 0) {
        self.k1 = k1
        self.k2 = k2
    }

    @inlinable public func distort(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let r2 = p.x * p.x + p.y * p.y
        return p * (1 + r2 * (k1 + k2 * r2))
    }

    /// Fixed-point inverse; converges quickly for the few-percent distortions this models.
    public func undistort(_ d: SIMD2<Double>) -> SIMD2<Double> {
        var p = d
        for _ in 0..<8 {
            let r2 = p.x * p.x + p.y * p.y
            p = d / (1 + r2 * (k1 + k2 * r2))
        }
        return p
    }
}

/// Refinements to Apple's per-frame intrinsics plus the camera's fixed misalignment to the device.
public struct LensCalibration: Sendable, Codable, Equatable {
    public var focalScaleX: Double
    public var focalScaleY: Double
    /// Principal-point shifts as fractions of the buffer width / height.
    public var principalShiftX: Double
    public var principalShiftY: Double
    public var distortion: RadialDistortion
    /// Rotation vector (radians) of the camera's true orientation relative to the nominal one, expressed in the
    /// camera frame: `trueCameraFromReference = exp(boresight) · nominalCameraFromReference`.
    public var boresight: SIMD3<Double>

    public init(focalScaleX: Double = 1, focalScaleY: Double = 1, principalShiftX: Double = 0, principalShiftY: Double = 0,
                distortion: RadialDistortion = RadialDistortion(k1: 0), boresight: SIMD3<Double> = .zero) {
        self.focalScaleX = focalScaleX
        self.focalScaleY = focalScaleY
        self.principalShiftX = principalShiftX
        self.principalShiftY = principalShiftY
        self.distortion = distortion
        self.boresight = boresight
    }

    public static let identity = LensCalibration()

    public func applied(to i: CameraIntrinsics) -> CameraIntrinsics {
        CameraIntrinsics(fx: i.fx * focalScaleX, fy: i.fy * focalScaleY,
                         cx: i.cx + principalShiftX * i.bufferWidth, cy: i.cy + principalShiftY * i.bufferHeight,
                         bufferWidth: i.bufferWidth, bufferHeight: i.bufferHeight)
    }

    public var hasDistortion: Bool { distortion.k1 != 0 || distortion.k2 != 0 }

    /// Active rotation in the camera frame.
    public var boresightRotation: simd_quatd { Rotations.quaternion(rotationVector: boresight) }

    /// The same misalignment as a device-frame rotation `Dᵀ·B·D`: the renderer draws with
    /// `deviceFromReference = boresightInDevice · coreMotion · correction`.
    public var boresightInDevice: simd_quatd {
        let d = simd_quatd(CameraPose.deviceToCamera)
        return (d.inverse * boresightRotation * d).normalized
    }
}

/// The JSON the app loads (Documents/calibration.json, else the bundled one). Each tool fills in its own section.
public struct PrecisionCalibration: Sendable, Codable, Equatable {
    public var timing: TimingCalibration?
    public var lens: LensCalibration?

    public init(timing: TimingCalibration? = nil, lens: LensCalibration? = nil) {
        self.timing = timing
        self.lens = lens
    }

    public static func decode(_ data: Data) throws -> PrecisionCalibration {
        try JSONDecoder().decode(PrecisionCalibration.self, from: data)
    }
}

public enum Rotations {
    public static func quaternion(rotationVector v: SIMD3<Double>) -> simd_quatd {
        let angle = simd_length(v)
        guard angle > 1e-15 else { return simd_quatd(ix: v.x / 2, iy: v.y / 2, iz: v.z / 2, r: 1).normalized }
        return simd_quatd(angle: angle, axis: v / angle)
    }

    public static func rotationVector(_ q: simd_quatd) -> SIMD3<Double> {
        let q = q.real < 0 ? simd_quatd(vector: -q.vector) : q
        let s = simd_length(q.imag)
        guard s > 1e-15 else { return 2 * q.imag }
        return q.imag / s * (2 * atan2(s, q.real))
    }
}
