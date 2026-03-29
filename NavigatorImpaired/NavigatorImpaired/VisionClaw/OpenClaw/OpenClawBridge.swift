import CryptoKit
import Foundation
import UIKit

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

enum OpenClawError: LocalizedError {
  case disconnected
  case timeout
  case gatewayError(String)

  var errorDescription: String? {
    switch self {
    case .disconnected: return "OpenClaw WebSocket disconnected"
    case .timeout: return "OpenClaw request timed out"
    case .gatewayError(let s): return s
    }
  }
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private var webSocketTask: URLSessionWebSocketTask?
  private var wsSession: URLSession?
  private var wsConnected = false
  private var shouldReconnect = false
  private var reconnectDelay: TimeInterval = 2
  private let maxReconnectDelay: TimeInterval = 30
  private var sessionSubscribed = false
  /// Server `connect.challenge` nonce; required for protocol v3 device signatures.
  private var connectChallengeNonce: String?
  private var cachedDevicePrivateKey: Curve25519.Signing.PrivateKey?

  private struct PendingRun {
    let continuation: CheckedContinuation<String, Error>
    var fragments: [String] = []
    var runId: String?
  }

  private var pendingRuns: [String: PendingRun] = [:]
  private var runIdToIdempotencyKey: [String: String] = [:]

  private let sessionKey = "agent:main:glass"

  private let httpSession: URLSession
  private let pingSession: URLSession

  var onNotification: ((String) -> Void)?

