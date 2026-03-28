import CoreLocation
import Combine

/// GPS + compass. Requires NSLocationWhenInUseUsageDescription in Info.plist.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()

    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var currentHeading: Double = 0
    @Published var hasPermission: Bool = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
        let status = manager.authorizationStatus
        hasPermission = status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func requestPermissionAndStart() {
        manager.requestWhenInUseAuthorization()
        if hasPermission {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentCoordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.trueHeading >= 0 {
            currentHeading = newHeading.trueHeading
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        hasPermission = status == .authorizedWhenInUse || status == .authorizedAlways
        if hasPermission {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }
}
