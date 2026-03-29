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

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

    OBSTACLE DETECTION: When you receive a message starting with [OBSTACLE SCAN], immediately look at the camera feed and describe what is directly ahead in 15 words or fewer. Name each object, its clock-face direction (12 o clock = straight ahead, 3 o clock = right, 9 o clock = left), and distance (very close, close, or nearby). If the path looks clear say "Path clear." Never refuse an obstacle scan — always give a response. No apostrophes in clock positions.

    CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

    Tools: execute (OpenClaw gateway agent over WebSocket), invoke_openclaw_tool (gateway skill with JSON args — HTTP tools/invoke when enabled, otherwise agent fallback), navigate_to, set_ping, and clear_ping. execute connects you to a powerful assistant for open-ended work. invoke_openclaw_tool is for registered gateway skills when you know the exact skill name and arguments. navigate_to starts on-device walking navigation with Google Maps.

    When the user wants walking directions or to go to a named place, call navigate_to with the destination string. Examples: "navigate to Walgreens", "take me to the library", "directions to the coffee shop".

    Use invoke_openclaw_tool when the user or context refers to a specific OpenClaw skill and you can supply tool_name and a JSON tool_args string.

    ALWAYS use execute when the user asks you to (and a dedicated skill is not clearly appropriate):
    - Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
    - Search or look up anything (web, local info, facts, news)
    - Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
    - Research, analyze, or draft anything
    - Control or interact with apps, devices, or services
    - Remember or store any information for later

    Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

    NEVER pretend to do these things yourself.

    IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
    - "Sure, let me add that to your shopping list." then call execute.
    - "Got it, searching for that now." then call execute.
    - "On it, sending that message." then call execute.
    Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

    For messages, confirm recipient and content before delegating unless clearly urgent.

    Before invoke_openclaw_tool, give a short spoken acknowledgment like you do for execute.
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
