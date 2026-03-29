import CoreLocation
import Combine

/// GPS + compass with coordinate smoothing. Requires NSLocationWhenInUseUsageDescription in Info.plist.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()

    /// Smoothed GPS coordinate (filtered to reduce jitter when stationary).
    @Published var currentCoordinate: CLLocationCoordinate2D?
    /// Latest raw/smoothed `CLLocation` for accuracy and distance APIs.
    @Published var currentLocation: CLLocation?
    @Published var currentHeading: Double = 0
    @Published var hasPermission: Bool = false

    /// Current speed in m/s from GPS. Negative means invalid.
    @Published var currentSpeed: Double = -1

    private var navigationHighAccuracy = false

    /// Raw unfiltered coordinate for debugging.
    private var rawCoordinate: CLLocationCoordinate2D?

    /// Smoothing factor for GPS coordinates. Lower = more stable but slower to respond.
    private let coordAlpha: Double = 0.15

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
        manager.distanceFilter = kCLDistanceFilterNone
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

    /// Toggle `kCLLocationAccuracyBestForNavigation` while walking navigation is active.
    func setNavigationHighAccuracyEnabled(_ enabled: Bool) {
        navigationHighAccuracy = enabled
        manager.desiredAccuracy = enabled ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        rawCoordinate = loc.coordinate
        currentSpeed = loc.speed
        currentLocation = loc

        if let prev = currentCoordinate {
            // When stationary, use very low alpha to virtually freeze position.
            // When moving, allow faster updates.
            let isStationary = loc.speed < 0.5
            let alpha = isStationary ? 0.02 : coordAlpha
            let lat = prev.latitude + (loc.coordinate.latitude - prev.latitude) * alpha
            let lon = prev.longitude + (loc.coordinate.longitude - prev.longitude) * alpha
            currentCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            currentCoordinate = loc.coordinate
        }
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
