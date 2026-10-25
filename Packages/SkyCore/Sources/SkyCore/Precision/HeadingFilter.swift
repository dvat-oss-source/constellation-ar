import Foundation
import simd

/// Estimates the reference-side correction `C` that turns Core Motion's attitude into the true one
/// (`deviceFromReference_true = deviceFromReference_cm · C`), from star fixes and the gyro-derived attitude between them.
///
/// `C(t) = tilt · Rz(yaw(t))`: a yaw about the vertical that drifts at `yawRate` (Kalman state [yaw, rate]) plus a small
/// fixed tilt. The correction only moves when a fix arrives or slowly with `yawRate`; the drawn orientation is
/// never filtered. Between fixes the gyro tells how far the phone has turned, and the uncertainty grows with
/// both elapsed time and that angle (gyro scale error).
public struct HeadingFilter: Sendable, Codable, Equatable {
    public struct Parameters: Sendable, Codable, Equatable {
        /// Yaw random walk of Core Motion's magnetometer-fused heading, degrees per √second.
        public var yawWalk = 0.03
        /// Random walk of the yaw drift rate, degrees per second per √second.
        public var rateWalk = 0.0005
        /// Yaw error accumulated per radian the phone is turned (gyro scale and axis error), unitless.
        public var turnError = 0.005
        /// Tilt random walk, degrees per √second.
        public var tiltWalk = 0.001
        public var initialYawSigma = 15.0
        public var initialTiltSigma = 0.25
        /// Accuracy never reported below this, degrees (catalog, refraction and pixel-scale model error).
        public var floorSigma = 0.1
        public var maxSigma = 45.0

        public init() {}
    }

    public var parameters = Parameters()
    /// Radians, active about +Z (north toward west), at `epoch`.
    public private(set) var yaw = 0.0
    /// Radians per second.
    public private(set) var yawRate = 0.0
    public private(set) var epoch: Double
    /// Covariance of [yaw, yawRate] at `epoch`, rad² and rad²/s.
    private var pYaw: Double
    private var pCross = 0.0
    private var pRate: Double
    private var tiltXYZW = SIMD4<Double>(0, 0, 0, 1)
    public var tilt: simd_quatd { simd_quatd(ix: tiltXYZW.x, iy: tiltXYZW.y, iz: tiltXYZW.z, r: tiltXYZW.w) }
    private var pTilt: Double
    /// Radians turned since the last fix.
    private var turned = 0.0
    private var lastTurn: Double?
    public private(set) var fixCount = 0
    public private(set) var lastFixTime: Double?

    public init(epoch: Double = 0, parameters: Parameters = Parameters()) {
        self.parameters = parameters
        self.epoch = epoch
        pYaw = Angle.radians(parameters.initialYawSigma) * Angle.radians(parameters.initialYawSigma)
        pRate = Angle.radians(0.01) * Angle.radians(0.01)
        pTilt = Angle.radians(parameters.initialTiltSigma) * Angle.radians(parameters.initialTiltSigma)
    }

    public var isAligned: Bool { fixCount > 0 }

    /// Before any fix the compass accuracy sets the yaw prior.
    public mutating func setCompassAccuracy(degrees: Double) {
        guard !isAligned, degrees > 0 else { return }
        let sigma = min(degrees, parameters.maxSigma)
        pYaw = Angle.radians(sigma) * Angle.radians(sigma)
    }

    public func yaw(at hostTime: Double) -> Double { yaw + yawRate * (hostTime - epoch) }

    /// Reference-side correction at `hostTime`.
    public func correction(at hostTime: Double) -> simd_quatd {
        tilt * simd_quatd(angle: yaw(at: hostTime), axis: SIMD3(0, 0, 1))
    }

    /// One-sigma pointing accuracy at `hostTime`, degrees.
    public func sigmaDegrees(at hostTime: Double) -> Double {
        let sigma = (yawVariance(at: hostTime) + pTilt).squareRoot()
        return min(max(Angle.degrees(sigma), parameters.floorSigma), parameters.maxSigma)
    }

    /// Feeds the gyro: `cumulativeTurn` is the total angle (radians) the phone has been rotated since the motion
    /// stream started, so the filter knows how far it turned between fixes.
    public mutating func advance(cumulativeTurn: Double) {
        if let last = lastTurn { turned += max(cumulativeTurn - last, 0) }
        lastTurn = cumulativeTurn
    }

