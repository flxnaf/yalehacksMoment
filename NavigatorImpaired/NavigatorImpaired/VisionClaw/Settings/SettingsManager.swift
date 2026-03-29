import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case geminiAPIKey
    case openClawHost
    case openClawPort
    case openClawHookToken
    case openClawGatewayToken
    case geminiSystemPrompt
    case webrtcSignalingURL
    case k2APIKey
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
  }

  private init() {}

  /// Values saved from the template should not override real defaults in `Secrets.swift`.
  private static func isOpenClawHostPlaceholder(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return s == "http://YOUR_MAC_HOSTNAME.local" || s == "https://YOUR_MAC_HOSTNAME.local"
  }

  private static let openClawGatewayTokenPlaceholder = "YOUR_OPENCLAW_GATEWAY_TOKEN"

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { defaults.string(forKey: Key.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { defaults.set(newValue, forKey: Key.geminiAPIKey.rawValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? GeminiConfig.defaultSystemInstruction }
    set { defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue) }
  }

  // MARK: - OpenClaw

  var openClawHost: String {
    get {
      // Empty or template host in UserDefaults must not mask Secrets.
      if let s = defaults.string(forKey: Key.openClawHost.rawValue), !s.isEmpty,
         !Self.isOpenClawHostPlaceholder(s) {
        return s
      }
      return Secrets.openClawHost
    }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawHookToken: String {
    get {
      if let s = defaults.string(forKey: Key.openClawHookToken.rawValue), !s.isEmpty { return s }
      return Secrets.openClawHookToken
    }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get {
      if let s = defaults.string(forKey: Key.openClawGatewayToken.rawValue), !s.isEmpty {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != Self.openClawGatewayTokenPlaceholder { return t }
      }
      return Secrets.openClawGatewayToken
    }
    set { defaults.set(newValue, forKey: Key.openClawGatewayToken.rawValue) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { defaults.string(forKey: Key.webrtcSignalingURL.rawValue) ?? Secrets.webrtcSignalingURL }
    set { defaults.set(newValue, forKey: Key.webrtcSignalingURL.rawValue) }
  }

  var k2APIKey: String? {
    get {
      let s = defaults.string(forKey: Key.k2APIKey.rawValue)
      if let s, !s.isEmpty { return s }
      let fallback = Secrets.k2APIKey
      return fallback.isEmpty || fallback == "YOUR_K2_API_KEY_HERE" ? nil : fallback
    }
    set {
      if let newValue {
        defaults.set(newValue, forKey: Key.k2APIKey.rawValue)
      } else {
        defaults.removeObject(forKey: Key.k2APIKey.rawValue)
      }
    }
  }

  // MARK: - Audio

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL, .k2APIKey,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
