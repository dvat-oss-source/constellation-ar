import CoreMotion
import QuartzCore
import Synchronization
import simd

struct MotionSample: Sendable {
    /// CMLogItem.timestamp: host clock seconds, same base as CACurrentMediaTime().
    var timestamp: Double
    /// CMAttitude.rotationMatrix exactly as delivered (convention settled by RotationConventionTest).
    var rawMatrix: simd_double3x3
    var gravity: SIMD3<Double>
    /// CMMagneticFieldCalibrationAccuracy raw value: −1 uncalibrated, 0 low, 1 medium, 2 high.
    var magneticAccuracy: Int32
    /// Degrees from true north.
    var heading: Double
    var receivedAt: Double

    init(_ motion: CMDeviceMotion, receivedAt: Double) {
        let m = motion.attitude.rotationMatrix
        timestamp = motion.timestamp
        rawMatrix = simd_double3x3(rows: [SIMD3(m.m11, m.m12, m.m13), SIMD3(m.m21, m.m22, m.m23), SIMD3(m.m31, m.m32, m.m33)])
        gravity = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        magneticAccuracy = motion.magneticField.accuracy.rawValue
        heading = motion.heading
        self.receivedAt = receivedAt
    }
}

/// Orientation of the device: maps Core Motion reference vectors (X north, Y west, Z up) into the device frame.
struct Attitude: Sendable {
    var timestamp: Double
    var deviceFromReference: simd_quatd

    var matrix: simd_double3x3 { simd_double3x3(deviceFromReference) }
}

/// Ring buffer of device-motion samples; attitude at any host time is interpolated (slerp), never smoothed.
final class AttitudeBuffer: Sendable {
    static let capacity = 512

    private struct State {
        var samples: [(time: Double, rotation: simd_quatd)] = []
        var head = 0
        var latest: MotionSample?
        var test = RotationConventionTest()
        var minimumDeliveryLag = Double.infinity
    }

    private let state = Mutex(State())

    func append(_ sample: MotionSample) {
        state.withLock { s in
            s.test.add(matrix: sample.rawMatrix, gravity: sample.gravity)
            let rotation = simd_quatd(sample.rawMatrix)
            let entry = (time: sample.timestamp, rotation: rotation)
            if s.samples.count < Self.capacity {
                s.samples.append(entry)
            } else {
                s.samples[s.head] = entry
                s.head = (s.head + 1) % Self.capacity
            }
            s.latest = sample
            s.minimumDeliveryLag = min(s.minimumDeliveryLag, sample.receivedAt - sample.timestamp)
        }
    }

    var latestSample: MotionSample? { state.withLock { $0.latest } }
    var conventionTest: RotationConventionTest { state.withLock { $0.test } }

    /// Smallest (handler time − CMLogItem.timestamp) seen; a few ms confirms both are on the host clock.
    var minimumDeliveryLag: Double? {
        let lag = state.withLock { $0.minimumDeliveryLag }
        return lag.isFinite ? lag : nil
    }

    var latestAttitude: Attitude? {
        state.withLock { s in
            guard let latest = s.latest else { return nil }
            return Attitude(timestamp: latest.timestamp, deviceFromReference: Self.oriented(simd_quatd(latest.rawMatrix), s.test.convention))
        }
    }

    /// Attitude at `hostTime`, interpolated between the neighbouring samples; clamped to the oldest/newest sample.
    func attitude(at hostTime: Double) -> Attitude? {
        state.withLock { s in
            let count = s.samples.count
            guard count > 0 else { return nil }
            let convention = s.test.convention
            func sample(_ i: Int) -> (time: Double, rotation: simd_quatd) {
                s.samples[(s.head + i) % count]
            }
            let newest = sample(count - 1)
            if hostTime >= newest.time {
                return Attitude(timestamp: newest.time, deviceFromReference: Self.oriented(newest.rotation, convention))
            }
            var i = count - 2
            while i >= 0 {
                let earlier = sample(i)
                if earlier.time <= hostTime {
                    let later = sample(i + 1)
                    let span = later.time - earlier.time
                    let t = span > 0 ? (hostTime - earlier.time) / span : 0
                    let q = simd_slerp(earlier.rotation, later.rotation, t)
                    return Attitude(timestamp: hostTime, deviceFromReference: Self.oriented(q, convention))
                }
                i -= 1
            }
            let oldest = sample(0)
            return Attitude(timestamp: oldest.time, deviceFromReference: Self.oriented(oldest.rotation, convention))
        }
    }

    private static func oriented(_ raw: simd_quatd, _ convention: RotationConvention) -> simd_quatd {
        convention == .matrixIsDeviceFromReference ? raw : raw.inverse
    }
}
