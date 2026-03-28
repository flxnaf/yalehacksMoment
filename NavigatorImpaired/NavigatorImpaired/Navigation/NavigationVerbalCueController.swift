import AVFoundation
import Foundation

/// Short throttled spoken cues for obstacle state transitions (supplements nav TTS, not duplicate).
@MainActor
final class NavigationVerbalCueController: NSObject, ObservableObject {

    @Published private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var prevUrgency: Double = 0
    private var prevDirection: String = "straight"

    private var lastCritical: Date = .distantPast
    private var lastDirection: Date = .distantPast
    private var lastClear: Date = .distantPast
    private var lastStop: Date = .distantPast

    private let throttleCritical: TimeInterval = 3
    private let throttleDirection: TimeInterval = 5
    private let throttleClear: TimeInterval = 10
    private let throttleStop: TimeInterval = 5

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Call once per depth frame after obstacle analysis. Skips if Gemini is speaking unless urgency is critical.
    func process(obstacle: ObstacleAnalysis, geminiSpeaking: Bool) {
        let now = Date()
        let u = obstacle.urgency
        let dir = obstacle.recommendedDirection

        if geminiSpeaking && u <= 0.7 {
            prevUrgency = u
            prevDirection = dir
            return
        }

        if prevUrgency <= 0.4 && u > 0.7, now.timeIntervalSince(lastCritical) > throttleCritical {
            speak("Stop")
            lastCritical = now
        }

        if dir != prevDirection, now.timeIntervalSince(lastDirection) > throttleDirection {
            switch dir {
            case "left": speak("Veer left")
            case "right": speak("Veer right")
            case "stop": break
            default: break
            }
            if dir == "left" || dir == "right" { lastDirection = now }
        }

        if prevUrgency > 0.4 && u <= 0.1, now.timeIntervalSince(lastClear) > throttleClear {
            speak("Path clear")
            lastClear = now
        }

        if dir == "stop", prevDirection != "stop", now.timeIntervalSince(lastStop) > throttleStop {
            speak("No clear path")
            lastStop = now
        }

        prevUrgency = u
        prevDirection = dir
    }

    func reset() {
        prevUrgency = 0
        prevDirection = "straight"
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(u)
        isSpeaking = true
    }
}

extension NavigationVerbalCueController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
