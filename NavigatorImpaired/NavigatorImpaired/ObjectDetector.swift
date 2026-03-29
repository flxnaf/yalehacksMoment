import AVFoundation
import Foundation
import Vision
import UIKit

// MARK: - ObjectDetection

/// A named hazard detected in one horizontal zone of the camera frame.
struct ObjectDetection: Sendable {
    /// Human-readable label, e.g. "stairs", "chair", "door".
    let label: String
    /// Normalised horizontal position 0 (left) → 1 (right), from the zone's centre.
    let azimuthFraction: Float
    /// Depth value 0 (far) → 1 (near) sampled inside this zone.
    let estimatedDepth: Float
    let confidence: Float

    /// Approximate distance in metres using DepthAnything V2's scale (max ~10 m).
    var approximateMeters: Double { Double(10.0 * (1.0 - estimatedDepth)) }

    /// Direction word for TTS ("ahead", "left", "right").
    var directionWord: String {
        switch azimuthFraction {
        case ..<0.35: return "left"
        case 0.65...: return "right"
        default:      return "ahead"
        }
    }

    /// Spoken announcement phrase, e.g. "Stairs ahead", "Chair left".
    var spokenPhrase: String { "\(label.capitalized) \(directionWord)" }
}

// MARK: - ObjectDetector

/// Detects named hazard objects by running Apple's built-in `VNClassifyImageRequest`
/// on three horizontal crops of each frame (left / centre / right), then gates results
/// against the monocular depth map so only genuinely close objects trigger an alert.
///
/// No external CoreML model required — works entirely with Apple's on-device classifiers.
/// Throttled to ~1 Hz so it does not compete with the depth inference pipeline.
///
/// Announces detections via `AVSpeechSynthesizer` with a per-label 6-second cooldown,
/// so "Chair left" only fires once every 6 s even if the chair stays in view.
@MainActor
final class ObjectDetector {

    // MARK: - Tunable

    /// Minimum VNClassifyImageRequest confidence to consider a label.
    var minimumClassifyConfidence: Float = 0.20

    /// Per-label cooldown between spoken announcements (seconds).
    var announcementCooldown: TimeInterval = 6.0

    // MARK: - Hazard catalogue
    // Each entry maps keyword substrings → (displayName, depth threshold, priority).
    // Depth threshold: minimum normalised depth (0=far, 1=near) to trigger an alert.
    // Using ObstacleAnalyzer scale: distance ≈ 10 × (1 − depth), so
    //   depth 0.70 ≈ 3 m   depth 0.80 ≈ 2 m   depth 0.90 ≈ 1 m

    private struct Hazard {
        let keywords:     [String]
        let displayName:  String
        let depthGate:    Float    // trigger only when zone depth ≥ this value
        let priority:     Int      // lower = more urgent
    }

    private let hazards: [Hazard] = [
        Hazard(keywords: ["stair", "escalator", "step"],               displayName: "stairs",   depthGate: 0.65, priority: 0),
        Hazard(keywords: ["door", "gate", "entrance", "exit"],         displayName: "door",     depthGate: 0.70, priority: 1),
        Hazard(keywords: ["bicycle", "bike", "cycle", "scooter"],      displayName: "bicycle",  depthGate: 0.75, priority: 2),
        Hazard(keywords: ["car", "truck", "vehicle", "bus", "auto"],   displayName: "vehicle",  depthGate: 0.75, priority: 2),
        Hazard(keywords: ["chair", "seat"],                            displayName: "chair",    depthGate: 0.80, priority: 3),
        Hazard(keywords: ["table", "desk", "counter"],                 displayName: "table",    depthGate: 0.80, priority: 3),
        Hazard(keywords: ["bench"],                                    displayName: "bench",    depthGate: 0.80, priority: 4),
        Hazard(keywords: ["sign", "pole", "post"],                     displayName: "pole",     depthGate: 0.80, priority: 4),
    ]

    // MARK: - State

    private var busy = false
    private var lastRunTime: Date = .distantPast
    private let runCooldown: TimeInterval = 1.0

    /// Cooldown between Gemini scans. 5 s keeps the user informed without overwhelming them.
    private let geminiCooldown: TimeInterval = 5.0
    private var lastGeminiTime: Date = .distantPast
    private var geminiInFlight = false
    /// True after the first scan fires — used to play a one-time startup announcement.
    private var geminiStarted = false

    private var lastAnnouncedAt: [String: Date] = [:]
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Public API

