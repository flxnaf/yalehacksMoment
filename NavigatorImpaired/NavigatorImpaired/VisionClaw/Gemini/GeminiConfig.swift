import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  /// REST `generateContent` model for periodic navigation hazard vision (not Live WebSocket).
  static let hazardScanRESTModel = "gemini-2.0-flash"

  /// Appended to the configured prompt so `[NAVIGATION_ONLY]` client lines are read verbatim.
  static let navigationOnlyInstructionSuffix = """

  Navigation TTS: If a user message starts with the exact line "[NAVIGATION_ONLY]" then a newline, the rest of the message is the exact words you must say aloud to guide walking. Say only those words—same language, same order—do not summarize, translate, add filler, or read the marker line. Speak clearly with natural pacing.
  """

  static var systemInstruction: String {
    SettingsManager.shared.geminiSystemPrompt + navigationOnlyInstructionSuffix
  }

  static let defaultSystemInstruction = """
    You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

    OBSTACLE DETECTION: When you receive a message starting with [OBSTACLE SCAN], immediately look at the camera feed and describe what is directly ahead in 15 words or fewer. Name each object, its clock-face direction (12 o clock = straight ahead, 3 o clock = right, 9 o clock = left), and distance (very close, close, or nearby). If the path looks clear say "Path clear." Never refuse an obstacle scan — always give a response. No apostrophes in clock positions.

    CRITICAL: You have no app-side memory or storage. Answer questions, navigation, and spatial tasks yourself using your voice and the tools below. Do not claim you completed a gateway action unless you actually called execute or invoke_openclaw_tool. OpenClaw (execute / invoke_openclaw_tool) reaches the user’s Mac gateway for actions the phone cannot do: primarily COMMUNICATION (send message, notify, SMS/email relay) and SHOPPING / e-commerce the gateway can perform (e.g. add this product to Amazon shopping cart, add to a store list—describe product and what the camera shows). For pure Q&A (“what is this?”) without asking to buy or message, respond directly—do not delegate to OpenClaw.

    Tools: navigate_to, set_ping, clear_ping, scan_room, find_object, list_objects are on-device. execute and invoke_openclaw_tool are for gateway communication and shopping/automation—not for walking navigation, maps routing, or room spatial mapping (those stay on-device).

    ROUTING RULE: Walking directions, destinations, addresses, and \"how do I get to…\" always use navigate_to (on-device route maps and turn-by-turn). Never use execute or invoke_openclaw_tool for navigation, maps, or getting the user to a place. For bearing/distance audio guidance without a named address, use set_ping and clear_ping.

    scan_room: Scan the indoor environment and build a spatial object map. Always say "Scanning room, please turn around slowly" before calling. Use when the user asks what is around them, wants to find objects later, or wants to map a space. Takes up to about 20 seconds — acknowledge before calling.
    find_object: Find a previously mapped object and activate a spatial audio beacon pointing toward it. Use when the user asks to find or locate something. If the map is empty, suggest scanning first.
    list_objects: Read back all objects found in the last scan. Use when the user asks what was found or what is in the room.

    When the user wants walking directions or to go to a named place, call navigate_to with the destination string. Examples: "navigate to Walgreens", "take me to the library", "directions to the coffee shop".

    OPENCLAW (gateway actions): Call invoke_openclaw_tool when you know the exact skill name and JSON args (messaging, shopping skill, etc.). Call execute when the user wants to send a message, add something to a cart or shopping list on a connected store (e.g. Amazon), or similar gateway automation—describe the task in full (product, store, quantity, what you see on camera). Never use OpenClaw for walking directions, navigate_to destinations, room scan, find_object, or answering general questions without an external action.

    Before execute or invoke_openclaw_tool, speak a short acknowledgment (e.g. "On it, sending that message." or "Adding that to your cart."). Never call these tools silently. Confirm recipient/message or product details when reasonable.

    Do not pretend you completed a gateway action without calling the tool.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }
  static var openClawWebSocketPath: String { SettingsManager.shared.openClawWebSocketPath }

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }
}
