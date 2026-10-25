import Observation
import simd

/// Drag-to-look: a synthetic attitude with the phone upright (portrait) looking at an azimuth/altitude.
@MainActor
@Observable
final class LookController {
    static let altitudeLimit = 89.5

    /// Degrees east of north.
    var azimuth: Double
    var altitude: Double

    init(azimuth: Double = FixedSkyPreset.azimuth, altitude: Double = FixedSkyPreset.altitude) {
        self.azimuth = azimuth
        self.altitude = altitude
    }

    /// Grab-the-sky: dragging right turns the view left, dragging down tilts it up.
    func pan(byPixels delta: SIMD2<Double>, radiansPerPixel: Double) {
        let degreesPerPixel = radiansPerPixel * 180 / .pi
        azimuth = (azimuth - delta.x * degreesPerPixel).truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }
        altitude = min(max(altitude + delta.y * degreesPerPixel, -Self.altitudeLimit), Self.altitudeLimit)
    }

    var deviceFromReference: simd_double3x3 {
        Self.deviceFromReference(azimuth: azimuth, altitude: altitude)
    }

    /// Rear camera (device −Z) toward (azimuth, altitude), top of the phone (device +Y) toward the zenith side.
    static func deviceFromReference(azimuth: Double, altitude: Double) -> simd_double3x3 {
        let forward = OverlayContext.referenceDirection(azimuthDegrees: azimuth, altitudeDegrees: altitude)
        let up = OverlayContext.referenceDirection(azimuthDegrees: azimuth, altitudeDegrees: altitude + 90)
        let right = cross(forward, up)
        let referenceFromDevice = simd_double3x3(columns: (right, up, -forward))
        return referenceFromDevice.transpose
    }
}

/// Exponential slerp toward the measured attitude. Only for sky-only mode, where no camera image has to match.
struct AttitudeSmoother {
    var timeConstant = 0.12
    private var state: simd_quatd?
    private var lastTime: Double?

    mutating func update(_ target: simd_quatd, at time: Double) -> simd_quatd {
        guard let current = state, let last = lastTime, time > last else {
            state = target
            lastTime = time
            return target
        }
        let alpha = 1 - exp(-(time - last) / timeConstant)
        let next = simd_slerp(current, target, alpha)
        state = next
        lastTime = time
        return next
    }

    mutating func reset() {
        state = nil
        lastTime = nil
    }
}
