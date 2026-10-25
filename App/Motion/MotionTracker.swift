import CoreMotion
import Observation
import QuartzCore

/// Device motion at 100 Hz in the .xTrueNorthZVertical frame, recorded into `buffer` on its own queue.
@MainActor
@Observable
final class MotionTracker {
    let buffer = AttitudeBuffer()
    private(set) var isRunning = false
    private(set) var unavailableReason: String? = nil

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ConstellationAR.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard !isRunning else { return }
        guard manager.isDeviceMotionAvailable else {
            unavailableReason = "device motion unavailable"
            return
        }
        guard CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical) else {
            unavailableReason = "true-north reference frame unavailable"
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 100
        let buffer = buffer
        // @Sendable keeps the closure off the main actor; it runs on `queue`.
        manager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: queue) { @Sendable motion, _ in
            guard let motion else { return }
            buffer.append(MotionSample(motion, receivedAt: CACurrentMediaTime()))
        }
        isRunning = true
        unavailableReason = nil
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }
}
