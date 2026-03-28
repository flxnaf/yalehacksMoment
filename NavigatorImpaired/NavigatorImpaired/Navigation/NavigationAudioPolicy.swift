import Foundation

// MARK: - Input / Output

/// Single frame of context for routing all spatial audio. All fields are from the same depth tick.
struct AudioPolicyInput: Sendable {
    let obstacle: ObstacleAnalysis
    /// Six frontal column nearest distances in meters (smaller = closer obstacle).
    let columnDepthsMeters: [Float]
    let navigationActive: Bool
    let guidance: NavigationGuidance?
    /// Gemini model speaking and/or other assistant playback.
    let geminiSpeaking: Bool
    /// Short obstacle / nav verbal cues from `NavigationVerbalCueController`.
    let verbalCueSpeaking: Bool

    var anySpeechActive: Bool { geminiSpeaking || verbalCueSpeaking }
}

struct AudioPolicyOutput: Equatable, Sendable {
    /// Per column 0...5: whether to play pings.
    let obstacleColumnsActive: [Bool]
    let obstaclePingRateHz: [Float]
    let obstaclePingFreqHz: [Float]
    let obstacleVolume: [Float]
    let beaconEnabled: Bool
    let beaconVolume: Float
    /// Degrees: negative = left, positive = right, 0 = ahead (listener-relative).
    let beaconAzimuthDegrees: Double
    /// Multiply obstacle + beacon gains (0...1).
    let duckNonSpeech: Float
    /// 0...1; use with haptics; 0 when speech would mask vibration.
    let hapticIntensity: Float
    let speechActive: Bool
}

// MARK: - Policy engine (hysteresis + caps)

/// Policy curves with urgency EMA + frame hysteresis (10 Hz depth clock). Call once per depth frame.
///
/// `duckNonSpeech` is applied **once** in `SpatialAudioEngine` — obstacle/beacon volumes here are pre-duck magnitudes.
final class NavigationAudioPolicyEngine: @unchecked Sendable {

    /// Smoothed urgency (matches `ObstacleAnalysis.urgency` scale).
    private var urgencyEMA: Double = 0
    private let urgencySmoothingAlpha: Double = 0.38

    // Hysteresis at 10 Hz (see AUDIO_REVAMP_DIAGNOSIS_AND_PLAN §5.4)
    private var criticalLatched = false
    private var criticalEnterFrames = 0
    private var criticalExitFrames = 0
    private var cautionAboveFrames = 0
    private var cautionExitFrames = 0
    private var cautionLatched = false

    func reset() {
        urgencyEMA = 0
        criticalLatched = false
        criticalEnterFrames = 0
        criticalExitFrames = 0
        cautionAboveFrames = 0
        cautionExitFrames = 0
        cautionLatched = false
    }

    func evaluate(_ input: AudioPolicyInput) -> AudioPolicyOutput {
        let raw = input.obstacle.urgency
        urgencyEMA = urgencySmoothingAlpha * raw + (1 - urgencySmoothingAlpha) * urgencyEMA
        let u = urgencyEMA

        updateHysteresis(raw: raw)

        let band = policyBand(urgency: u, raw: raw)
        let maxCols = maxSimultaneousColumns(band: band, speech: input.anySpeechActive)

        let duck: Float = input.anySpeechActive ? 0.15 : 1.0

        let ranked = rankColumnIndicesByNearest(columns: input.columnDepthsMeters)
        var active = [Bool](repeating: false, count: 6)
        var rates = [Float](repeating: 0, count: 6)
        var freqs = [Float](repeating: 400, count: 6)
        var vols = [Float](repeating: 0, count: 6)

        var count = 0
        for idx in ranked {
            let dist = input.columnDepthsMeters[idx]
            guard dist < 2.0 else { continue }
            if count >= maxCols { break }
            active[idx] = true
            let (r, f, v) = pingParams(distanceMeters: dist)
            rates[idx] = r
            freqs[idx] = f
            vols[idx] = v
            count += 1
        }

        let (beaconOn, beaconVol, beaconAz) = beaconParams(input: input, urgency: u)

        let haptic: Float = {
            if input.anySpeechActive { return 0 }
            switch u {
            case ..<0.1: return 0
            case ..<0.4: return 0
            case ..<0.7: return 0.3
            case ..<0.9: return 0.7
            default: return 1.0
            }
        }()

        return AudioPolicyOutput(
            obstacleColumnsActive: active,
            obstaclePingRateHz: rates,
            obstaclePingFreqHz: freqs,
            obstacleVolume: vols,
            beaconEnabled: beaconOn,
            beaconVolume: Float(beaconVol),
            beaconAzimuthDegrees: beaconAz,
            duckNonSpeech: duck,
            hapticIntensity: haptic,
            speechActive: input.anySpeechActive
        )
    }

