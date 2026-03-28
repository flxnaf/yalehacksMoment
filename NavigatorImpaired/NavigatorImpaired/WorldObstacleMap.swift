import Foundation

// MARK: - WorldObstacle

/// A single obstacle tracked in world-space coordinates.
struct WorldObstacle {
    /// World-space bearing in radians (CCW-positive, same frame as CMAttitude.yaw).
    let bearing: Float
    /// Proximity: 0 = far, 1 = very close. Attenuated by staleness.
    let depth: Float
    /// Approach velocity (positive = getting closer).
    let velocity: Float
    /// Combined urgency score for ranking.
    let priority: Float
    /// Seconds since the camera last observed this bearing.
    let staleness: Float
}

// MARK: - WorldObstacleMap

/// Maintains a persistent 360° map of obstacles in world-space coordinates.
///
/// Each frame, the camera's visible slice (determined by FOV and phone heading)
/// is merged into a ring of bearing bins covering the full circle. Obstacles
/// outside the current view persist with gradual decay, so the user retains
/// spatial awareness of obstacles behind them after scanning.
///
/// Bins use an attack/release envelope: fast attack when obstacles appear,
/// slow release when they leave the camera's view or recede. Stale obstacles
/// (not refreshed for several seconds) fade their priority so they eventually
/// go silent.
@MainActor
final class WorldObstacleMap {

    // MARK: - Configuration

    /// Camera horizontal field of view in radians. Default = ultra-wide ~120°.
    var cameraFOV: Float = 120 * .pi / 180

    // MARK: - Tuning

    static let binCount = 72                       // 5° per bin
    private let attackAlpha:  Float = 0.50
    private let visibleDecayAlpha: Float = 0.15    // blend rate when depth decreases in-view
    private let releaseDecay: Float = 0.985        // per-frame decay for non-visible bins
    private let presenceThreshold: Float = 0.35
    private let staleFadeStart: Float = 3.0        // seconds before stale penalty begins
    private let staleFadeEnd:   Float = 8.0        // seconds for full stale fadeout
    private let velocityWeight: Float = 0.45

    // MARK: - Per-bin state

    private var held:      [Float]
    private var fastEMA:   [Float]
    private var velSmooth: [Float]
    private var lastSeen:  [Date]
    private var lastUpdate: Date = .now

    // MARK: - Init

    init() {
        let n = WorldObstacleMap.binCount
        held      = [Float](repeating: 0, count: n)
        fastEMA   = [Float](repeating: 0, count: n)
        velSmooth = [Float](repeating: 0, count: n)
        lastSeen  = [Date](repeating: .distantPast, count: n)
    }

    // MARK: - Public API

    /// Merge the latest depth profile into the world map and return ranked obstacles.
    ///
    /// - Parameters:
    ///   - profile: Per-column depth values from PathFinder (0 = far, 1 = near).
    ///   - heading: Phone heading in radians from CMAttitude.yaw.
    /// - Returns: Active obstacles sorted by priority (highest first), capped at a
    ///   reasonable count for voice-pool assignment.
    func update(profile: [Float], heading: Float) -> [WorldObstacle] {
        let now = Date()
        let dt  = Float(now.timeIntervalSince(lastUpdate))
        lastUpdate = now

        let n = WorldObstacleMap.binCount
        guard !profile.isEmpty else { return topObstacles(now: now) }

        let colCount = profile.count
        let halfFOV  = cameraFOV / 2
        var visibleBins = Set<Int>()

        for col in 0..<colCount {
            let fraction    = Float(col) / Float(max(1, colCount - 1))
            let angleOffset = (0.5 - fraction) * cameraFOV   // +FOV/2 (left) → -FOV/2 (right)
            let worldBearing = heading + angleOffset
            let bin = bearingToBin(worldBearing)
            visibleBins.insert(bin)

            let raw      = profile[col]
            let prev     = held[bin]
            let prevFast = fastEMA[bin]

            if raw >= prev {
                held[bin] = attackAlpha * raw + (1 - attackAlpha) * prev
            } else {
                held[bin] = (1 - visibleDecayAlpha) * prev + visibleDecayAlpha * raw
            }

            fastEMA[bin] = 0.45 * raw + 0.55 * prevFast

            if dt > 0.004 {
                let rawVel = (fastEMA[bin] - prevFast) / dt
                velSmooth[bin] = 0.30 * rawVel + 0.70 * velSmooth[bin]
            }

            lastSeen[bin] = now
        }

        for bin in 0..<n where !visibleBins.contains(bin) {
            held[bin]      *= releaseDecay
            fastEMA[bin]   *= releaseDecay
            velSmooth[bin] *= 0.98
        }

        return topObstacles(now: now)
    }

    func reset() {
        let n = WorldObstacleMap.binCount
        held      = [Float](repeating: 0, count: n)
        fastEMA   = [Float](repeating: 0, count: n)
        velSmooth = [Float](repeating: 0, count: n)
        lastSeen  = [Date](repeating: .distantPast, count: n)
        lastUpdate = .now
    }

    // MARK: - Helpers

    private func bearingToBin(_ bearing: Float) -> Int {
        let twoPi = 2 * Float.pi
        var b = bearing.truncatingRemainder(dividingBy: twoPi)
        if b < 0 { b += twoPi }
        return min(Int(b / twoPi * Float(WorldObstacleMap.binCount)),
                   WorldObstacleMap.binCount - 1)
    }

    static func binToBearing(_ bin: Int) -> Float {
        (Float(bin) + 0.5) / Float(binCount) * 2 * .pi
    }

    private func topObstacles(now: Date) -> [WorldObstacle] {
        var out: [WorldObstacle] = []

        for bin in 0..<WorldObstacleMap.binCount {
            let d = held[bin]
            guard d > presenceThreshold else { continue }

            let staleness = Float(now.timeIntervalSince(lastSeen[bin]))
            let v = velSmooth[bin]

            var staleFactor: Float = 1.0
            if staleness > staleFadeStart {
                staleFactor = max(0, 1.0 - (staleness - staleFadeStart)
                                            / (staleFadeEnd - staleFadeStart))
            }

            let effectiveDepth = d * staleFactor
            let priority = (effectiveDepth + velocityWeight * max(0, v)) * staleFactor
            guard priority > 0.05 else { continue }

            out.append(WorldObstacle(
                bearing:   WorldObstacleMap.binToBearing(bin),
                depth:     effectiveDepth,
                velocity:  v,
                priority:  priority,
                staleness: staleness
            ))
        }

        return out.sorted { $0.priority > $1.priority }
    }
}
