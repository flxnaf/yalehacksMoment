import CoreLocation
import Foundation

enum RouteError: LocalizedError {
    case missingAPIKey
    case httpFailure(Int)
    case googleStatus(String)
    case invalidJSON
    case noRouteFound
    case noResults
    case segmentationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Google Maps API key is missing or invalid."
        case .httpFailure(let code): return "HTTP error \(code)."
        case .googleStatus(let s): return "Google API status: \(s)"
        case .invalidJSON: return "Invalid response from Google."
        case .noRouteFound: return "No walking route found."
        case .noResults: return "No places matched your search."
        case .segmentationFailed(let s): return "Could not parse route: \(s)"
        }
    }
}

/// Google Directions + Places Text Search for walking routes.
final class RouteService {
    private let apiKey: String
    private let segmenter = RouteSegmenter()
    private let turnExtractor = TurnPointExtractor()

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

    /// Raw Directions JSON for rerouting or tests.
    func fetchDirectionsData(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> Data {
        guard isAPIKeyValid else { throw RouteError.missingAPIKey }
        guard let url = directionsURL(from: origin, to: destination) else { throw RouteError.invalidJSON }
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
        return data
    }

    /// Fetch a walking route between two coordinates (step-based segmentation + ping targets).
    func fetchRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, destinationName: String) async throws -> NavigationRoute {
        let data = try await fetchDirectionsData(from: origin, to: destination)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [[String: Any]],
              let route0 = routes.first,
              let legs = route0["legs"] as? [[String: Any]],
              let leg0 = legs.first,
              let distanceObj = leg0["distance"] as? [String: Any],
              let durationObj = leg0["duration"] as? [String: Any],
              let totalMeters = distanceObj["value"] as? Double ?? (distanceObj["value"] as? Int).map(Double.init),
              let durationSec = durationObj["value"] as? Double ?? (durationObj["value"] as? Int).map(Double.init) else {
            throw RouteError.noRouteFound
        }

        let segmented: RouteSegmentationResult
        do {
            segmented = try segmenter.segment(directionsResponseData: data)
        } catch {
            let msg = String(describing: error)
            throw RouteError.segmentationFailed(msg)
        }

        let pingTargets = turnExtractor.extract(checkpoints: segmented.checkpoints)
        guard !pingTargets.isEmpty else { throw RouteError.noRouteFound }

        return NavigationRoute(
            checkpoints: segmented.checkpoints,
            pingTargets: pingTargets,
            totalDistanceMeters: totalMeters,
            estimatedDurationSeconds: durationSec,
            destinationName: destinationName
        )
    }

    private func directionsURL(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/directions/json")!
        components.queryItems = [
            URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "mode", value: "walking"),
            URLQueryItem(name: "key", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        return components.url
    }
}
