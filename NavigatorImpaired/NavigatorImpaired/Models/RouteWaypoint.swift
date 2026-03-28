import CoreLocation

/// A single point along a walking route.
struct RouteWaypoint {
    let coordinate: CLLocationCoordinate2D
    let bearingToNext: Double
    let distanceToNext: Double
    let instruction: String
}

/// Complete route from origin to destination.
struct NavigationRoute {
    let waypoints: [RouteWaypoint]
    let totalDistanceMeters: Double
    let estimatedDurationSeconds: Double
    let destinationName: String
}
