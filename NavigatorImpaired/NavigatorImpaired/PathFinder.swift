import Foundation

// MARK: - ClearPath

/// A detected gap in the depth map — a direction the user can safely walk.
struct ClearPath {
    /// Horizontal position of the gap centre, 0 = far-left edge, 1 = far-right edge.
    let azimuthFraction: Float
    /// Gap width as a fraction of frame width (0 → 1). Wider = more confident.
    let width: Float
    /// Average depth of pixels inside the gap (lower = farther away = clearer).
    let avgDepth: Float
    /// Combined confidence: wider + farther = higher. Used to rank paths.
    let confidence: Float

    /// Maps azimuthFraction to an AVAudio3D x-position.
    /// 0 → -2.5 (hard left), 0.5 → 0 (centre), 1 → +2.5 (hard right).
    var audioX: Float { (azimuthFraction - 0.5) * 5.0 }
}

// MARK: - PathScanResult

/// Bundles the raw depth profile with the detected clear paths so both can
/// be consumed without recomputing the profile.
struct PathScanResult {
    /// Per-column average depth (0 = far, 1 = near). Length = `PathFinder.columnCount`.
    let profile: [Float]
    /// Detected clear gaps sorted best-first by confidence.
    let paths: [ClearPath]
}

// MARK: - PathFinder

/// Scans the depth map horizontally and finds contiguous "clear" regions —
/// columns where no nearby obstacle is present — to identify walkable gaps.
///
/// Algorithm:
///   1. Build a 1-D depth profile across `profileCols` evenly-spaced columns,
///      averaging over the central vertical band (rows 30 %–70 %).
///   2. Scan for contiguous runs where depth < `clearThreshold`.
///   3. Each qualifying run becomes a ClearPath sorted by confidence.
enum PathFinder {

    // MARK: - Tuning

    /// Number of horizontal sample columns — more = finer angular resolution.
    static let columnCount = 20
    private static let profileCols = columnCount
    /// Rows to sample, as fractions of frame height (eye-level band only).
    private static let yBandLow:  Float = 0.28
    private static let yBandHigh: Float = 0.68
    /// Rows sampled per column within the band.
    private static let rowSamples = 10
    /// Depth below this is "clear" — no close obstacle.
    /// 0.32: strict enough to reject moderately close objects, loose enough
    /// to still detect open corridors where far walls register at ~0.25-0.30.
    static let clearThreshold: Float = 0.32
    /// A gap narrower than this fraction of frame width is ignored.
    /// 0.20 = at least 20% of frame width — rejects tiny slivers between obstacles.
    private static let minGapFraction: Float = 0.20

    // MARK: - Public

    /// Returns the depth profile and detected clear paths together.
    static func scan(depthMap: [Float], width: Int, height: Int) -> PathScanResult {
        guard !depthMap.isEmpty, width > 1, height > 1 else {
            return PathScanResult(profile: [], paths: [])
        }
        let profile = buildProfile(depthMap: depthMap, width: width, height: height)
        let paths = extractGaps(from: profile)
        return PathScanResult(profile: profile, paths: paths)
    }

    /// Returns detected clear paths sorted best-first (legacy convenience).
    static func findClearPaths(depthMap: [Float], width: Int, height: Int) -> [ClearPath] {
        scan(depthMap: depthMap, width: width, height: height).paths
    }

    // MARK: - Private

    private static func buildProfile(depthMap: [Float], width: Int, height: Int) -> [Float] {
        let yStart = Int(yBandLow  * Float(height))
        let yEnd   = Int(yBandHigh * Float(height))
        let yStep  = max(1, (yEnd - yStart) / rowSamples)

        var profile = [Float](repeating: 1.0, count: profileCols)
        for col in 0..<profileCols {
            let xFraction = Float(col) / Float(profileCols - 1)
            let x = min(Int(xFraction * Float(width - 1)), width - 1)
            var sum: Float = 0; var n = 0
            var y = yStart
            while y < yEnd {
                let idx = y * width + x
                if idx < depthMap.count { sum += depthMap[idx]; n += 1 }
                y += yStep
            }
            profile[col] = n > 0 ? sum / Float(n) : 1.0
        }
        return profile
    }

    private static func extractGaps(from profile: [Float]) -> [ClearPath] {
        var paths: [ClearPath] = []
        var gapStart: Int? = nil

        func close(at end: Int) {
            guard let start = gapStart else { return }
            gapStart = nil
            guard end >= start else { return }
            let gapFraction = Float(end - start + 1) / Float(profileCols)
            guard gapFraction >= minGapFraction else { return }

            let slice    = profile[start...end]
            let avgDepth = slice.reduce(0, +) / Float(slice.count)
            let centre   = Float(start + end) / 2.0 / Float(profileCols - 1)
            // Confidence: wide gap + low depth (far = clear) = high score
            let conf     = gapFraction * (1.0 - avgDepth)
            paths.append(ClearPath(azimuthFraction: centre,
                                   width: gapFraction,
                                   avgDepth: avgDepth,
                                   confidence: conf))
        }

        for col in 0..<profileCols {
            if profile[col] < clearThreshold {
                if gapStart == nil { gapStart = col }
            } else {
                close(at: col - 1)
            }
        }
        close(at: profileCols - 1)

        return paths.sorted { $0.confidence > $1.confidence }
    }
}