    /// Detect hazard objects in `image` using zone-based classification + depth gating.
    /// Speaks any newly detected close objects. Safe to call every depth frame — internally throttled to ~1 Hz.
    func detectAndAnnounce(
        image: UIImage,
        depthMap: [Float],
        depthWidth: Int,
        depthHeight: Int
    ) {
        let now = Date()
        guard !busy, now.timeIntervalSince(lastRunTime) >= runCooldown else { return }
        guard !depthMap.isEmpty, depthWidth > 0, depthHeight > 0 else { return }
        guard let cgImage = image.cgImage else { return }

        busy = true
        lastRunTime = now

        let fullW  = cgImage.width
        let fullH  = cgImage.height
        guard fullW > 0, fullH > 0 else { busy = false; return }

        // Three equal horizontal crops: left (0..⅓), centre (⅓..⅔), right (⅔..1).
        // azimuthFraction is the crop's horizontal centre in normalised [0,1] space.
        let zoneWidth = fullW / 3
        let zones: [(rect: CGRect, azimuth: Float)] = [
            (CGRect(x: 0,            y: 0, width: zoneWidth,              height: fullH), 1.0 / 6.0),
            (CGRect(x: zoneWidth,    y: 0, width: zoneWidth,              height: fullH), 0.5),
            (CGRect(x: 2 * zoneWidth,y: 0, width: fullW - 2 * zoneWidth,  height: fullH), 5.0 / 6.0),
        ]

        let dm           = depthMap
        let dw           = depthWidth
        let dh           = depthHeight
        let minConf      = minimumClassifyConfidence
        let hazardCopy   = hazards

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var detections: [ObjectDetection] = []

            for (zoneIdx, zone) in zones.enumerated() {
                guard let crop = cgImage.cropping(to: zone.rect) else { continue }

                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:])
                guard (try? handler.perform([request])) != nil else { continue }

                let results = request.results ?? []

                // Find the highest-priority hazard label present in this crop.
                var matchedHazard: Hazard? = nil
                var matchedConfidence: Float = 0

                for hazard in hazardCopy {
                    for obs in results {
                        guard obs.confidence >= minConf else { continue }
                        let id = obs.identifier.lowercased()
                        if hazard.keywords.contains(where: { id.contains($0) }) {
                            if matchedHazard == nil || hazard.priority < matchedHazard!.priority {
                                matchedHazard = hazard
                                matchedConfidence = obs.confidence
                            }
                            break
                        }
                    }
                }

                guard let hazard = matchedHazard else { continue }

                // Zone bounding box in Vision normalised coordinates (y=0 at bottom).
                // Covering the full height of this horizontal strip.
                let visionBBox = CGRect(
                    x: CGFloat(zoneIdx) / 3.0,
                    y: 0,
                    width: 1.0 / 3.0,
                    height: 1.0
                )

                guard let depth = VisionDetector.sampleDepth(
                    depthMap: dm, width: dw, height: dh, bbox: visionBBox
                ), depth >= hazard.depthGate else { continue }

                detections.append(ObjectDetection(
                    label:           hazard.displayName,
                    azimuthFraction: zone.azimuth,
                    estimatedDepth:  depth,
                    confidence:      matchedConfidence
                ))
            }

            // Sort: highest priority first, then nearest.
            detections.sort { a, b in
                let pa = hazardCopy.first(where: { $0.displayName == a.label })?.priority ?? 99
                let pb = hazardCopy.first(where: { $0.displayName == b.label })?.priority ?? 99
                if pa != pb { return pa < pb }
                return a.estimatedDepth > b.estimatedDepth  // deeper = nearer
            }

            Task { @MainActor [weak self] in
                self?.busy = false
                self?.handleDetections(detections)
            }
        }
    }

    // MARK: - Gemini obstacle scanner (proactive, always-on)

    /// Proactively scans the scene with Gemini Vision every `geminiCooldown` seconds.
    /// No depth threshold — always fires so the user is continuously informed.
    /// Safe to call every depth frame; the cooldown gate handles rate-limiting.
    func detectWithGeminiIfClose(
        image: UIImage,
        depthMap: [Float],
        depthWidth: Int,
        depthHeight: Int
    ) {
        let now = Date()
        guard !geminiInFlight,
              now.timeIntervalSince(lastGeminiTime) >= geminiCooldown
        else { return }

        // First call ever — announce that obstacle detection is live, then start scanning.
        if !geminiStarted {
            geminiStarted = true
            lastGeminiTime = now
            speak("Obstacle detection is active. I will alert you of what is ahead.")
            print("🔍 [ObjectDetector] Gemini obstacle detection started")
            return
        }

        geminiInFlight = true
        lastGeminiTime = now
        print("🔍 [ObjectDetector] Gemini scanning…")

        NetworkManager.identifyObstacles(image: image) { [weak self] text in
            guard let self else { return }
            self.geminiInFlight = false
            guard let text, !text.isEmpty else {
                print("🔍 [ObjectDetector] Gemini returned nil — check API key")
                return
            }
            print("🔍 [ObjectDetector] Gemini: \(text)")
            self.speak(text)
        }
    }

    // MARK: - Announcement

    private func handleDetections(_ detections: [ObjectDetection]) {
        let now = Date()

        for detection in detections {
            let key = detection.label
            if let last = lastAnnouncedAt[key],
               now.timeIntervalSince(last) < announcementCooldown { continue }

            lastAnnouncedAt[key] = now
            speak(detection.spokenPhrase)
            print("🔍 [ObjectDetector] \(detection.spokenPhrase) — depth=\(String(format:"%.2f", detection.estimatedDepth)) (~\(String(format:"%.1f",detection.approximateMeters))m) conf=\(String(format:"%.2f",detection.confidence))")

            // Announce at most one object per run to avoid overloading the user.
            break
        }
    }

    private func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance             = AVSpeechUtterance(string: text)
        utterance.voice           = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate            = 0.52
        utterance.volume          = 1.0
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }
}
