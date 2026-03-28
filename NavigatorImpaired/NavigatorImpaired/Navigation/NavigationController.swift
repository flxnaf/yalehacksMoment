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
    private let locationManager: LocationManager
    private let routeService: RouteService
    private let obstacleAnalyzer = ObstacleAnalyzer()
    private let fusedNavigator = FusedNavigator()

    private var route: NavigationRoute?
    private var navTimer: Timer?
    private var currentObstacles: ObstacleAnalysis = .clear
    private var firstGuidanceSeeded = false

    /// Latest obstacle summary from the most recent `updatePerception` call (same frame as depth).
    @Published private(set) var latestObstacleAnalysis: ObstacleAnalysis = .clear

    @Published var isNavigating = false
    @Published var currentWaypointIndex = 0
    @Published var totalWaypoints = 0
    @Published var distanceToWaypoint: Double = 0
    @Published var relativeBearing: Double = 0
    @Published var currentGuidance: NavigationGuidance?
    @Published var destinationName: String = ""
    @Published var hasArrived = false

    var onSpeakInstruction: ((String) -> Void)?

    init(locationManager: LocationManager = .shared, googleMapsAPIKey: String) {
        self.locationManager = locationManager
        self.routeService = RouteService(apiKey: googleMapsAPIKey)
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
            onSpeakInstruction?("Waiting for GPS signal.")
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
            route = navRoute
            destinationName = navRoute.destinationName
            totalWaypoints = navRoute.waypoints.count
            currentWaypointIndex = 0
            hasArrived = false
            isNavigating = true
            onSpeakInstruction?("Starting navigation to \(navRoute.destinationName)")
            startNavigationLoop()
        } catch let err as RouteError {
            NSLog("[NavigationController] Route error: %@", err.localizedDescription)
            onSpeakInstruction?("Could not start navigation. Check your internet connection and API key.")
            throw err
        } catch {
            NSLog("[NavigationController] Unexpected error: %@", error.localizedDescription)
            onSpeakInstruction?("Could not start navigation. Check your internet connection and API key.")
            throw error
        }
    }

    func stopNavigation() {
        navTimer?.invalidate()
        navTimer = nil
        guard isNavigating else { return }
        route = nil
        isNavigating = false
        currentWaypointIndex = 0
        totalWaypoints = 0
        distanceToWaypoint = 0
        relativeBearing = 0
        currentGuidance = nil
        hasArrived = false
        firstGuidanceSeeded = false
        fusedNavigator.resetSpeechState()
        onSpeakInstruction?("Navigation stopped.")
    }

    private func startNavigationLoop() {
        navTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.navigationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        navTimer = timer
    }

    private func navigationTick() {
        guard isNavigating, let navRoute = route else { return }
        guard let userCoord = locationManager.currentCoordinate else { return }
        let waypoints = navRoute.waypoints
        guard !waypoints.isEmpty, currentWaypointIndex < waypoints.count else { return }

        let userLocation = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let targetWP = waypoints[currentWaypointIndex]
        let targetCoord = targetWP.coordinate
        let dist = userLocation.distance(from: CLLocation(latitude: targetCoord.latitude, longitude: targetCoord.longitude))

        distanceToWaypoint = dist

        let userHeading = locationManager.currentHeading
        let bearingToTarget = bearing(from: userCoord, to: targetCoord)
        let guidance = fusedNavigator.fuse(
            userHeading: userHeading,
            targetBearing: bearingToTarget,
            distanceToWaypoint: dist,
            waypointInstruction: targetWP.instruction,
            obstacles: currentObstacles,
            destinationName: navRoute.destinationName
        )
        relativeBearing = guidance.relativeBearing
        currentGuidance = guidance

        if !firstGuidanceSeeded {
            firstGuidanceSeeded = true
            fusedNavigator.seedInitialState(guidance)
            return
        }

        let isLast = currentWaypointIndex >= waypoints.count - 1
        if isLast && dist < 5.0 {
            finishArrival()
            return
        }

        if !isLast && dist < 8.0 {
            currentWaypointIndex += 1
            let newWP = waypoints[currentWaypointIndex]
            let newCoord = newWP.coordinate
            let newDist = userLocation.distance(from: CLLocation(latitude: newCoord.latitude, longitude: newCoord.longitude))
            let newGuidance = fusedNavigator.fuse(
                userHeading: userHeading,
                targetBearing: bearing(from: userCoord, to: newCoord),
                distanceToWaypoint: newDist,
                waypointInstruction: newWP.instruction,
                obstacles: currentObstacles,
                destinationName: navRoute.destinationName
            )
            distanceToWaypoint = newDist
            relativeBearing = newGuidance.relativeBearing
            currentGuidance = newGuidance
            onSpeakInstruction?(newGuidance.voiceInstruction)
            fusedNavigator.didSpeak(guidance: newGuidance)
            return
        }

        if fusedNavigator.shouldSpeak(guidance: guidance) {
            onSpeakInstruction?(guidance.voiceInstruction)
            fusedNavigator.didSpeak(guidance: guidance)
        }
    }

    private func finishArrival() {
        hasArrived = true
        onSpeakInstruction?("You have arrived at \(destinationName)")
        stopNavigationAfterArrival()
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
