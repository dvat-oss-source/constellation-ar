import Observation
import simd

/// Compass quality from CLHeading.headingAccuracy and the magnetometer calibration, with hysteresis.
struct HeadingQuality: Sendable, Equatable {
    static let showHintAbove = 25.0
    static let hideHintBelow = 15.0

    var accuracyDegrees: Double?
    var magneticAccuracy: Int32?
    var needsFigure8 = false

    mutating func update(accuracyDegrees: Double?, magneticAccuracy: Int32?) {
        self.accuracyDegrees = accuracyDegrees
        self.magneticAccuracy = magneticAccuracy
        let uncalibrated = magneticAccuracy == -1
        if needsFigure8 {
            needsFigure8 = uncalibrated || (accuracyDegrees ?? .infinity) > Self.hideHintBelow
        } else {
            needsFigure8 = uncalibrated || (accuracyDegrees ?? .infinity) > Self.showHintAbove
        }
    }
}

/// Tap-to-align yaw correction. The correction is a rotation about the vertical (reference +Z) applied on the
/// reference side, so it fixes compass heading without touching the gravity-derived tilt.
@MainActor
@Observable
final class HeadingAlignment {
    /// Radians, counter-clockwise seen from above (from north toward west).
    private(set) var yawCorrection: Double = 0
    private(set) var isAligned = false
    private(set) var accuracyAtAlignment: Double? = nil
    private(set) var suggestsRealign = false

    /// `tapDirection` is the reference-frame ray under the finger, computed with the currently corrected attitude;
    /// `objectDirection` is where the chosen catalog object really is (reference frame).
    func align(tapDirection t: SIMD3<Double>, objectDirection s: SIMD3<Double>, headingAccuracy: Double?) {
        let delta = atan2(t.y, t.x) - atan2(s.y, s.x)
        yawCorrection = remainder(yawCorrection + delta, 2 * .pi)
        isAligned = true
        accuracyAtAlignment = headingAccuracy
        suggestsRealign = false
    }

    func reset() {
        yawCorrection = 0
        isAligned = false
        accuracyAtAlignment = nil
        suggestsRealign = false
    }

    func update(headingAccuracy current: Double?) {
        guard isAligned else { return }
        guard let current else {
            suggestsRealign = true
            return
        }
        let reference = accuracyAtAlignment ?? current
        suggestsRealign = current > max(reference * 1.5, reference + 10)
    }

    func apply(to deviceFromReference: simd_double3x3) -> simd_double3x3 {
        guard yawCorrection != 0 else { return deviceFromReference }
        let c = cos(yawCorrection), s = sin(yawCorrection)
        let rz = simd_double3x3(rows: [SIMD3(c, -s, 0), SIMD3(s, c, 0), SIMD3(0, 0, 1)])
        return deviceFromReference * rz
    }
}
