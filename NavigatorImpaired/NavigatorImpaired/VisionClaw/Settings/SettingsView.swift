import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showResetConfirmation = false

  @State private var guardianName: String = ""
  @State private var guardianPhone: String = ""
  @State private var twilioSid: String = ""
  @State private var twilioToken: String = ""
  @State private var twilioFrom: String = ""
  @State private var gx10BaseURL: String = ""
  @State private var gx10Model: String = ""
  @State private var imgbbApiKey: String = ""
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

        Section(header: Text("OpenClaw"), footer: Text("Connect to an OpenClaw gateway running on your Mac for agentic tool-calling.")) {
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

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from OpenClaw (heartbeat, scheduled tasks) spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
        }

        Section(
          header: Text("Guardian / Fall alert"),
          footer: Text(
            "Used when SightAssist detects a fall or you trigger SOS. Contact phone should be E.164 (e.g. +15551234567). Twilio sends SMS; OpenClaw bridge can also notify if configured. GX10 and imgbb are optional for scene description and image links in alerts."
          )
        ) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Guardian name")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Jane Doe", text: $guardianName)
              .autocapitalization(.words)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Contact phone (E.164)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("+15551234567", text: $guardianPhone)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.phonePad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Twilio Account SID")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("AC…", text: $twilioSid)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Twilio Auth Token")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Auth token", text: $twilioToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Twilio From (your Twilio number)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("+15559876543", text: $twilioFrom)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.phonePad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("GX10 base URL (optional)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://127.0.0.1:8000", text: $gx10BaseURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("GX10 model id (optional)")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Qwen/Qwen2.5-VL-7B-Instruct", text: $gx10Model)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("imgbb API key (optional)")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("imgbb key", text: $imgbbApiKey)
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
          UserDefaults.standard.removeObject(forKey: GuardianAlertManager.gx10BaseURLKey)
          UserDefaults.standard.removeObject(forKey: GuardianAlertManager.gx10ModelKey)
          UserDefaults.standard.removeObject(forKey: GuardianAlertManager.imgbbKeyDefaults)
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
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled

    if let g = GuardianAlertManager.shared.loadConfig() {
      guardianName = g.name
      guardianPhone = g.phoneNumber
      twilioSid = g.twilioAccountSid
      twilioToken = g.twilioAuthToken
      twilioFrom = g.twilioFromNumber
    } else {
      guardianName = ""
      guardianPhone = ""
      twilioSid = ""
      twilioToken = ""
      twilioFrom = ""
    }
    gx10BaseURL = UserDefaults.standard.string(forKey: GuardianAlertManager.gx10BaseURLKey) ?? ""
    gx10Model = UserDefaults.standard.string(forKey: GuardianAlertManager.gx10ModelKey) ?? ""
    imgbbApiKey = UserDefaults.standard.string(forKey: GuardianAlertManager.imgbbKeyDefaults) ?? ""
  }

  /// Returns `false` if guardian fields fail validation (alert is shown); caller should not dismiss.
  private func saveAll() -> Bool {
    let name = guardianName.trimmingCharacters(in: .whitespacesAndNewlines)
    let phone = guardianPhone.trimmingCharacters(in: .whitespacesAndNewlines)
    let sid = twilioSid.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = twilioToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let from = twilioFrom.trimmingCharacters(in: .whitespacesAndNewlines)

    let allEmpty = name.isEmpty && phone.isEmpty && sid.isEmpty && token.isEmpty && from.isEmpty
    let twilioAny = !sid.isEmpty || !token.isEmpty || !from.isEmpty
    if twilioAny {
      let twilioComplete = !sid.isEmpty && !token.isEmpty && !from.isEmpty
      if !twilioComplete {
        guardianValidationMessage =
          "Twilio Account SID, Auth Token, and From number must all be filled to send SMS, or clear all three."
        showGuardianValidationAlert = true
        return false
      }
      if name.isEmpty || phone.isEmpty {
        guardianValidationMessage = "Enter guardian name and contact phone (E.164) when using Twilio."
        showGuardianValidationAlert = true
        return false
      }
    } else if !allEmpty {
      if name.isEmpty || phone.isEmpty {
        guardianValidationMessage =
          "Enter guardian name and contact phone (E.164), or clear all guardian fields to remove saved contact."
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
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled

    if allEmpty {
      GuardianAlertManager.shared.clearGuardianConfig()
    } else {
      let cfg = GuardianConfig(
        name: name,
        phoneNumber: phone,
        twilioAccountSid: sid,
        twilioAuthToken: token,
        twilioFromNumber: from
      )
      GuardianAlertManager.shared.saveConfig(cfg)
    }

    persistOptionalDefaults(gx10BaseURL, GuardianAlertManager.gx10BaseURLKey)
    persistOptionalDefaults(gx10Model, GuardianAlertManager.gx10ModelKey)
    persistOptionalDefaults(imgbbApiKey, GuardianAlertManager.imgbbKeyDefaults)

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
