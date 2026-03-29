import CoreLocation
import Foundation

/// Picks sparse ping targets from dense checkpoints using turn angle threshold (default 45°).
final class TurnPointExtractor {
    private let turnThresholdDegrees: Double

    init(turnThresholdDegrees: Double = 45) {
        self.turnThresholdDegrees = turnThresholdDegrees
    }

    func extract(checkpoints: [RouteCheckpoint]) -> [PingTarget] {
        guard let first = checkpoints.first else { return [] }
        if checkpoints.count == 1 {
            return [
                PingTarget(
                    coordinate: first.coordinate,
                    instruction: first.stepInstruction.isEmpty ? "You have arrived" : first.stepInstruction,
                    isFinalDestination: true,
                    bearingAfterTurnDegrees: first.bearingToNextDegrees
                )
            ]
        }

        var targets: [PingTarget] = []

        let startInstr = first.stepInstruction.isEmpty ? "Begin route" : first.stepInstruction
        targets.append(
            PingTarget(
                coordinate: first.coordinate,
                instruction: startInstr,
                isFinalDestination: false,
                bearingAfterTurnDegrees: first.bearingToNextDegrees
            )
        )

        for i in 1..<(checkpoints.count - 1) {
            let bearIn = RouteGeometry.bearingDegrees(
                from: checkpoints[i - 1].coordinate,
                to: checkpoints[i].coordinate
            )
            let bearOut = RouteGeometry.bearingDegrees(
                from: checkpoints[i].coordinate,
                to: checkpoints[i + 1].coordinate
            )
            let delta = RouteGeometry.angleDifferenceDegrees(bearIn, bearOut)
            guard delta >= turnThresholdDegrees else { continue }

            let instr = checkpoints[i].stepInstruction
            targets.append(
                PingTarget(
                    coordinate: checkpoints[i].coordinate,
                    instruction: instr.isEmpty ? "Turn" : instr,
                    isFinalDestination: false,
                    bearingAfterTurnDegrees: bearOut
                )
            )
        }

        let last = checkpoints[checkpoints.count - 1]
        targets.append(
            PingTarget(
                coordinate: last.coordinate,
                instruction: "You have arrived",
                isFinalDestination: true,
                bearingAfterTurnDegrees: last.bearingToNextDegrees
            )
        )

        return targets
    }
}
