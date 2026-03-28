import Foundation

/// Six frontal columns across the frame: 5th-percentile inverse depth per column → meters.
enum ColumnDepthSampler {
    static let columnCount = 6
    private static let maxDepthMeters: Float = 10

    /// Nearest-obstacle distance in meters per column (smaller = closer). Uses an eye-level band.
    static func sampleMeters(depthMap: [Float], width: Int, height: Int) -> [Float] {
        guard width > 1, height > 1, !depthMap.isEmpty else {
            return [Float](repeating: maxDepthMeters, count: columnCount)
        }
        let yStart = Int(Float(height) * 0.20)
        let yEnd = Int(Float(height) * 0.72)
        let colW = max(1, width / columnCount)
        var out = [Float](repeating: maxDepthMeters, count: columnCount)

        for c in 0..<columnCount {
            let x0 = c * colW
            let x1 = min(width - 1, (c + 1) * colW - 1)
            var samples: [Float] = []
            samples.reserveCapacity((yEnd - yStart) * (x1 - x0 + 1))
            var y = yStart
            while y < yEnd {
                for x in x0...x1 {
                    let idx = y * width + x
                    guard idx < depthMap.count else { continue }
                    samples.append(depthMap[idx])
                }
                y += 4
            }
            guard !samples.isEmpty else { continue }
            let p5 = percentile5(samples)
            let meters = maxDepthMeters * (1 - p5)
            out[c] = max(0, meters)
        }
        return out
    }

    private static func percentile5(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.05)))
        return sorted[idx]
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
