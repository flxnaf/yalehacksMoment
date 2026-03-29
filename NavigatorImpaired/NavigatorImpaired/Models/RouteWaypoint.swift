import CoreLocation

/// Legacy micro-waypoint (removed from production pipeline; kept for compatibility if needed).
struct RouteWaypoint {
    let coordinate: CLLocationCoordinate2D
    let bearingToNext: Double
    let distanceToNext: Double
    let instruction: String
}

/// Walking route with dense checkpoints and sparse ping targets.
struct NavigationRoute {
    let checkpoints: [RouteCheckpoint]
    let pingTargets: [PingTarget]
    let totalDistanceMeters: Double
    let estimatedDurationSeconds: Double
    let destinationName: String
    /// Destination coordinate from the last ping target (or last checkpoint).
    var destinationCoordinate: CLLocationCoordinate2D? {
        pingTargets.last?.coordinate ?? checkpoints.last?.coordinate
    }
}
