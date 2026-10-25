import CoreMotion
import Observation
import QuartzCore
import Synchronization

/// Device motion at 100 Hz in the .xTrueNorthZVertical frame, recorded into `buffer` on its own queue.
@MainActor
@Observable
final class MotionTracker {
    let buffer = AttitudeBuffer()
    private(set) var isRunning = false
    private(set) var unavailableReason: String? = nil

    @ObservationIgnored private let recorder = RecorderSlot()
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
        let buffer = buffer, recorder = recorder
        // @Sendable keeps the closure off the main actor; it runs on `queue`.
        manager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: queue) { @Sendable motion, _ in
            guard let motion else { return }
            let received = CACurrentMediaTime()
            buffer.append(MotionSample(motion, receivedAt: received))
            if let recorder = recorder.current, recorder.isRecording { recorder.record(motion: motion, receivedAt: received) }
        }
        isRunning = true
        unavailableReason = nil
    }

    func setRecorder(_ recorder: SessionRecorder?) {
        self.recorder.set(recorder)
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }
}
