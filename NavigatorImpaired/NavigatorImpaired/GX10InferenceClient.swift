import Foundation

/// OpenAI-compatible `/v1/chat/completions` client for local vLLM / llama.cpp (Qwen2.5-VL).
final class GX10InferenceClient {
    static let shared = GX10InferenceClient()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()

    private init() {}

    private static let baseURLKey = "gx10BaseURL"
    private static let modelKey = "gx10Model"

    private func completionsURL() throws -> URL {
        let raw = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? "http://127.0.0.1:8000"
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: "\(trimmed)/v1/chat/completions") else {
            throw GX10Error.badURL
        }
        return u
    }

    private var modelName: String {
        let m = UserDefaults.standard.string(forKey: Self.modelKey)
        if let m, !m.isEmpty { return m }
        return "Qwen/Qwen2.5-VL-7B-Instruct"
    }

    func describeImage(imageData: Data, prompt: String) async throws -> String {
        let b64 = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(b64)"

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": dataURL]],
                    ],
                ],
            ],
            "max_tokens": 256,
            "temperature": 0.2,
        ]

        let url = try completionsURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GX10Error.http
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw GX10Error.parse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum GX10Error: Error {
        case badURL
        case http
        case parse
    }
}
