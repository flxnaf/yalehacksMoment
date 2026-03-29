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
    return [
      execute, invokeOpenClawTool, navigateTo, setPing, clearPing,
      scanRoom, findObject, listObjects,
    ]
  }

  static let scanRoom: [String: Any] = [
    "name": "scan_room",
    "description": "Scan the current room and build a spatial map of all objects. Use when user says 'scan the room', 'what's around me', 'map this space', or 'what objects are here'.",
    "parameters": [
      "type": "object",
      "properties": [:] as [String: Any],
      "required": [] as [String],
    ] as [String: Any],
    "behavior": "BLOCKING",
  ]

  static let findObject: [String: Any] = [
    "name": "find_object",
    "description": "Find a previously scanned object and point the user toward it using spatial audio. Use when user asks to find or locate something specific.",
    "parameters": [
      "type": "object",
      "properties": [
        "query": [
          "type": "string",
          "description": "Object to find, e.g. 'my keys', 'a chair', 'the charger'",
        ],
      ],
      "required": ["query"],
    ] as [String: Any],
    "behavior": "BLOCKING",
  ]

  static let listObjects: [String: Any] = [
    "name": "list_objects",
    "description": "List all objects found in the last room scan. Use when user asks what was found or what's in the room.",
    "parameters": [
      "type": "object",
      "properties": [:] as [String: Any],
      "required": [] as [String],
    ] as [String: Any],
    "behavior": "BLOCKING",
  ]

  static let navigateTo: [String: Any] = [
    "name": "navigate_to",
    "description": "Start or update on-device walking navigation using the phone’s built-in route and maps (Google Maps walking directions, turn-by-turn, and route pings)—not OpenClaw. Use for any request to go somewhere on foot: navigate, walk to, go to, get directions, take me to, how do I get to, directions to an address or place name, or starting a new walking route. Do not use execute or invoke_openclaw_tool for these.",
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

  /// Structured call to a named OpenClaw gateway skill (HTTP `tools/invoke` when the gateway exposes it; otherwise WebSocket agent fallback).
  static let invokeOpenClawTool: [String: Any] = [
    "name": "invoke_openclaw_tool",
    "description": "Call a registered OpenClaw skill by name with JSON args. Use for gateway skills you know by name: messaging (send message, notify, SMS/email relay) or shopping/automation (e.g. add to cart skill). Do not use for walking navigation, maps, turn-by-turn, or on-device spatial tasks—use navigate_to, set_ping/clear_ping, scan_room, find_object, list_objects. For pure questions without an action, answer yourself.",
    "parameters": [
      "type": "object",
      "properties": [
        "tool_name": [
          "type": "string",
          "description": "Skill name as registered on the OpenClaw gateway."
        ],
        "tool_args": [
          "type": "string",
          "description": "JSON object string of arguments for the skill, e.g. {\"to\":\"+15551234567\",\"message\":\"Hello\"}. Use {} if the skill needs no args."
        ],
        "session_key": [
          "type": "string",
          "description": "Optional gateway session key; omit for default."
        ]
      ],
      "required": ["tool_name"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Delegate to the OpenClaw gateway for actions the phone cannot do alone: (1) communication—send a message (WhatsApp, Telegram, Slack, SMS/email relay, etc.); (2) shopping/e-commerce on the gateway—e.g. add this product to Amazon cart, add to a store list, checkout flows the Mac agent can run. Do NOT use for walking navigation, maps, turn-by-turn, room scan, find_object, or bearing pings—use on-device tools (navigate_to, set_ping/clear_ping, scan_room, find_object, list_objects). For pure factual Q&A without an external action, answer yourself. When a specific skill name and JSON args are known, prefer invoke_openclaw_tool. Never use for \"get me to [place]\" walking directions—use navigate_to.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Detailed gateway task: for messages—who, platform, exact text; for shopping—store (e.g. Amazon), product name or what the camera shows, quantity, add-to-cart or list intent. Not for walking navigation."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
}
