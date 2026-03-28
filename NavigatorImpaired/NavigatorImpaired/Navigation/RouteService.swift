import CoreLocation
import Foundation

private let microWaypointIntervalMeters: Double = 6.0

enum RouteError: LocalizedError {
    case missingAPIKey
    case httpFailure(Int)
    case googleStatus(String)
    case invalidJSON
    case noRouteFound
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Google Maps API key is missing or invalid."
        case .httpFailure(let code): return "HTTP error \(code)."
        case .googleStatus(let s): return "Google API status: \(s)"
        case .invalidJSON: return "Invalid response from Google."
        case .noRouteFound: return "No walking route found."
        case .noResults: return "No places matched your search."
        }
    }
}

/// Google Directions + Places Text Search for walking routes.
final class RouteService {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private var isAPIKeyValid: Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "YOUR_KEY_HERE"
    }

    /// Resolve a free-text place query to coordinates near `near`.
    func resolveDestination(_ query: String, near: CLLocationCoordinate2D) async throws -> (coordinate: CLLocationCoordinate2D, name: String?) {
        guard isAPIKeyValid else { throw RouteError.missingAPIKey }
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/textsearch/json")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "location", value: "\(near.latitude),\(near.longitude)"),
            URLQueryItem(name: "radius", value: "5000"),
            URLQueryItem(name: "key", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        guard let url = components.url else { throw RouteError.invalidJSON }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RouteError.httpFailure(-1) }
        guard http.statusCode == 200 else { throw RouteError.httpFailure(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouteError.invalidJSON
        }
        let status = json["status"] as? String ?? ""
        if status != "OK" {
            #if DEBUG
            NSLog("[RouteService] Places error body: %@", String(data: data, encoding: .utf8) ?? "")
            #endif
            throw RouteError.googleStatus(status)
        }
        guard let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let geometry = first["geometry"] as? [String: Any],
              let loc = geometry["location"] as? [String: Any],
              let lat = loc["lat"] as? Double,
              let lng = loc["lng"] as? Double else {
            throw RouteError.noResults
        }
        let name = first["name"] as? String
        return (CLLocationCoordinate2D(latitude: lat, longitude: lng), name)
    }

    /// Fetch a walking route between two coordinates.
    func fetchRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, destinationName: String) async throws -> NavigationRoute {
        guard isAPIKeyValid else { throw RouteError.missingAPIKey }
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/directions/json")!
        components.queryItems = [
            URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "mode", value: "walking"),
            URLQueryItem(name: "key", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        guard let url = components.url else { throw RouteError.invalidJSON }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RouteError.httpFailure(-1) }
        guard http.statusCode == 200 else { throw RouteError.httpFailure(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouteError.invalidJSON
        }
        let status = json["status"] as? String ?? ""
        if status != "OK" {
            #if DEBUG
            NSLog("[RouteService] Directions error body: %@", String(data: data, encoding: .utf8) ?? "")
            #endif
            throw RouteError.googleStatus(status)
        }
        guard let routes = json["routes"] as? [[String: Any]],
              let route0 = routes.first,
              let overview = route0["overview_polyline"] as? [String: Any],
              let polyline = overview["points"] as? String,
              let legs = route0["legs"] as? [[String: Any]],
              let leg0 = legs.first,
              let distanceObj = leg0["distance"] as? [String: Any],
              let durationObj = leg0["duration"] as? [String: Any],
              let totalMeters = distanceObj["value"] as? Double ?? (distanceObj["value"] as? Int).map(Double.init),
              let durationSec = durationObj["value"] as? Double ?? (durationObj["value"] as? Int).map(Double.init) else {
            throw RouteError.noRouteFound
        }
        let path = decodePolyline(polyline)
        let waypoints = createMicroWaypoints(from: path, intervalMeters: microWaypointIntervalMeters)
        guard !waypoints.isEmpty else { throw RouteError.noRouteFound }
        return NavigationRoute(
            waypoints: waypoints,
            totalDistanceMeters: totalMeters,
            estimatedDurationSeconds: durationSec,
            destinationName: destinationName
        )
    }

    private func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
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

    /// Densify the polyline and build turn-by-turn style micro-waypoints.
    private func createMicroWaypoints(from path: [CLLocationCoordinate2D], intervalMeters: Double) -> [RouteWaypoint] {
        guard path.count >= 2 else {
            if let single = path.first {
                return [RouteWaypoint(coordinate: single, bearingToNext: 0, distanceToNext: 0, instruction: "You have arrived")]
            }
            return []
        }
        let coords = resamplePolyline(path, every: intervalMeters)
        guard !coords.isEmpty else { return [] }
        var waypoints: [RouteWaypoint] = []
        for i in 0..<coords.count {
            let c = coords[i]
            if i < coords.count - 1 {
                let next = coords[i + 1]
                let bear = bearingBetween(c, next)
                let dist = distanceMeters(c, next)
                let instruction = i == 0
                    ? "Head \(compassDirection(bear))"
                    : "Continue \(compassDirection(bear))"
                waypoints.append(RouteWaypoint(coordinate: c, bearingToNext: bear, distanceToNext: dist, instruction: instruction))
            } else {
                waypoints.append(RouteWaypoint(coordinate: c, bearingToNext: 0, distanceToNext: 0, instruction: "You have arrived"))
            }
        }
        return waypoints
    }

    private func resamplePolyline(_ path: [CLLocationCoordinate2D], every step: Double) -> [CLLocationCoordinate2D] {
        guard path.count >= 2 else { return path }
        var out: [CLLocationCoordinate2D] = []
        out.append(path[0])
        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]
            let len = distanceMeters(a, b)
            guard len > 0.001 else { continue }
            var d = step
            while d < len - 0.001 {
                let t = d / len
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                d += step
            }
        }
        if let last = path.last {
            if let prev = out.last, distanceMeters(prev, last) > 2 {
                out.append(last)
            } else if out.isEmpty {
                out.append(last)
            } else if distanceMeters(out[out.count - 1], last) > 0.5 {
                out.append(last)
            }
        }
        return out
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func bearingBetween(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let brng = atan2(y, x) * 180 / .pi
        return normalizeBearing(brng)
    }

    private func normalizeBearing(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private func compassDirection(_ bearingDegrees: Double) -> String {
        let directions = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let idx = Int((bearingDegrees + 22.5) / 45.0) % 8
        return directions[idx]
    }
}
