import Foundation

// MARK: - JSON extraction (strip model think blocks)

enum K2JSONExtractor {
  /// Strips K2 angle-bracket think blocks, markdown ``` fences, then the outermost `{ ... }` JSON.
  static func extractJSON(from raw: String) -> String {
    var text = raw

    let openThink = "\u{003C}think\u{003E}"
    let closeThink = "\u{003C}/think\u{003E}"
    while let tagStart = text.range(of: openThink, options: .caseInsensitive),
          let tagEnd = text.range(
            of: closeThink,
            options: .caseInsensitive,
            range: tagStart.upperBound..<text.endIndex
          ),
          tagEnd.upperBound > tagStart.lowerBound {
      text.removeSubrange(tagStart.lowerBound..<tagEnd.upperBound)
    }

    text = text.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
    text = text.replacingOccurrences(of: "```", with: "")

    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let open = text.firstIndex(of: "{"),
          let close = text.lastIndex(of: "}") else {
      return text
    }
    return String(text[open...close])
  }
}

// MARK: - Errors

enum K2Error: Error {
  case notConfigured
  case httpError(Int)
  case malformedResponse
  case timeout
}

// MARK: - Client

/// OpenAI-compatible `/v1/chat/completions` client for MBZUAI K2 Think V2.
final class K2ThinkClient {
  static let shared = K2ThinkClient()

  private static let baseURL = URL(string: "https://api.k2think.ai/v1/chat/completions")!
  private static let modelId = "MBZUAI-IFM/K2-Think-v2"

