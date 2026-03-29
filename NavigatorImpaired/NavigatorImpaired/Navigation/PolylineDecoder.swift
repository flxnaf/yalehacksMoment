import CoreLocation
import Foundation

/// Google Encoded Polyline Algorithm Format (same as legacy `RouteService.decodePolyline`).
enum PolylineDecoder {
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lng = 0
        while index < encoded.endIndex {
            var shift = 0
            var result = 0
            var byte: Int
            repeat {
                guard index < encoded.endIndex, let ascii = encoded[index].asciiValue else { break }
                byte = Int(ascii) - 63
                result |= (byte & 0x1F) << shift
                shift += 5
                index = encoded.index(after: index)
            } while byte >= 0x20
            let dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += dlat
            shift = 0
            result = 0
            repeat {
                guard index < encoded.endIndex, let ascii = encoded[index].asciiValue else { break }
                byte = Int(ascii) - 63
                result |= (byte & 0x1F) << shift
                shift += 5
                index = encoded.index(after: index)
            } while byte >= 0x20
            let dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lng += dlng
            coordinates.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return coordinates
    }
}
