import UIKit

/// Holds the most recent video frame queued to Gemini Live (`GeminiLiveService.sendVideoFrame`).
/// Used for fall/SOS alerts so the guardian receives the last assistant-camera view before the incident.
@MainActor
enum LastGeminiVideoFrame {
    static var lastImageSentToGemini: UIImage?

    static func clear() {
        lastImageSentToGemini = nil
    }
}
