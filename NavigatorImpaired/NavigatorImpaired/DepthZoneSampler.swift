import AVFoundation

// MARK: - Zone definition

enum DepthZone: Int, CaseIterable, Hashable {
    case middleLeft
    case middleCenter
    case middleRight

    /// 3D position in AVFoundation listener-relative space.
    /// Sources are spread wide (±56° azimuth) so HRTF panning is clearly audible.
    var audioPosition: AVAudio3DPoint {
        switch self {
        case .middleLeft:   return AVAudio3DPoint(x: -1.8, y: 0.0, z: -1.0)
        case .middleCenter: return AVAudio3DPoint(x:  0.0, y: 0.0, z: -1.5)
        case .middleRight:  return AVAudio3DPoint(x:  1.8, y: 0.0, z: -1.0)
        }
    }

    /// Carrier frequency for the FM obstacle voice.
    /// Spread across F#3–C4 so each zone has a distinct pitch even without HRTF.
    var carrierFrequency: Float {
        switch self {
        case .middleLeft:   return 185   // F#3 — warm low
        case .middleCenter: return 220   // A3  — neutral center
        case .middleRight:  return 262   // C4  — slightly brighter
        }
    }
}

// MARK: - Sampler

struct DepthZoneSampler {

    /// Returns the "nearest-object" depth score [0,1] for each zone.
    /// 0 = farthest, 1 = closest. Zones below the proximity threshold are omitted.
    ///
    /// - Parameters:
    ///   - depthMap: Row-major float array from DepthInferenceEngine (1 = closest pixel in frame).
    ///   - width: Map width in pixels.
    ///   - height: Map height in pixels.
    /// - Returns: Dictionary keyed by zone; only zones with depth > `threshold` are included.
    static func sample(
        depthMap: [Float],
        width: Int,
        height: Int,
        threshold: Float = 0.15
    ) -> [DepthZone: Float] {

        guard !depthMap.isEmpty, width > 0, height > 0 else { return [:] }

        // Middle row: vertical band from 33% to 67% of frame height.
        let yStart = height / 3
        let yEnd   = (height * 2) / 3

        // Horizontal thirds for left / center / right zones.
        let columns: [(DepthZone, xStart: Int, xEnd: Int)] = [
            (.middleLeft,   0,            width / 3),
            (.middleCenter, width / 3,    (width * 2) / 3),
            (.middleRight,  (width * 2) / 3, width)
        ]

        var result: [DepthZone: Float] = [:]

        for (zone, xStart, xEnd) in columns {
            let depth = sampleZone(
                depthMap: depthMap,
                width: width,
                yStart: yStart, yEnd: yEnd,
                xStart: xStart, xEnd: xEnd
            )
            if depth > threshold {
                result[zone] = depth
            }
        }

        return result
    }

    // MARK: - Private

    /// Samples a 5×5 subgrid inside the zone and returns the 95th-percentile value
    /// (closest objects, noise-filtered). Higher output = closer obstacle.
    private static func sampleZone(
        depthMap: [Float],
        width: Int,
        yStart: Int, yEnd: Int,
        xStart: Int, xEnd: Int
    ) -> Float {

        let zoneW = xEnd - xStart
        let zoneH = yEnd - yStart
        guard zoneW > 0, zoneH > 0 else { return 0 }

        let xStep = max(1, zoneW / 5)
        let yStep = max(1, zoneH / 5)

        var samples: [Float] = []
        samples.reserveCapacity(25)

        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let idx = y * width + x
                if idx < depthMap.count {
                    samples.append(depthMap[idx])
                }
                x += xStep
            }
            y += yStep
        }

        guard !samples.isEmpty else { return 0 }

        // Sort ascending; 95th percentile ≈ closest objects in the zone.
        samples.sort()
        let p95 = samples[min(Int(Float(samples.count) * 0.95), samples.count - 1)]
        return p95
    }
}
