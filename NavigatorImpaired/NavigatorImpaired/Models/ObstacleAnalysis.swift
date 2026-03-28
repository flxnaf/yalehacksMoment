import Foundation

/// Compact obstacle summary for navigation fusion and audio.
struct ObstacleAnalysis {
    let leftClearance: Double
    let centerClearance: Double
    let rightClearance: Double
    let closestDistance: Double
    let urgency: Double
    let recommendedDirection: String

    static let clear = ObstacleAnalysis(
        leftClearance: 1.0,
        centerClearance: 1.0,
        rightClearance: 1.0,
        closestDistance: 10.0,
        urgency: 0.0,
        recommendedDirection: "straight"
    )
}
