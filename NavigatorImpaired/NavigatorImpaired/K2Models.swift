import Foundation

// MARK: - Hazard (Use Case A)

struct RawObstacle: Sendable {
  let label: String
  let distanceMeters: Double
  let direction: String
  let zone: String
  let isDynamic: Bool
}

struct HazardDecision: Sendable {
  let primaryHazard: RawObstacle?
  let spokenText: String
  let shouldAnnounce: Bool
}

// MARK: - Navigation replan (Use Case B)

struct NavigationReplanContext: Sendable {
  let destination: String
  let completedSteps: [String]
  let currentStep: String
  let currentStepDistanceRemaining: Int
  let distanceOffPath: Double
  let headingDegrees: Double
  let expectedHeadingDegrees: Double
  let secondsOnCurrentStep: Int
  let gpsAccuracyMeters: Double
}

struct NavigationReplanDecision: Sendable {
  enum Action: Sendable {
    case continueCurrentStep(guidance: String)
    case correctCourse(instruction: String)
    case reroute
    case waitForGPS
  }

  let action: Action
  let spokenText: String
}

// MARK: - Fall / guardian SMS (Use Case C)

struct FallContextInput: Sendable {
  let timestamp: String
  let locationDescription: String
  let sceneDescriptions: [String]
  let wasNavigating: Bool
  let navigationDestination: String?
  let recentHazardsDetected: [String]
  let fallConfidence: Float
}

struct FallContextOutput: Sendable {
  let refinedSMSBody: String
  let contextSummary: String
}
