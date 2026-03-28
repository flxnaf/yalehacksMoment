import Foundation

/// Depth + lightweight vision rules for obstacle summary (no Vision framework imports).
final class ObstacleAnalyzer {
    private let maxDepthMeters: Double = 10.0

    /// Mobility-related scene substrings (lowercase) that slightly raise urgency.
    private let mobilityKeywords: Set<String> = [
        "stair", "stairs", "escalator", "construction", "road", "street", "crosswalk"
    ]

    func analyze(
        depthData: [Float],
        width: Int,
        height: Int,
        persons: [PersonDetection]?,
        sceneLabel: String?
    ) -> ObstacleAnalysis {
        guard width > 0, height > 0, !depthData.isEmpty else {
            return .clear
        }

        let rowStart = Int(Double(height) * 0.4)
        let rowEnd = height
        let colThird = width / 3

        func zoneMinDistance(colRange: Range<Int>) -> Double {
            var samples: [Float] = []
            for row in rowStart..<rowEnd {
                for col in colRange {
                    let idx = row * width + col
                    guard idx < depthData.count else { continue }
                    samples.append(depthData[idx])
                }
            }
            guard !samples.isEmpty else { return Double(maxDepthMeters) }
            let sorted = samples.sorted()
            let p5 = sorted[max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.05)))]
            return Double(maxDepthMeters) * (1.0 - Double(p5))
        }

        let leftDist = zoneMinDistance(colRange: 0..<colThird)
        let centerDist = zoneMinDistance(colRange: colThird..<(2 * colThird))
        let rightDist = zoneMinDistance(colRange: (2 * colThird)..<width)

        let leftClearance = min(1.0, leftDist / maxDepthMeters)
        let centerClearance = min(1.0, centerDist / maxDepthMeters)
        let rightClearance = min(1.0, rightDist / maxDepthMeters)

        let closest = min(leftDist, centerDist, rightDist)
        var urgency: Double = min(1.0, 1.0 - (closest / maxDepthMeters))
        var direction = "straight"
        if centerDist <= leftDist, centerDist <= rightDist {
            direction = leftDist >= rightDist ? "left" : "right"
        } else if leftDist <= rightDist {
            direction = "right"
        } else {
            direction = "left"
        }
        if centerDist < 1.5 {
            direction = "stop"
        }

        if let persons {
            for p in persons {
                let az = p.azimuthFraction
                if (0.33...0.66).contains(Double(az)),
                   let ed = p.estimatedDepth, ed > 0.5 {
                    urgency = min(1.0, urgency + 0.2)
                    if direction == "straight" { direction = az < 0.5 ? "right" : "left" }
                }
            }
        }

        if let label = sceneLabel?.lowercased() {
            for kw in mobilityKeywords where label.contains(kw) {
                urgency = min(1.0, urgency + 0.05)
                break
            }
        }

        return ObstacleAnalysis(
            leftClearance: leftClearance,
            centerClearance: centerClearance,
            rightClearance: rightClearance,
            closestDistance: closest,
            urgency: urgency,
            recommendedDirection: direction
        )
    }
}
