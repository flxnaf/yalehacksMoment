import AVFoundation
import Foundation

/// Verbal cue controller — all path/direction cues have been removed.
/// Audio navigation is now handled by the shrine ping beacon + Gemini voice.
/// Room detection is retained for future use.
@MainActor
final class NavigationVerbalCueController: NSObject, ObservableObject {

    @Published private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    let roomDetector = RoomTransitionDetector()

    override init() {
        super.init()
        synthesizer.delegate = self
        ElevenLabsTTSClient.shared.prewarm()
    }

    /// Call once per depth frame. Only room detection is active;
    /// all path/direction verbal cues have been removed.
    func process(activePath: ClearPath?,
                 allPaths: [ClearPath] = [],
                 doorDetected: Bool = false,
                 corridorDetected: Bool = false,
                 geminiSpeaking: Bool,
                 depthProfile: [Float] = [],
                 heading: Float = 0) {
        if !depthProfile.isEmpty {
            if let roomCue = roomDetector.update(
                profile: depthProfile,
                clearThreshold: PathFinder.clearThreshold,
                heading: heading
            ) {
                if !geminiSpeaking { speak(roomCue) }
            }
        }
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
