import AVFoundation
import UIKit

class PhoneCameraManager: NSObject, ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var statusMessage = "Not started"

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cam.q")
    private var frameCount = 0

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.statusMessage = "Camera permission denied" }
                return
            }
            self.sessionQueue.async { self.setup() }
        }
    }

    func stop() {
        sessionQueue.async {
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.currentFrame = nil
                self.statusMessage = "Stopped"
            }
        }
    }

    private func setup() {
        let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                  ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.statusMessage = "Camera unavailable" }
            return
        }
        let lensName = device.deviceType == .builtInUltraWideCamera ? "0.5×" : "1×"
        print("[Cam] Using \(lensName) lens")

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()

        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                               object: session, queue: nil) { n in
            let code = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            print("[Cam] ⚠️ Interrupted: \(code)")
            DispatchQueue.main.async { self.statusMessage = "Interrupted (\(code))" }
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                               object: session, queue: nil) { _ in
            self.sessionQueue.async { self.session.startRunning() }
        }

        session.startRunning()
        DispatchQueue.main.async { self.statusMessage = self.session.isRunning ? "Running" : "Failed" }
        print("[Cam] running: \(session.isRunning)")
    }

    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])
}

extension PhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount % 3 == 0 else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Physically rotate the pixel data to portrait so both the UI and
        // VNImageRequestHandler see the same orientation.
        let ci = CIImage(cvPixelBuffer: pb).oriented(.right)
        guard let cg = Self.ctx.createCGImage(ci, from: ci.extent) else { return }
        let img = UIImage(cgImage: cg)
        DispatchQueue.main.async { self.currentFrame = img }
    }
}
