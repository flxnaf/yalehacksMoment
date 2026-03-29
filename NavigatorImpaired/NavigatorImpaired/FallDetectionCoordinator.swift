import UIKit

@MainActor
final class FallDetectionCoordinator: FallDetectorDelegate {
    static let shared = FallDetectionCoordinator()

    weak var cameraManager: RayBanCameraManager?

    /// Original spec 0.45; real drops + tuned detector often score ~0.2–0.35 — stay above false-positive floor.
    private let confidenceThreshold: Float = 0.22
    private let detector = FallDetector()

    private init() {}

    func start() {
        detector.delegate = self
        detector.startMonitoring()
    }

    func stop() {
        detector.stopMonitoring()
    }

    func handleDoubleTap() {
        Task { await GuardianAlertManager.shared.cancelAlert() }
    }

    func triggerManualSOS() {
        Task {
            let frame = await frameForGuardianEmail()
            await GuardianAlertManager.shared.triggerAlert(confidence: 1.0, lastFrame: frame)
        }
    }

    func fallDetected(confidence: Float, timestamp: Date) {
        guard confidence >= confidenceThreshold else {
            #if DEBUG
            print("[FallDetectionCoordinator] ignored fall: confidence=\(confidence) < \(confidenceThreshold)")
            #endif
            return
        }
        Task {
            let frame = await frameForGuardianEmail()
            await GuardianAlertManager.shared.triggerAlert(confidence: confidence, lastFrame: frame)
        }
    }

    /// Prefer the last frame actually sent to Gemini Live; otherwise the current stream frame (glasses/phone).
    private func frameForGuardianEmail() async -> UIImage? {
        if let lastToGemini = LastGeminiVideoFrame.lastImageSentToGemini {
            return lastToGemini
        }
        return await cameraManager?.captureFrame()
    }
}
