import AVFoundation

enum LightingPhase: String, Sendable {
    case day, twilight, night

    /// `blend` 0 = full day, 1 = full night (driven by the Sun's altitude).
    init(blend: Double) {
        if blend <= 0.02 {
            self = .day
        } else if blend >= 0.98 {
            self = .night
        } else {
            self = .twilight
        }
    }
}

enum NightExposureStrategy: String, CaseIterable, Sendable {
    /// Fixed duration and ISO; the frame rate drops to 1/duration.
    case manual
    /// iOS 27 priority mode: fixed duration, ISO auto. Streaming exposure is capped at activeMaxExposureDuration.
    case shutterPriority
}

struct ExposureState: Sendable, Equatable {
    var phase: LightingPhase
    var blend: Double
    var strategy: String
    var requestedDuration: Double?
    var requestedISO: Float?
    var maxFrameDuration: Double
}

/// Day: continuous auto exposure at the format's top frame rate. Twilight: still auto, but the auto-exposure
/// ceiling and the frame duration stretch (log scale) toward the night duration. Night: long custom exposure.
struct ExposureController: Sendable {
    var dayFrameRate: Double = 60
    var nightExposureDuration: Double = 1.0 / 8
    var nightISOFraction: Float = 1
    var nightStrategy: NightExposureStrategy = .manual

    func apply(blend rawBlend: Double, to device: AVCaptureDevice) -> ExposureState? {
        let blend = min(max(rawBlend, 0), 1)
        let format = device.activeFormat
        let phase = LightingPhase(blend: blend)
        let frameDuration = 1 / dayFrameRate
        let nightDuration = exposureTime(nightExposureDuration, format).seconds

        guard (try? device.lockForConfiguration()) != nil else { return nil }
        defer { device.unlockForConfiguration() }

        switch phase {
        case .day:
            setFrameDurations(device, min: frameDuration, max: frameDuration)
            device.activeMaxExposureDuration = .invalid
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            return state(phase, blend, "auto", nil, nil, device)

        case .twilight:
            let ceiling = exposureTime(exp(log(frameDuration) + (log(nightDuration) - log(frameDuration)) * blend), format)
            setFrameDurations(device, min: frameDuration, max: max(frameDuration, ceiling.seconds))
            device.activeMaxExposureDuration = ceiling
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            return state(phase, blend, "auto, raised ceiling", ceiling.seconds, nil, device)

        case .night:
            guard device.isExposureModeSupported(.custom) else { return nil }
            let duration = exposureTime(nightExposureDuration, format)
            setFrameDurations(device, min: frameDuration, max: max(frameDuration, duration.seconds))
            let priorityAllowed = format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                                                                    duration: duration, iso: AVCaptureDevice.autoISO)
            if nightStrategy == .shutterPriority, priorityAllowed {
                device.activeMaxExposureDuration = duration
                device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.autoISO, completionHandler: nil)
                return state(phase, blend, "shutter priority, ISO auto", duration.seconds, nil, device)
            }
            let iso = min(max(format.minISO + (format.maxISO - format.minISO) * nightISOFraction, format.minISO), format.maxISO)
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            return state(phase, blend, "manual", duration.seconds, iso, device)
        }
    }

    private func state(_ phase: LightingPhase, _ blend: Double, _ strategy: String, _ duration: Double?, _ iso: Float?,
                       _ device: AVCaptureDevice) -> ExposureState {
        ExposureState(phase: phase, blend: blend, strategy: strategy, requestedDuration: duration, requestedISO: iso,
                      maxFrameDuration: device.activeVideoMaxFrameDuration.seconds)
    }

    // Out-of-range durations raise Objective-C exceptions (uncatchable in Swift), and rounding e.g. 1/120 s to a
    // CMTime can land just outside a bound, so every value is clamped as a CMTime against the format's own limits.
    private func setFrameDurations(_ device: AVCaptureDevice, min minimum: Double, max maximum: Double) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        let minDuration = clamp(time(minimum), range.minFrameDuration, range.maxFrameDuration)
        let maxDuration = clamp(time(maximum), minDuration, range.maxFrameDuration)
        device.activeVideoMinFrameDuration = minDuration
        device.activeVideoMaxFrameDuration = maxDuration
    }

    private func exposureTime(_ value: Double, _ format: AVCaptureDevice.Format) -> CMTime {
        clamp(time(value), format.minExposureDuration, format.maxExposureDuration)
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    private func clamp(_ value: CMTime, _ lower: CMTime, _ upper: CMTime) -> CMTime {
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }
}
