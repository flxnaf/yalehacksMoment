import Foundation

/// Owns the shared `NavigationController` for stream + route debug map tabs.
@MainActor
final class NavigationControllerHolder: ObservableObject {
    let navigation: NavigationController

    init() {
        navigation = NavigationController(
            locationManager: LocationManager.shared,
            googleMapsAPIKey: Secrets.googleMapsAPIKey
        )
    }
}