    /// Raw-urgency hysteresis: enter critical after 2 frames > 0.7; exit after 5 frames < 0.5.
    /// Caution latch: enter after 3 frames > 0.1; exit to “safe” after 5 frames ≤ 0.1.
    private func updateHysteresis(raw: Double) {
        if !criticalLatched {
            if raw > 0.7 {
                criticalEnterFrames += 1
            } else {
                criticalEnterFrames = 0
            }
            if criticalEnterFrames >= 2 {
                criticalLatched = true
                criticalEnterFrames = 0
                criticalExitFrames = 0
            }
        } else {
            if raw < 0.5 {
                criticalExitFrames += 1
            } else {
                criticalExitFrames = 0
            }
            if criticalExitFrames >= 5 {
                criticalLatched = false
                criticalExitFrames = 0
            }
        }

        if !cautionLatched {
            if raw > 0.1 {
                cautionAboveFrames += 1
            } else {
                cautionAboveFrames = 0
            }
            if cautionAboveFrames >= 3 {
                cautionLatched = true
                cautionAboveFrames = 0
                cautionExitFrames = 0
            }
        } else {
            if raw <= 0.1 {
                cautionExitFrames += 1
            } else {
                cautionExitFrames = 0
            }
            if cautionExitFrames >= 5 {
                cautionLatched = false
                cautionExitFrames = 0
            }
        }
    }

    /// Band used for polyphony caps: critical latch overrides; otherwise EMA, gated by caution latch for safe/caution edge.
    private func policyBand(urgency: Double, raw: Double) -> Band {
        if criticalLatched { return .critical }
        if !cautionLatched && raw <= 0.1 { return .safe }
        var u = urgency
        // Until caution hysteresis exits, keep at least “caution” band while raw stays above 0.1.
        if cautionLatched && raw > 0.1 {
            u = max(u, 0.11)
        }
        return urgencyBand(u)
    }

    private enum Band { case safe, caution, warning, critical }

    private func urgencyBand(_ u: Double) -> Band {
        switch u {
        case ...0.1: return .safe
        case ...0.4: return .caution
        case ...0.7: return .warning
        default: return .critical
        }
    }

    private func maxSimultaneousColumns(band: Band, speech: Bool) -> Int {
        if speech { return band == .critical ? 1 : 0 }
        switch band {
        case .safe: return 0
        case .caution: return 2
        case .warning: return 3
        case .critical: return 4
        }
    }

    private func rankColumnIndicesByNearest(columns: [Float]) -> [Int] {
        guard columns.count == 6 else { return Array(0..<6) }
        return columns.indices.sorted { columns[$0] < columns[$1] }
    }

    private func pingParams(distanceMeters d: Float) -> (Float, Float, Float) {
        switch d {
        case ..<0.5:
            return (4.0, 900, 0.55)
        case ..<1.0:
            return (2.0, 650, 0.45)
        case ..<2.0:
            return (0.75, 400, 0.35)
        default:
            return (0, 400, 0)
        }
    }

    private func beaconParams(input: AudioPolicyInput, urgency u: Double) -> (Bool, Double, Double) {
        let dir = input.obstacle.recommendedDirection
        if dir == "stop" { return (false, 0, 0) }

        let volTable: Double = {
            switch u {
            case ...0.1: return 1.0
            case ...0.4: return 0.8
            case ...0.7: return 0.5
            default: return 0.2
            }
        }()

        if input.navigationActive, let g = input.guidance {
            return (true, volTable, g.beaconAzimuth)
        }

        let az: Double = switch dir {
        case "left": -30
        case "right": 30
        default: 0
        }
        return (true, volTable, az)
    }
}
