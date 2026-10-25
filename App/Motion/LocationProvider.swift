import CoreLocation
import Observation

struct ObserverLocation: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    /// Metres above the WGS84 ellipsoid.
    var altitude: Double
    var isLive: Bool
}

/// When-in-use location (sets the sky; Core Motion also needs it for true north) and compass heading accuracy.
@MainActor
@Observable
final class LocationProvider: NSObject {
    private static let lastKnownKey = "location.lastKnown"

    private(set) var authorization: CLAuthorizationStatus
    private(set) var observer: ObserverLocation? = nil
    private(set) var horizontalAccuracy: Double? = nil
    /// CLHeading.headingAccuracy in degrees; nil while invalid.
    private(set) var headingAccuracy: Double? = nil
    private(set) var trueHeading: Double? = nil

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        if let stored = UserDefaults.standard.array(forKey: Self.lastKnownKey) as? [Double], stored.count == 3 {
            observer = ObserverLocation(latitude: stored[0], longitude: stored[1], altitude: stored[2], isLive: false)
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.headingFilter = 1
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }
}

extension LocationProvider: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        let c = location.coordinate
        observer = ObserverLocation(latitude: c.latitude, longitude: c.longitude, altitude: location.altitude, isLive: true)
        horizontalAccuracy = location.horizontalAccuracy
        UserDefaults.standard.set([c.latitude, c.longitude, location.altitude], forKey: Self.lastKnownKey)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        headingAccuracy = newHeading.headingAccuracy >= 0 ? newHeading.headingAccuracy : nil
        trueHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }
}
