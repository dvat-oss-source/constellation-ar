import simd

/// Camera and display geometry for one frame (no sky math).
///
/// Frames: device (X right, Y toward the top of the phone, Z out of the screen); camera (x right and y down in the
/// native landscape buffer, z along the rear camera's view = device −Z); sensor pixels (buffer, origin upper-left);
/// screen pixels (portrait drawable, origin upper-left). The back camera's native buffer is upright with the phone
/// in landscape, home side right, so buffer +x points along device −Y and buffer +y along device −X.
struct CameraGeometry: Sendable {
    static let cameraFromDevice = simd_double3x3(rows: [SIMD3(0, -1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, -1)])
    static let nearPlane = 1e-3
    static let viewportMargin = 64.0

    let intrinsics: CameraIntrinsics
    let drawableSize: SIMD2<Double>
    /// Homogeneous sensor px → screen px: the buffer rotated 90° clockwise and aspect-filled into the drawable.
    let screenFromSensor: simd_double3x3
    let sensorFromScreen: simd_double3x3
    /// Screen pixels per sensor pixel.
    let scale: Double

    init(intrinsics: CameraIntrinsics, drawableSize: SIMD2<Double>) {
        self.intrinsics = intrinsics
        self.drawableSize = drawableSize
        let w = intrinsics.referenceSize.x, h = intrinsics.referenceSize.y
        let s = max(drawableSize.x / h, drawableSize.y / w)
        let ox = (drawableSize.x - s * h) / 2
        let oy = (drawableSize.y - s * w) / 2
        scale = s
        screenFromSensor = simd_double3x3(rows: [SIMD3(0, -s, ox + s * h), SIMD3(s, 0, oy), SIMD3(0, 0, 1)])
        sensorFromScreen = simd_double3x3(rows: [SIMD3(0, 1 / s, -oy / s), SIMD3(-1 / s, 0, h + ox / s), SIMD3(0, 0, 1)])
    }

    var intrinsicMatrix: simd_double3x3 {
        simd_double3x3(rows: [SIMD3(intrinsics.fx, 0, intrinsics.cx), SIMD3(0, intrinsics.fy, intrinsics.cy), SIMD3(0, 0, 1)])
    }

    /// Radians per screen pixel at the centre (for drag-to-look and pixel-size tolerances).
    var radiansPerPixel: Double { 1 / (intrinsics.fy * scale) }

    /// Screen pixel for a camera-frame vector, nil if it is not in front of the camera.
    func project(camera p: SIMD3<Double>) -> SIMD2<Double>? {
        guard p.z > Self.nearPlane else { return nil }
        let sensor = SIMD3(intrinsics.fx * p.x / p.z + intrinsics.cx, intrinsics.fy * p.y / p.z + intrinsics.cy, 1)
        let screen = screenFromSensor * sensor
        return SIMD2(screen.x, screen.y)
    }

    func project(device v: SIMD3<Double>) -> SIMD2<Double>? {
        project(camera: Self.cameraFromDevice * v)
    }

    /// Straight screen segment between two camera-frame directions: clipped at the near plane (a segment that
    /// passes behind the camera is shortened, not dropped), then clipped to the viewport plus a margin.
    /// `phase` is the screen distance from the unclipped start, for stable dash patterns (0 if that start is behind).
    func segment(camera a: SIMD3<Double>, _ b: SIMD3<Double>) -> (a: SIMD2<Double>, b: SIMD2<Double>, phase: Double)? {
        var a = a, b = b
        let near = Self.nearPlane * 2
        if a.z <= near, b.z <= near { return nil }
        let originalStart = a.z > near ? project(camera: a) : nil
        if a.z < near { a += (b - a) * ((near - a.z) / (b.z - a.z)) }
        if b.z < near { b += (a - b) * ((near - b.z) / (a.z - b.z)) }
        guard let pa = project(camera: a), let pb = project(camera: b) else { return nil }
        guard let (ca, cb) = clipToViewport(pa, pb) else { return nil }
        let phase = originalStart.map { length(ca - $0) } ?? 0
        return (ca, cb, phase)
    }

    /// Unit ray in the camera frame through a screen pixel.
    func cameraRay(screen p: SIMD2<Double>) -> SIMD3<Double> {
        let sensor = sensorFromScreen * SIMD3(p.x, p.y, 1)
        return normalize(SIMD3((sensor.x - intrinsics.cx) / intrinsics.fx, (sensor.y - intrinsics.cy) / intrinsics.fy, 1))
    }

    func deviceRay(screen p: SIMD2<Double>) -> SIMD3<Double> {
        Self.cameraFromDevice.transpose * cameraRay(screen: p)
    }

    /// Homogeneous screen px → unnormalised reference-frame ray, for per-pixel sky shading.
    func referenceFromScreen(deviceFromReference r: simd_double3x3) -> simd_double3x3 {
        r.transpose * Self.cameraFromDevice.transpose * intrinsicMatrix.inverse * sensorFromScreen
    }

    private func clipToViewport(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (SIMD2<Double>, SIMD2<Double>)? {
        let m = Self.viewportMargin
        let lower = SIMD2(-m, -m), upper = drawableSize + m
        let d = b - a
        var t0 = 0.0, t1 = 1.0
        for axis in 0..<2 {
            for (p, q) in [(-d[axis], a[axis] - lower[axis]), (d[axis], upper[axis] - a[axis])] {
                if p == 0 {
                    if q < 0 { return nil }
                } else {
                    let r = q / p
                    if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                    if t0 > t1 { return nil }
                }
            }
        }
        return (a + d * t0, a + d * t1)
    }
}
