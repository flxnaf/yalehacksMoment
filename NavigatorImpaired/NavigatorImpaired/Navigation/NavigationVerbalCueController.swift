import AVFoundation
import Foundation

/// Short throttled spoken cues driven by PathFinder clear-path results.
///
/// Multi-path announcements ("Door to your left and right") use scene
/// classification for context-aware labels. Single-path direction cues
/// (veer left/right) have been removed — the beacon chord direction
/// and Gemini voice guidance handle steering instead.
@MainActor
final class NavigationVerbalCueController: NSObject, ObservableObject {

    @Published private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    private var prevHadPath: Bool = false
    private var prevAzimuth: Float = 0.5

    private var lastClear: Date = .distantPast
    private var lastNoPath: Date = .distantPast
    private var lastMultiPath: Date = .distantPast

    private let throttleClear: TimeInterval = 12
    private let throttleNoPath: TimeInterval = 8
    private let throttleMultiPath: TimeInterval = 10

    /// Consecutive frames with no path before announcing "No clear path".
    private let noPathFramesRequired = 15
    private var noPathFrameCount = 0

    let roomDetector = RoomTransitionDetector()

    override init() {
        super.init()
        synthesizer.delegate = self
        ElevenLabsTTSClient.shared.prewarm()
    }

    /// Call once per depth frame with the active clear path from the chord
    /// beacon logic and the depth profile for room detection.
    /// - Parameters:
    ///   - activePath: The single best clear path from the beacon logic.
    ///   - allPaths: All detected clear paths for multi-exit announcements.
    ///   - doorDetected: Scene classifier thinks there is a door in the frame.
    ///   - corridorDetected: Scene classifier thinks there is a corridor/hallway.
    func process(activePath: ClearPath?,
                 allPaths: [ClearPath] = [],
                 doorDetected: Bool = false,
                 corridorDetected: Bool = false,
                 geminiSpeaking: Bool,
                 depthProfile: [Float] = [],
                 heading: Float = 0) {
        // Room detection
        if !depthProfile.isEmpty {
            if let roomCue = roomDetector.update(
                profile: depthProfile,
                clearThreshold: PathFinder.clearThreshold,
                heading: heading
            ) {
                if !geminiSpeaking { speak(roomCue) }
            }
        }

        if geminiSpeaking { return }

        let now = Date()
        let hasPath = activePath != nil

        // Multi-path announcements: when we see paths on both sides
        if allPaths.count >= 2,
           now.timeIntervalSince(lastMultiPath) > throttleMultiPath {
            let hasLeft = allPaths.contains { $0.azimuthFraction < 0.4 }
            let hasRight = allPaths.contains { $0.azimuthFraction > 0.6 }

            if hasLeft && hasRight {
                let label = doorDetected ? "Door" : (corridorDetected ? "Corridor" : "Path")
                speak("\(label) to your left and right")
                lastMultiPath = now
                prevHadPath = hasPath
                return
            }
        }

        if let path = activePath {
            noPathFrameCount = 0

            if !prevHadPath, now.timeIntervalSince(lastClear) > throttleClear {
                speak("Path clear")
                lastClear = now
            }

            prevAzimuth = path.azimuthFraction
        } else {
            noPathFrameCount += 1

            if noPathFrameCount >= noPathFramesRequired,
               prevHadPath,
               now.timeIntervalSince(lastNoPath) > throttleNoPath {
                speak("No clear path")
                lastNoPath = now
            }
        }

        prevHadPath = hasPath
    }

    func reset() {
        prevHadPath = false
        prevAzimuth = 0.5
        noPathFrameCount = 0
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        isSpeaking = false
        roomDetector.reset()
    }

    // MARK: - Speech (ElevenLabs → fallback to system TTS)

    private func speak(_ text: String) {
        isSpeaking = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try await ElevenLabsTTSClient.shared.audioData(for: text)
                await self?.playAudioData(data)
            } catch {
                print("[VerbalCue] ElevenLabs failed (\(error.localizedDescription)), falling back to system TTS")
                await self?.fallbackSpeak(text)
            }
        }
    }

    private func playAudioData(_ data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.volume = 1.0
            self.audioPlayer = player
            player.play()
        } catch {
            print("[VerbalCue] AVAudioPlayer error: \(error)")
            isSpeaking = false
        }
    }

    private func fallbackSpeak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(u)
    }
}

// MARK: - AVSpeechSynthesizerDelegate (fallback)

extension NavigationVerbalCueController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

// MARK: - AVAudioPlayerDelegate (ElevenLabs playback)

extension NavigationVerbalCueController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
