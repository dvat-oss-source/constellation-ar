import AVFoundation

/// What the active camera format actually allows on this hardware, recorded once after configuration.
struct CameraProbe: Sendable {
    var deviceName: String
    var dimensions: SIMD2<Int>
    var pixelFormat: String
    var isBinned: Bool
    var maxFrameRate: Double
    var minFrameRate: Double
    var minExposure: Double
    var maxExposure: Double
    var defaultMaxAutoExposure: Double
    var minISO: Float
    var maxISO: Float
    var fieldOfViewDegrees: Double
    var lensAperture: Float
    var intrinsicDeliverySupported: Bool
    var intrinsicDeliveryEnabled: Bool
    var stabilizationMode: String
    var customFocusLockSupported: Bool
    var shutterPrioritySupported: Bool
    var isoPrioritySupported: Bool
    var lowLightBoostSupported: Bool
    var lowLightNoiseReductionSupported: Bool
    /// CMClockGetTime(session.synchronizationClock) − CMClockGetTime(host clock); ~0 means the clocks coincide.
    var syncClockOffsetFromHost: Double?
    var formatsTried: [String]

    init(device: AVCaptureDevice, connection: AVCaptureConnection, formatsTried: [String]) {
        let format = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let ranges = format.videoSupportedFrameRateRanges
        deviceName = device.localizedName
        dimensions = SIMD2(Int(dims.width), Int(dims.height))
        pixelFormat = Self.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        isBinned = format.isVideoBinned
        maxFrameRate = ranges.map(\.maxFrameRate).max() ?? 0
        minFrameRate = ranges.map(\.minFrameRate).min() ?? 0
        minExposure = format.minExposureDuration.seconds
        maxExposure = format.maxExposureDuration.seconds
        defaultMaxAutoExposure = device.activeMaxExposureDuration.seconds
        minISO = format.minISO
        maxISO = format.maxISO
        fieldOfViewDegrees = Double(format.videoFieldOfView)
        lensAperture = device.lensAperture
        intrinsicDeliverySupported = connection.isCameraIntrinsicMatrixDeliverySupported
        intrinsicDeliveryEnabled = connection.isCameraIntrinsicMatrixDeliveryEnabled
        stabilizationMode = String(describing: connection.activeVideoStabilizationMode.rawValue)
        customFocusLockSupported = device.isLockingFocusWithCustomLensPositionSupported
        shutterPrioritySupported = format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                                                                     duration: format.maxExposureDuration, iso: AVCaptureDevice.autoISO)
        isoPrioritySupported = format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                                                                 duration: AVCaptureDevice.autoExposureDuration, iso: format.maxISO)
        lowLightBoostSupported = device.isLowLightBoostSupported
        lowLightNoiseReductionSupported = connection.isLowLightVideoNoiseReductionSupported
        syncClockOffsetFromHost = nil
        self.formatsTried = formatsTried
    }

    var lines: [String] {
        [
            "\(deviceName) \(dimensions.x)×\(dimensions.y) \(pixelFormat)\(isBinned ? " binned" : "")",
            String(format: "fps %.0f–%.0f, FOV %.1f°, f/%.2f", minFrameRate, maxFrameRate, fieldOfViewDegrees, lensAperture),
            String(format: "exposure %.6f–%.3f s (auto max %.3f s)", minExposure, maxExposure, defaultMaxAutoExposure),
            String(format: "ISO %.0f–%.0f", minISO, maxISO),
            "intrinsics supported \(intrinsicDeliverySupported), enabled \(intrinsicDeliveryEnabled); stabilization \(stabilizationMode)",
            "focus lock \(customFocusLockSupported); priority: shutter \(shutterPrioritySupported), ISO \(isoPrioritySupported)",
            "low-light boost \(lowLightBoostSupported), low-light NR \(lowLightNoiseReductionSupported)",
            "sync clock − host: " + (syncClockOffsetFromHost.map { String(format: "%.6f s", $0) } ?? "n/a"),
        ] + formatsTried.map { "tried " + $0 }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}

/// One measured night-exposure configuration from `CameraCapture.runNightProbe()`.
struct NightProbeTrial: Sendable {
    var label: String
    var requestedDuration: Double
    var measuredFPS: Double
    var deviceExposure: Double
    var deviceISO: Float
    var frameExposure: Double?
    var frameISO: Double?
    var maxFrameDuration: Double

    var line: String {
        String(format: "%@: req %.3f s → fps %.1f, exp %.3f s, ISO %.0f, frame exp %@, max frame %.3f s",
               label, requestedDuration, measuredFPS, deviceExposure, deviceISO,
               frameExposure.map { String(format: "%.3f s", $0) } ?? "n/a", maxFrameDuration)
    }
}
