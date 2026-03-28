import CoreHaptics
import Foundation

/// Continuous haptic feedback driven by obstacle proximity.
///
/// Uses a long-running `CHHapticContinuous` event whose intensity and sharpness
/// are updated in real time via `sendParameters`. Multi-object differentiation
/// is achieved by time-multiplexing: each detected obstacle gets a distinct
/// haptic "slot" so the user can feel separate objects as alternating pulses
/// of varying strength.
///
/// Proximity mapping:
///   - Far  (0.15–0.30): soft buzz, low sharpness
///   - Mid  (0.30–0.60): moderate vibration
///   - Near (0.60–0.85): strong vibration, sharper
///   - Very near (0.85+): full intensity, maximum sharpness
@MainActor
final class NavigationHapticEngine {

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var isRunning = false

    private var surfaces: [SurfaceSnapshot] = []
    /// When set, `tick` uses policy-driven intensity instead of zone surfaces.
    private var policyIntensity: Float?
    private var tickTimer: Timer?

    // Time-multiplexing state
    private var tickCounter = 0
    private let tickRate: TimeInterval = 1.0 / 15.0
    private let ticksPerSlot = 2
    private let gapTicks = 1

    // MARK: - Init

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true
            eng.isAutoShutdownEnabled = false
            eng.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.isRunning = false }
            }
            eng.resetHandler = { [weak self] in
                Task { @MainActor in self?.restart() }
            }
            engine = eng
        } catch {
            print("[Haptics] Engine creation failed: \(error)")
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard let engine, !isRunning else { return }
        do {
            try engine.start()
            isRunning = true
            startContinuousPlayer()
            startTick()
        } catch {
            print("[Haptics] Start failed: \(error)")
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        isRunning = false
        engine?.stop()
    }

    // MARK: - Per-frame update (called from SpatialAudioEngine)

    func update(surfaces: [SurfaceSnapshot]) {
        policyIntensity = nil
        self.surfaces = surfaces
    }

    /// Urgency-driven haptics from `NavigationAudioPolicy`. Clears zone-based mapping until `update(surfaces:)` is used again.
    func updatePolicy(intensity: Float, speechActive: Bool) {
        policyIntensity = speechActive ? 0 : max(0, min(1, intensity))
    }

    // MARK: - Continuous player

    /// Creates a single long continuous haptic event and starts it.
    /// Parameters are modulated in real time via `sendParameters`.
    private func startContinuousPlayer() {
        guard let engine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0),
                ],
                relativeTime: 0,
                duration: 3600
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            player = try engine.makeAdvancedPlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[Haptics] Player creation failed: \(error)")
        }
    }

    // MARK: - Tick loop

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickRate, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isRunning, player != nil else { return }

        if let p = policyIntensity {
            if p < 0.02 {
                sendParams(intensity: 0, sharpness: 0)
            } else {
                sendParams(intensity: p, sharpness: min(1, p * 0.9 + 0.1))
            }
            return
        }

        guard !surfaces.isEmpty else {
            sendParams(intensity: 0, sharpness: 0)
            return
        }

        let count = surfaces.count

        if count == 1 {
            // Single obstacle: continuous vibration, no cycling
            let s = surfaces[0]
            sendParams(intensity: mapIntensity(s.depth), sharpness: mapSharpness(s.depth))
            return
        }

        // Multi-object: time-multiplexed slots with gaps
        let cycleLength = count * (ticksPerSlot + gapTicks)
        let pos = tickCounter % cycleLength
        let slotIdx = pos / (ticksPerSlot + gapTicks)
        let posInSlot = pos % (ticksPerSlot + gapTicks)

        if posInSlot < ticksPerSlot, slotIdx < count {
            let s = surfaces[slotIdx]
            sendParams(intensity: mapIntensity(s.depth), sharpness: mapSharpness(s.depth))
        } else {
            sendParams(intensity: 0, sharpness: 0)
        }

        tickCounter += 1
    }

    private func sendParams(intensity: Float, sharpness: Float) {
        try? player?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                     value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                     value: sharpness, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    // MARK: - Mapping curves

    /// Quadratic intensity ramp: soft at far, strong at near.
    private func mapIntensity(_ depth: Float) -> Float {
        let t = max(0, (depth - 0.15) / 0.70)
        return min(1.0, t * t * 0.85 + 0.15)
    }

    /// Linear sharpness ramp: low buzz at far, crisp at near.
    private func mapSharpness(_ depth: Float) -> Float {
        let t = max(0, (depth - 0.15) / 0.70)
        return min(1.0, t * 0.90 + 0.10)
    }

    // MARK: - Reset handling

    private func restart() {
        guard let engine else { return }
        do {
            try engine.start()
            isRunning = true
            startContinuousPlayer()
        } catch {
            print("[Haptics] Restart failed: \(error)")
        }
    }
}
