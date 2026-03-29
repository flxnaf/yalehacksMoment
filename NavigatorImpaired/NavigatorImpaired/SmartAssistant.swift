import AVFoundation
import Foundation

// MARK: - SmartAssistant

/// Replaces continuous audio beeping with high-value verbal navigation cues.
///
/// Three subsystems work together:
///
///   1. **Clock-face spatial audio** — converts a detection's normalised horizontal
///      position into a clock-face string ("12 o'clock", "3 o'clock", etc.) and
///      speaks it via `AVSpeechSynthesizer`. Only fires when confidence > 0.8 and
///      the obstacle is within the configurable distance threshold (~1.5 m).
///
///   2. **Smart silence / cooldown** — normal announcements are throttled to at most
///      once every `cooldownInterval` seconds. Major hazards (very close obstacles)
///      bypass the cooldown and interrupt any current speech immediately.
///
///   3. **Scene description output** — `speak(_:force:)` is the single exit point
///      for all verbal output, including LLM scene summaries from `NetworkManager`.
///
/// Depth convention: `estimatedDepth` is 0 = far, 1 = near (same as depth map).
/// Metric approximation via the audio engine's mapping: 0.8 + (1-d)*4.5 metres.
///   • depth > 0.844  ≈ closer than 1.5 m  → normal threshold
///   • depth > 0.956  ≈ closer than ~0.8 m → major hazard, bypasses cooldown
@MainActor
final class SmartAssistant {

    // MARK: - Tunable thresholds

    /// Minimum Vision confidence to trigger any announcement.
    var minimumConfidence: Float = 0.8

    /// Depth gate for normal announcements (≈ 1.5 m).
    var normalDepthThreshold: Float = 0.844

    /// Depth gate that overrides the cooldown (≈ 0.8 m — major hazard).
    var hazardDepthThreshold: Float = 0.956

    /// Minimum seconds between normal announcements (Smart Silence).
    var cooldownInterval: TimeInterval = 3.0

    // MARK: - Private state

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpeakTime: Date = .distantPast

    // MARK: - Public API

    /// Evaluate the latest person detections and announce the most urgent one.
    ///
    /// Call this once per inference frame. The cooldown prevents speech spam even
    /// when called at full inference rate (~10 fps).
    func processDetections(_ detections: [PersonDetection]) {
        print("🧠 [SmartAssistant] processDetections called — \(detections.count) total detections")

        // Find the closest detection that passes both gates, preferring higher depth.
        guard let best = detections
            .filter({ $0.confidence > minimumConfidence })
            .filter({ ($0.estimatedDepth ?? 0) > normalDepthThreshold })
            .max(by: { ($0.estimatedDepth ?? 0) < ($1.estimatedDepth ?? 0) })
        else {
            if !detections.isEmpty {
                let reasons = detections.map {
                    "conf=\(String(format: "%.2f", $0.confidence)) depth=\(String(format: "%.2f", $0.estimatedDepth ?? 0))"
                }.joined(separator: ", ")
                print("🧠 [SmartAssistant] ❌ All detections filtered out — \(reasons)")
            }
            return
        }

        let depth         = best.estimatedDepth ?? 0
        let isMajorHazard = depth > hazardDepthThreshold
        let elapsed       = Date().timeIntervalSince(lastSpeakTime)

        print("🧠 [SmartAssistant] ✅ Best detection — conf=\(String(format: "%.2f", best.confidence)) depth=\(String(format: "%.2f", depth)) azimuth=\(String(format: "%.2f", best.azimuthFraction)) hazard=\(isMajorHazard) cooldownRemaining=\(String(format: "%.1f", max(0, cooldownInterval - elapsed)))s")

        // Respect cooldown unless this is a major hazard.
        guard isMajorHazard || elapsed >= cooldownInterval else {
            print("🧠 [SmartAssistant] ⏱ Cooldown active — \(String(format: "%.1f", cooldownInterval - elapsed))s remaining, skipping")
            return
        }

        let clock  = clockPosition(for: best.azimuthFraction)
        let prefix = isMajorHazard ? "Warning! " : ""
        let phrase = "\(prefix)Person at \(clock)"
        print("🧠 [SmartAssistant] 🔊 Speaking: \"\(phrase)\"")
        speak(phrase, force: isMajorHazard)
    }

    /// Speak `text` aloud.
    ///
    /// - Parameter force: If `true`, interrupt any current speech immediately.
    ///                    Use `true` for hazard alerts and LLM scene summaries.
    func speak(_ text: String, force: Bool = false) {
        if synthesizer.isSpeaking {
            guard force else {
                print("🔊 [SmartAssistant] speak() blocked — already speaking, force=false")
                return
            }
            print("🔊 [SmartAssistant] Interrupting current speech (force=true)")
            synthesizer.stopSpeaking(at: .immediate)
        }

        print("🔊 [SmartAssistant] ▶️ speak(\"\(text)\")")
        let utterance             = AVSpeechUtterance(string: text)
        utterance.voice           = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate            = 0.52    // Slightly faster than default for navigation
        utterance.volume          = 1.0
        utterance.pitchMultiplier = 1.1

        synthesizer.speak(utterance)
        lastSpeakTime = Date()
    }

    // MARK: - Clock-face mapping

    /// Converts a normalised horizontal position [0, 1] to a clock-face string.
    ///
    /// Assumes a 120° camera field of view, so:
    ///   azimuth 0.0 → −60° (far left)   azimuth 0.5 → 0° (12 o'clock)
    ///   azimuth 1.0 → +60° (far right)
    ///
    /// Clock segments (positive = right of centre):
    ///   −15°…+15°  → "12 o'clock"
    ///   +15°…+45°  → "1 or 2 o'clock"
    ///   +45°…+90°  → "3 o'clock"
    ///   −15°…−45°  → "10 or 11 o'clock"
    ///   −45°…−90°  → "9 o'clock"
    func clockPosition(for azimuthFraction: Float) -> String {
        let degrees = (azimuthFraction - 0.5) * 120   // −60 … +60

        switch degrees {
        case  -15 ..<  15:  return "12 o'clock"
        case   15 ..<  45:  return "1 or 2 o'clock"
        case   45 ... 90:   return "3 o'clock"
        case  -45 ..< -15:  return "10 or 11 o'clock"
        default:            return degrees < 0 ? "9 o'clock" : "3 o'clock"
        }
    }
}
