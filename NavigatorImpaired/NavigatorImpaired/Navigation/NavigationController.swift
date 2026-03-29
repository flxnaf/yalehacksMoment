import CoreLocation
import Foundation

enum NavigationError: LocalizedError {
    case noGPSFix
    case destinationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noGPSFix:
            return "No GPS fix yet. Move outdoors and try again."
        case .destinationNotFound(let q):
            return "Could not find \(q)."
        }
    }
}

@MainActor
final class NavigationController: ObservableObject {
    /// Proximity to advance ping / speak maneuver (meters).
    static let arrivalRadiusMeters: Double = 8
    static let rerouteDistanceMeters: Double = 25
    static let rerouteCooldownSeconds: TimeInterval = 30
    /// Above this horizontal accuracy, treat GPS as degraded for advancement / reroute heuristics.
    static let maxHorizontalAccuracyMeters: Double = 50
    static let vlmHandoffDistanceMeters: Double = 40
    static let ttsDebounceSeconds: TimeInterval = 4
    /// Minimum time between routine turn-by-turn updates (same ping). Reduces Gemini / TTS queue spam from GPS jitter.
    static let minSecondsBetweenRoutineGuidance: TimeInterval = 14

    private let locationManager: LocationManager
    private let routeService: RouteService
    private let obstacleAnalyzer = ObstacleAnalyzer()
    private let fusedNavigator = FusedNavigator()

    private var route: NavigationRoute?
    private var navTimer: Timer?
    private var currentObstacles: ObstacleAnalysis = .clear
    private var firstGuidanceSeeded = false
    private var destinationCoordinate: CLLocationCoordinate2D?
    private var lastRerouteAt: Date?
    private var lastKnownGoodTTS: String?
    private var lastDegradedSpeechAt: Date?
    private var vlmHandoffSent = false
    private var advancingWaypointAfterSpeech = false
    private var lastRoutineGuidanceSpokenAt: Date?
    private var routineCooldownWaypointIndex: Int = -1

    /// Optional Gemini Live bridge for one-shot navigation context (`clientContent`).
    weak var geminiSessionForHandoff: GeminiSessionViewModel?

    /// Applied by `StreamSessionViewModel` to shrine ping gain (duck near waypoint).
    @Published private(set) var navigationPingVolumeScale: Float = 1.0

    @Published private(set) var latestObstacleAnalysis: ObstacleAnalysis = .clear

    @Published var isNavigating = false
    @Published var currentWaypointIndex = 0
    @Published var totalWaypoints = 0
    @Published var distanceToWaypoint: Double = 0
    @Published var relativeBearing: Double = 0
    @Published var currentGuidance: NavigationGuidance?
    @Published var destinationName: String = ""
    @Published var hasArrived = false

    /// Debug map / UI: dense path.
    @Published private(set) var allCheckpoints: [RouteCheckpoint] = []
    /// Debug map / UI: sparse ping targets (same order as navigation indices).
    @Published private(set) var routePingTargets: [PingTarget] = []

    /// `(utterance, optional completion)` — completion runs after TTS finishes when using `NavSpeechCoordinator`.
    var onSpeakInstruction: ((String, (() -> Void)?) -> Void)?

    init(locationManager: LocationManager = .shared, googleMapsAPIKey: String) {
        self.locationManager = locationManager
        self.routeService = RouteService(apiKey: googleMapsAPIKey)
    }

    /// Spoken once when a route is ready: destination, ETA, and number of guidance stops (pings).
    private static func startNavigationBriefing(for route: NavigationRoute) -> String {
        let name = route.destinationName
        let time = spokenWalkingDuration(seconds: route.estimatedDurationSeconds)
        let n = route.pingTargets.count
        let stopPhrase: String
        switch n {
        case 0: stopPhrase = "no guidance stops"
        case 1: stopPhrase = "1 guidance stop"
        default: stopPhrase = "\(n) guidance stops"
        }
        return "Starting navigation to \(name). About \(time) on foot, \(stopPhrase)."
    }

