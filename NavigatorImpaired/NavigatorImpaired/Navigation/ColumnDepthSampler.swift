import Foundation

/// Six frontal columns across the frame: per-column obstacle distance in meters.
///
/// Aligned with PathFinder's sampling strategy: same vertical band, same floor
/// filtering, and 25th percentile instead of 5th to avoid treating floor pixels
/// as close obstacles.
enum ColumnDepthSampler {
    static let columnCount = 6
    private static let maxDepthMeters: Float = 10

    /// Same vertical band as PathFinder to ensure consistent readings.
    private static let yBandLow:  Float = 0.15
    private static let yBandHigh: Float = 0.55
    private static let ySampleStep = 4

    static func sampleMeters(depthMap: [Float], width: Int, height: Int) -> [Float] {
        guard width > 1, height > 1, !depthMap.isEmpty else {
            return [Float](repeating: maxDepthMeters, count: columnCount)
        }
        let yStart = Int(Float(height) * yBandLow)
        let yEnd = Int(Float(height) * yBandHigh)
        let colW = max(1, width / columnCount)
        var out = [Float](repeating: maxDepthMeters, count: columnCount)

        for c in 0..<columnCount {
            let x0 = c * colW
            let x1 = min(width - 1, (c + 1) * colW - 1)
            var samples: [Float] = []
            samples.reserveCapacity((yEnd - yStart) / ySampleStep * (x1 - x0 + 1))
            var y = yStart
            while y < yEnd {
                for x in x0...x1 {
                    let idx = y * width + x
                    guard idx < depthMap.count else { continue }

                    if isLikelyFloor(depthMap: depthMap, x: x, y: y,
                                     width: width, height: height) {
                        continue
                    }
                    samples.append(depthMap[idx])
                }
                y += ySampleStep
            }
            guard !samples.isEmpty else { continue }
            let p25 = percentile(samples, frac: 0.25)
            let meters = maxDepthMeters * (1 - p25)
            out[c] = max(0, meters)
        }
        return out
    }

    /// Distance in meters along a vertical slice at `horizontalFraction` (0 = left edge, 1 = right).
    /// Same vertical band, floor filter, and 25th-percentile→meters mapping as `sampleMeters`.
    /// Returns `nil` if no valid samples (caller should fall back to a coarse distance bucket).
    static func distanceMeters(
        depthMap: [Float],
        width: Int,
        height: Int,
        horizontalFraction: Float
    ) -> Float? {
        guard width > 1, height > 1, !depthMap.isEmpty else { return nil }
        let f = max(0, min(1, horizontalFraction))
        let xCenter = Int(f * Float(width - 1))
        let halfW = max(3, width / 20)
        let x0 = max(0, xCenter - halfW)
        let x1 = min(width - 1, xCenter + halfW)

        let yStart = Int(Float(height) * yBandLow)
        let yEnd = Int(Float(height) * yBandHigh)
        var samples: [Float] = []
        var y = yStart
        while y < yEnd {
            for x in x0...x1 {
                let idx = y * width + x
                guard idx < depthMap.count else { continue }
                if isLikelyFloor(depthMap: depthMap, x: x, y: y,
                                 width: width, height: height) {
                    continue
                }
                samples.append(depthMap[idx])
            }
            y += ySampleStep
        }
        guard !samples.isEmpty else { return nil }
        let p25 = percentile(samples, frac: 0.25)
        return max(0, maxDepthMeters * (1 - p25))
    }

    private static func percentile(_ values: [Float], frac: Double) -> Float {
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * frac)))
        return sorted[idx]
    }

    /// Same floor filter as PathFinder.
    private static func isLikelyFloor(
        depthMap: [Float], x: Int, y: Int, width: Int, height: Int
    ) -> Bool {
        let step = 6
        guard y + step < height else { return false }
        let curr = depthMap[y * width + x]
        let below = depthMap[(y + step) * width + x]
        let diff = below - curr
        let yFrac = Float(y) / Float(height)

        if diff > 0.04 && yFrac > 0.40 { return true }
        if diff > 0.07 { return true }
        if abs(diff) < 0.035 && yFrac > 0.62 && curr < 0.40 { return true }
        if curr > 0.60 && yFrac > 0.70 && diff > 0.01 { return true }

        return false
    }
}

/// Per-frame EMA on six column distances (meters).
final class ColumnDepthEMA: @unchecked Sendable {
    private var smoothed: [Float] = [Float](repeating: 10, count: ColumnDepthSampler.columnCount)
    private let alpha: Float = 0.35

    func update(depthMap: [Float], width: Int, height: Int) -> [Float] {
        let raw = ColumnDepthSampler.sampleMeters(depthMap: depthMap, width: width, height: height)
        for i in 0..<ColumnDepthSampler.columnCount {
            smoothed[i] = alpha * raw[i] + (1 - alpha) * smoothed[i]
        }
        return smoothed
    }

    func reset() {
        smoothed = [Float](repeating: 10, count: ColumnDepthSampler.columnCount)
    }
}
