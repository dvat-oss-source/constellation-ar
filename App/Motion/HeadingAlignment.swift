import Foundation
import Observation
import SkyCore
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

/// Tap-to-align yaw correction (SkyCore's `HeadingCorrection`), persisted across launches. A rotation about the
/// vertical (reference +Z) applied on the reference side, so it fixes compass heading without touching the
/// gravity-derived tilt.
@MainActor
@Observable
final class HeadingAlignment {
    private static let storageKey = "headingCorrection"

    private(set) var correction: HeadingCorrection
    private(set) var headingAccuracy: Double? = nil

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(HeadingCorrection.self, from: data) {
            correction = stored
        } else {
            correction = .identity
        }
    }

    /// Radians, counter-clockwise seen from above (from north toward west).
    var yawCorrection: Double { correction.yaw }
    var isAligned: Bool { correction.alignedAt != nil }
    var suggestsRealign: Bool { isAligned && correction.shouldSuggestRealign(currentHeadingAccuracy: headingAccuracy) }

    /// Adds the yaw `TapToAlign` computed for a tap; the delta is relative to the correction already applied.
    func align(yawDelta: Double, headingAccuracy: Double?, date: Date = Date()) {
        correction = correction.composed(withDelta: yawDelta, at: date, headingAccuracy: headingAccuracy)
        persist()
    }

    func reset() {
        correction = .identity
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    func update(headingAccuracy current: Double?) {
        headingAccuracy = current
    }

    func apply(to deviceFromReference: simd_double3x3) -> simd_double3x3 {
        guard correction.yaw != 0 else { return deviceFromReference }
        return deviceFromReference * correction.matrix
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(correction) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}