    private static func spokenWalkingDuration(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 45 {
            return "less than a minute"
        }
        let minutes = (s + 30) / 60
        if minutes < 60 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 {
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        if h == 1 {
            return m == 1 ? "1 hour and 1 minute" : "1 hour and \(m) minutes"
        }
        return m == 1 ? "\(h) hours and 1 minute" : "\(h) hours and \(m) minutes"
    }

    @discardableResult
    func updatePerception(
        depthMap: [Float],
        width: Int,
        height: Int,
        persons: [PersonDetection],
        sceneLabel: String?
    ) -> ObstacleAnalysis {
        currentObstacles = obstacleAnalyzer.analyze(
            depthData: depthMap,
            width: width,
            height: height,
            persons: persons,
            sceneLabel: sceneLabel
        )
        latestObstacleAnalysis = currentObstacles
        return currentObstacles
    }

    func startNavigation(to destination: String) async throws {
        guard let origin = locationManager.currentCoordinate else {
            speak("Waiting for GPS signal.", completion: nil)
            throw NavigationError.noGPSFix
        }
        do {
            let resolved = try await routeService.resolveDestination(destination, near: origin)
            let displayName = resolved.name ?? destination
            let navRoute = try await routeService.fetchRoute(
                from: origin,
                to: resolved.coordinate,
                destinationName: displayName
            )
            fusedNavigator.resetSpeechState()
            firstGuidanceSeeded = false
            lastRoutineGuidanceSpokenAt = nil
            routineCooldownWaypointIndex = -1
            route = navRoute
            destinationCoordinate = resolved.coordinate
            destinationName = navRoute.destinationName
            allCheckpoints = navRoute.checkpoints
            routePingTargets = navRoute.pingTargets
            totalWaypoints = navRoute.pingTargets.count
            currentWaypointIndex = 0
            hasArrived = false
            lastRerouteAt = nil
            vlmHandoffSent = false
            advancingWaypointAfterSpeech = false
            isNavigating = true
            navigationPingVolumeScale = 1
            locationManager.setNavigationHighAccuracyEnabled(true)
            speak(Self.startNavigationBriefing(for: navRoute), completion: nil)
            startNavigationLoop()
        } catch let err as RouteError {
            NSLog("[NavigationController] Route error: %@", err.localizedDescription)
            speak("Could not start navigation. Check your internet connection and API key.", completion: nil)
            throw err
        } catch {
            NSLog("[NavigationController] Unexpected error: %@", error.localizedDescription)
            speak("Could not start navigation. Check your internet connection and API key.", completion: nil)
            throw error
        }
    }

    func stopNavigation() {
        navTimer?.invalidate()
        navTimer = nil
        locationManager.setNavigationHighAccuracyEnabled(false)
        guard isNavigating || route != nil else { return }
        route = nil
        isNavigating = false
        currentWaypointIndex = 0
        totalWaypoints = 0
        distanceToWaypoint = 0
        relativeBearing = 0
        currentGuidance = nil
        hasArrived = false
        firstGuidanceSeeded = false
        allCheckpoints = []
        routePingTargets = []
        destinationCoordinate = nil
        navigationPingVolumeScale = 1
        advancingWaypointAfterSpeech = false
        lastRoutineGuidanceSpokenAt = nil
        routineCooldownWaypointIndex = -1
        fusedNavigator.resetSpeechState()
        speak("Navigation stopped.", completion: nil)
    }

    private func startNavigationLoop() {
        navTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.navigationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        navTimer = timer
    }

    private func navigationTick() {
        guard isNavigating, let navRoute = route else { return }
        if hasArrived { return }
        let targets = navRoute.pingTargets
        guard !targets.isEmpty, currentWaypointIndex < targets.count else { return }

        guard let userCoord = locationManager.currentCoordinate else { return }
        let userLocation = locationManager.currentLocation
            ?? CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)

        let accuracy = userLocation.horizontalAccuracy
        let gpsDegraded = accuracy > 0 && accuracy > Self.maxHorizontalAccuracyMeters

        maybeTriggerReroute(userLocation: userLocation, navRoute: navRoute, gpsDegraded: gpsDegraded)

        let target = targets[currentWaypointIndex]
        let targetCoord = target.coordinate
        let dist = userLocation.distance(from: CLLocation(latitude: targetCoord.latitude, longitude: targetCoord.longitude))
        distanceToWaypoint = dist

        let userHeading = locationManager.currentHeading
        let bearingToTarget = bearing(from: userCoord, to: targetCoord)
        let guidance = fusedNavigator.fuse(
            userHeading: userHeading,
            targetBearing: bearingToTarget,
            distanceToWaypoint: dist,
            waypointInstruction: target.instruction,
            obstacles: currentObstacles,
            destinationName: navRoute.destinationName
        )
        relativeBearing = guidance.relativeBearing
        currentGuidance = guidance

        if currentWaypointIndex != routineCooldownWaypointIndex {
            routineCooldownWaypointIndex = currentWaypointIndex
            lastRoutineGuidanceSpokenAt = nil
        }

        if !firstGuidanceSeeded {
            firstGuidanceSeeded = true
            fusedNavigator.seedInitialState(guidance)
            return
        }

        maybeVLMHandoffIfNearFinal(distance: dist, target: target, navRoute: navRoute)

        let withinArrival = dist < Self.arrivalRadiusMeters
        navigationPingVolumeScale = (withinArrival && !target.isFinalDestination) ? 0.25 : 1.0

        if gpsDegraded {
            speakIfNotDebounced("GPS accuracy is low. Move to a clearer area.")
            return
        }

        let isLast = currentWaypointIndex >= targets.count - 1
        if isLast && withinArrival {
            finishArrival()
            return
        }

        if !isLast && withinArrival {
            if advancingWaypointAfterSpeech { return }
            advancingWaypointAfterSpeech = true
            let g = guidance
            speak(g.voiceInstruction) { [weak self] in
                guard let self else { return }
                self.currentWaypointIndex += 1
                self.advancingWaypointAfterSpeech = false
                self.fusedNavigator.didSpeak(guidance: g)
            }
            return
        }

        if fusedNavigator.shouldSpeak(guidance: guidance) {
            let now = Date()
            if let last = lastRoutineGuidanceSpokenAt,
               now.timeIntervalSince(last) < Self.minSecondsBetweenRoutineGuidance {
                return
            }
            speak(guidance.voiceInstruction, completion: nil)
            lastRoutineGuidanceSpokenAt = now
            fusedNavigator.didSpeak(guidance: guidance)
        }
    }

