import Foundation

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private weak var navigationController: NavigationController?
  private weak var audioEngine: SpatialAudioEngine?
  private var inFlightTasks: [String: Task<Void, Never>] = [:]

  init(bridge: OpenClawBridge,
       navigationController: NavigationController? = nil,
       audioEngine: SpatialAudioEngine? = nil) {
    self.bridge = bridge
    self.navigationController = navigationController
    self.audioEngine = audioEngine
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
            try await nav.startNavigation(to: destination)
            result = .success("Navigation started to \(destination).")
          } catch {
            result = .failure(error.localizedDescription)
          }
        } else {
          result = .failure("Navigation is not available.")
        }
      } else if callName == "set_ping" {
        let bearing = (call.args["bearing"] as? NSNumber)?.floatValue ?? 0
        if let engine = audioEngine {
          engine.setBeaconBearing(bearing)
          result = .success("Ping beacon placed at \(bearing)° from your current facing direction.")
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
