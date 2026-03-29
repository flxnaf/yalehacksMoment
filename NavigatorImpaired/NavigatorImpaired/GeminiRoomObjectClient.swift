import Foundation
import UIKit

struct RoomObject: Codable {
  let label: String
  let clockDirection: Int
  let estimatedDistance: String
  let confidence: Float
  /// 0 = left edge of frame, 1 = right, 0.5 = center. Finer horizontal aim than clock alone.
  let horizontalFraction: Float?
}

struct RoomScanResponse: Codable {
  let objects: [RoomObject]
  let summary: String
}

enum GeminiRoomObjectClient {
  private static let urlSession: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 60
    c.timeoutIntervalForResource = 90
    return URLSession(configuration: c)
  }()

  private static let responseSchema: [String: Any] = [
    "type": "OBJECT",
    "properties": [
      "objects": [
        "type": "ARRAY",
        "items": [
          "type": "OBJECT",
          "properties": [
            "label": ["type": "STRING"],
            "clockDirection": ["type": "INTEGER"],
            "estimatedDistance": ["type": "STRING"],
            "confidence": ["type": "NUMBER"],
            "horizontalFraction": ["type": "NUMBER"],
          ],
          "required": ["label", "clockDirection", "estimatedDistance", "confidence"],
        ],
      ],
      "summary": ["type": "STRING"],
    ],
    "required": ["objects", "summary"],
  ]

  static func analyzeKeyframes(_ keyframes: [ScanKeyframe]) async throws -> RoomScanResponse {
    guard !keyframes.isEmpty else {
      throw NSError(
        domain: "RoomScan", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "No keyframes"])
    }

    let key = GeminiConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key != "YOUR_GEMINI_API_KEY" else {
      throw NSError(
        domain: "RoomScan", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Gemini API key not configured"])
    }

    var components = URLComponents(
      string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
    components?.queryItems = [URLQueryItem(name: "key", value: key)]
    guard let url = components?.url else {
      throw NSError(domain: "RoomScan", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
    }

    let n = keyframes.count
    let step = max(1, n / 6)
    let sampled = Array(stride(from: 0, to: n, by: step).map { keyframes[$0] }.prefix(6))

    var parts: [[String: Any]] = sampled.compactMap { kf in
      guard let jpeg = kf.image.jpegData(compressionQuality: 0.5) else { return nil }
      return [
        "inline_data": [
          "mime_type": "image/jpeg",
          "data": jpeg.base64EncodedString(),
        ],
      ]
    }

    parts.append([
      "text": """
      You are analyzing frames from an indoor environment captured by a blind user's camera.
      List every distinct object visible across all frames.
      For each object return:
      - label: short descriptive name (e.g. "red mug", "wooden chair", "laptop charger")
      - clockDirection: clock position 1–12 from the camera center (12 = straight ahead)
      - horizontalFraction: horizontal center of the object in the image from 0.0 (left edge) to 1.0 (right edge); 0.5 is dead center. Use this for precise left-right placement.
      - estimatedDistance: one of "very close" (< 0.5m), "close" (0.5–2m), "nearby" (2–5m) — used as fallback when depth is unclear
      - confidence: 0.0–1.0

      Also return a spoken summary of the room in one sentence.
      Return JSON only, no markdown.
      """,
    ])

    let body: [String: Any] = [
      "contents": [["parts": parts]],
      "generationConfig": [
        "temperature": 0.2,
        "responseMimeType": "application/json",
        "responseSchema": responseSchema,
      ],
    ]

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await urlSession.data(for: req)
    guard let http = response as? HTTPURLResponse else {
      throw NSError(
        domain: "RoomScan", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
    }
    guard (200...299).contains(http.statusCode) else {
      throw NSError(
        domain: "RoomScan", code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
    }

    guard
      let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = outer["candidates"] as? [[String: Any]],
      let first = candidates.first,
      let content = first["content"] as? [String: Any],
      let partsOut = content["parts"] as? [[String: Any]],
      let jsonText = partsOut.first?["text"] as? String,
      let jsonData = jsonText.data(using: .utf8)
    else {
      throw NSError(
        domain: "RoomScan", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Bad response body"])
    }

    return try JSONDecoder().decode(RoomScanResponse.self, from: jsonData)
  }
}
