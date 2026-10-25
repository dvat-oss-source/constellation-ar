import Foundation
import simd

/// Yaw correction about the vertical, applied in the Core Motion reference frame between reference and device.
/// `yaw` is an active rotation of world directions from north toward west (counter-clockwise seen from above),
/// i.e. it lowers azimuths by `yaw`. Corrections about the same axis compose by adding.
public struct HeadingCorrection: Sendable, Hashable, Codable {
    public var yaw: Double
    public var alignedAt: Date?
    /// Heading accuracy (degrees) reported when the alignment was made, if known.
    public var headingAccuracyAtAlignment: Double?

    public static let identity = HeadingCorrection(yaw: 0)

    public init(yaw: Double, alignedAt: Date? = nil, headingAccuracyAtAlignment: Double? = nil) {
        self.yaw = yaw
        self.alignedAt = alignedAt
        self.headingAccuracyAtAlignment = headingAccuracyAtAlignment
    }

    public var matrix: simd_double3x3 { Rotation.rz(-yaw) }

    public func composed(withDelta delta: Double, at date: Date? = nil, headingAccuracy: Double? = nil) -> HeadingCorrection {
        HeadingCorrection(yaw: Angle.wrapPi(yaw + delta), alignedAt: date ?? alignedAt,
                          headingAccuracyAtAlignment: headingAccuracy ?? headingAccuracyAtAlignment)
    }

    /// Suggest re-aligning when heading accuracy has degraded markedly since alignment (or is poor and no
    /// alignment exists).
    public func shouldSuggestRealign(currentHeadingAccuracy current: Double?, poorThreshold: Double = 15) -> Bool {
        guard let current, current >= 0 else { return false }
        guard alignedAt != nil, let base = headingAccuracyAtAlignment else { return current > poorThreshold }
        return current > max(2 * base, base + 5) || current > max(poorThreshold, base + 5)
    }
}

public struct AlignmentCandidate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case star(hip: Int)
        case sun, moon
        case planet(SolarSystemBody)
    }

    public var kind: Kind
    public var name: String
    public var magnitude: Double
    /// Apparent (refracted) ENU direction, as drawn.
    public var enu: SIMD3<Double>

    public init(kind: Kind, name: String, magnitude: Double, enu: SIMD3<Double>) {
        self.kind = kind
        self.name = name
        self.magnitude = magnitude
        self.enu = enu
    }
}

public enum AlignmentMode: Sendable, Hashable {
    case day, twilight, night

    public init(daylight: DaylightState) {
        switch daylight.phase {
        case .day: self = .day
        case .night: self = .night
        default: self = .twilight
        }
    }
}

public struct AlignmentResult: Sendable, Hashable {
    public var candidate: AlignmentCandidate
    /// Angle between the tap ray and the object before correction, radians.
    public var separation: Double
    /// Yaw added by this alignment, radians.
    public var yawDelta: Double
    public var correction: HeadingCorrection
    /// Remaining angle between the tap ray and the object after the yaw-only correction (its altitude
    /// difference, which yaw cannot remove), radians.
    public var residual: Double
}

public enum TapToAlign {
    public static let defaultMaxSeparation = Angle.radians(5)

    public static func isEligible(_ c: AlignmentCandidate, mode: AlignmentMode) -> Bool {
        let nightOK: Bool, dayOK: Bool
        switch c.kind {
        case .star: nightOK = c.magnitude < 2; dayOK = false
        case .moon: nightOK = true; dayOK = true
        case .planet(let b): nightOK = b == .venus || b == .jupiter; dayOK = nightOK
        case .sun: nightOK = false; dayOK = true
        }
        switch mode {
        case .night: return nightOK
        case .day: return dayOK
        case .twilight: return nightOK || dayOK
        }
    }

    /// Picks the nearest eligible object within `maxSeparation` of the tap ray and returns the yaw correction that
    /// puts it under the finger. `pose` is the pose used to draw the frame (including its current correction).
    public static func align(tap: SIMD2<Double>, pose: CameraPose, intrinsics: CameraIntrinsics, mapping: ScreenMapping,
                             candidates: [AlignmentCandidate], mode: AlignmentMode,
                             maxSeparation: Double = defaultMaxSeparation,
                             date: Date? = nil, headingAccuracy: Double? = nil) -> AlignmentResult? {
        let projector = Projector(pose: pose, intrinsics: intrinsics, mapping: mapping)
        let ray = projector.ray(screenPoint: tap)
        var best: (AlignmentCandidate, Double)?
        for c in candidates where isEligible(c, mode: mode) && c.enu.z > -0.05 {
            let sep = Angle.separation(ray, c.enu)
            if sep <= maxSeparation && sep < (best?.1 ?? .infinity) { best = (c, sep) }
        }
        guard let (candidate, separation) = best else { return nil }
        let delta = yawDelta(object: candidate.enu, tapRay: ray)
        let rotated = Rotation.rz(-delta) * CameraPose.enuToReference * candidate.enu
        let objectAfter = CameraPose.enuToReference.transpose * rotated
        return AlignmentResult(
            candidate: candidate,
            separation: separation,
            yawDelta: delta,
            correction: pose.headingCorrection.composed(withDelta: delta, at: date, headingAccuracy: headingAccuracy),
            residual: Angle.separation(objectAfter, ray)
        )
    }

    /// Yaw (active, north→west) that brings `object`'s azimuth onto `tapRay`'s azimuth. Both ENU.
    public static func yawDelta(object: SIMD3<Double>, tapRay: SIMD3<Double>) -> Double {
        let azObject = atan2(object.x, object.y)
        let azTap = atan2(tapRay.x, tapRay.y)
        return Angle.wrapPi(azObject - azTap)
    }
}
