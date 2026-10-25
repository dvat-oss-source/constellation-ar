import AVFoundation

struct FocusOutcome: Sendable, Equatable {
    enum Source: String, Sendable {
        case autofocused = "autofocused on centre"
        case stored = "stored far position"
        case fallback = "fallback 1.0"
        case unsupported = "custom lock unsupported"
    }

    var lensPosition: Float
    var source: Source
}

/// AVFoundation has no "focus at infinity": lensPosition 1.0 is not infinity and positions differ per device.
/// By day the lens autofocuses once on the distant centre and that position is kept as the "far" position.
struct FocusController: Sendable {
    static let storedPositionKey = "focus.farLensPosition"
    static let fallbackLensPosition: Float = 1.0

    var storedFarPosition: Float? {
        UserDefaults.standard.object(forKey: Self.storedPositionKey) as? Float
    }

    /// `autofocus` true by day; at night (no contrast to focus on) the stored position is reused.
    nonisolated(nonsending) func lockFar(_ device: AVCaptureDevice, autofocus: Bool) async -> FocusOutcome {
        guard device.isLockingFocusWithCustomLensPositionSupported else {
            return FocusOutcome(lensPosition: device.lensPosition, source: .unsupported)
        }

        if autofocus, device.isFocusModeSupported(.autoFocus), device.isFocusPointOfInterestSupported,
           (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .far
            }
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            device.focusMode = .autoFocus
            device.unlockForConfiguration()

            // A scan may not start at all if the lens is already sharp, so the first wait is short.
            _ = await waitUntil(timeout: 0.5) { device.isAdjustingFocus }
            if await waitUntil(timeout: 3.0, { !device.isAdjustingFocus }) {
                let position = device.lensPosition
                UserDefaults.standard.set(position, forKey: Self.storedPositionKey)
                lock(device, at: position)
                return FocusOutcome(lensPosition: position, source: .autofocused)
            }
        }

        if let stored = storedFarPosition {
            lock(device, at: stored)
            return FocusOutcome(lensPosition: stored, source: .stored)
        }
        lock(device, at: Self.fallbackLensPosition)
        return FocusOutcome(lensPosition: Self.fallbackLensPosition, source: .fallback)
    }

    private func lock(_ device: AVCaptureDevice, at position: Float) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
        device.unlockForConfiguration()
    }

    private nonisolated(nonsending) func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }
}
