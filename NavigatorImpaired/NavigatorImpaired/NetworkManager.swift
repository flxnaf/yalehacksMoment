import Foundation
import UIKit

// MARK: - NetworkManager

/// Sends a camera frame to the Gemini Vision API and returns a concise scene
/// description suitable for reading aloud to a blind user.
///
/// Uses the `gemini-1.5-flash` model for low-latency responses (~1–2 s).
/// The API key is read from `Secrets.geminiAPIKey`.
///
/// Usage:
/// ```swift
/// NetworkManager.describeScene(image: frame) { description in
///     smartAssistant.speak(description ?? "Scene analysis unavailable", force: true)
/// }
/// ```
struct NetworkManager {

    // MARK: - Private constants

    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

    private static var apiKey: String {
        SettingsManager.shared.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prompt engineered for concise, practical navigation guidance for blind users.
    private static let scenePrompt = """
        You are a navigation assistant for a blind person. \
        Give the most practical guidance for the next few steps in 35 words or fewer. \
        Start with whether the path at 12 o clock is clear or blocked. \
        Then mention the nearest person, obstacle, doorway, turn, or landmark. \
        Use only clock-face directions with this style: 12 o clock, 1 or 2 o clock, 3 o clock, 10 or 11 o clock, 9 o clock. \
        Prefer distance words like close, a few steps, or farther. \
        Avoid colors, appearance, and non-actionable details. \
        Do not use apostrophes in clock positions.
        """

    // MARK: - Public API

    /// Encode `image` as JPEG, call Gemini Vision, and return the model's text
    /// on the **main thread** via `completion`. Passes `nil` on any failure.
    ///
    /// - Parameters:
    ///   - image:      The current camera frame to analyse.
    ///   - completion: Called on the main thread with the description or `nil`.
    static func describeScene(image: UIImage,
                              destination: String? = nil,
                              completion: @escaping @MainActor (String?) -> Void) {
        guard apiKey != "YOUR_GEMINI_API_KEY", !apiKey.isEmpty else {
            print("[NetworkManager] Gemini API key is missing")
            Task { @MainActor in completion(nil) }
            return
        }

        // Compress to JPEG at 50% quality — sufficient for scene understanding,
        // and keeps the Base64 payload small enough for fast API round-trips.
        guard let jpegData = image.jpegData(compressionQuality: 0.5) else {
            Task { @MainActor in completion(nil) }
            return
        }

        let base64Image = jpegData.base64EncodedString()

        let destinationPromptPart: String
        if let destination,
           !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destinationPromptPart =
                " The user wants to go to \(destination). Tailor the guidance toward reaching that destination if the route is visible or infer the best immediate next movement."
        } else {
            destinationPromptPart = ""
        }

        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": scenePrompt + destinationPromptPart],
                    [
                        "inline_data": [
                            "mime_type": "image/jpeg",
                            "data": base64Image
                        ]
                    ]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 100,   // short spoken guidance with a little room for landmarks
                "temperature": 0.2        // Low temperature for consistent, factual output
            ]
        ]

        guard let url = URL(string: "\(endpoint)?key=\(apiKey)"),
              let payload = try? JSONSerialization.data(withJSONObject: requestBody)
        else {
            Task { @MainActor in completion(nil) }
            return
        }

        var request        = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody   = payload

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("[NetworkManager] Request failed: \(error.localizedDescription)")
                Task { @MainActor in completion(nil) }
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("[NetworkManager] HTTP \(http.statusCode): \(body.prefix(500))")
                Task { @MainActor in completion(nil) }
                return
            }

            guard let data else {
                Task { @MainActor in completion(nil) }
                return
            }

            let text = parseGeminiResponse(data)
            if let text {
                print("[NetworkManager] Scene: \(text)")
            } else {
                print("[NetworkManager] Failed to parse response")
            }
            Task { @MainActor in completion(text) }
        }.resume()
    }

    // MARK: - Obstacle identification (depth-triggered Gemini)

    /// Prompt tuned for fast, actionable obstacle identification.
    /// Asks Gemini to name close objects + clock-face direction + distance, ≤ 20 words.
    private static let obstaclePrompt = """
        You are a real-time obstacle detection system built into a navigation app for a blind person. \
        Look at this image and describe what is directly ahead. \
        You must always give a response — never decline. \
        If the way ahead looks open say: Path clear. \
        If objects are visible within a few meters name each one with a clock direction and distance. \
        Clock directions: 12 o clock is straight ahead, 3 o clock is right, 9 o clock is left, \
        1 or 2 o clock is slightly right, 10 or 11 o clock is slightly left. \
        Distance words: very close, close, nearby. \
        Reply in 15 words or fewer. No apostrophes. \
        Examples: Path clear. Or: Chair at 12 o clock close. Wall at 3 o clock nearby.
        """

    /// Send the current frame to Gemini and return a spoken obstacle description.
    /// Designed to be called only when the depth map has already confirmed something close.
    ///
    /// - Parameters:
    ///   - image:      Camera frame to send.
    ///   - completion: Called on the main thread with the spoken text or `nil` on failure.
    static func identifyObstacles(image: UIImage,
                                  completion: @escaping @MainActor (String?) -> Void) {
        guard apiKey != "YOUR_GEMINI_API_KEY", !apiKey.isEmpty else {
            print("[NetworkManager] identifyObstacles: API key missing")
            Task { @MainActor in completion(nil) }
            return
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.45) else {
            Task { @MainActor in completion(nil) }
            return
        }

        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": obstaclePrompt],
                    ["inline_data": ["mime_type": "image/jpeg",
                                     "data": jpegData.base64EncodedString()]]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 60,
                "temperature": 0.1    // near-zero: we want consistent, factual output
            ]
        ]

        guard let url = URL(string: "\(endpoint)?key=\(apiKey)"),
              let payload = try? JSONSerialization.data(withJSONObject: requestBody)
        else {
            Task { @MainActor in completion(nil) }
            return
        }

        var request        = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody   = payload

        print("[NetworkManager] identifyObstacles: sending frame…")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("[NetworkManager] identifyObstacles: \(error.localizedDescription)")
                Task { @MainActor in completion(nil) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("[NetworkManager] identifyObstacles HTTP \(http.statusCode): \(body.prefix(400))")
                Task { @MainActor in completion(nil) }
                return
            }
            guard let data else { Task { @MainActor in completion(nil) }; return }
            let text = parseGeminiResponse(data)
            print("[NetworkManager] identifyObstacles: \(text ?? "<nil>")")
            Task { @MainActor in completion(text) }
        }.resume()
    }

    // MARK: - Voice query (Hold-to-Ask)

    /// Prompt tuned for answering a specific object-location question from the user.
    private static let queryPromptTemplate = """
        You are a navigation assistant for a blind person. \
        The user asked: "%@". \
        Answer in 20 words or fewer using clock-face directions (12 o clock, 3 o clock, 9 o clock, etc.) \
        and distance words (close, a few steps, farther). \
        If the item is not visible, say so in 5 words. \
        Do not use apostrophes in clock positions.
        """

    /// Send a camera frame + spoken question to Gemini and return the answer.
    /// Called by `VoiceQueryManager` after the user releases the mic button.
    ///
    /// - Parameters:
    ///   - image:        The current camera frame at the time the button was released.
    ///   - question:     The transcript of what the user asked.
    ///   - sceneContext: Optional recent scene description to give Gemini extra context.
    ///   - completion:   Called on the main thread with the answer or `nil` on failure.
    static func queryScene(image: UIImage,
                           question: String,
                           sceneContext: String?,
                           completion: @escaping @MainActor (String?) -> Void) {
        guard apiKey != "YOUR_GEMINI_API_KEY", !apiKey.isEmpty else {
            print("[NetworkManager] queryScene: API key missing")
            Task { @MainActor in completion(nil) }
            return
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.5) else {
            Task { @MainActor in completion(nil) }
            return
        }

        let base64Image = jpegData.base64EncodedString()
        let prompt = String(format: queryPromptTemplate, question)
        let contextNote = sceneContext.map { "\nFor context, the scene was recently described as: \($0)" } ?? ""

        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt + contextNote],
                    [
                        "inline_data": [
                            "mime_type": "image/jpeg",
                            "data": base64Image
                        ]
                    ]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 60,
                "temperature": 0.2
            ]
        ]

        guard let url = URL(string: "\(endpoint)?key=\(apiKey)"),
              let payload = try? JSONSerialization.data(withJSONObject: requestBody)
        else {
            Task { @MainActor in completion(nil) }
            return
        }

        var request        = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody   = payload

        print("[NetworkManager] queryScene: sending — question=\"\(question)\"")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("[NetworkManager] queryScene: request failed: \(error.localizedDescription)")
                Task { @MainActor in completion(nil) }
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("[NetworkManager] queryScene: HTTP \(http.statusCode): \(body.prefix(500))")
                Task { @MainActor in completion(nil) }
                return
            }

            guard let data else {
                Task { @MainActor in completion(nil) }
                return
            }

            let text = parseGeminiResponse(data)
            if let text {
                print("[NetworkManager] queryScene answer: \(text)")
            } else {
                print("[NetworkManager] queryScene: failed to parse response")
            }
            Task { @MainActor in completion(text) }
        }.resume()
    }

    // MARK: - Response parsing

    /// Extracts the text content from a Gemini `generateContent` JSON response.
    ///
    /// Expected structure:
    /// ```json
    /// { "candidates": [{ "content": { "parts": [{ "text": "..." }] } }] }
    /// ```
    private static func parseGeminiResponse(_ data: Data) -> String? {
        guard
            let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first      = candidates.first,
            let content    = first["content"] as? [String: Any],
            let parts      = content["parts"] as? [[String: Any]],
            let text       = parts.first?["text"] as? String
        else {
            // Log raw response for debugging when parsing fails
            if let raw = String(data: data, encoding: .utf8) {
                print("[NetworkManager] Raw response: \(raw.prefix(300))")
            }
            return nil
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
