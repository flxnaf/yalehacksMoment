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
    case navigationHazardScanEnabled
    case navigationHazardScanIntervalSeconds
  }

  private init() {}

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
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
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
    get { defaults.string(forKey: Key.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get { defaults.string(forKey: Key.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
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

  // MARK: - Navigation hazard scan (Gemini REST)

  var navigationHazardScanEnabled: Bool {
    get { defaults.object(forKey: Key.navigationHazardScanEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.navigationHazardScanEnabled.rawValue) }
  }

  /// Seconds between periodic hazard scans while `NavigationController.isNavigating` is true.
  var navigationHazardScanIntervalSeconds: TimeInterval {
    get {
      let v = defaults.double(forKey: Key.navigationHazardScanIntervalSeconds.rawValue)
      if v > 0 { return min(max(v, 2), 5) }
      return 3
    }
    set { defaults.set(min(max(newValue, 2), 5), forKey: Key.navigationHazardScanIntervalSeconds.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL, .k2APIKey,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled, .navigationHazardScanEnabled,
                .navigationHazardScanIntervalSeconds] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
