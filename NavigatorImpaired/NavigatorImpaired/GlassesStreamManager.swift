import UIKit
import CoreImage
import CoreMedia
import CoreVideo
import MWDATCore
import MWDATCamera

@MainActor
class GlassesStreamManager: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var statusText: String = "Disconnected"

    private let wearables: WearablesInterface
    private let session: StreamSession
    private var listenerToken: (any AnyListenerToken)?
    private var stateToken: (any AnyListenerToken)?
    private var errorToken: (any AnyListenerToken)?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        let selector = AutoDeviceSelector(wearables: wearables)
        // `.hvc1` often yields frames where `makeUIImage()` is nil on device; `.raw` matches Meta samples.
        session = StreamSession(
            streamSessionConfig: StreamSessionConfig(
                videoCodec: .raw,
                resolution: .medium,
                frameRate: 30
            ),
            deviceSelector: selector
        )
    }

    func startStreaming() async {
        await listenerToken?.cancel()
        await stateToken?.cancel()
        await errorToken?.cancel()
        listenerToken = nil
        stateToken = nil
        errorToken = nil
        await session.stop()

        do {
            let status = try await wearables.requestPermission(.camera)
            guard status == .granted else {
                statusText = "Allow glasses camera in Meta AI, then retry"
                return
            }
        } catch {
            statusText = "Camera permission: \(error.localizedDescription)"
            return
        }

        stateToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.statusText = state.description
            }
        }

        errorToken = session.errorPublisher.listen { [weak self] err in
            Task { @MainActor [weak self] in
                self?.statusText = err.userMessage
            }
        }

        listenerToken = session.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image = Self.uiImage(from: frame), image.size.width > 0, image.size.height > 0 else {
                    return
                }
                self.currentFrame = image
            }
        }

        await session.start()
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Prefer SDK conversion; fall back to CVPixelBuffer → CGImage (needed when HEVC path returns nil).
    private static func uiImage(from frame: VideoFrame) -> UIImage? {
        if let img = frame.makeUIImage(), img.size.width > 0, img.size.height > 0 {
            return img
        }
        let sb = frame.sampleBuffer
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ci = CIImage(cvPixelBuffer: pb)
        var extent = ci.extent
        if extent.isInfinite || extent.isEmpty {
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            guard w > 0, h > 0 else { return nil }
            extent = CGRect(x: 0, y: 0, width: w, height: h)
        }
        guard let cg = ciContext.createCGImage(ci, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func stopStreaming() async {
        await listenerToken?.cancel()
        await stateToken?.cancel()
        await errorToken?.cancel()
        listenerToken = nil
        stateToken = nil
        errorToken = nil
        await session.stop()
        currentFrame = nil
        statusText = "Stopped"
    }
}

private extension StreamSessionError {
    var userMessage: String {
        switch self {
        case .internalError: return "Stream error (internal)"
        case .permissionDenied: return "Glasses camera denied — check Meta AI"
        case .hingesClosed: return "Open the glasses arms / display"
        case .thermalCritical: return "Glasses too warm — wait and retry"
        case .timeout: return "Stream timed out"
        case .videoStreamingError: return "Video streaming failed"
        case .deviceNotFound: return "Glasses not found"
        case .deviceNotConnected: return "Glasses not connected"
        }
    }
}

private extension StreamSessionState {
    var description: String {
        switch self {
        case .stopped:          return "Stopped"
        case .stopping:         return "Stopping…"
        case .waitingForDevice: return "Waiting for glasses…"
        case .starting:         return "Starting…"
        case .streaming:        return "Streaming"
        case .paused:           return "Paused"
        }
    }
}
