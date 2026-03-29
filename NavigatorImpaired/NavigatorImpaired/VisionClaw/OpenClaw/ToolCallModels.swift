import Foundation

// MARK: - Gemini Tool Call (parsed from server JSON)

struct GeminiFunctionCall {
  let id: String
  let name: String
  let args: [String: Any]
}

struct GeminiToolCall {
  let functionCalls: [GeminiFunctionCall]

  init?(json: [String: Any]) {
    guard let toolCall = json["toolCall"] as? [String: Any],
          let calls = toolCall["functionCalls"] as? [[String: Any]] else {
      return nil
    }
    self.functionCalls = calls.compactMap { call in
      guard let id = call["id"] as? String,
            let name = call["name"] as? String else { return nil }
      let args = call["args"] as? [String: Any] ?? [:]
      return GeminiFunctionCall(id: id, name: name, args: args)
    }
  }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
  let ids: [String]

  init?(json: [String: Any]) {
    guard let cancellation = json["toolCallCancellation"] as? [String: Any],
          let ids = cancellation["ids"] as? [String] else {
      return nil
    }
    self.ids = ids
  }
}

// MARK: - Tool Result

enum ToolResult {
  case success(String)
  case failure(String)

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": result]
    case .failure(let error):
      return ["error": error]
    }
  }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
  case idle
  case executing(String)
  case completed(String)
  case failed(String, String)
  case cancelled(String)

  var displayText: String {
    switch self {
    case .idle: return ""
    case .executing(let name): return "Running: \(name)..."
    case .completed(let name): return "Done: \(name)"
    case .failed(let name, let err): return "Failed: \(name) - \(err)"
    case .cancelled(let name): return "Cancelled: \(name)"
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - Tool Declarations (for Gemini setup message)

enum ToolDeclarations {

  static func allDeclarations() -> [[String: Any]] {
    return [execute, navigateTo, setPing, clearPing]
  }

  static let navigateTo: [String: Any] = [
    "name": "navigate_to",
    "description": "Start walking navigation to a destination. Use when the user asks to navigate, walk to, go to, get directions, take me to, etc.",
    "parameters": [
      "type": "object",
      "properties": [
        "destination": [
          "type": "string",
          "description": "Destination name or address as spoken by the user."
        ]
      ],
      "required": ["destination"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let setPing: [String: Any] = [
    "name": "set_ping",
    "description": "Place a spatial audio ping beacon at a direction and distance from the user. The ping sounds like a Zelda shrine detector chime that the user hears from that direction in 3D audio. It is anchored to a GPS coordinate so it stays fixed in the real world. When the user walks close enough, it auto-clears. Use when the user says things like 'I want to reach the end of the hall', 'ping that direction', 'guide me 10 meters ahead', etc. Always ask or estimate the distance.",
    "parameters": [
      "type": "object",
      "properties": [
        "bearing": [
          "type": "number",
          "description": "Direction in degrees relative to user's current facing. 0 = ahead, -90 = left, +90 = right, 180 = behind."
        ],
        "distance_meters": [
          "type": "number",
          "description": "Distance to the beacon in meters. Ask the user if unclear. Default 10. Examples: end of hall ~20m, across the room ~5m, nearby door ~3m."
        ]
      ],
      "required": ["bearing"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let clearPing: [String: Any] = [
    "name": "clear_ping",
    "description": "Remove the active spatial audio ping beacon. Use when the user arrives at the target, says 'stop pinging', 'cancel', or no longer needs directional guidance.",
    "parameters": [
      "type": "object",
      "properties": [:] as [String: Any]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
}
