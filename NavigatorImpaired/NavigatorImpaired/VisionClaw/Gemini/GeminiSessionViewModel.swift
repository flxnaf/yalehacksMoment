import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  /// Completions for `speakNavigationForUser`; advanced on `onTurnComplete` (may skew if other turns interleave).
  private var navigationUtteranceCompletions: [(() -> Void)?] = []
  private var pendingNavigationSpeakTurns: Int = 0

  weak var navigationController: NavigationController?
  weak var audioEngine: SpatialAudioEngine?

  var streamingMode: StreamingMode = .glasses

  var shouldUseGeminiForNavigationVoice: Bool {
    isGeminiActive && connectionState == .ready
  }

  /// True while a `speakNavigationForUser` line is awaiting Live TTS completion.
  var isNavigationVoiceBusy: Bool {
    pendingNavigationSpeakTurns > 0
  }

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // Mute mic while model speaks when speaker is on the phone
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
        self.advanceNavigationUtteranceCompletionIfNeeded()
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    // Handle unexpected disconnection
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // Check OpenClaw connectivity and start fresh session
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    // Wire tool call handling (navigationController must be set on this VM before startSession — see MainAppView `.task`)
    toolCallRouter = ToolCallRouter(bridge: openClawBridge,
                                     navigationController: navigationController,
                                     audioEngine: audioEngine)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to OpenClaw event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    let pending = navigationUtteranceCompletions
    navigationUtteranceCompletions.removeAll()
    pendingNavigationSpeakTurns = 0
    for c in pending { c?() }
    navigationController?.stopNavigation()
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  /// Injects one-shot navigation context into the Live session (`clientContent`).
  func sendNavigationHandoff(_ text: String) {
    guard isGeminiActive, connectionState == .ready else { return }
    geminiService.sendTextMessage(text)
  }

  /// Speaks a navigation line through the same Live voice as the assistant when the session is ready.
  func speakNavigationForUser(_ text: String, completion: (() -> Void)?) {
    guard shouldUseGeminiForNavigationVoice else {
      completion?()
      return
    }
    let plain = Self.plainTextForNavigationSpeech(text)
    guard !plain.isEmpty else {
      completion?()
      return
    }
    pendingNavigationSpeakTurns += 1
    navigationUtteranceCompletions.append(completion)
    // First line is the marker; everything after the newline is exactly what should be spoken (Directions API text).
    let wrapped = "[NAVIGATION_ONLY]\n\(plain)"
    geminiService.sendTextMessage(wrapped)
  }

  /// Strip HTML / entities from Google Directions `html_instructions` so TTS matches the API wording.
  private static func plainTextForNavigationSpeech(_ raw: String) -> String {
    var s = raw
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
      let range = NSRange(s.startIndex..., in: s)
      s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
    }
    s = s.replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&quot;", with: "\"")
    if let regex = try? NSRegularExpression(pattern: "[ \t\n]+", options: []) {
      let range = NSRange(s.startIndex..., in: s)
      s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func advanceNavigationUtteranceCompletionIfNeeded() {
    guard pendingNavigationSpeakTurns > 0 else { return }
    pendingNavigationSpeakTurns -= 1
    guard !navigationUtteranceCompletions.isEmpty else { return }
    let done = navigationUtteranceCompletions.removeFirst()
    done?()
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

}
