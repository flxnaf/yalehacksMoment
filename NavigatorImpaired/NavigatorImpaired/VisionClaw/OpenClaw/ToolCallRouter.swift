import Foundation

@MainActor
class ToolCallRouter {
  private enum InvokeArgsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
      switch self {
      case .invalid(let s): return s
      }
    }
  }

  private let bridge: OpenClawBridge
  private weak var navigationController: NavigationController?
  private weak var audioEngine: SpatialAudioEngine?
  weak var streamSessionViewModel: StreamSessionViewModel?
  weak var geminiSessionViewModel: GeminiSessionViewModel?
  private let roomScanController = RoomScanController()
  private var inFlightTasks: [String: Task<Void, Never>] = [:]

  init(
    bridge: OpenClawBridge,
    navigationController: NavigationController? = nil,
    audioEngine: SpatialAudioEngine? = nil,
    streamSessionViewModel: StreamSessionViewModel? = nil,
    geminiSessionViewModel: GeminiSessionViewModel? = nil
  ) {
    self.bridge = bridge
    self.navigationController = navigationController
    self.audioEngine = audioEngine
    self.streamSessionViewModel = streamSessionViewModel
    self.geminiSessionViewModel = geminiSessionViewModel
    roomScanController.streamVM = streamSessionViewModel
    roomScanController.geminiVM = geminiSessionViewModel
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    let task = Task { @MainActor in
      let result: ToolResult
      if callName == "navigate_to" {
        let destination = call.args["destination"] as? String ?? ""
        if destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          result = .failure("Missing destination for navigate_to.")
        } else if let nav = navigationController {
          do {
            audioEngine?.releaseUserBeaconControlForNavigation()
            try await nav.startNavigation(to: destination)
            result = .success("OK")
          } catch {
            result = .failure(error.localizedDescription)
          }
        } else {
          result = .failure("Navigation is not available.")
        }
      } else if callName == "set_ping" {
        let bearing = (call.args["bearing"] as? NSNumber)?.floatValue ?? 0
        let distance = (call.args["distance_meters"] as? NSNumber)?.floatValue ?? 10
        if let engine = audioEngine {
          engine.setBeaconBearing(bearing, distanceMeters: distance, fromUserTool: true)
          result = .success("Ping beacon placed \(distance)m away at \(bearing)° from your current facing. It will auto-clear when you arrive.")
        } else {
          result = .failure("Spatial audio engine is not available.")
        }
      } else if callName == "clear_ping" {
        if let engine = audioEngine {
          engine.clearBeacon()
          result = .success("Ping beacon cleared.")
        } else {
          result = .failure("Spatial audio engine is not available.")
        }
      } else if callName == "invoke_openclaw_tool" {
        let toolNm = (call.args["tool_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if toolNm.isEmpty {
          result = .failure("Missing tool_name for invoke_openclaw_tool.")
        } else {
          switch Self.parseOpenClawInvokeArgs(call.args["tool_args"]) {
          case .failure(let err):
            result = .failure(err.localizedDescription)
          case .success(let invokeArgs):
            let rawSession = (call.args["session_key"] as? String ?? "main").trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionKey = rawSession.isEmpty ? "main" : rawSession
            self.bridge.lastToolCallStatus = .executing(callName)
            let r = await self.bridge.invokeTool(name: toolNm, args: invokeArgs, sessionKey: sessionKey)
            self.bridge.lastToolCallStatus = r.ok ? .completed(callName) : .failed(callName, r.detail)
            result = r.ok ? .success(r.detail) : .failure(r.detail)
          }
        }
      } else if callName == "scan_room" {
        self.roomScanController.streamVM = self.streamSessionViewModel
        self.roomScanController.geminiVM = self.geminiSessionViewModel
        do {
          let summary = try await self.roomScanController.startScan()
          if let g = self.geminiSessionViewModel {
            if !g.isGeminiActive || g.connectionState != .ready {
              NSLog(
                "[ToolCall] scan_room finished but Gemini session is not active (isGeminiActive=%@ state=%@); tool response may not reach the client.",
                String(g.isGeminiActive), String(describing: g.connectionState))
            }
          } else {
            NSLog("[ToolCall] scan_room finished but geminiSessionViewModel is nil; tool response may not reach the client.")
          }
          result = .success(summary)
        } catch let roomErr as RoomScanError {
          result = .failure(roomErr.localizedDescription)
        } catch {
          result = .failure("Scan failed: \(error.localizedDescription)")
        }
      } else if callName == "find_object" {
        let query = (call.args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = SpatialObjectMap.shared.find(query: query) {
          if let engine = self.audioEngine {
            engine.setBeacon(atWorldPosition: found.worldPosition)
            result = .success("Found \(found.label). Pointing audio beacon toward it now.")
          } else {
            result = .failure("Spatial audio engine is not available.")
          }
        } else {
          let q = query.isEmpty ? "that object" : query
          result = .failure("Couldn't find \(q). Try scanning the room first.")
        }
      } else if callName == "list_objects" {
        let objects = SpatialObjectMap.shared.allObjects()
        if objects.isEmpty {
          result = .failure("No objects mapped yet. Say 'scan the room' first.")
        } else {
          let list = objects.map(\.label).joined(separator: ", ")
          result = .success("I found \(objects.count) objects: \(list).")
        }
      } else {
        let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
        result = await bridge.delegateTask(task: taskDesc, toolName: callName)
      }

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
  }

  // MARK: - Private

  /// Accepts omitted args, `{}`, a JSON object string, or a dictionary from the Live API.
  private static func parseOpenClawInvokeArgs(_ value: Any?) -> Result<[String: Any], InvokeArgsError> {
    guard let value else { return .success([:]) }
    if let dict = value as? [String: Any] { return .success(dict) }
    if let s = value as? String {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty || t == "{}" { return .success([:]) }
      guard let data = t.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure(.invalid("tool_args must be valid JSON object text, e.g. {\"to\":\"+15551234567\"}."))
      }
      return .success(obj)
    }
    return .failure(.invalid("tool_args must be a JSON object string or object."))
  }

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
