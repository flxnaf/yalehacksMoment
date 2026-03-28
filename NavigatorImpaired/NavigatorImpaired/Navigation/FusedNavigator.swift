import Foundation

/// Closed set for `command` / voice: turn_left, turn_right, proceed, stop, arrived, obstacle, reroute (reserved).
struct NavigationGuidance {
    let command: String
    let relativeBearing: Double
    let distanceToWaypoint: Double
    let urgency: Double
    let voiceInstruction: String
    let beaconAzimuth: Double
}

/// Fuses GPS bearing, route geometry, and obstacle analysis into guidance + throttled speech.
final class FusedNavigator {
    private var lastSpokenDistance: Double = .infinity
    private var lastSpokenBearing: Double = 0

    func fuse(
        userHeading: Double,
        targetBearing: Double,
        distanceToWaypoint: Double,
        waypointInstruction: String,
        obstacles: ObstacleAnalysis,
        destinationName: String
    ) -> NavigationGuidance {
        var relative = targetBearing - userHeading
        while relative > 180 { relative -= 360 }
        while relative < -180 { relative += 360 }

        let absRel = abs(relative)
        let command: String
        if obstacles.recommendedDirection == "stop" || obstacles.urgency > 0.85 {
            command = "stop"
        } else if absRel > 45 {
            command = relative > 0 ? "turn_right" : "turn_left"
        } else {
            command = "proceed"
        }

        var voice = waypointInstruction
        if obstacles.urgency > 0.4 {
            switch obstacles.recommendedDirection {
            case "left": voice += ". Obstacle ahead, step left"
            case "right": voice += ". Obstacle ahead, step right"
            case "stop": voice += ". Stop, obstacle very close"
            default: break
            }
        }

        let beacon = relative

        return NavigationGuidance(
            command: command,
            relativeBearing: relative,
            distanceToWaypoint: distanceToWaypoint,
            urgency: obstacles.urgency,
            voiceInstruction: voice,
            beaconAzimuth: beacon
        )
    }

    /// Call once after the route intro TTS so the first tick does not immediately repeat guidance.
    func seedInitialState(_ guidance: NavigationGuidance) {
        lastSpokenDistance = guidance.distanceToWaypoint
        lastSpokenBearing = guidance.relativeBearing
    }

    func shouldSpeak(guidance: NavigationGuidance) -> Bool {
        let distDelta = abs(guidance.distanceToWaypoint - lastSpokenDistance)
        let bearDelta = abs(guidance.relativeBearing - lastSpokenBearing)
        if distDelta > 5.0 || bearDelta > 30 {
            return true
        }
        return false
    }

    func didSpeak(guidance: NavigationGuidance) {
        lastSpokenDistance = guidance.distanceToWaypoint
        lastSpokenBearing = guidance.relativeBearing
    }

    func resetSpeechState() {
        lastSpokenDistance = .infinity
        lastSpokenBearing = 0
    }
}