    private func maybeVLMHandoffIfNearFinal(distance: Double, target: PingTarget, navRoute: NavigationRoute) {
        guard target.isFinalDestination, !vlmHandoffSent else { return }
        guard distance < Self.vlmHandoffDistanceMeters else { return }
        vlmHandoffSent = true
        let msg = "Navigation: approaching final destination \(navRoute.destinationName). User may need visual assistance for the last meters."
        geminiSessionForHandoff?.sendNavigationHandoff(msg)
    }

    private func maybeTriggerReroute(userLocation: CLLocation, navRoute: NavigationRoute, gpsDegraded: Bool) {
        guard !gpsDegraded else { return }
        guard let origin = locationManager.currentCoordinate,
              let destCoord = destinationCoordinate else { return }
        let off = distanceToRoutePolylineMeters(userLocation.coordinate, checkpoints: navRoute.checkpoints)
        guard off > Self.rerouteDistanceMeters else { return }
        let now = Date()
        if let last = lastRerouteAt, now.timeIntervalSince(last) < Self.rerouteCooldownSeconds {
            return
        }
        lastRerouteAt = now
        Task { await performReroute(from: origin, to: destCoord, name: navRoute.destinationName) }
    }

    private func distanceToRoutePolylineMeters(_ coord: CLLocationCoordinate2D, checkpoints: [RouteCheckpoint]) -> Double {
        guard checkpoints.count >= 2 else { return 0 }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(checkpoints.count - 1) {
            let a = checkpoints[i].coordinate
            let b = checkpoints[i + 1].coordinate
            let d = distanceToSegmentMeters(point: coord, a: a, b: b)
            best = min(best, d)
        }
        return best
    }

