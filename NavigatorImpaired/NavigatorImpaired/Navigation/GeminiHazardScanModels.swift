import Foundation

/// Parsed JSON from Gemini REST hazard scan (`responseMimeType: application/json`).
struct GeminiHazardDecision: Equatable, Sendable {
  let shouldAnnounce: Bool
  let primaryObject: String
  let relativePosition: String
  let suggestedMovement: String?
  let spoken: String
  let severity: String?

  static func parse(jsonData: Data) throws -> GeminiHazardDecision {
    let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    guard let obj else { throw GeminiHazardScanError.malformedJSON }
    return try parse(dictionary: obj)
  }

  static func parse(jsonString: String) throws -> GeminiHazardDecision {
    guard let data = jsonString.data(using: .utf8) else { throw GeminiHazardScanError.malformedJSON }
    return try parse(jsonData: data)
  }

  private static func parse(dictionary obj: [String: Any]) throws -> GeminiHazardDecision {
    let shouldAnnounce = obj["shouldAnnounce"] as? Bool ?? false
    let primaryObject = (obj["primaryObject"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let relativePosition = (obj["relativePosition"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let suggestedMovement = (obj["suggestedMovement"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let spoken = (obj["spoken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let severity = (obj["severity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return GeminiHazardDecision(
      shouldAnnounce: shouldAnnounce,
      primaryObject: primaryObject,
      relativePosition: relativePosition,
      suggestedMovement: suggestedMovement.flatMap { $0.isEmpty ? nil : $0 },
      spoken: spoken,
      severity: severity.flatMap { $0.isEmpty ? nil : $0 }
    )
  }

  /// Drop obvious vague one-word lines; keep model output otherwise.
  func sanitizedForSpeech() -> GeminiHazardDecision? {
    guard shouldAnnounce, !spoken.isEmpty else { return nil }
    let lower = spoken.lowercased()
    let words = spoken.split { $0.isWhitespace }.filter { !$0.isEmpty }
    if words.count <= 2, lower == "obstacle" || lower == "obstacle ahead" || lower == "an obstacle" {
      return nil
    }
    if primaryObject.lowercased() == "obstacle", words.count < 5 {
      return nil
    }
    // Model echoing generic templates ("obstacle to your left") without naming a thing.
    let po = primaryObject.lowercased()
    if po == "obstacle" || po == "unknown" || po == "object" {
      if words.count < 6 { return nil }
    }
    if lower.contains("obstacle"), words.count < 9 {
      let specific = ["car", "truck", "door", "person", "people", "bike", "bicycle", "pole", "curb", "wall", "bench", "tree", "sign", "stairs", "cone", "hydrant"]
      let edgeCue = ["slow", "unclear", "dark", "blur", "careful", "pause", "listen", "hard to see", "can't see", "cannot see", "visibility", "crowd", "narrow", "glare", "fog"]
      if !specific.contains(where: { lower.contains($0) }),
         !edgeCue.contains(where: { lower.contains($0) }) {
        return nil
      }
    }
    return self
  }
}

enum GeminiHazardScanError: Error, Equatable {
  case notConfigured
  case badImage
  case httpStatus(Int)
  case malformedJSON
  case emptyModelText
}
