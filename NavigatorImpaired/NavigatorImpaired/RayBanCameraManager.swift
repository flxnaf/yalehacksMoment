import UIKit

/// Thin adapter over the main streaming view model’s latest glasses/phone video frame.
final class RayBanCameraManager {
    weak var streamViewModel: StreamSessionViewModel?

    init() {}

    func bind(streamViewModel: StreamSessionViewModel) {
        self.streamViewModel = streamViewModel
    }

    func captureFrame() async -> UIImage? {
        await MainActor.run { streamViewModel?.currentVideoFrame }
    }
}