  private var responseHandlers: [String: ([String: Any]) -> Void] = [:]

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.httpSession = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)
  }

  func connect() {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      NSLog("[OpenClaw] Not configured, skipping WS connect")
      return
    }
    shouldReconnect = true
    reconnectDelay = 2
    // `checkConnection()` already calls `connect()` after /health; `GeminiSessionViewModel` calls
    // `connect()` again after Gemini Live is up. A second `establishConnection()` would cancel the
    // first socket and produce "Socket is not connected" + reconnect storms — skip if already good.
    if sessionSubscribed, webSocketTask != nil {
      NSLog("[OpenClaw] WS already subscribed, skipping redundant connect")
      return
    }
    if webSocketTask != nil {
      NSLog("[OpenClaw] WS connection in progress, skipping duplicate connect")
      return
    }
    connectionState = .checking
    establishConnection()
  }

  func disconnect() {
    shouldReconnect = false
    wsConnected = false
    sessionSubscribed = false
    connectChallengeNonce = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    wsSession?.invalidateAndCancel()
    wsSession = nil
    connectionState = .notConfigured
    responseHandlers.removeAll()
    runIdToIdempotencyKey.removeAll()
    for (_, pending) in pendingRuns {
      pending.continuation.resume(throwing: OpenClawError.disconnected)
    }
    pendingRuns.removeAll()
    NSLog("[OpenClaw] WS disconnected")
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    let base = "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)"
    guard let url = URL(string: "\(base)/health") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (data, response) = try await pingSession.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        connectionState = .unreachable("No HTTP response")
        return
      }
      if (200...299).contains(http.statusCode) {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["ok"] as? Bool == true {
          connectionState = .checking
          NSLog("[OpenClaw] Gateway reachable via /health (HTTP %d)", http.statusCode)
          if !wsConnected { connect() }
          return
        }
      }
      connectionState = .unreachable("HTTP \(http.statusCode)")
    } catch {
      connectionState = .unreachable(error.localizedDescription)
    }
  }

  func resetSession() {
    runIdToIdempotencyKey.removeAll()
    for (_, pending) in pendingRuns {
      pending.continuation.resume(throwing: OpenClawError.disconnected)
    }
    pendingRuns.removeAll()
    NSLog("[OpenClaw] Session reset (key: %@)", sessionKey)
  }

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard GeminiConfig.isOpenClawConfigured else {
      lastToolCallStatus = .failed(toolName, "OpenClaw not configured")
      return .failure(
        "OpenClaw is not set up. In the app’s Settings, fill in OpenClaw: Mac host (e.g. http://YourMac.local), port, and gateway token, and run the OpenClaw gateway on that Mac on the same Wi‑Fi. Until then, only conversation, navigation, and ping tools work."
      )
    }

    await ensureWebSocketConnected()

    guard wsConnected else {
      lastToolCallStatus = .failed(toolName, "WebSocket not connected")
      return .failure("Cannot reach the OpenClaw gateway. Check that the gateway is running and your phone is on the same network.")
    }

    guard sessionSubscribed else {
      lastToolCallStatus = .failed(toolName, "OpenClaw session not ready")
      return .failure(
        "OpenClaw gateway session is not ready. If the status bar shows an error, fix the gateway token (operator.read and operator.write scopes in your OpenClaw dashboard) or check gateway logs."
      )
    }

    let idempotencyKey = UUID().uuidString
    NSLog("[OpenClaw] chat.send (key: %@, task: %@)", idempotencyKey, String(task.prefix(120)))

    do {
      let reply = try await completeChatSend(message: task, idempotencyKey: idempotencyKey, attachments: nil)
      NSLog("[OpenClaw] Agent result: %@", String(reply.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(reply)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }

  func invokeTool(name: String, args: [String: Any], sessionKey: String = "main") async -> (ok: Bool, detail: String) {
    guard GeminiConfig.isOpenClawConfigured else {
      return (false, "OpenClaw not configured")
    }
    let resolvedSession = Self.resolvedGatewaySessionKey(sessionKey)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/tools/invoke") else {
      return (false, "Invalid gateway URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "tool": name,
      "args": args,
      "sessionKey": resolvedSession,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await httpSession.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return (false, "No HTTP response")
      }

      if http.statusCode == 404 {
        NSLog("[OpenClaw] tools/invoke HTTP 404 — trying chat.send fallback")
        return await invokeToolViaChatSendFallback(name: name, args: args)
      }

      guard (200...299).contains(http.statusCode) else {
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        NSLog("[OpenClaw] tools/invoke failed HTTP %d — %@", http.statusCode, String(bodyStr.prefix(300)))
        return (false, "HTTP \(http.statusCode)")
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (true, String(data: data, encoding: .utf8) ?? "")
      }
      if let ok = json["ok"] as? Bool, ok {
        if let result = json["result"] as? String {
          return (true, result)
        }
        if let dict = json["result"] as? [String: Any], let text = dict["text"] as? String {
          return (true, text)
        }
        return (true, "ok")
      }
      let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "unknown"
      return (false, errMsg)
    } catch {
      NSLog("[OpenClaw] tools/invoke error: %@", error.localizedDescription)
      return (false, error.localizedDescription)
    }
  }

  private func ensureWebSocketConnected() async {
    if !wsConnected {
      connect()
      for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if wsConnected { break }
      }
    }
    guard wsConnected else { return }
    for _ in 0..<40 {
      if sessionSubscribed { break }
      if !wsConnected { break }
      if case .unreachable = connectionState { break }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
  }

  private func completeChatSend(
    message: String,
    idempotencyKey: String,
    attachments: [[String: Any]]?
  ) async throws -> String {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
      pendingRuns[idempotencyKey] = PendingRun(continuation: cont)
      sendChatMessage(message: message, idempotencyKey: idempotencyKey, attachments: attachments)
    }
  }

  private func invokeToolViaChatSendFallback(name: String, args: [String: Any]) async -> (ok: Bool, detail: String) {
    await ensureWebSocketConnected()
    guard wsConnected else {
      return (false, "WebSocket not connected")
    }
    guard sessionSubscribed else {
      return (
        false,
        "OpenClaw session not ready — gateway token may be missing operator.read / operator.write scopes, or subscribe failed."
      )
    }

    var argsForMessage = args
    var attachments: [[String: Any]] = []
    if let b64 = argsForMessage["image_jpeg_base64"] as? String, !b64.isEmpty {
      argsForMessage.removeValue(forKey: "image_jpeg_base64")
      attachments.append([
        "type": "image",
        "mimeType": "image/jpeg",
        "content": b64,
      ])
    }

    let argsJson: String
    if let data = try? JSONSerialization.data(withJSONObject: argsForMessage, options: []),
       let s = String(data: data, encoding: .utf8) {
      argsJson = s
    } else {
      argsJson = "{}"
    }

    let message =
      "Execute the OpenClaw skill or tool named \"\(name)\" using exactly this JSON args object (do not invent keys): \(argsJson). Reply with a one-sentence outcome for the user."

    let idempotencyKey = UUID().uuidString
    do {
      let text = try await completeChatSend(
        message: message,
        idempotencyKey: idempotencyKey,
        attachments: attachments.isEmpty ? nil : attachments
      )
      return (true, text)
    } catch {
      return (false, error.localizedDescription)
    }
  }

  private static func resolvedGatewaySessionKey(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty || t == "main" { return "agent:main:glass" }
    return t
  }

  private func establishConnection() {
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    wsSession?.invalidateAndCancel()
    connectChallengeNonce = nil

    let rawHost = GeminiConfig.openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = rawHost
      .replacingOccurrences(of: "http://", with: "")
      .replacingOccurrences(of: "https://", with: "")
    let port = GeminiConfig.openClawPort
    let wsScheme = rawHost.lowercased().hasPrefix("https://") ? "wss" : "ws"
    var path = GeminiConfig.openClawWebSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !path.isEmpty, !path.hasPrefix("/") {
      path = "/" + path
    }
    guard let url = URL(string: "\(wsScheme)://\(host):\(port)\(path)") else {
      NSLog("[OpenClaw] Invalid WS URL")
      connectionState = .unreachable("Invalid WebSocket URL")
      return
    }

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    let sess = URLSession(configuration: config)
    wsSession = sess
    webSocketTask = sess.webSocketTask(with: url)
    webSocketTask?.resume()

    wsConnected = false
    sessionSubscribed = false
    NSLog("[OpenClaw] WS connecting to %@", url.absoluteString)
    startReceiving()
  }

  private func startReceiving() {
    webSocketTask?.receive { [weak self] result in
      guard let self else { return }
      Task { @MainActor in
        self.handleReceiveResult(result)
      }
    }
  }

  private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
    switch result {
    case .success(let message):
      let text: String?
      switch message {
      case .string(let s): text = s
      case .data(let d): text = String(data: d, encoding: .utf8)
      @unknown default: text = nil
      }
      if let text {
        handleWSMessage(text)
      }
      startReceiving()

    case .failure(let error):
      NSLog("[OpenClaw] WS receive error: %@", error.localizedDescription)
      wsConnected = false
      sessionSubscribed = false
      if shouldReconnect {
        if case .unreachable = connectionState {
          // Keep a more specific message (e.g. subscribe failure, missing scopes).
        } else {
          connectionState = .unreachable("WebSocket disconnected")
        }
      }
      for (_, pending) in pendingRuns {
        pending.continuation.resume(throwing: OpenClawError.disconnected)
      }
      pendingRuns.removeAll()
      runIdToIdempotencyKey.removeAll()
      responseHandlers.removeAll()
      scheduleReconnect()
    }
  }

  private func handleWSMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return }

    switch type {
    case "event":
      handleEvent(json)
    case "res":
      handleResponse(json)
    default:
      break
    }
  }

  private func handleEvent(_ json: [String: Any]) {
    guard let event = json["event"] as? String else { return }
    let payload = json["payload"] as? [String: Any] ?? [:]

    switch event {
    case "connect.challenge":
      if let n = payload["nonce"] as? String, !n.isEmpty {
        connectChallengeNonce = n
      }
      sendConnectHandshake()

    case "session.message":
      handleSessionMessage(payload)

    case "heartbeat":
      handleHeartbeatEvent(payload)

    case "cron":
      handleCronEvent(payload)

    default:
      break
    }
  }

  private func resolvePendingKey(forSessionMessage payload: [String: Any]) -> String? {
    if let rid = payload["runId"] as? String, let key = runIdToIdempotencyKey[rid] {
      return key
    }
    if let ik = payload["idempotencyKey"] as? String, pendingRuns[ik] != nil {
      return ik
    }
    if pendingRuns.count == 1, let only = pendingRuns.keys.first {
      return only
    }
    return nil
  }

  private func handleSessionMessage(_ payload: [String: Any]) {
    let eventSessionKey = payload["sessionKey"] as? String ?? ""
    guard eventSessionKey == sessionKey else { return }

    guard let message = payload["message"] as? [String: Any] else { return }
    let role = message["role"] as? String ?? ""
    guard role == "assistant" else { return }

    let content = message["content"] as? String ?? ""
    let msgStatus = (payload["status"] as? String) ?? (message["status"] as? String) ?? ""
    let partial =
      msgStatus == "delta" || msgStatus == "partial"
      || (message["partial"] as? Bool == true)
      || (payload["partial"] as? Bool == true)

    guard let key = resolvePendingKey(forSessionMessage: payload) else {
      NSLog("[OpenClaw] session.message: no pending run matched (runId=%@)", payload["runId"] as? String ?? "?")
      return
    }

    guard var pending = pendingRuns[key] else { return }

    if !content.isEmpty {
      pending.fragments.append(content)
    }

    let isFinal =
      msgStatus == "final" || msgStatus == "completed" || msgStatus == "done"
      || (payload["done"] as? Bool == true)

    if partial {
      pendingRuns[key] = pending
      return
    }

    if isFinal || !content.isEmpty {
      let reply = pending.fragments.joined()
      pendingRuns.removeValue(forKey: key)
      if let rid = pending.runId ?? (payload["runId"] as? String) {
        runIdToIdempotencyKey.removeValue(forKey: rid)
      }
      pending.continuation.resume(returning: reply.isEmpty ? content : reply)
    } else {
      pendingRuns[key] = pending
    }
  }

  private func handleResponse(_ json: [String: Any]) {
    let ok = json["ok"] as? Bool ?? false
    let id = json["id"] as? String ?? ""

    if let handler = responseHandlers.removeValue(forKey: id) {
      handler(json)
      return
    }

    if !id.isEmpty, var pending = pendingRuns[id] {
      if !ok {
        let errObj = json["error"] as? [String: Any]
        let msg = errObj?["message"] as? String ?? "request failed"
        pendingRuns.removeValue(forKey: id)
        pending.continuation.resume(throwing: OpenClawError.gatewayError(msg))
        return
      }

      if let pl = json["payload"] as? [String: Any],
         let rid = pl["runId"] as? String {
        runIdToIdempotencyKey[rid] = id
        pending.runId = rid
        pendingRuns[id] = pending
      }
      return
    }

    if !ok {
      let errObj = json["error"] as? [String: Any]
      let msg = errObj?["message"] as? String ?? "unknown"
      NSLog("[OpenClaw] req failed: %@", msg)
    }
  }

  private func sendConnectHandshake() {
    let reqId = UUID().uuidString
    let token = GeminiConfig.openClawGatewayToken
    let role = "operator"
    let scopes = ["operator.read", "operator.write"]
    let clientId = "openclaw-control-ui"
    let clientMode = "ui"
    let platform = "ios"
    let deviceFamily = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
    let nonce = connectChallengeNonce ?? ""

    let privateKey = loadOrCreateDevicePrivateKey()
    let rawPub = privateKey.publicKey.rawRepresentation
    let deviceId = "81cd1b518c9c1f8d49b291e775b63713094c5281315662999e1f3949414dab4a"

    var params: [String: Any] = [
      "minProtocol": 1,
      "maxProtocol": 3,
      "client": [
        "id": clientId,
        "displayName": "VisionClaw Glass",
        "version": "1.0",
        "platform": platform,
        "mode": clientMode,
      ] as [String: Any],
      "role": role,
      "scopes": scopes,
      "caps": ["tool-events"],
      "commands": [String](),
      "permissions": [String: Bool](),
      "auth": [
        "token": token,
      ],
      "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
      "userAgent": "VisionClaw/1.0 (OpenClaw-iOS)",
    ]

    if !nonce.isEmpty {
      let payloadV3 = Self.buildDeviceAuthPayloadV3(
        deviceId: deviceId,
        clientId: clientId,
        clientMode: clientMode,
        role: role,
        scopes: scopes,
        signedAtMs: signedAtMs,
        token: token,
        nonce: nonce,
        platform: platform,
        deviceFamily: deviceFamily
      )
      if let payloadData = payloadV3.data(using: .utf8),
         let sig = try? privateKey.signature(for: payloadData) {
        params["device"] = [
          "id": deviceId,
          "publicKey": Self.base64urlEncode(Data(rawPub)),
          "signature": Self.base64urlEncode(sig),
          "signedAt": signedAtMs,
          "nonce": nonce,
        ] as [String: Any]
      } else {
        NSLog("[OpenClaw] Failed to build device auth signature (nonce present)")
      }
    }

    let connectMsg: [String: Any] = [
      "type": "req",
      "id": reqId,
      "method": "connect",
      "params": params,
    ]

    responseHandlers[reqId] = { [weak self] json in
      guard let self else { return }
      let handshakeOk = json["ok"] as? Bool ?? false
      if handshakeOk {
        NSLog("[OpenClaw] WS authenticated")
        self.connectChallengeNonce = nil
        self.wsConnected = true
        self.connectionState = .checking
        self.reconnectDelay = 2
        self.subscribeToSession()
      } else {
        let error = json["error"] as? [String: Any]
        let msg = error?["message"] as? String ?? "auth failed"
        let details = error?["details"] as? [String: Any]
        let detailCode = (details?["code"] as? String) ?? ""
        let msgLower = msg.lowercased()
        let pairingRequired =
          detailCode == "PAIRING_REQUIRED"
          || msgLower.contains("pairing required")
          || msgLower.contains("pairing_required")
        NSLog("[OpenClaw] WS auth failed: %@", msg)
        if pairingRequired {
          self.shouldReconnect = false
          let deviceFull = Self.sha256Hex(data: Data(self.loadOrCreateDevicePrivateKey().publicKey.rawRepresentation))
          NSLog(
            "[OpenClaw] Gateway requires device pairing — approve this iPhone in your OpenClaw admin (full device id: %@)",
            deviceFull
          )
          self.connectionState = .unreachable(
            "OpenClaw: pairing required — approve this iPhone in your gateway (Moltly/OpenClaw devices / pairing). Device id: \(deviceFull)"
          )
        } else {
          self.connectionState = .unreachable("Auth failed: \(msg)")
        }
      }
    }

    NSLog("[OpenClaw] sending device id: %@", deviceId)
    sendJSON(connectMsg)
  }

  private static let devicePrivateKeyDefaultsKey = "VisionClaw.OpenClaw.devicePrivateKeyRaw"

  private func loadOrCreateDevicePrivateKey() -> Curve25519.Signing.PrivateKey {
    if let cached = cachedDevicePrivateKey { return cached }
    let key = Self.loadOrCreateDevicePrivateKeyStatic()
    cachedDevicePrivateKey = key
    return key
  }

  private static func loadOrCreateDevicePrivateKeyStatic() -> Curve25519.Signing.PrivateKey {
    let defaults = UserDefaults.standard
    if let b64 = defaults.string(forKey: devicePrivateKeyDefaultsKey),
       let data = Data(base64Encoded: b64),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
      return key
    }
    let key = Curve25519.Signing.PrivateKey()
    defaults.set(key.rawRepresentation.base64EncodedString(), forKey: devicePrivateKeyDefaultsKey)
    return key
  }

  private static func sha256Hex(data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Matches `buildDeviceAuthPayloadV3` in OpenClaw `src/gateway/device-auth.ts`.
  private static func buildDeviceAuthPayloadV3(
    deviceId: String,
    clientId: String,
    clientMode: String,
    role: String,
    scopes: [String],
    signedAtMs: Int,
    token: String,
    nonce: String,
    platform: String,
    deviceFamily: String
  ) -> String {
    let scopesCsv = scopes.joined(separator: ",")
    let pf = platform.lowercased()
    let df = deviceFamily.lowercased()
    return [
      "v3",
      deviceId,
      clientId,
      clientMode,
      role,
      scopesCsv,
      String(signedAtMs),
      token,
      nonce,
      pf,
      df,
    ].joined(separator: "|")
  }

  private func subscribeToSession() {
    guard !sessionSubscribed else { return }
    let reqId = UUID().uuidString
    let msg: [String: Any] = [
      "type": "req",
      "id": reqId,
      "method": "sessions.messages.subscribe",
      "params": [
        "key": sessionKey,
      ] as [String: Any],
    ]

    responseHandlers[reqId] = { [weak self] json in
      guard let self else { return }
      if let raw = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
         let rawStr = String(data: raw, encoding: .utf8) {
        NSLog("[OpenClaw] sessions.messages.subscribe response:\n%@", rawStr)
      }
      let subOk = json["ok"] as? Bool ?? false
      if subOk {
        NSLog("[OpenClaw] Subscribed to session messages for %@", self.sessionKey)
        self.sessionSubscribed = true
        self.connectionState = .connected
        self.reconnectDelay = 2
      } else {
        let errCode = (json["error"] as? [String: Any])?["code"] as? String ?? ""
        let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown"
        let msgLower = errMsg.lowercased()
        let missingScope =
          msgLower.contains("missing scope")
          || (errCode == "INVALID_REQUEST" && msgLower.contains("operator."))
        if missingScope {
          self.shouldReconnect = false
          self.connectionState = .unreachable(
            "OpenClaw token missing required scopes (operator.read / operator.write). In Moltly OpenClaw → API Keys / Tokens, edit this gateway token and add those scopes, or create a new token and update Secrets.openClawGatewayToken."
          )
          NSLog("[OpenClaw] Token scope error — stopping reconnect. Grant operator.read and operator.write to the gateway token.")
          self.cleanupWebSocketAfterSubscribeFailure()
        } else {
          self.connectionState = .unreachable("OpenClaw subscribe failed: \(errMsg)")
          self.cleanupWebSocketAfterSubscribeFailure()
          // Socket cancel will trigger `handleReceiveResult` failure, which schedules reconnect.
        }
      }
    }

    sendJSON(msg)
  }

  /// Drops the WebSocket after a failed `sessions.messages.subscribe` (session is unusable until fixed).
  private func cleanupWebSocketAfterSubscribeFailure() {
    wsConnected = false
    sessionSubscribed = false
    for (_, pending) in pendingRuns {
      pending.continuation.resume(throwing: OpenClawError.disconnected)
    }
    pendingRuns.removeAll()
    runIdToIdempotencyKey.removeAll()
    responseHandlers.removeAll()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    wsSession?.invalidateAndCancel()
    wsSession = nil
  }

  private func sendChatMessage(message: String, idempotencyKey: String, attachments: [[String: Any]]?) {
    var params: [String: Any] = [
      "sessionKey": sessionKey,
      "message": message,
      "idempotencyKey": idempotencyKey,
    ]
    if let attachments, !attachments.isEmpty {
      params["attachments"] = attachments
    }

    let msg: [String: Any] = [
      "type": "req",
      "id": idempotencyKey,
      "method": "chat.send",
      "params": params,
    ]
    sendJSON(msg)

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000_000)
      await MainActor.run {
        guard let self else { return }
        if let pending = self.pendingRuns.removeValue(forKey: idempotencyKey) {
          if let rid = pending.runId {
            self.runIdToIdempotencyKey.removeValue(forKey: rid)
          }
          pending.continuation.resume(throwing: OpenClawError.timeout)
        }
      }
    }
  }

  private func sendJSON(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let string = String(data: data, encoding: .utf8) else {
      NSLog("[OpenClaw] Failed to serialize WS message")
      return
    }
    webSocketTask?.send(.string(string)) { error in
      if let error {
        NSLog("[OpenClaw] WS send error: %@", error.localizedDescription)
      }
    }
  }

  private func handleHeartbeatEvent(_ payload: [String: Any]) {
    let status = payload["status"] as? String ?? ""
    guard status == "sent", let preview = payload["preview"] as? String, !preview.isEmpty else {
      return
    }
    let silent = payload["silent"] as? Bool ?? false
    guard !silent else { return }
    NSLog("[OpenClaw] Heartbeat notification: %@", String(preview.prefix(100)))
    onNotification?("[Notification from your assistant] \(preview)")
  }

  private func handleCronEvent(_ payload: [String: Any]) {
    let action = payload["action"] as? String ?? ""
    guard action == "finished" else { return }
    let summary =
      payload["summary"] as? String
      ?? payload["result"] as? String
      ?? ""
    guard !summary.isEmpty else { return }
    NSLog("[OpenClaw] Cron notification: %@", String(summary.prefix(100)))
    onNotification?("[Scheduled update] \(summary)")
  }

  private func scheduleReconnect() {
    guard shouldReconnect else { return }
    NSLog("[OpenClaw] Reconnecting in %.0fs", reconnectDelay)
    let delay = reconnectDelay
    reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.shouldReconnect else { return }
      self.establishConnection()
    }
  }
}
