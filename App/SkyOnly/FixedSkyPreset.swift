import Foundation

/// Repeatable sky for screenshots: Orion near the meridian on a January evening in Cupertino, looking south.
enum FixedSkyPreset {
    /// 2026-01-16 05:30:00 UTC (21:30 PST on 15 January).
    static let date = Date(timeIntervalSince1970: 1_768_541_400)
    static let observer = ObserverLocation(latitude: 37.3349, longitude: -122.0090, altitude: 60, isLive: false)
    static let azimuth = 180.0
    static let altitude = 45.0
}