    private func yawVariance(at hostTime: Double) -> Double {
        let dt = max(hostTime - epoch, 0)
        let walk = Angle.radians(parameters.yawWalk)
        let rateWalk = Angle.radians(parameters.rateWalk)
        let drifted = pYaw + 2 * dt * pCross + dt * dt * pRate
        let process = walk * walk * dt + rateWalk * rateWalk * dt * dt * dt / 3
        let turn = parameters.turnError * turned
        return drifted + process + turn * turn
    }

    /// Takes a star fix. `current` is the raw Core Motion attitude at `fix.hostTime` and `boresight` the device-frame
    /// rotation the renderer applies on top of it (identity if uncalibrated).
    public mutating func ingest(_ fix: StarFix, coreMotion current: simd_quatd, boresight: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))) {
        let t = fix.hostTime
        if !isAligned { epoch = t }
        rebase(to: t)
        // fix = boresight · cm · C, so C = cm⁻¹ · boresight⁻¹ · fix.
        let measured = (current.inverse * boresight.inverse * fix.deviceFromReference).normalized
        let (swing, yawMeasured) = Self.decompose(measured)
        let sigma = Angle.radians(max(fix.sigmaDegrees, 0.01))
        let r = sigma * sigma

        let turn = parameters.turnError * turned
        let pyy = pYaw + turn * turn
        let s = pyy + r
        let k0 = pyy / s, k1 = pCross / s
        let innovation = Angle.wrapPi(yawMeasured - yaw)
        yaw = Angle.wrapPi(yaw + k0 * innovation)
        yawRate += k1 * innovation
        let (oldYY, oldYR, oldRR) = (pYaw, pCross, pRate)
        pYaw = (1 - k0) * (oldYY + turn * turn)
        pCross = (1 - k0) * oldYR
        pRate = max(oldRR - k1 * oldYR, 0)
        turned = 0

        if fix.source == .multiStar || fix.source == .plateSolve {
            let kTilt = pTilt / (pTilt + r)
            let blended = simd_slerp(tilt, swing, kTilt).normalized
            tiltXYZW = SIMD4(blended.imag, blended.real)
            pTilt = (1 - kTilt) * pTilt
        }
        fixCount += 1
        lastFixTime = t
    }

    /// Time update only; keeps the stored state valid at `hostTime` (so persisted state restarts from there).
    public mutating func rebase(to hostTime: Double) {
        guard hostTime > epoch else { return }
        let dt = hostTime - epoch
        let walk = Angle.radians(parameters.yawWalk), rateWalk = Angle.radians(parameters.rateWalk)
        pYaw += 2 * dt * pCross + dt * dt * pRate + walk * walk * dt + rateWalk * rateWalk * dt * dt * dt / 3
        pCross += dt * pRate + rateWalk * rateWalk * dt * dt / 2
        pRate += rateWalk * rateWalk * dt
        pTilt += Angle.radians(parameters.tiltWalk) * Angle.radians(parameters.tiltWalk) * dt
        yaw = Angle.wrapPi(yaw + yawRate * dt)
        epoch = hostTime
    }

    /// Restores a persisted filter after `elapsed` wall-clock seconds (the host clock restarts with the device, so
    /// `epoch` is re-anchored). A drift rate older than an hour is no longer trusted.
    public mutating func resume(atHostTime hostTime: Double, afterElapsed elapsed: Double) {
        epoch = hostTime - max(elapsed, 0)
        lastTurn = nil
        turned = 0
        if elapsed > 3600 {
            yawRate = 0
            pCross = 0
        }
        rebase(to: hostTime)
    }

    public mutating func reset(epoch: Double) {
        self = HeadingFilter(epoch: epoch, parameters: parameters)
    }

    /// `q = swing · twist` with `twist` a rotation about +Z.
    static func decompose(_ q: simd_quatd) -> (swing: simd_quatd, yaw: Double) {
        let twist = simd_quatd(ix: 0, iy: 0, iz: q.imag.z, r: q.real)
        let length = simd_length(twist.vector)
        guard length > 1e-12 else { return (q, 0) }
        let unit = simd_quatd(vector: twist.vector / length)
        let swing = (q * unit.inverse).normalized
        let yaw = 2 * atan2(unit.imag.z, unit.real)
        return (swing, Angle.wrapPi(yaw))
    }
}
