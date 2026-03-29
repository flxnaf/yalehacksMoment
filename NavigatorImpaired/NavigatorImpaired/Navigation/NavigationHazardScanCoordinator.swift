import Foundation
import SwiftUI
import UIKit

/// Periodic Gemini REST vision scans while walking navigation is active.
@MainActor
final class NavigationHazardScanCoordinator: ObservableObject {
  private weak var streamVM: StreamSessionViewModel?
  private weak var nav: NavigationController?
  private weak var geminiVM: GeminiSessionViewModel?
  private weak var navSpeech: NavSpeechCoordinator?

  private let client = GeminiNavigationHazardClient()
  private var timer: Timer?
  private var inFlight = false
  private var chainingTimers = false

  private var lastSpokenKey: String?
  private var lastSpokenAt: Date?

  func attach(
    stream: StreamSessionViewModel,
    navigation: NavigationController,
    gemini: GeminiSessionViewModel,
    navSpeech: NavSpeechCoordinator
  ) {
    streamVM = stream
    nav = navigation
    geminiVM = gemini
    self.navSpeech = navSpeech
    start()
  }

  func start() {
    guard !chainingTimers else { return }
    chainingTimers = true
    scheduleNextFire()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    chainingTimers = false
    inFlight = false
  }

  private func scheduleNextFire() {
    timer?.invalidate()
    let interval = max(1.5, SettingsManager.shared.navigationHazardScanIntervalSeconds)
    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor in
        await self?.tick()
        guard let self, self.chainingTimers else { return }
        self.scheduleNextFire()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func tick() async {
    guard SettingsManager.shared.navigationHazardScanEnabled else { return }
    guard GeminiConfig.isConfigured else { return }
    guard let nav, nav.isNavigating else { return }
    guard let streamVM, let image = streamVM.currentVideoFrame else { return }
    guard let geminiVM else { return }
    guard !inFlight else { return }

    inFlight = true
    defer { inFlight = false }

    let context = Self.buildNavigationContext(nav: nav)
    do {
      let decision = try await client.analyze(image: image, navigationContext: context)
      guard let sanitized = decision.sanitizedForSpeech() else { return }

      let key = Self.normalizeKey(sanitized.spoken)
      if let prev = lastSpokenKey, let t = lastSpokenAt, prev == key, Date().timeIntervalSince(t) < 8 {
        return
      }

      lastSpokenKey = key
      lastSpokenAt = Date()

      let line = sanitized.spoken
      // Hazard lines: use AVSpeech when Gemini Live is busy with queued nav TTS so scans are not starved.
      if geminiVM.shouldUseGeminiForNavigationVoice, !geminiVM.isNavigationVoiceBusy {
        geminiVM.speakNavigationForUser(line, completion: nil)
      } else if let navSpeech {
        navSpeech.speak(line, completion: nil)
      }
    } catch {
      NSLog("[NavigationHazardScan] \(error.localizedDescription)")
    }
  }

  private static func normalizeKey(_ s: String) -> String {
    let lower = s.lowercased()
    let cleaned = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return cleaned.joined(separator: " ")
  }

  private static func buildNavigationContext(nav: NavigationController) -> String {
    var lines: [String] = []
    if !nav.destinationName.isEmpty {
      lines.append("Destination: \(nav.destinationName)")
    }
    lines.append("Guidance stop \(nav.currentWaypointIndex + 1) of \(max(nav.totalWaypoints, 1))")
    lines.append(String(format: "Distance to next guidance point: %.0f meters", nav.distanceToWaypoint))
    lines.append(String(format: "Relative bearing to next stop: %.0f degrees", nav.relativeBearing))
    if nav.currentWaypointIndex < nav.routePingTargets.count {
      let step = nav.routePingTargets[nav.currentWaypointIndex].instruction
      lines.append("Current route maneuver (from map, no camera): \(step)")
    }
    lines.append(
      "Do not parrot generic obstacle wording. Use the image to name specific things (car, door, person, pole, curb, etc.)."
    )
    lines.append(
      "Egocentric position must distinguish forward path vs sides: use ahead / center / in front when the hazard is in the forward field of view, not only left or right."
    )
    let o = nav.latestObstacleAnalysis
    lines.append(
      String(
        format: "On-device depth summary: urgency %.2f, suggested direction: %@",
        o.urgency,
        o.recommendedDirection
      )
    )
    let speed = LocationManager.shared.currentSpeed
    if speed >= 0 {
      lines.append(String(format: "Walking speed (GPS): %.2f m/s", speed))
      if speed < 0.35 {
        lines.append("User may be stationary or moving slowly—prioritize hazards directly in front or at feet.")
      }
    } else {
      lines.append("Walking speed (GPS): unknown")
    }
    if let loc = LocationManager.shared.currentLocation {
      let acc = loc.horizontalAccuracy
      if acc > 0, acc > 25 {
        lines.append(String(format: "GPS accuracy is poor (±%.0f m)—user position on map may be uncertain.", acc))
      }
    }
    return lines.joined(separator: "\n")
  }
}
