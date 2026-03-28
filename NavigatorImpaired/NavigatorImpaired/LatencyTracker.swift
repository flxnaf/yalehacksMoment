import Foundation

struct LatencyTracker {
    private(set) var average: Double = 0
    private(set) var min: Double = .infinity
    private(set) var max: Double = 0
    private var total: Double = 0
    private var count: Int = 0

    mutating func record(_ ms: Double) {
        count += 1
        total += ms
        average = total / Double(count)
        if ms < min { min = ms }
        if ms > max { max = ms }
    }

    mutating func reset() {
        average = 0; min = .infinity; max = 0; total = 0; count = 0
    }
}
