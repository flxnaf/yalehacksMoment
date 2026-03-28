import Foundation
import Vision
import UIKit

// MARK: - Detection types

struct PersonDetection: Sendable {
    let boundingBox: CGRect
    let confidence: Float
    /// Estimated depth (0 = far, 1 = near) sampled from the centre of the bounding box.
    let estimatedDepth: Float?
    /// Horizontal position as a fraction 0 (left) → 1 (right), derived from bbox centre.
    let azimuthFraction: Float
}

struct SceneLabel: Sendable {
    let identifier: String
    let confidence: Float
}

// MARK: - VisionDetector

/// Runs Apple Vision framework requests (person detection + scene classification)
/// on camera frames and cross-references results with the monocular depth map.
///
/// Throttled internally so it can be called every frame without stalling the
/// depth inference pipeline. Person detection at ~5 Hz, classification at ~1 Hz.
final class VisionDetector: @unchecked Sendable {

    // MARK: - Published results (read from main thread)

    private(set) var latestPersons: [PersonDetection] = []
    private(set) var latestSceneLabel: SceneLabel?

    // MARK: - Throttle state

    private var personBusy = false
    private var classifyBusy = false
    private var lastClassifyTime: Date = .distantPast
    private let classifyCooldown: TimeInterval = 1.0

    private let relevantKeywords: Set<String> = [
        "wall", "door", "person", "chair", "table", "car", "tree",
        "pole", "fence", "bicycle", "staircase", "bench", "sign"
    ]

    // MARK: - Public API

    /// Run person detection on the given image. Results stored in `latestPersons`.
    /// Optionally cross-reference with the current depth map for distance estimation.
    func detectPersons(
        image: UIImage,
        depthMap: [Float]? = nil,
        depthWidth: Int = 0,
        depthHeight: Int = 0
    ) {
        guard !personBusy else { return }
        personBusy = true

        guard let cgImage = image.cgImage else {
            personBusy = false
            return
        }

        let dm = depthMap
        let dw = depthWidth
        let dh = depthHeight

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let request = VNDetectHumanRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

            do {
                try handler.perform([request])
            } catch {
                self.personBusy = false
                return
            }

            let observations = (request.results ?? [])
                .filter { $0.confidence > 0.50 }

            let detections: [PersonDetection] = observations.map { obs in
                let box = obs.boundingBox
                let azimuth = Float(box.midX)

                var depth: Float? = nil
                if let dm, dw > 0, dh > 0 {
                    depth = Self.sampleDepth(
                        depthMap: dm, width: dw, height: dh, bbox: box
                    )
                }

                return PersonDetection(
                    boundingBox: box,
                    confidence: obs.confidence,
                    estimatedDepth: depth,
                    azimuthFraction: azimuth
                )
            }

            DispatchQueue.main.async {
                self.latestPersons = detections
                self.personBusy = false
            }
        }
    }

    /// Run scene classification. Throttled to ~1 Hz internally.
    func classifyScene(image: UIImage) {
        let now = Date()
        guard !classifyBusy,
              now.timeIntervalSince(lastClassifyTime) > classifyCooldown else { return }
        classifyBusy = true
        lastClassifyTime = now

        guard let cgImage = image.cgImage else {
            classifyBusy = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

            do {
                try handler.perform([request])
            } catch {
                self.classifyBusy = false
                return
            }

            let top = (request.results ?? [])
                .filter { $0.confidence > 0.25 }
                .first { obs in
                    self.relevantKeywords.contains { obs.identifier.lowercased().contains($0) }
                }

            let label = top.map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }

            DispatchQueue.main.async {
                self.latestSceneLabel = label
                self.classifyBusy = false
            }
        }
    }

    // MARK: - Depth sampling

    /// Sample the depth map within a Vision bounding box.
    /// Vision bbox is (originX, originY, width, height) in normalised coordinates,
    /// with origin at bottom-left. Depth map is row-major top-left origin.
    /// Returns 80th-percentile depth (biased toward the closer readings).
    static func sampleDepth(
        depthMap: [Float], width dw: Int, height dh: Int, bbox: CGRect
    ) -> Float? {
        guard !depthMap.isEmpty, dw > 0, dh > 0 else { return nil }

        let x0 = max(0, Int(bbox.minX * CGFloat(dw)))
        let x1 = min(dw - 1, Int(bbox.maxX * CGFloat(dw)))
        let y0Top = max(0, Int((1.0 - bbox.maxY) * CGFloat(dh)))
        let y1Top = min(dh - 1, Int((1.0 - bbox.minY) * CGFloat(dh)))

        let step = 4
        var samples: [Float] = []
        samples.reserveCapacity(((y1Top - y0Top) / step + 1) * ((x1 - x0) / step + 1))

        var y = y0Top
        while y <= y1Top {
            var x = x0
            while x <= x1 {
                let idx = y * dw + x
                if idx < depthMap.count {
                    let v = depthMap[idx]
                    if v > 0.01 { samples.append(v) }
                }
                x += step
            }
            y += step
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        let p80 = samples[min(samples.count - 1, Int(Float(samples.count) * 0.80))]
        return p80
    }
}
