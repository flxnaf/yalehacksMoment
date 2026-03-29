import AVFoundation
import Foundation

/// Lightweight ElevenLabs REST TTS client with in-memory caching.
///
/// Navigation cues are short, repeated phrases so we pre-generate and cache
/// the audio data on first use to eliminate network latency on subsequent plays.
final class ElevenLabsTTSClient: @unchecked Sendable {

    static let shared = ElevenLabsTTSClient()

    private let voiceId = "JBFqnCBsd6RMkjVDRZzb" // George — deep, calm
    private let modelId = "eleven_turbo_v2_5"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    private var cache: [String: Data] = [:]
    private let lock = NSLock()

    /// Known nav cues — pre-warmed at startup.
    static let navPhrases = [
        "Stop", "Path clear",
        "No clear path", "Entered new room. Turn around to exit.", "Left room.",
        "Path to your left and right", "Door to your left and right",
        "Corridor to your left and right"
    ]

    /// Fall / SOS lines spoken via `AudioOrchestrator` at `.hazard` — prewarm to reduce countdown latency.
    static let fallHazardPhrases = [
        "Fall detected. Alerting your guardian in 10 seconds. Double-tap to cancel.",
        "5 seconds. Double-tap to cancel.",
        "3 seconds. Double-tap to cancel.",
        "Alert cancelled.",
        "No guardian configured.",
        "Guardian alerted. Help is on the way.",
        "Guardian alerted by email and text.",
        "Guardian emailed. Send the text message if Messages opened with a draft.",
        "Alert failed to send. Please call for help manually.",
        "Email could not be sent. Text to your guardian was sent or opened in Messages.",
        "You've arrived.",
    ]

    // MARK: - Pre-warm

    /// Call once on app launch to pre-generate all known cues.
    func prewarm() {
        let apiKey = Secrets.elevenLabsAPIKey
        guard !apiKey.isEmpty, apiKey != "YOUR_ELEVENLABS_API_KEY" else {
            print("[ElevenLabs] No API key — will fall back to system speech")
            return
        }
        for phrase in Self.navPhrases {
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await self?.audioData(for: phrase)
            }
        }
        for phrase in Self.fallHazardPhrases {
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await self?.audioData(for: phrase)
            }
        }
    }

    // MARK: - Generate or fetch from cache

    func audioData(for text: String) async throws -> Data {
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let data = try await requestTTS(text: text)

        lock.lock()
        cache[text] = data
        lock.unlock()

        return data
    }

    // MARK: - REST call

    private func requestTTS(text: String) async throws -> Data {
        let apiKey = Secrets.elevenLabsAPIKey
        guard !apiKey.isEmpty, apiKey != "YOUR_ELEVENLABS_API_KEY" else {
            throw TTSError.noAPIKey
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.75,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TTSError.httpError(code)
        }
        return data
    }

    enum TTSError: LocalizedError {
        case noAPIKey
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "ElevenLabs API key not configured"
            case .httpError(let c): return "ElevenLabs HTTP \(c)"
            }
        }
    }
}
