import CoreLocation
import Foundation

/// Result of parsing Directions JSON into dense checkpoints along the walking path.
struct RouteSegmentationResult {
    let checkpoints: [RouteCheckpoint]
    let steps: [DirectionsStepRecord]
}

enum RouteSegmentationError: Error {
    case invalidJSON
    case noRoutes
    case noLegs
    case noSteps
    case emptyPath
}

/// Builds merged, deduped polylines from `legs[0].steps` and resamples into checkpoints.
final class RouteSegmenter {

    private let checkpointIntervalMeters: Double

    init(checkpointIntervalMeters: Double = 15) {
        self.checkpointIntervalMeters = checkpointIntervalMeters
    }

    func segment(directionsResponseData data: Data) throws -> RouteSegmentationResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouteSegmentationError.invalidJSON
        }
        guard let routes = json["routes"] as? [[String: Any]], let route0 = routes.first else {
            throw RouteSegmentationError.noRoutes
        }
        guard let legs = route0["legs"] as? [[String: Any]], let leg0 = legs.first else {
            throw RouteSegmentationError.noLegs
        }
        guard let stepDicts = leg0["steps"] as? [[String: Any]], !stepDicts.isEmpty else {
            throw RouteSegmentationError.noSteps
        }

        var steps: [DirectionsStepRecord] = []
        steps.reserveCapacity(stepDicts.count)

        /// Merged vertices with step index (fix #1: dedupe shared step boundary points).
        var tagged: [(CLLocationCoordinate2D, Int)] = []
        tagged.reserveCapacity(stepDicts.count * 8)

        for (stepIndex, sd) in stepDicts.enumerated() {
            let html = sd["html_instructions"] as? String ?? ""
            guard let polyObj = sd["polyline"] as? [String: Any],
                  let encoded = polyObj["points"] as? String else { continue }
            let distObj = sd["distance"] as? [String: Any]
            let distVal = (distObj?["value"] as? Double)
                ?? (distObj?["value"] as? Int).map(Double.init)
                ?? 0
            steps.append(DirectionsStepRecord(htmlInstructions: html, polylineEncoded: encoded, distanceMeters: distVal))

            let decoded = PolylineDecoder.decode(encoded)
            for p in decoded {
                if let last = tagged.last {
                    let d = RouteGeometry.distanceMeters(last.0, p)
                    if d < 1.5 {
                        continue
                    }
                }
                tagged.append((p, stepIndex))
            }
        }

        guard tagged.count >= 2 else { throw RouteSegmentationError.emptyPath }

        let resampled = resampleTaggedPath(tagged, every: checkpointIntervalMeters)
        guard resampled.count >= 2 else { throw RouteSegmentationError.emptyPath }

        var checkpoints: [RouteCheckpoint] = []
        checkpoints.reserveCapacity(resampled.count)

        var cumulative: Double = 0
        for i in 0..<resampled.count {
            if i > 0 {
                cumulative += RouteGeometry.distanceMeters(resampled[i - 1].coord, resampled[i].coord)
            }
            let stepIdx = resampled[i].stepIndex
            let instruction = steps.indices.contains(stepIdx)
                ? Self.stripHTMLTags(steps[stepIdx].htmlInstructions)
                : ""

            let bearing: Double
            if i < resampled.count - 1 {
                bearing = RouteGeometry.bearingDegrees(from: resampled[i].coord, to: resampled[i + 1].coord)
            } else if i > 0 {
                bearing = RouteGeometry.bearingDegrees(from: resampled[i - 1].coord, to: resampled[i].coord)
            } else {
                bearing = 0
            }

            checkpoints.append(
                RouteCheckpoint(
                    coordinate: resampled[i].coord,
                    distanceFromStartMeters: cumulative,
                    stepIndex: stepIdx,
                    stepInstruction: instruction,
                    bearingToNextDegrees: bearing
                )
            )
        }

        fixStepEndBearings(checkpoints: &checkpoints, resampled: resampled)
        densifyFinalSegmentBearings(checkpoints: &checkpoints)

        return RouteSegmentationResult(checkpoints: checkpoints, steps: steps)
    }

    // MARK: - Fix #2 step-end bearings

    /// Align bearings at step boundaries with the direction into the next step’s geometry.
    private func fixStepEndBearings(
        checkpoints: inout [RouteCheckpoint],
        resampled: [(coord: CLLocationCoordinate2D, stepIndex: Int)]
    ) {
        guard checkpoints.count == resampled.count else { return }
        for i in 0..<(checkpoints.count - 1) {
            let s0 = resampled[i].stepIndex
            let s1 = resampled[i + 1].stepIndex
            if s1 > s0 {
                let b = RouteGeometry.bearingDegrees(from: checkpoints[i].coordinate, to: checkpoints[i + 1].coordinate)
                checkpoints[i] = RouteCheckpoint(
                    coordinate: checkpoints[i].coordinate,
                    distanceFromStartMeters: checkpoints[i].distanceFromStartMeters,
                    stepIndex: checkpoints[i].stepIndex,
                    stepInstruction: checkpoints[i].stepInstruction,
                    bearingToNextDegrees: b
                )
            }
        }
    }

    // MARK: - Fix #3 final-segment bearing consistency

    private func densifyFinalSegmentBearings(checkpoints: inout [RouteCheckpoint]) {
        guard checkpoints.count >= 2 else { return }
        let penultimate = checkpoints.count - 2
        let approach = RouteGeometry.bearingDegrees(
            from: checkpoints[penultimate].coordinate,
            to: checkpoints[checkpoints.count - 1].coordinate
        )
        checkpoints[penultimate] = RouteCheckpoint(
            coordinate: checkpoints[penultimate].coordinate,
            distanceFromStartMeters: checkpoints[penultimate].distanceFromStartMeters,
            stepIndex: checkpoints[penultimate].stepIndex,
            stepInstruction: checkpoints[penultimate].stepInstruction,
            bearingToNextDegrees: approach
        )
    }

    // MARK: - Resample

    /// Distance-along-route resample: emit a point every `interval` m; `stepIndex` is the segment’s start step.
    private func resampleTaggedPath(
        _ tagged: [(CLLocationCoordinate2D, Int)],
        every interval: Double
    ) -> [(coord: CLLocationCoordinate2D, stepIndex: Int)] {
        guard tagged.count >= 2 else {
            return tagged.map { ($0.0, $0.1) }
        }
        var out: [(CLLocationCoordinate2D, Int)] = []
        out.append((tagged[0].0, tagged[0].1))

        var distanceToSegmentStart: Double = 0
        var nextMark = interval

        for i in 0..<(tagged.count - 1) {
            let a = tagged[i].0
            let b = tagged[i + 1].0
            let stepIdx = tagged[i].1
            let len = RouteGeometry.distanceMeters(a, b)
            guard len > 0.001 else { continue }

            while distanceToSegmentStart + len >= nextMark - 0.001 {
                let alongSeg = nextMark - distanceToSegmentStart
                let t = min(1, max(0, alongSeg / len))
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                out.append((CLLocationCoordinate2D(latitude: lat, longitude: lon), stepIdx))
                nextMark += interval
            }
            distanceToSegmentStart += len
        }

        if let end = tagged.last {
            if let prev = out.last, RouteGeometry.distanceMeters(prev.0, end.0) > 2 {
                out.append(end)
            } else if !out.isEmpty {
                out[out.count - 1] = end
            }
        }

        return out
    }

    private static func stripHTMLTags(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
