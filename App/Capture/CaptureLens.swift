import AVFoundation

/// Physical back camera (never the virtual multi-lens device).
enum CaptureLens: String, Sendable, Equatable, CaseIterable {
    case ultraWide
    case wide
    case telephoto

    static let persistenceKey = "captureLens"
    static let displayOrder: [CaptureLens] = [.ultraWide, .wide, .telephoto]

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    var label: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .telephoto: "4×"
        }
    }

    static func available() -> [CaptureLens] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: displayOrder.map(\.deviceType),
            mediaType: .video,
            position: .back)
        let types = Set(session.devices.map(\.deviceType))
        return displayOrder.filter { types.contains($0.deviceType) }
    }

    static func loadPersisted(available: [CaptureLens]) -> CaptureLens {
        let stored = UserDefaults.standard.string(forKey: persistenceKey).flatMap(CaptureLens.init(rawValue:))
        if let stored, available.contains(stored) { return stored }
        if available.contains(.wide) { return .wide }
        return available.first ?? .wide
    }
}
