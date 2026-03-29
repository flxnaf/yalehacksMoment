import Foundation
import UIKit

/// One-shot Gemini REST vision call for walking hazard descriptions (not Live WebSocket).
final class GeminiNavigationHazardClient {
  private let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 45
    c.timeoutIntervalForResource = 60
    return URLSession(configuration: c)
  }()

  init() {}

  func analyze(
    image: UIImage,
    navigationContext: String,
    jpegQuality: CGFloat = 0.5
  ) async throws -> GeminiHazardDecision {
    let key = SettingsManager.shared.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key != "YOUR_GEMINI_API_KEY" else { throw GeminiHazardScanError.notConfigured }

    guard let jpeg = image.jpegData(compressionQuality: jpegQuality), !jpeg.isEmpty else {
      throw GeminiHazardScanError.badImage
    }
    let b64 = jpeg.base64EncodedString()

    let model = GeminiConfig.hazardScanRESTModel
    var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
    components?.queryItems = [URLQueryItem(name: "key", value: key)]
    guard let url = components?.url else { throw GeminiHazardScanError.notConfigured }

    let systemText = Self.systemInstruction
    let userText = """
    Navigation and motion context (plain text):
    \(navigationContext)

    Task: You are the vision safety layer for someone walking with smart glasses. From this single frame, decide if they need a short spoken line that (1) names what matters, (2) says where it is (including ahead/center vs sides), and (3) suggests what to do next when useful.

    Hazard examples: vehicles, doors (especially glass), people, bikes/e-scooters, poles, signs, curbs, stairs up/down, wet floor, construction tape, barriers, dogs, strollers, café furniture, bollards, open cellar doors, low branches.

    Guidance (action) rules:
    - Prefer ending with a calm action: slow down, stop, step left/right, veer slightly left/right, pause, or wait—only when it fits the hazard.
    - If several hazards exist, pick the one that affects the next step forward; one sentence only.

    Edge cases:
    - Dark, glare, motion blur, or fog: if you truly cannot identify objects but the path looks risky, you MAY set shouldAnnounce true with spoken like "Hard to see ahead—slow down and use your cane" and primaryObject "visibility" or "scene", relativePosition unknown, suggestedMovement slow_down, severity medium. Do not invent specific objects you do not see.
    - Crowd or clutter on both sides: name that ("People close on both sides—narrow path, slow down").
    - Something may be moving fast (bike, runner): bump severity and be direct ("Bike coming up on your left—stay right and slow down").
    - Glass / reflective surface ahead: warn about glass, not just "door".
    - Stairs or sudden level change: mention up or down if visible.
    - Image looks safe and clear: shouldAnnounce false.

    Rules:
    - If the path looks clear and there is no meaningful hazard, set shouldAnnounce to false and spoken to an empty string.
    - When shouldAnnounce is true, primaryObject must be a concrete noun or a short scene label (visibility, crowd, construction) when edge case applies—not the lone word "obstacle".
    - relativePosition MUST reflect image layout: ahead / center / ahead_left / ahead_right for forward cone; left/right only for clearly lateral hazards; below for trip hazards near feet; unknown when appropriate.
    - Fill suggestedMovement from the enum when you are suggesting an action (use none if you only described the scene without a movement cue).
    - Set severity from the enum to match urgency.
    - spoken: under 28 words, natural, includes guidance when helpful. Do not copy "tight space" from context unless the image shows it.
    """

    let body = Self.makeRequestBody(userText: userText, base64JPEG: b64, systemText: systemText)
    let data = try JSONSerialization.data(withJSONObject: body, options: [])

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data

    let (respData, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw GeminiHazardScanError.malformedJSON }
    guard (200...299).contains(http.statusCode) else { throw GeminiHazardScanError.httpStatus(http.statusCode) }

    guard
      let root = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
      let candidates = root["candidates"] as? [[String: Any]],
      let first = candidates.first,
      let content = first["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let textPart = parts.first?["text"] as? String,
      let jsonData = textPart.data(using: .utf8)
    else {
      throw GeminiHazardScanError.malformedJSON
    }

    return try GeminiHazardDecision.parse(jsonData: jsonData)
  }

  private static let systemInstruction = """
  You output only a single JSON object matching the schema. You help a blind pedestrian while walking.
  Balance safety with calm: announce real risks and genuine edge cases (poor visibility, crowds, fast movers); avoid spam when the path is clearly open.
  Combine description + egocentric position + suggested movement when it helps (e.g. veer left, slow down, stop).
  relativePosition must use the allowed enum values; prefer ahead/center/ahead_left/ahead_right for forward hazards.
  Never use only the word "obstacle" as primaryObject or as the entire spoken line.
  """

  private static func makeRequestBody(userText: String, base64JPEG: String, systemText: String) -> [String: Any] {
    [
      "systemInstruction": [
        "parts": [["text": systemText]],
      ],
      "contents": [
        [
          "role": "user",
          "parts": [
            ["text": userText],
            [
              "inline_data": [
                "mime_type": "image/jpeg",
                "data": base64JPEG,
              ],
            ],
          ],
        ],
      ],
      "generationConfig": [
        "temperature": 0.2,
        "responseMimeType": "application/json",
        "responseSchema": hazardResponseSchema,
      ],
    ]
  }

  /// Gemini REST Schema (v1beta): types are uppercase. `relativePosition` enum forces front vs lateral labels.
  private static let hazardResponseSchema: [String: Any] = [
    "type": "OBJECT",
    "properties": [
      "shouldAnnounce": ["type": "BOOLEAN"],
      "primaryObject": ["type": "STRING"],
      "relativePosition": [
        "type": "STRING",
        "enum": [
          "ahead",
          "center",
          "ahead_left",
          "ahead_right",
          "left",
          "right",
          "below",
          "unknown",
        ],
      ],
      "suggestedMovement": [
        "type": "STRING",
        "enum": [
          "none",
          "slow_down",
          "stop",
          "step_left",
          "step_right",
          "veer_left",
          "veer_right",
          "pause",
          "wait",
          "unknown",
        ],
      ],
      "spoken": ["type": "STRING"],
      "severity": [
        "type": "STRING",
        "enum": ["none", "low", "medium", "high", "critical"],
      ],
    ],
    "required": ["shouldAnnounce", "primaryObject", "relativePosition", "spoken"],
  ]
}
