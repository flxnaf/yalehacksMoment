import Foundation
import CoreMotion

// MARK: - SurfaceSnapshot

/// A snapshot of a tracked surface zone at the current moment.
struct SurfaceSnapshot {
    let zone: DepthZone
    /// Slow-EMA depth: 0 = far, 1 = very close. Persists for several seconds after the surface leaves frame.
    let depth: Float
    /// Rate of depth change in depth-units / second. Positive = obstacle approaching the user.
    let velocity: Float
    /// Combined urgency score. Higher = should be louder / faster.
    let priority: Float
}

// MARK: - SurfaceMemory

/// Tracks surfaces across frames using an **attack-release envelope** per zone:
///
///   Attack  (obstacle appears / gets closer): fast blend — reaches 90% of true value in ~0.3 s
///   Release (obstacle recedes / leaves frame): slow decay  — holds for ~3 s before going silent
///
/// This means a chair in view registers almost instantly but lingers in memory
/// long enough to guide the user around it.
///
/// Priority = heldDepth  +  0.45 × max(0, approachVelocity)
@MainActor
final class SurfaceMemory {

    // MARK: - Depth state

    private var held:      [DepthZone: Float] = [:]
    private var fastEMA:   [DepthZone: Float] = [:]
    private var velSmooth: [DepthZone: Float] = [:]
    private var lastUpdate: Date = .now

    // MARK: - Step tracking

    private let pedometer = CMPedometer()
    private var totalSteps: Int = 0
    /// Total steps at the frame when each zone last started being approached.
    private var stepsAtApproachStart: [DepthZone: Int] = [:]
    /// Whether each zone was in approach (velocity > 0) last frame.
    private var wasApproaching: [DepthZone: Bool] = [:]

    // MARK: - Tuning

    private let attackAlpha: Float  = 0.55
    private let releaseMul:  Float  = 0.93
    private let fastAlpha:   Float  = 0.50
    private let velAlpha:    Float  = 0.30
    private let presenceThreshold: Float = 0.12
    private let velocityWeight: Float    = 0.50
    /// Each confirmed approach step adds this to priority (capped at `maxStepBonus`).
    private let stepBonusPerStep: Float  = 0.07
    private let maxStepBonus: Float      = 0.28

    // MARK: - Init

    init() { startPedometer() }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let steps = data?.numberOfSteps.intValue else { return }
            Task { @MainActor [weak self] in self?.totalSteps = steps }
        }
    }

    // MARK: - Public API

    func update(rawZones: [DepthZone: Float]) -> [SurfaceSnapshot] {
        let now = Date()
        let dt  = Float(now.timeIntervalSince(lastUpdate))
        lastUpdate = now

        for zone in DepthZone.allCases {
            let raw      = rawZones[zone] ?? 0
            let prevHeld = held[zone]    ?? raw
            let prevFast = fastEMA[zone] ?? raw

            if raw >= prevHeld {
                held[zone] = attackAlpha * raw + (1 - attackAlpha) * prevHeld
            } else {
                held[zone] = releaseMul * prevHeld
            }
            fastEMA[zone] = fastAlpha * raw + (1 - fastAlpha) * prevFast

            if dt > 0.004 {
                let rawVel = (fastEMA[zone]! - prevFast) / dt
                velSmooth[zone] = velAlpha * rawVel + (1 - velAlpha) * (velSmooth[zone] ?? 0)
            }

            // Step tracking: count steps taken while actively approaching this zone.
            let vel = velSmooth[zone] ?? 0
            let approachingNow = vel > 0.04
            if approachingNow && !(wasApproaching[zone] ?? false) {
                // Approach just started — record current step count as baseline.
                stepsAtApproachStart[zone] = totalSteps
            } else if !approachingNow {
                // No longer approaching — clear the baseline.
                stepsAtApproachStart.removeValue(forKey: zone)
            }
            wasApproaching[zone] = approachingNow
        }

        var out: [SurfaceSnapshot] = []
        for zone in DepthZone.allCases {
            let d = held[zone] ?? 0
            guard d > presenceThreshold else { continue }
            let v = velSmooth[zone] ?? 0

            // Steps taken while walking toward this obstacle boost urgency.
            let approachSteps = stepsAtApproachStart[zone].map { totalSteps - $0 } ?? 0
            let stepBonus = min(maxStepBonus, Float(max(0, approachSteps)) * stepBonusPerStep)

            let priority = d + velocityWeight * max(0, v) + stepBonus
            out.append(SurfaceSnapshot(zone: zone, depth: d, velocity: v, priority: priority))
        }
        return out.sorted { $0.priority > $1.priority }
    }

    /// Read-only held depth for a zone — used by the beacon to suppress
    /// paths that overlap recent obstacle memory.
    func heldDepth(for zone: DepthZone) -> Float { held[zone] ?? 0 }

    func reset() {
        held.removeAll()
        fastEMA.removeAll()
        velSmooth.removeAll()
        stepsAtApproachStart.removeAll()
        wasApproaching.removeAll()
        lastUpdate = .now
    }
}
