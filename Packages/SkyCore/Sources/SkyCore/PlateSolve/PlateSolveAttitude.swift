import Foundation
import simd

public struct SolvedDeviceAttitude: Sendable {
    /// Maps Core Motion reference vectors (X north, Y west, Z up) into the device frame; the reference frame is
    /// the one the stars imply, so it includes whatever heading error Core Motion had.
    public var deviceFromReference: simd_quatd
    public var sigmaDegrees: Double
    public var starCount: Int
    public var rmsDegrees: Double
}

public enum PlateSolveAttitude {
    /// Camera attitude from a plate solution at one instant: re-fits the rotation in ENU, using for every matched star the
    /// same aberrated and refracted direction the overlay draws, then removes the fixed camera and reference mounts.
    public static func deviceFromReference(_ solution: PlateSolution, session: SkySession, instant: AstroInstant,
                                           refraction: Refraction = .standard) -> SolvedDeviceAttitude? {
        let icrsToENU = session.icrsToENU(at: instant)
        let beta = session.earthVelocityOverC
        let k = solution.intrinsics
        let enu = solution.matches.map { refraction.apparent(enu: icrsToENU * SkySession.aberrate($0.direction, beta: beta)) }
        let camera = solution.matches.map { m in
            simd_normalize(SIMD3((m.pixel.x - k.cx) / k.fx, (m.pixel.y - k.cy) / k.fy, 1))
        }
        guard let enuToCamera = PlateWahba.rotation(body: camera, reference: enu) else { return nil }
        let residuals = zip(camera, enu).map { PlateSolver.angle($0, enuToCamera * $1) }
        let rms = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot()
        let referenceToDevice = CameraPose.deviceToCamera.transpose * enuToCamera * CameraPose.enuToReference.transpose
        let n = Double(solution.matches.count)
        let rmsDegrees = Angle.degrees(rms)
        // Per-axis rms of a fit with ~3 free parameters, plus a floor for centroid and refraction-model systematics.
        let sigma = (pow(rmsDegrees / 2.0.squareRoot(), 2) / max(n - 2, 1) + 0.005 * 0.005).squareRoot()
        return SolvedDeviceAttitude(deviceFromReference: simd_quatd(referenceToDevice), sigmaDegrees: sigma,
                                    starCount: solution.matches.count, rmsDegrees: rmsDegrees)
    }
}
