import Foundation
import simd

/// One absolute orientation measurement derived from stars.
///
/// `deviceFromReference` maps Core Motion reference vectors (X north, Y west, Z up) into the device frame. It is the
/// attitude the renderer would draw with: the nominal camera mounting (`CameraPose.deviceToCamera`) is assumed, so a
/// solver that turns a camera-frame solution into a device attitude with that matrix needs no knowledge of the
/// app's boresight calibration.
public struct StarFix: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        case tap, tapSnapped, multiStar, plateSolve
    }

    /// Host-clock seconds (`CACurrentMediaTime` base) the attitude was true at.
    public var hostTime: Double
    public var deviceFromReference: simd_quatd
    /// One-sigma accuracy of the attitude, degrees.
    public var sigmaDegrees: Double
    public var starCount: Int
    public var source: Source

    public init(hostTime: Double, deviceFromReference: simd_quatd, sigmaDegrees: Double, starCount: Int, source: Source) {
        self.hostTime = hostTime
        self.deviceFromReference = deviceFromReference
        self.sigmaDegrees = sigmaDegrees
        self.starCount = starCount
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case hostTime, quaternion, sigmaDegrees, starCount, source }

    /// `simd_quatd` is not Codable; it travels as [x, y, z, w].
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostTime = try c.decode(Double.self, forKey: .hostTime)
        let q = try c.decode([Double].self, forKey: .quaternion)
        guard q.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: .quaternion, in: c, debugDescription: "expected [x, y, z, w]")
        }
        deviceFromReference = simd_quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3])
        sigmaDegrees = try c.decode(Double.self, forKey: .sigmaDegrees)
        starCount = try c.decode(Int.self, forKey: .starCount)
        source = try c.decode(Source.self, forKey: .source)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostTime, forKey: .hostTime)
        let q = deviceFromReference
        try c.encode([q.imag.x, q.imag.y, q.imag.z, q.real], forKey: .quaternion)
        try c.encode(sigmaDegrees, forKey: .sigmaDegrees)
        try c.encode(starCount, forKey: .starCount)
        try c.encode(source, forKey: .source)
    }
}
