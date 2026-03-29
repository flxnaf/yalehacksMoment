import ARKit
import UIKit

class IPhoneCameraManager: NSObject {
  let arSession = ARSession()
  private let context = CIContext()
  private let processQueue = DispatchQueue(label: "ar-frame-process")
  private var isRunning = false
  private var isProcessingFrame = false

  /// Latest camera transform, written on main thread (ARSession delegate).
  /// Safe to read from main thread / main actor without locking.
  private(set) var latestTransform: simd_float4x4 = matrix_identity_float4x4

  var onFrameCaptured: ((UIImage) -> Void)?

  func start() {
    guard !isRunning else { return }
    arSession.delegate = self
    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity
    config.isAutoFocusEnabled = true
    config.planeDetection = [.horizontal, .vertical]
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      config.sceneReconstruction = .mesh
    }
    arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    isRunning = true
    NSLog("[iPhoneCamera] ARSession started (world tracking, plane detection ON)")
  }

  func stop() {
    guard isRunning else { return }
    arSession.pause()
    isRunning = false
    NSLog("[iPhoneCamera] ARSession paused")
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
    latestTransform = frame.camera.transform

    guard !isProcessingFrame else { return }
    isProcessingFrame = true

    let pixelBuffer = frame.capturedImage
    processQueue.async { [weak self] in
      guard let self else { return }
      let image: UIImage? = autoreleasepool {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        guard let cgImage = self.context.createCGImage(ciImage, from: ciImage.extent) else {
          return nil
        }
        return UIImage(cgImage: cgImage)
      }
      guard let image else {
        DispatchQueue.main.async { self.isProcessingFrame = false }
        return
      }
      DispatchQueue.main.async {
        self.isProcessingFrame = false
        self.onFrameCaptured?(image)
      }
    }
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
