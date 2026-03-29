import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var openClawWebSocketPath: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var navigationHazardScanEnabled: Bool = true
  @State private var navigationHazardScanInterval: Double = 4
  @State private var showResetConfirmation = false

  @State private var guardianName: String = ""
  @State private var guardianEmail: String = ""
  @State private var guardianPhone: String = ""
  @State private var guardianWhatsApp: String = ""
  @State private var sendGridRelayBaseURL: String = ""
  @State private var sendGridRelaySecret: String = ""
  @State private var showGuardianValidationAlert = false
  @State private var guardianValidationMessage = ""

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Enter Gemini API key", text: $geminiAPIKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }

        Section(
          header: Text("OpenClaw"),
          footer: Text(
            "Agentic tools use the OpenClaw WebSocket gateway (`agent` RPC) after GET /health. Use your Mac’s Wi‑Fi IP or .local hostname — on a physical iPhone, localhost/127.0.0.1 refers to the phone, not your Mac. 172.17.x.x is often Docker-only. Gateway token must match auth.token. Hosted gateways (e.g. Moltly) require one-time device pairing in the provider’s OpenClaw dashboard — check Xcode logs for the full device id if the app shows “pairing required.” Optional WebSocket path (e.g. /ws) if your reverse proxy requires it; leave empty for the default root path."
          )
        ) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Host")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://your-mac.local", text: $openClawHost)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Port")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("18789", text: $openClawPort)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Hook Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Hook token", text: $openClawHookToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Gateway Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Gateway auth token", text: $openClawGatewayToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("WebSocket path (optional)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("/ws or leave empty", text: $openClawWebSocketPath)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("WebRTC")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Signaling URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("wss://your-server.example.com", text: $webrtcSignalingURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Audio"), footer: Text("Route audio output to the iPhone speaker instead of glasses. Useful for demos where others need to hear.")) {
          Toggle("Speaker Output", isOn: $speakerOutputEnabled)
        }

        Section(header: Text("Video"), footer: Text("Disable video streaming to save battery. Audio remains active for voice-only interaction.")) {
          Toggle("Video Streaming", isOn: $videoStreamingEnabled)
        }

        Section(
          header: Text("Walking navigation"),
          footer: Text(
            "While GPS walking navigation is on, sends a camera frame to Gemini (REST) on a timer. Positions include ahead/center as well as left and right. Uses your Gemini API key."
          )
        ) {
          Toggle("Hazard vision scan", isOn: $navigationHazardScanEnabled)
          Stepper(value: $navigationHazardScanInterval, in: 2...5, step: 1) {
            Text("Scan every \(Int(navigationHazardScanInterval)) seconds")
          }
          .disabled(!navigationHazardScanEnabled)
        }

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from OpenClaw (heartbeat, scheduled tasks) spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
        }

        Section(
          header: Text("Guardian / Fall alert"),
          footer: Text(
            "After the SOS countdown: email via sgQuickstart relay (http:// + Mac LAN IP), SMS to Guardian phone if set, and WhatsApp via OpenClaw tool fall_alert if WhatsApp number is set and OpenClaw is configured. Load skills/fall_alert.js on your gateway. SMS opens Messages (you may need to tap Send). Relay secret optional if .env has RELAY_SECRET."
          )
        ) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Your name (optional, for alert text)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Jane Doe", text: $guardianName)
              .autocapitalization(.words)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Guardian email")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("parent@example.com", text: $guardianEmail)
              .keyboardType(.emailAddress)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Guardian phone (optional, for SMS)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("+15551234567", text: $guardianPhone)
              .keyboardType(.phonePad)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Guardian WhatsApp (optional, E.164)")
              .font(.caption)
              .foregroundColor(.secondary)
            Text("Uses OpenClaw tool fall_alert after countdown (HTTP tools/invoke when available, otherwise WebSocket agent fallback). Same gateway token as Settings → OpenClaw.")
              .font(.caption2)
              .foregroundColor(.secondary)
            TextField("+15551234567", text: $guardianWhatsApp)
              .keyboardType(.phonePad)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Fall alert email relay URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://192.168.1.5:8787", text: $sendGridRelayBaseURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Relay shared secret (optional)")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("RELAY_SECRET", text: $sendGridRelaySecret)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            if saveAll() {
              dismiss()
            }
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Guardian settings", isPresented: $showGuardianValidationAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(guardianValidationMessage)
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          GuardianAlertManager.shared.clearGuardianConfig()
          UserDefaults.standard.removeObject(forKey: "gx10BaseURL")
          UserDefaults.standard.removeObject(forKey: "gx10Model")
          UserDefaults.standard.removeObject(forKey: "imgbbApiKey")
          UserDefaults.standard.removeObject(forKey: GuardianAlertManager.sendGridRelayBaseURLKey)
          UserDefaults.standard.removeObject(forKey: GuardianAlertManager.sendGridRelaySecretKey)
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        loadCurrentValues()
      }
    }
  }

  private func loadCurrentValues() {
    geminiAPIKey = settings.geminiAPIKey
    geminiSystemPrompt = settings.geminiSystemPrompt
    openClawHost = settings.openClawHost
    openClawPort = String(settings.openClawPort)
    openClawHookToken = settings.openClawHookToken
    openClawGatewayToken = settings.openClawGatewayToken
    openClawWebSocketPath = settings.openClawWebSocketPath
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
    navigationHazardScanEnabled = settings.navigationHazardScanEnabled
    navigationHazardScanInterval = settings.navigationHazardScanIntervalSeconds

    if let g = GuardianAlertManager.shared.loadConfig() {
      guardianName = g.name
      guardianEmail = g.guardianEmail
      guardianPhone = g.guardianPhone
      guardianWhatsApp = g.guardianWhatsApp
    } else {
      guardianName = ""
      guardianEmail = ""
      guardianPhone = ""
      guardianWhatsApp = ""
    }
    sendGridRelayBaseURL = UserDefaults.standard.string(forKey: GuardianAlertManager.sendGridRelayBaseURLKey) ?? ""
    sendGridRelaySecret = UserDefaults.standard.string(forKey: GuardianAlertManager.sendGridRelaySecretKey) ?? ""
  }

  /// Returns `false` if guardian fields fail validation (alert is shown); caller should not dismiss.
  private func saveAll() -> Bool {
    let name = guardianName.trimmingCharacters(in: .whitespacesAndNewlines)
    let email = guardianEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let relay = sendGridRelayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let phone = guardianPhone.trimmingCharacters(in: .whitespacesAndNewlines)
    let whatsApp = guardianWhatsApp.trimmingCharacters(in: .whitespacesAndNewlines)

    // Secret is optional: do not include it here — a leftover saved secret must not block saving
    // “email + relay + blank secret” or force users to clear a stale SecureField to satisfy “all empty”.
    let guardianFallCoreEmpty = name.isEmpty && email.isEmpty && relay.isEmpty && phone.isEmpty && whatsApp.isEmpty
    if !guardianFallCoreEmpty {
      let hasEmailChannel = !email.isEmpty && !relay.isEmpty
      let partialEmail = !email.isEmpty || !relay.isEmpty
      if partialEmail && !hasEmailChannel {
        guardianValidationMessage =
          "Enter both guardian email and fall alert relay URL (http://…), or clear email and relay to use only SMS or WhatsApp. Relay shared secret is optional if sgQuickstart/.env sets RELAY_SECRET."
        showGuardianValidationAlert = true
        return false
      }
      let hasAnyChannel = hasEmailChannel || !phone.isEmpty || !whatsApp.isEmpty
      if !hasAnyChannel {
        guardianValidationMessage =
          "Add guardian email and relay URL, a guardian phone for SMS, or a WhatsApp number for OpenClaw fall_alert."
        showGuardianValidationAlert = true
        return false
      }
    }

    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHost = openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(openClawPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
      settings.openClawPort = port
    }
    settings.openClawHookToken = openClawHookToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawGatewayToken = openClawGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawWebSocketPath = openClawWebSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
    settings.navigationHazardScanEnabled = navigationHazardScanEnabled
    settings.navigationHazardScanIntervalSeconds = navigationHazardScanInterval

    if guardianFallCoreEmpty {
      GuardianAlertManager.shared.clearGuardianConfig()
      UserDefaults.standard.removeObject(forKey: GuardianAlertManager.sendGridRelayBaseURLKey)
      UserDefaults.standard.removeObject(forKey: GuardianAlertManager.sendGridRelaySecretKey)
      sendGridRelayBaseURL = ""
      sendGridRelaySecret = ""
      guardianPhone = ""
      guardianWhatsApp = ""
    } else {
      let cfg = GuardianConfig(name: name, guardianEmail: email, guardianPhone: phone, guardianWhatsApp: whatsApp)
      GuardianAlertManager.shared.saveConfig(cfg)
    }

    persistOptionalDefaults(sendGridRelayBaseURL, GuardianAlertManager.sendGridRelayBaseURLKey)
    persistOptionalDefaults(sendGridRelaySecret, GuardianAlertManager.sendGridRelaySecretKey)

    return true
  }

  private func persistOptionalDefaults(_ value: String, _ key: String) {
    let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty {
      UserDefaults.standard.removeObject(forKey: key)
    } else {
      UserDefaults.standard.set(t, forKey: key)
    }
  }
}
