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

/// Scans the depth map horizontally to build a 1-D depth profile, applies
/// floor filtering and spatial smoothing, then extracts walkable gaps.
///
/// Algorithm (inspired by gap-seeking steering research):
///   1. Sample a band of pixels per column (not a single pixel) in the
///      eye-level vertical region.
///   2. Filter out likely floor pixels using vertical depth-gradient analysis.
///   3. Take the median depth per column (robust against outliers without
///      the obstacle-bias of higher percentiles).
///   4. Smooth the profile with a [0.25, 0.5, 0.25] convolution kernel.
///   5. Apply lightweight temporal EMA to reduce frame-to-frame flicker.
///   6. Extract contiguous runs below `clearThreshold` as ClearPath candidates.
final class PathFinder {

    // MARK: - Tuning

    /// Number of horizontal sample columns — finer than single-column gives better gap resolution.
    static let columnCount = 24
    /// Horizontal pixels sampled per column (band width, centred on the column).
    private static let xBandPixels = 5
    /// Rows to sample — wider band captures more floor for better filtering.
    private static let yBandLow:  Float = 0.20
    private static let yBandHigh: Float = 0.75
    /// Vertical sample step (every Nth pixel row in the band).
    private static let ySampleStep = 6
    /// Depth below this is "clear" — no close obstacle.
    /// 0.45 lets far walls (doorways, corridors) count as walkable.
    static let clearThreshold: Float = 0.45
    /// A gap narrower than this fraction of frame width is ignored.
    private static let minGapFraction: Float = 0.15
    /// Temporal EMA alpha: higher = more responsive, lower = more stable.
    private static let temporalAlpha: Float = 0.40

    // MARK: - State

    private var prevProfile: [Float]?

    // MARK: - Public API

    /// Returns the depth profile and detected clear paths together.
    func scan(depthMap: [Float], width: Int, height: Int) -> PathScanResult {
        guard !depthMap.isEmpty, width > 1, height > 1 else {
            return PathScanResult(profile: [], paths: [])
        }
        var profile = Self.buildProfile(depthMap: depthMap, width: width, height: height)
        profile = Self.smoothProfile(profile)
        profile = applyTemporalEMA(profile)
        let paths = Self.extractGaps(from: profile)
        return PathScanResult(profile: profile, paths: paths)
    }

    /// Legacy static convenience (no temporal smoothing).
    static func scan(depthMap: [Float], width: Int, height: Int) -> PathScanResult {
        guard !depthMap.isEmpty, width > 1, height > 1 else {
            return PathScanResult(profile: [], paths: [])
        }
        var profile = buildProfile(depthMap: depthMap, width: width, height: height)
        profile = smoothProfile(profile)
        let paths = extractGaps(from: profile)
        return PathScanResult(profile: profile, paths: paths)
    }

    static func findClearPaths(depthMap: [Float], width: Int, height: Int) -> [ClearPath] {
        scan(depthMap: depthMap, width: width, height: height).paths
    }

    func reset() {
        prevProfile = nil
    }

    // MARK: - Profile construction

    /// Build the raw 1-D profile by sampling a band of pixels per column,
    /// filtering out likely floor pixels, then taking the 75th percentile.
    private static func buildProfile(depthMap: [Float], width: Int, height: Int) -> [Float] {
        let yStart = Int(yBandLow  * Float(height))
        let yEnd   = Int(yBandHigh * Float(height))
        let halfBand = xBandPixels / 2
        let cols = columnCount

        var profile = [Float](repeating: 0, count: cols)
        for col in 0..<cols {
            let xFrac = Float(col) / Float(cols - 1)
            let xCenter = min(Int(xFrac * Float(width - 1)), width - 1)
            let x0 = max(0, xCenter - halfBand)
            let x1 = min(width - 1, xCenter + halfBand)

            var samples: [Float] = []
            samples.reserveCapacity(((yEnd - yStart) / ySampleStep + 1) * (x1 - x0 + 1))

            var y = yStart
            while y < yEnd {
                for x in x0...x1 {
                    let idx = y * width + x
                    guard idx < depthMap.count else { continue }
                    let d = depthMap[idx]

                    if isLikelyFloor(depthMap: depthMap, x: x, y: y,
                                     width: width, height: height) {
                        continue
                    }
                    samples.append(d)
                }
                y += ySampleStep
            }

            if samples.isEmpty {
                profile[col] = 0
            } else {
                samples.sort()
                let median = samples[samples.count / 2]
                profile[col] = median
            }
        }
        return profile
    }

