import Speech
import AVFoundation
import UIKit

// MARK: - VoiceQueryManager

/// "Hold to Ask" voice query — the core feature from Mira (TreeHacks 2026).
///
/// The user holds a button and speaks a natural-language question like
/// "Where is the door?" or "Is there a chair in front of me?". The current
/// camera frame + spoken question are sent to Gemini Vision, and the answer
/// is spoken aloud via SmartAssistant.
///
/// Lifecycle:
///   idle → listening (button held) → processing (button released) → idle
///
/// Audio session note: SpatialAudioEngine uses AVAudioEngine for OUTPUT only.
/// This class taps the INPUT node on a separate AVAudioEngine. Both share the
/// existing .playAndRecord session without conflict.
///
/// Required Info.plist keys:
///   NSSpeechRecognitionUsageDescription  "Used to answer your spoken questions about the scene."
///   NSMicrophoneUsageDescription         "Used to hear your navigation questions."
@MainActor
final class VoiceQueryManager: ObservableObject {

    // MARK: - State

    enum QueryState: Equatable {
        case idle
        case listening(partial: String)
        case processing
    }

    @Published var state: QueryState = .idle

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    // MARK: - Private

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let captureEngine = AVAudioEngine()

    // MARK: - Permission

    /// Request both microphone and speech recognition permissions.
    /// Call once on first use; subsequent calls are no-ops if already granted.
    func requestPermissions() async -> Bool {
        let micStatus = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard micStatus else {
            print("[VoiceQuery] ❌ Microphone permission denied")
            return false
        }

        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            print("[VoiceQuery] ❌ Speech recognition permission denied: \(speechStatus.rawValue)")
            return false
        }

        print("[VoiceQuery] ✅ Permissions granted")
        return true
    }

    // MARK: - Start listening

    /// Begin capturing speech. Call when the user presses the mic button.
    /// Speaks "Listening" immediately as tactile confirmation for blind users.
    func startListening(assistant: SmartAssistant) {
        guard state == .idle else { return }
        guard recognizer?.isAvailable == true else {
            print("[VoiceQuery] ❌ Speech recognizer unavailable")
            assistant.speak("Voice query unavailable", force: true)
            return
        }

        stopInternal()   // clean up any previous session

        do {
            try beginCapture()
            print("CHANGED [Mira] Voice query capture started")
            print("[VoiceQuery] 🎙 Listening...")
            assistant.speak("Listening", force: true)
        } catch {
            print("[VoiceQuery] ❌ Failed to start capture: \(error)")
            assistant.speak("Microphone error", force: true)
            state = .idle
        }
    }

    // MARK: - Stop and query

    /// Stop capturing and send the transcript + frame to Gemini.
    /// Call when the user releases the mic button.
    func stopAndQuery(image: UIImage,
                      sceneContext: String?,
                      assistant: SmartAssistant) {
        // Extract transcript before teardown
        let transcript: String
        if case .listening(let partial) = state {
            transcript = partial
        } else {
            return
        }

        stopInternal()

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[VoiceQuery] ⚠️ No speech detected")
            assistant.speak("I didn't hear a question", force: true)
            state = .idle
            return
        }

        print("[VoiceQuery] 📝 Question: \"\(transcript)\"")
        state = .processing
        assistant.speak("Looking", force: true)

        NetworkManager.queryScene(image: image,
                                  question: transcript,
                                  sceneContext: sceneContext) { [weak self] answer in
            guard let self else { return }
            self.state = .idle
            let response = answer ?? "I couldn't find an answer. Try again."
            print("[VoiceQuery] 💬 Answer: \"\(response)\"")
            assistant.speak(response, force: true)
        }
    }

    /// Cancel listening without sending a query (e.g. accidental press).
    func cancel() {
        stopInternal()
        state = .idle
        print("[VoiceQuery] Cancelled")
    }

    // MARK: - Private helpers

    private func beginCapture() throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest, let recognizer else { return }
        request.shouldReportPartialResults = true
        request.taskHint = .search    // optimises recognizer for short queries

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.state = .listening(partial: text)
                    if result.isFinal {
                        print("CHANGED [Mira] Final transcript: \(text)")
                    } else if !text.isEmpty {
                        print("[Mira] Partial transcript: \(text)")
                    }
                }
                if let error {
                    print("[VoiceQuery] Recognition error: \(error.localizedDescription)")
                }
            }
        }

        let inputNode = captureEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }

        captureEngine.prepare()
        try captureEngine.start()
        state = .listening(partial: "")
    }

    private func stopInternal() {
        captureEngine.stop()
        captureEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
