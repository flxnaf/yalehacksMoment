import CoreLocation
import Foundation

/// One Google Directions walking step (parsed subset).
struct DirectionsStepRecord {
    let htmlInstructions: String
    let polylineEncoded: String
    let distanceMeters: Double
}

/// Dense point along the merged walking path for reroute / nearest-point queries.
struct RouteCheckpoint {
    let coordinate: CLLocationCoordinate2D
    /// Distance along route from origin (meters).
    let distanceFromStartMeters: Double
    /// Which Directions step this point belongs to.
    let stepIndex: Int
    /// Plain text for the step (HTML stripped).
    let stepInstruction: String
    /// Bearing toward the next checkpoint, degrees 0...360, north=0 CW. Last checkpoint uses approach bearing.
    let bearingToNextDegrees: Double
}

/// A navigation ping target (turn, start, or destination).
struct PingTarget {
    let coordinate: CLLocationCoordinate2D
    let instruction: String
    let isFinalDestination: Bool
    /// Bearing along the path after this decision point (for debug arrows).
    let bearingAfterTurnDegrees: Double
}