    // MARK: - Floor filtering

    /// Heuristic: floor pixels show a smooth vertical depth gradient (depth
    /// increases as we look down) while obstacles have roughly constant depth
    /// vertically. For monocular depth (0 = far, 1 = near), floor below the
    /// camera gets nearer toward the bottom of the frame.
    ///
    /// Aggressive filtering: we'd rather accidentally drop a few obstacle
    /// pixels than mistake walkable floor for a wall.
    private static func isLikelyFloor(
        depthMap: [Float], x: Int, y: Int, width: Int, height: Int
    ) -> Bool {
        let step = 6
        guard y + step < height else { return false }
        let curr = depthMap[y * width + x]
        let below = depthMap[(y + step) * width + x]
        let diff = below - curr
        let yFrac = Float(y) / Float(height)

        // Any downward gradient (nearer below) in lower 60% of frame → floor
        if diff > 0.04 && yFrac > 0.40 { return true }

        // Moderate gradient anywhere → floor
        if diff > 0.07 { return true }

        // Flat region in lower 45% of frame → ground plane
        if abs(diff) < 0.035 && yFrac > 0.55 { return true }

        // Very high depth (close) in bottom quarter → almost certainly floor
        if curr > 0.60 && yFrac > 0.65 { return true }

        return false
    }

    // MARK: - Spatial smoothing

    /// [0.25, 0.5, 0.25] convolution kernel — removes single-column noise
    /// without smearing real obstacle edges too much.
    private static func smoothProfile(_ raw: [Float]) -> [Float] {
        let n = raw.count
        guard n >= 3 else { return raw }
        var out = [Float](repeating: 0, count: n)
        out[0]     = 0.75 * raw[0] + 0.25 * raw[1]
        out[n - 1] = 0.25 * raw[n - 2] + 0.75 * raw[n - 1]
        for i in 1..<(n - 1) {
            out[i] = 0.25 * raw[i - 1] + 0.50 * raw[i] + 0.25 * raw[i + 1]
        }
        return out
    }

    // MARK: - Temporal EMA

    /// Blends the current profile with the previous frame's to reduce flicker.
    private func applyTemporalEMA(_ profile: [Float]) -> [Float] {
        guard let prev = prevProfile, prev.count == profile.count else {
            prevProfile = profile
            return profile
        }
        let alpha = Self.temporalAlpha
        var blended = [Float](repeating: 0, count: profile.count)
        for i in 0..<profile.count {
            blended[i] = alpha * profile[i] + (1 - alpha) * prev[i]
        }
        prevProfile = blended
        return blended
    }

    // MARK: - Gap extraction

    private static func extractGaps(from profile: [Float]) -> [ClearPath] {
        let n = profile.count
        var paths: [ClearPath] = []
        var gapStart: Int? = nil

        func close(at end: Int) {
            guard let start = gapStart else { return }
            gapStart = nil
            guard end >= start else { return }
            let gapFraction = Float(end - start + 1) / Float(n)
            guard gapFraction >= minGapFraction else { return }

            let slice = profile[start...end]
            let avgDepth = slice.reduce(0, +) / Float(slice.count)
            let centre = Float(start + end) / 2.0 / Float(n - 1)
            let conf = gapFraction * (1.0 - avgDepth)
            paths.append(ClearPath(azimuthFraction: centre,
                                   width: gapFraction,
                                   avgDepth: avgDepth,
                                   confidence: conf))
        }

        for col in 0..<n {
            if profile[col] < clearThreshold {
                if gapStart == nil { gapStart = col }
            } else {
                close(at: col - 1)
            }
        }
        close(at: n - 1)

        return paths.sorted { $0.confidence > $1.confidence }
    }
}
