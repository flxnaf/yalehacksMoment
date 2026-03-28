import UIKit
import MWDATCore
import MWDATCamera

@MainActor
class GlassesStreamManager: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var statusText: String = "Disconnected"

    private let session: StreamSession
    private var listenerToken: (any AnyListenerToken)?
    private var stateToken: (any AnyListenerToken)?

    init(wearables: WearablesInterface) {
        // AutoDeviceSelector picks whichever paired glasses are connected
        let selector = AutoDeviceSelector(wearables: wearables)
        session = StreamSession(
            streamSessionConfig: StreamSessionConfig(
                videoCodec: .hvc1,
                resolution: .medium,
                frameRate: 30
            ),
            deviceSelector: selector
        )
    }

    func startStreaming() async {
        // Observe session state for UI feedback
        stateToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.statusText = state.description
            }
        }

        // Receive video frames
        listenerToken = session.videoFramePublisher.listen { [weak self] frame in
            guard let image = frame.makeUIImage() else { return }
            Task { @MainActor [weak self] in
                self?.currentFrame = image
            }
        }

        await session.start()
    }

    func stopStreaming() async {
        await listenerToken?.cancel()
        await stateToken?.cancel()
        listenerToken = nil
        stateToken = nil
        await session.stop()
        currentFrame = nil
        statusText = "Stopped"
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
