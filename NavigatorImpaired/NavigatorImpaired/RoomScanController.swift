import ARKit
import Foundation
import simd
import UIKit

enum RoomScanError: LocalizedError {
  case notIPhoneMode
  case noKeyframes
  case streamUnavailable

  var errorDescription: String? {
    switch self {
    case .notIPhoneMode:
      return "Object scanning requires iPhone camera mode."
    case .noKeyframes:
      return "Couldn't capture any frames. Make sure the camera is active."
    case .streamUnavailable:
      return "Streaming session is not available."
    }
  }
}

@MainActor
final class RoomScanController {
  private(set) var isScanning = false
  private var keyframes: [ScanKeyframe] = []

  private let maxKeyframes = 12
  private let keyframeInterval: TimeInterval = 1.5
  private let scanDuration: TimeInterval = 18.0

  weak var streamVM: StreamSessionViewModel?
  weak var geminiVM: GeminiSessionViewModel?

  func startScan() async throws -> String {
    guard !isScanning else {
      return "Scan already in progress."
    }
    guard let streamVM else {
      throw RoomScanError.streamUnavailable
    }
    guard streamVM.streamingMode == .iPhone else {
      throw RoomScanError.notIPhoneMode
    }
    guard streamVM.streamingStatus != .stopped else {
      throw RoomScanError.streamUnavailable
    }

    isScanning = true
    defer { isScanning = false }

    keyframes = []
    SpatialObjectMap.shared.clear()

    streamVM.setDepthInferenceEnabled(true)
    await waitForDepthModel(streamVM: streamVM, maxWait: 8.0)

    geminiVM?.speakNavigationForUser("Scanning room. Please turn around slowly.", completion: nil)

    let start = Date()
    while Date().timeIntervalSince(start) < scanDuration && keyframes.count < maxKeyframes {
      if let kf = await waitForKeyframe(from: streamVM, maxWait: 2.0) {
        keyframes.append(kf)
      }
      try await Task.sleep(nanoseconds: UInt64(keyframeInterval * 1_000_000_000))
    }

    guard !keyframes.isEmpty else {
      throw RoomScanError.noKeyframes
    }

    geminiVM?.speakNavigationForUser("Analyzing room, one moment.", completion: nil)

    let response = try await GeminiRoomObjectClient.analyzeKeyframes(keyframes)

    let refKeyframe = keyframes.last!
    for obj in response.objects {
      guard obj.confidence > 0.4 else { continue }
      let worldPos = Self.estimateWorldPosition(
        clockDirection: obj.clockDirection,
        horizontalFraction: obj.horizontalFraction,
        distanceBucket: obj.estimatedDistance,
        keyframe: refKeyframe
      )
      SpatialObjectMap.shared.upsert(
        MappedObject(
          label: obj.label,
          worldPosition: worldPos,
          confidence: obj.confidence,
          lastSeen: Date()
        ))
    }

    return response.summary
  }

  private func waitForDepthModel(streamVM: StreamSessionViewModel, maxWait: TimeInterval) async {
    let deadline = Date().addingTimeInterval(maxWait)
    while Date() < deadline {
      if streamVM.depthModelLoaded { return }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
  }

  /// Waits until depth + pose + image align (or fallback), up to `maxWait` seconds.
  private func waitForKeyframe(from vm: StreamSessionViewModel, maxWait: TimeInterval) async -> ScanKeyframe? {
    let deadline = Date().addingTimeInterval(maxWait)
    while Date() < deadline {
      if let depth = vm.latestDepthResult,
         let pose = vm.depthAlignedCameraPose ?? vm.latestCameraTransform,
         let image = vm.depthAlignedImage ?? vm.currentVideoFrame {
        return ScanKeyframe(
          image: image,
          depthResult: depth,
          cameraPose: pose,
          timestamp: Date()
        )
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return nil
  }

  /// World-space point from horizontal aim + depth-informed distance (Gemini bucket is fallback only).
  private static func estimateWorldPosition(
    clockDirection: Int,
    horizontalFraction: Float?,
    distanceBucket: String,
    keyframe: ScanKeyframe
  ) -> simd_float3 {
    let hf: Float
    if let h = horizontalFraction {
      hf = max(0, min(1, h))
    } else {
      hf = horizontalFractionFromClock(clockDirection)
    }

    let depth = keyframe.depthResult
    let depthMeters = ColumnDepthSampler.distanceMeters(
      depthMap: depth.depthMap,
      width: depth.mapWidth,
      height: depth.mapHeight,
      horizontalFraction: hf
    )
    let distanceMeters: Float
    if let dm = depthMeters {
      distanceMeters = min(9.5, max(0.25, dm))
    } else {
      distanceMeters = distanceMetersFromBucket(distanceBucket)
    }

    // 120° horizontal FOV (matches SmartAssistant clock-face mapping).
    let bearingDeg = (hf - 0.5) * 120.0
    let angleRad = bearingDeg * .pi / 180.0
    let localDir = simd_float3(sin(angleRad), 0, -cos(angleRad))

    let cam = keyframe.cameraPose
    let basis = simd_float3x3(
      simd_float3(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z),
      simd_float3(cam.columns.1.x, cam.columns.1.y, cam.columns.1.z),
      simd_float3(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
    )
    let worldDir = simd_normalize(simd_mul(basis, localDir))
    let cameraPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
    return cameraPos + worldDir * distanceMeters
  }

  /// Maps clock 1–12 to 0…1 horizontal image position (120° FOV, center = 0.5).
  private static func horizontalFractionFromClock(_ clockDirection: Int) -> Float {
    let angleDeg = Float(clockDirection - 12) * 30.0
    let wrapped = wrapAngle180(angleDeg)
    let clamped = min(60, max(-60, wrapped))
    return (clamped + 60) / 120
  }

  private static func wrapAngle180(_ degrees: Float) -> Float {
    var v = degrees.truncatingRemainder(dividingBy: 360)
    if v > 180 { v -= 360 }
    if v < -180 { v += 360 }
    return v
  }

  private static func distanceMetersFromBucket(_ bucket: String) -> Float {
    switch bucket.lowercased() {
    case "very close": return 0.4
    case "close": return 1.2
    case "nearby": return 3.5
    default: return 3.0
    }
  }
}
