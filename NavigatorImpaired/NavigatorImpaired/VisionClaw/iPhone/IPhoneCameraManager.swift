import ARKit
import UIKit

class IPhoneCameraManager: NSObject {
  let arSession = ARSession()
  private let context = CIContext()
  private var isRunning = false

  var onFrameCaptured: ((UIImage) -> Void)?
  var onARFrameUpdate: ((ARFrame) -> Void)?

  func start() {
    guard !isRunning else { return }
    arSession.delegate = self
    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity
    config.isAutoFocusEnabled = true
    if let hiRes = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
      $0.imageResolution.width >= 1280
    }) {
      config.videoFormat = hiRes
    }
    arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    isRunning = true
    NSLog("[iPhoneCamera] ARSession started (world tracking)")
  }

  func stop() {
    guard isRunning else { return }
    arSession.pause()
    isRunning = false
    NSLog("[iPhoneCamera] ARSession paused")
  }

  var currentFrame: ARFrame? {
    arSession.currentFrame
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - ARSessionDelegate

extension IPhoneCameraManager: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let pixelBuffer = frame.capturedImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        .oriented(.right)

    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let image = UIImage(cgImage: cgImage)

    onFrameCaptured?(image)
    onARFrameUpdate?(frame)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    NSLog("[iPhoneCamera] ARSession failed: \(error.localizedDescription)")
  }

  func sessionWasInterrupted(_ session: ARSession) {
    NSLog("[iPhoneCamera] ARSession interrupted")
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    NSLog("[iPhoneCamera] ARSession interruption ended — relocating")
  }

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    switch camera.trackingState {
    case .notAvailable:
      NSLog("[iPhoneCamera] Tracking: NOT AVAILABLE")
    case .limited(let reason):
      NSLog("[iPhoneCamera] Tracking: LIMITED (\(reason))")
    case .normal:
      NSLog("[iPhoneCamera] Tracking: NORMAL")
    }
  }
}
