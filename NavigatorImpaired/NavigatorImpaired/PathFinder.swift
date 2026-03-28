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

    static let columnCount = 24
    private static let xBandPixels = 5
    private static let yBandLow:  Float = 0.20
    private static let yBandHigh: Float = 0.75
    private static let ySampleStep = 6
    static let clearThreshold: Float = 0.38
    private static let minGapFraction: Float = 0.10
    private static let temporalAlpha: Float = 0.40
    /// Columns with vertical depth stddev below this are likely flat walls,
    /// not open space. Walls have uniform depth; corridors/doorways do not.
    /// Kept conservative (0.02) because floor filtering removes the highest-
    /// variance samples, so even real open space can have moderate variance.
    private static let wallStddevThreshold: Float = 0.02

    // MARK: - State

    private var prevProfile: [Float]?

    // MARK: - Public API

    func scan(depthMap: [Float], width: Int, height: Int, wallHint: Bool = false) -> PathScanResult {
        guard !depthMap.isEmpty, width > 1, height > 1 else {
            return PathScanResult(profile: [], paths: [])
        }
        let effectiveWallThreshold = wallHint
            ? Self.wallStddevThreshold * 1.5
            : Self.wallStddevThreshold
        var profile = Self.buildProfile(depthMap: depthMap, width: width, height: height,
                                        wallStddev: effectiveWallThreshold)
        profile = Self.smoothProfile(profile)
        profile = applyTemporalEMA(profile)
        let paths = Self.extractGaps(from: profile)
        return PathScanResult(profile: profile, paths: paths)
    }

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

    private static func buildProfile(depthMap: [Float], width: Int, height: Int,
                                     wallStddev: Float = wallStddevThreshold) -> [Float] {
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

                // Wall detection: only for columns well below threshold
                // (suspicious "looks very far" readings) with truly uniform
                // depth. After floor filtering, real corridors still show some
                // variance from objects at different distances.
                if median < (clearThreshold - 0.10) && samples.count >= 8 {
                    let mean = samples.reduce(0, +) / Float(samples.count)
                    var sumSq: Float = 0
                    for s in samples { sumSq += (s - mean) * (s - mean) }
                    let stddev = sqrtf(sumSq / Float(samples.count))
                    if stddev < wallStddev {
                        profile[col] = clearThreshold + 0.05
                        continue
                    }
                }

                profile[col] = median
            }
        }
        return profile
    }

    // MARK: - Floor filtering

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

    // MARK: - Spatial smoothing

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
