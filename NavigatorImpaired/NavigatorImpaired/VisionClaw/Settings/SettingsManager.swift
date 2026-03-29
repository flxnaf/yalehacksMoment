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
    case openClawWebSocketPath
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

  /// Values saved from the template should not override real defaults in `Secrets.swift`.
  private static func isOpenClawHostPlaceholder(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return s == "http://YOUR_MAC_HOSTNAME.local" || s == "https://YOUR_MAC_HOSTNAME.local"
  }

  private static func userDefaultsOpenClawHostRaw() -> String {
    UserDefaults.standard.string(forKey: Key.openClawHost.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// `localhost` / loopback in Settings points at the iPhone (or Simulator), not the Mac — OpenClaw fails with ECONNREFUSED. Fall back to `Secrets` like template hosts.
  private static func isLoopbackOpenClawHost(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
      let lower = trimmed.lowercased()
      return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("[::1]")
    }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  /// True when OpenClaw host/port should come from `Secrets` because stored host is empty, template, or loopback.
  private static var openClawEndpointUsesSecrets: Bool {
    let udHost = userDefaultsOpenClawHostRaw()
    if udHost.isEmpty { return true }
    if isOpenClawHostPlaceholder(udHost) { return true }
    if isLoopbackOpenClawHost(udHost) { return true }
    return false
  }

  private static let openClawGatewayTokenPlaceholder = "YOUR_OPENCLAW_GATEWAY_TOKEN"

  /// Removes stale loopback host/port from UserDefaults so Settings UI and resolved endpoint stay aligned (one-time cleanup per bad value).
  private func sanitizeLoopbackOpenClawUserDefaultsIfNeeded() {
    let s = defaults.string(forKey: Key.openClawHost.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard Self.isLoopbackOpenClawHost(s) else { return }
    defaults.removeObject(forKey: Key.openClawHost.rawValue)
    defaults.removeObject(forKey: Key.openClawPort.rawValue)
  }

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
      sanitizeLoopbackOpenClawUserDefaultsIfNeeded()
      let s = defaults.string(forKey: Key.openClawHost.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let fromSecrets = s.isEmpty || Self.isOpenClawHostPlaceholder(s) || Self.isLoopbackOpenClawHost(s)
      return fromSecrets ? Secrets.openClawHost : s
    }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      sanitizeLoopbackOpenClawUserDefaultsIfNeeded()
      let port: Int
      if Self.openClawEndpointUsesSecrets {
        port = Secrets.openClawPort
      } else {
        let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
        port = stored != 0 ? stored : Secrets.openClawPort
      }
      return port
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

  /// WebSocket path on the gateway host (e.g. `/ws`). Empty uses the server root, matching most OpenClaw installs.
  var openClawWebSocketPath: String {
    get { defaults.string(forKey: Key.openClawWebSocketPath.rawValue) ?? Secrets.openClawWebSocketPath }
    set { defaults.set(newValue, forKey: Key.openClawWebSocketPath.rawValue) }
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
                .openClawHookToken, .openClawGatewayToken, .openClawWebSocketPath, .webrtcSignalingURL, .k2APIKey,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled, .navigationHazardScanEnabled,
                .navigationHazardScanIntervalSeconds] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