    /// Distance from `point` to segment AB (meters).
    private func distanceToSegmentMeters(point: CLLocationCoordinate2D, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Double {
        let px = point.latitude
        let py = point.longitude
        let ax = a.latitude
        let ay = a.longitude
        let bx = b.latitude
        let by = b.longitude
        let abx = bx - ax
        let aby = by - ay
        let apx = px - ax
        let apy = py - ay
        let ab2 = abx * abx + aby * aby
        guard ab2 > 1e-18 else {
            return CLLocation(latitude: px, longitude: py).distance(from: CLLocation(latitude: ax, longitude: ay))
        }
        var t = (apx * abx + apy * aby) / ab2
        t = min(1, max(0, t))
        let cx = ax + t * abx
        let cy = ay + t * aby
        return CLLocation(latitude: px, longitude: py).distance(from: CLLocation(latitude: cx, longitude: cy))
    }

    private func performReroute(from origin: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D, name: String) async {
        do {
            let newRoute = try await routeService.fetchRoute(from: origin, to: dest, destinationName: name)
            route = newRoute
            allCheckpoints = newRoute.checkpoints
            routePingTargets = newRoute.pingTargets
            totalWaypoints = newRoute.pingTargets.count
            currentWaypointIndex = min(currentWaypointIndex, max(0, newRoute.pingTargets.count - 1))
            fusedNavigator.resetSpeechState()
            firstGuidanceSeeded = false
            lastRoutineGuidanceSpokenAt = nil
            routineCooldownWaypointIndex = currentWaypointIndex
            speak("Rerouting.", completion: nil)
        } catch {
            speak("Reroute failed. Continuing with previous path.", completion: nil)
        }
    }

    private func speak(_ text: String, completion: (() -> Void)?) {
        let plain = Self.plainTextForNavigationSpeech(text)
        lastKnownGoodTTS = plain
        onSpeakInstruction?(plain, completion)
    }

    /// Strip HTML from Directions `html_instructions` for TTS (Gemini and AVSpeech).
    private static func plainTextForNavigationSpeech(_ raw: String) -> String {
        var s = raw
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        }
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        if let regex = try? NSRegularExpression(pattern: "[ \t\n]+", options: []) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakIfNotDebounced(_ text: String) {
        let now = Date()
        if let last = lastDegradedSpeechAt, now.timeIntervalSince(last) < Self.ttsDebounceSeconds {
            return
        }
        lastDegradedSpeechAt = now
        speak(text, completion: nil)
    }

    private func finishArrival() {
        hasArrived = true
        speak("You have arrived at \(destinationName)") { [weak self] in
            self?.stopNavigationAfterArrival()
        }
    }

    private func stopNavigationAfterArrival() {
        navTimer?.invalidate()
        navTimer = nil
        route = nil
        isNavigating = false
        currentWaypointIndex = 0
        totalWaypoints = 0
        distanceToWaypoint = 0
        relativeBearing = 0
        currentGuidance = nil
        firstGuidanceSeeded = false
        allCheckpoints = []
        routePingTargets = []
        destinationCoordinate = nil
        navigationPingVolumeScale = 1
        locationManager.setNavigationHighAccuracyEnabled(false)
        fusedNavigator.resetSpeechState()
    }

    private func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let brng = atan2(y, x) * 180 / .pi
        var d = brng.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }
}