  private let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 90
    c.timeoutIntervalForResource = 120
    return URLSession(configuration: c)
  }()

  private init() {}

  private func apiKey() throws -> String {
    guard let key = SettingsManager.shared.k2APIKey, !key.isEmpty else {
      throw K2Error.notConfigured
    }
    if key == "YOUR_K2_API_KEY_HERE" { throw K2Error.notConfigured }
    return key
  }

  func reason(system: String, user: String) async throws -> String {
    let key = try apiKey()
    let body: [String: Any] = [
      "model": Self.modelId,
      "stream": false,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
    ]
    var req = URLRequest(url: Self.baseURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: req)
    } catch let e as URLError {
      if e.code == .timedOut || e.code == .networkConnectionLost { throw K2Error.timeout }
      throw e
    }

    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw K2Error.httpError(http.statusCode)
    }

    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = json["choices"] as? [[String: Any]],
      let first = choices.first,
      let message = first["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      if let http = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let err = http["error"] as? [String: Any],
         let code = err["code"] as? Int {
        throw K2Error.httpError(code)
      }
      throw K2Error.malformedResponse
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Use Case A

  func prioritizeHazards(obstacles: [RawObstacle], navigationContext: String?) async throws -> HazardDecision {
    guard !obstacles.isEmpty else {
      return HazardDecision(primaryHazard: nil, spokenText: "", shouldAnnounce: false)
    }
    let system = """
      You are the hazard reasoning layer of SightAssist, an accessibility app for blind users.
      You receive a list of detected obstacles and must decide which single obstacle is most
      important to announce, and whether any announcement is needed at all.

      Rules:
      - Only announce if there is genuine risk. Do not announce background environment features
        (walls, floor, ceiling, expected furniture).
      - Dynamic obstacles (moving people, vehicles) outrank static ones at the same distance.
      - Immediate zone (<1m) always warrants announcement.
      - If multiple obstacles exist, pick the ONE highest priority. Do not list all of them.
      - If the user is navigating, factor in their direction of travel.
      - Output must be a single JSON object:
        {"announce": true/false, "obstacle": "label", "spoken": "ready-to-speak text"}
      - spoken text must be under 10 words. Examples: "Person approaching, 1 meter left."
      - Output JSON only. No preamble, no explanation.
      - Labels of "wall", "furniture", or "obstacle" with zone "mid" or farther: do not announce.
      - If all detected obstacles are walls, furniture, or generic obstacles with no immediate zone:
        {"announce": false, "obstacle": "", "spoken": ""}
      - Only announce "obstacle" label if zone is "immediate" (<1m).
      """
    var lines = "Obstacles detected:\n"
    for o in obstacles {
      let dyn = o.isDynamic ? "dynamic" : "static"
      lines += "- \(o.label), \(String(format: "%.1f", o.distanceMeters))m \(o.direction), \(o.zone) zone, \(dyn)\n"
    }
    if let nav = navigationContext, !nav.isEmpty {
      lines += "\nUser is currently navigating: \(nav)\n"
    }
    lines += "\nWhich obstacle should be announced, if any?"
    let raw = try await reason(system: system, user: lines)
    let jsonStr = K2JSONExtractor.extractJSON(from: raw)
    guard let data = jsonStr.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw K2Error.malformedResponse
    }
    let announce = obj["announce"] as? Bool ?? false
    let spoken = (obj["spoken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let label = (obj["obstacle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let match = obstacles.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
      ?? obstacles.first
    return HazardDecision(
      primaryHazard: announce ? (match ?? obstacles.first) : nil,
      spokenText: spoken,
      shouldAnnounce: announce && !spoken.isEmpty
    )
  }

  // MARK: - Use Case B

  func replanNavigation(context: NavigationReplanContext) async throws -> NavigationReplanDecision {
    let system = """
      You are the navigation reasoning layer of SightAssist, an accessibility app for blind users.
      The user cannot see. You receive navigation state and must decide the best recovery action.

      Rules:
      - If GPS accuracy is >20m, recommend waitForGPS — do not give directions on bad GPS.
      - If user is <10m off path and heading is within 30° of expected, continueCurrentStep.
      - If user is 10–30m off path, correctCourse with a simple spoken instruction.
      - If user is >30m off path or has been on a step >3x its expected duration, reroute.
      - spoken text must be short, calm, and directional. Under 15 words.
      - Output a single JSON object:
        {"action": "continueCurrentStep|correctCourse|reroute|waitForGPS", "spoken": "text"}
      - Output JSON only. No preamble.
      """
    let completed = context.completedSteps.joined(separator: "; ")
    let user = """
      Destination: \(context.destination)
      Completed: \(completed)
      Current step: \(context.currentStep) (\(context.currentStepDistanceRemaining)m remaining)
      Off path: \(String(format: "%.1f", context.distanceOffPath))m
      Heading: \(String(format: "%.0f", context.headingDegrees))° (expected \(String(format: "%.0f", context.expectedHeadingDegrees))°)
      Time on step: \(context.secondsOnCurrentStep)s
      GPS accuracy: \(String(format: "%.1f", context.gpsAccuracyMeters))m

      What should the user do?
      """
    let raw = try await reason(system: system, user: user)
    let jsonStr = K2JSONExtractor.extractJSON(from: raw)
    guard let data = jsonStr.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw K2Error.malformedResponse
    }
    let spoken = (obj["spoken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return parseReplanAction(from: obj, spokenText: spoken)
  }

  private func parseReplanAction(from json: [String: Any], spokenText: String) -> NavigationReplanDecision {
    let rawAction = (json["action"] as? String ?? "")
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let action: NavigationReplanDecision.Action
    switch rawAction {
    case let s where s.contains("reroute"):
      action = .reroute
    case let s where s.contains("waitforgps") || (s.contains("wait") && s.contains("gps")):
      action = .waitForGPS
    case let s where s.contains("correctcourse")
      || (s.contains("correct") && !s.contains("incorrect")):
      action = .correctCourse(instruction: spokenText)
    case let s where s.contains("continue"):
      action = .continueCurrentStep(guidance: spokenText)
    default:
      #if DEBUG
      print("[K2 Nav] Unknown action '\(rawAction)' — defaulting to continueCurrentStep")
      #endif
      action = .continueCurrentStep(guidance: spokenText)
    }
    return NavigationReplanDecision(action: action, spokenText: spokenText)
  }

  // MARK: - Use Case C

  func reasonFallContext(context: FallContextInput) async throws -> FallContextOutput {
    let system = """
      You are writing an emergency SMS alert for the guardian of a blind person who may have fallen.
      The message will be sent to a family member or caregiver who needs to act immediately.

      Rules:
      - Write plain text only. No markdown, no bullet points, no emoji except 🚨 at the start.
      - Total message must be under 800 characters.
      - Always include: time, location link, and what was happening before the fall.
      - If recent hazards were detected, mention the most relevant one as likely context.
      - If the person was navigating somewhere, include where they were going.
      - End with: "Reply SAFE if they are okay."
      - Be factual and calm. Do not speculate beyond what the data shows.
      - Do not use the word "victim."
      - Output a single JSON object:
        {"refinedSMSBody": "full message text", "contextSummary": "one sentence for logging"}
      - Output JSON only. No preamble.
      """
    let scenes = context.sceneDescriptions.enumerated().map { "Scene \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
    let navLine: String
    if context.wasNavigating {
      navLine = "Yes, to: \(context.navigationDestination ?? "unknown")"
    } else {
      navLine = "No"
    }
    let hazards = context.recentHazardsDetected.isEmpty
      ? "None"
      : context.recentHazardsDetected.joined(separator: "\n")
    let user = """
      Time of fall: \(context.timestamp)
      Location: \(context.locationDescription)
      Fall detection confidence: \(String(format: "%.0f", context.fallConfidence * 100))%

      What the camera saw before the fall:
      \(scenes)

      Was navigating: \(navLine)

      Recent hazards announced:
      \(hazards)

      Write the guardian SMS.
      """
    let raw = try await reason(system: system, user: user)
    let jsonStr = K2JSONExtractor.extractJSON(from: raw)
    guard let data = jsonStr.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw K2Error.malformedResponse
    }
    let body = (obj["refinedSMSBody"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = (obj["contextSummary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw K2Error.malformedResponse }
    return FallContextOutput(refinedSMSBody: body, contextSummary: summary)
  }
}

// MARK: - World obstacle → RawObstacle

enum RawObstacleEncoder {
  /// Maps world-space obstacles to `RawObstacle` for K2 (labels + rough distances).
  static func encode(
    obstacles: [WorldObstacle],
    headingRadians: Float,
    sceneLabel: String?
  ) -> [RawObstacle] {
    let baseLabel = sceneLabel.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "obstacle"
    return obstacles.prefix(12).enumerated().map { idx, obstacle in
      let rel = normalizeAngle(obstacle.bearing - headingRadians)
      let direction: String
      if rel < -Float.pi / 6 {
        direction = "left"
      } else if rel > Float.pi / 6 {
        direction = "right"
      } else {
        direction = "center"
      }
      let depth = min(max(obstacle.depth, 0), 1)
      let distanceMeters = Double((1.0 - depth) * 4.0 + 0.3)
      let zone: String
      if distanceMeters < 1.0 {
        zone = "immediate"
      } else if distanceMeters < 2.5 {
        zone = "near"
      } else {
        zone = "mid"
      }
      let dynamic = abs(obstacle.velocity) > 0.05
      let rawLabel = "\(baseLabel) \(idx + 1)"
      let label = normalizeObstacleLabel(rawLabel)
      return RawObstacle(
        label: label,
        distanceMeters: distanceMeters,
        direction: direction,
        zone: zone,
        isDynamic: dynamic
      )
    }
  }

  static func normalizeObstacleLabel(_ raw: String) -> String {
    let lower = raw.lowercased()

    if lower.contains("person") || lower.contains("human")
      || lower.contains("pedestrian") || lower.contains("people") {
      return "person"
    }
    if lower.contains("car") || lower.contains("vehicle")
      || lower.contains("truck") || lower.contains("bus") || lower.contains("bicycle") {
      return "vehicle"
    }
    if lower.contains("step") || lower.contains("stair") || lower.contains("curb") {
      return "step"
    }
    if lower.contains("door") || lower.contains("entrance") || lower.contains("exit") {
      return "door"
    }
    if lower.contains("wall") || lower.contains("floor") || lower.contains("ceiling")
      || lower.contains("column") || lower.contains("pillar") {
      return "wall"
    }
    if lower.contains("chair") || lower.contains("table") || lower.contains("desk")
      || lower.contains("bench") || lower.contains("sofa") {
      return "furniture"
    }
    if lower.contains("indoor") || lower.contains("outdoor") {
      return "obstacle"
    }

    let words = lower.components(separatedBy: .whitespaces)
    return words.first(where: { !$0.allSatisfy(\.isNumber) && !$0.isEmpty }) ?? "obstacle"
  }

  private static func normalizeAngle(_ x: Float) -> Float {
    var a = x
    while a > Float.pi { a -= 2 * Float.pi }
    while a < -Float.pi { a += 2 * Float.pi }
    return a
  }
}
