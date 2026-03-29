import CoreLocation
import Foundation
import Testing
@testable import NavigatorImpaired

struct RouteSegmentationTests {

    @Test func polylineDecoderDecodesWithoutCrashing() {
        let pts = PolylineDecoder.decode("")
        #expect(pts.isEmpty)
        // Two-point path (common Google example polyline).
        let encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        let pts2 = PolylineDecoder.decode(encoded)
        #expect(!pts2.isEmpty)
    }

    @Test func segmenterThrowsOnEmptyRoutes() {
        let data = Data(#"{"status":"OK","routes":[]}"#.utf8)
        #expect(throws: RouteSegmentationError.self) {
            try RouteSegmenter().segment(directionsResponseData: data)
        }
    }

    @Test func angleDifferenceAcute() {
        let d = RouteGeometry.angleDifferenceDegrees(10, 90)
        #expect(abs(d - 80) < 0.01)
    }

    @Test func turnExtractorEmitsStartCornerAndDestination() {
        // Square path: north 100m, east 100m, south 100m — sharp corners ~90°.
        let o = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let n = CLLocationCoordinate2D(latitude: 40.0009, longitude: -74.0)
        let e = CLLocationCoordinate2D(latitude: 40.0009, longitude: -73.9991)
        let s = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.9991)

        func cp(_ c: CLLocationCoordinate2D, dist: Double, step: Int, instr: String, bear: Double) -> RouteCheckpoint {
            RouteCheckpoint(
                coordinate: c,
                distanceFromStartMeters: dist,
                stepIndex: step,
                stepInstruction: instr,
                bearingToNextDegrees: bear
            )
        }

        let b0n = RouteGeometry.bearingDegrees(from: o, to: n)
        let bne = RouteGeometry.bearingDegrees(from: n, to: e)
        let bes = RouteGeometry.bearingDegrees(from: e, to: s)

        let checkpoints = [
            cp(o, dist: 0, step: 0, instr: "Head north", bear: b0n),
            cp(n, dist: 100, step: 0, instr: "Turn right", bear: bne),
            cp(e, dist: 200, step: 1, instr: "Turn right", bear: bes),
            cp(s, dist: 300, step: 1, instr: "Arrive", bear: bes)
        ]

        let targets = TurnPointExtractor().extract(checkpoints: checkpoints)
        #expect(targets.count >= 3)
        #expect(targets.first?.isFinalDestination == false)
        #expect(targets.last?.isFinalDestination == true)
    }
}
