import Foundation
import Observation
import QuartzCore
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

/// The reference-side correction between Core Motion's attitude and the stars, owned by SkyCore's `HeadingFilter`
/// (tap, snapped-tap, multi-star and plate-solve fixes in; a slowly drifting yaw plus a fixed tilt out), persisted
/// across launches. The drawn attitude is `boresight · coreMotion · correction`: only the correction is estimated, and it
/// never touches the gyro-rate content of the orientation.
@MainActor
@Observable
final class HeadingAlignment {
    private static let storageKey = "headingFilter"
    /// Alignment is suggested again once the filter's accuracy has grown past this, degrees.
    static let realignSigma = 2.0

    private struct Stored: Codable {
        var filter: HeadingFilter
        var savedAt: Date
    }

    private(set) var filter: HeadingFilter
    private(set) var headingAccuracy: Double? = nil
    private(set) var observations: [StarObservation] = []
    private(set) var lastMultiStar: MultiStarAligner.Solution? = nil
    private(set) var accuracyDegrees: Double
    @ObservationIgnored private(set) var boresight = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))

    init() {
        let now = CACurrentMediaTime()
        var restored = HeadingFilter(epoch: now)
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            restored = stored.filter
            restored.resume(atHostTime: now, afterElapsed: Date().timeIntervalSince(stored.savedAt))
        }
        filter = restored
        accuracyDegrees = restored.sigmaDegrees(at: now)
    }

    var isAligned: Bool { filter.isAligned }
    var yawCorrection: Double { filter.yaw(at: CACurrentMediaTime()) }
    var suggestsRealign: Bool { isAligned && accuracyDegrees > Self.realignSigma }

    func setBoresight(_ rotation: simd_quatd) {
        boresight = rotation
    }

    /// Reference-side correction at `hostTime`.
    func correction(at hostTime: Double) -> simd_quatd { filter.correction(at: hostTime) }

    /// `boresight · coreMotion · correction`.
    func drawnAttitude(coreMotion q: simd_quatd, at hostTime: Double) -> simd_quatd {
        (boresight * q * filter.correction(at: hostTime)).normalized
    }

    func apply(to deviceFromReference: simd_double3x3, at hostTime: Double) -> simd_double3x3 {
        simd_double3x3(drawnAttitude(coreMotion: simd_quatd(deviceFromReference), at: hostTime))
    }

    /// Ingests a fix (`coreMotion` = raw attitude at `fix.hostTime`), refreshes the accuracy and saves.
    func ingest(_ fix: StarFix, coreMotion: simd_quatd, cumulativeTurn: Double) {
        filter.advance(cumulativeTurn: cumulativeTurn)
        filter.ingest(fix, coreMotion: coreMotion, boresight: boresight)
        accuracyDegrees = filter.sigmaDegrees(at: fix.hostTime)
        persist()
    }

    /// Adds a star seen by the camera; returns the 3-axis solution once two or more recent, separated stars exist.
    func add(_ observation: StarObservation, now: Double) -> MultiStarAligner.Solution? {
        observations.append(observation)
        observations.removeAll { now - $0.hostTime > MultiStarAligner.maxAge }
        if observations.count > 12 { observations.removeFirst(observations.count - 12) }
        lastMultiStar = MultiStarAligner.solve(observations, now: now)
        return lastMultiStar
    }

    func update(headingAccuracy current: Double?, now: Double, cumulativeTurn: Double) {
        headingAccuracy = current
        if !filter.isAligned, let current { filter.setCompassAccuracy(degrees: current) }
        filter.advance(cumulativeTurn: cumulativeTurn)
        accuracyDegrees = filter.sigmaDegrees(at: now)
    }

    func reset() {
        filter.reset(epoch: CACurrentMediaTime())
        observations = []
        lastMultiStar = nil
        accuracyDegrees = filter.sigmaDegrees(at: CACurrentMediaTime())
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(filter: filter, savedAt: Date())) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
