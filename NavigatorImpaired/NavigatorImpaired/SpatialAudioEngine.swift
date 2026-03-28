import AVFoundation
import CoreMotion
import UIKit

// MARK: - FMObstacleVoice

/// FM synthesis voice producing a warm, soft tone for obstacle sonification.
///
/// Uses a 1:1 carrier:modulator ratio (harmonic series) with a *low* modulation
/// index that stays musical. Proximity adds gentle brightness, never metallic:
///   - **Modulation index**: 0.15 (near-pure sine) → 0.9 (warm overtones, never harsh)
///   - **Pulse rate**: subtle 0.6 Hz breathing → 5 Hz alert pulse
///   - **Volume**: quadratic ramp from silence to peak
///
/// A two-stage soft-knee envelope keeps the output warm:
///   1. FM index capped well below metallic range
///   2. One-pole LP filter rolls off highs above ~2.5 kHz
final class FMObstacleVoice {

    var targetVolume:    Float = 0
    var targetModIndex:  Float = 0.15
    var targetPulseRate: Float = 0.6

    private let carrierFreq: Float
    private let sr: Float

    private var carrierPhase: Float = 0
    private var modPhase:     Float = 0
    private var pulsePhase:   Float = 0

    private var currentVolume:    Float = 0
    private var currentModIndex:  Float = 0.15
    private var currentPulseRate: Float = 0.6

    private var lpState: Float = 0
    private let lpAlpha: Float = 0.30
    private let slewRate: Float = 0.0005

    init(carrierFreq: Float, sampleRate: Float) {
        self.carrierFreq = carrierFreq
        self.sr = sampleRate
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv  = targetVolume
        let tmi = targetModIndex
        let tpr = targetPulseRate

        for i in 0..<frameCount {
            currentVolume    += (tv  - currentVolume)    * slewRate
            currentModIndex  += (tmi - currentModIndex)  * slewRate
            currentPulseRate += (tpr - currentPulseRate)  * slewRate

            // Subtle breathing — amplitude stays between 0.78 and 1.0
            let pulse = 0.78 + 0.22 * sinf(2 * .pi * pulsePhase)
            pulsePhase += max(0.2, currentPulseRate) / sr
            if pulsePhase >= 1.0 { pulsePhase -= 1.0 }

            // FM: gentle modulation keeps the tone warm, not metallic
            let mod = currentModIndex * sinf(2 * .pi * modPhase)
            modPhase += carrierFreq / sr
            if modPhase >= 1.0 { modPhase -= 1.0 }

            let carrier = sinf(2 * .pi * carrierPhase + mod)
            carrierPhase += carrierFreq / sr
            if carrierPhase >= 1.0 { carrierPhase -= 1.0 }

            let raw = carrier * pulse * currentVolume
            lpState = lpAlpha * raw + (1 - lpAlpha) * lpState
            buffer[i] = lpState
        }
    }
}

// MARK: - FMBeaconVoice

/// Karplus-Strong plucked-string beacon producing a repeating harp/kalimba arpeggio.
///
/// Instead of a continuous synth chord, this plays C5 → E5 → G5 as naturally
/// decaying plucked notes, cycling every ~2 seconds. Karplus-Strong works by
/// exciting a delay line with filtered noise and repeatedly averaging adjacent
/// samples — the result is a physically realistic vibrating-string timbre with
/// no synthetic character.
///
/// The arpeggio pattern makes the beacon musical and immediately recognisable
/// as "the safe direction sound," clearly distinct from the obstacle FM tones.
final class ArpeggioBeaconVoice {

    var targetVolume: Float = 0

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.0005

    // Arpeggio state
    private let noteFreqs: [Float] = [523.25, 659.25, 783.99]  // C5, E5, G5
    private var currentNote = 0
    private var samplesSinceLastPluck = 0
    private let samplesPerNote: Int    // ~0.6 s per note

    // Karplus-Strong delay lines (one per note for overlap / ring-out)
    private var lines: [KSLine]

    private struct KSLine {
        var buffer: [Float]
        var writePos: Int = 0
        let length: Int
        var energy: Float = 0
        let decay: Float          // per-sample decay (controls ring time)
    }

    init(sampleRate: Float) {
        self.sr = sampleRate
        self.samplesPerNote = Int(sampleRate * 0.65)

        var ls: [KSLine] = []
        for freq in [523.25, 659.25, 783.99] as [Float] {
            let len = max(2, Int(sampleRate / freq))
            ls.append(KSLine(
                buffer: [Float](repeating: 0, count: len),
                length: len,
                decay: 0.998      // warm decay — rings for ~1.5 s
            ))
        }
        self.lines = ls
    }

    /// Trigger a pluck on the given note index by filling its delay line with
    /// band-limited noise shaped by a gentle low-pass.
    private func pluck(note idx: Int) {
        let len = lines[idx].length
        var prev: Float = 0
        for i in 0..<len {
            let noise = Float.random(in: -1...1)
            let filtered = 0.5 * noise + 0.5 * prev
            lines[idx].buffer[i] = filtered
            prev = filtered
        }
        lines[idx].writePos = 0
        lines[idx].energy = 1.0
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            // Trigger next note in arpeggio when it's time
            if currentVolume > 0.01 {
                samplesSinceLastPluck += 1
                if samplesSinceLastPluck >= samplesPerNote {
                    pluck(note: currentNote)
                    currentNote = (currentNote + 1) % noteFreqs.count
                    samplesSinceLastPluck = 0
                }
            } else {
                samplesSinceLastPluck = samplesPerNote - 1
            }

            // Sum all active lines (notes ring out and overlap naturally)
            var sample: Float = 0
            for li in 0..<lines.count {
                guard lines[li].energy > 0.001 else { continue }

                let len = lines[li].length
                let pos = lines[li].writePos
                let cur = lines[li].buffer[pos]
                let next = lines[li].buffer[(pos + 1) % len]

                // Karplus-Strong averaging filter — this is what creates the string sound
                let avg = lines[li].decay * 0.5 * (cur + next)
                lines[li].buffer[pos] = avg
                lines[li].writePos = (pos + 1) % len
                lines[li].energy *= lines[li].decay

                sample += cur
            }

            buffer[i] = sample * 0.45 * currentVolume
        }
    }
}

// MARK: - SpatialAudioEngine

/// 360° navigation audio engine with three perceptual layers:
///
/// **Obstacle layer** (pool of 8 repositionable voices)
///   FM bell/mallet tones (175–290 Hz). Each frame, the depth profile is merged
///   into a persistent `WorldObstacleMap` covering the full 360° around the user.
///   The top-N obstacles are assigned to the voice pool and positioned via HRTF
///   at their exact world-space bearing. Obstacles behind the user (scanned
///   earlier) persist and fade gradually, giving continuous spatial awareness.
///
/// **Path beacon** (single moving source)
///   Karplus-Strong harp arpeggio (C5 → E5 → G5). Positioned at the widest
///   clear gap. Tells the user: "walk TOWARD this sound."
///
/// **Haptics** (via NavigationHapticEngine)
///   Continuous vibration with intensity/sharpness mapped to proximity.
///   Uses zone-based sampling for left/center/right haptic differentiation.
@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true

    /// Best sustained clear path currently driving the beacon (nil = not yet sustained).
    @Published var activePath: ClearPath? = nil
    /// All raw clear paths detected this frame.
    @Published var rawPaths: [ClearPath] = []
    /// Per-column depth profile (0=far, 1=near) for the azimuth bar visualization.
    @Published var depthProfile: [Float] = []
    /// 0→1 fraction of the required sustain window.
    @Published var beaconSustainProgress: Float = 0

    // MARK: - Audio graph

    private let avEngine    = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let reverb      = AVAudioUnitReverb()

    // Voice pool — 8 repositionable obstacle voices
    private let poolSize = 8
    private var poolVoices: [FMObstacleVoice] = []
    private var poolNodes:  [AVAudioSourceNode] = []
    /// Carrier frequencies spread across a warm octave (F3 → D4).
    private let poolFrequencies: [Float] = [175, 190, 207, 220, 240, 256, 272, 290]
    /// Currently assigned world bearing per pool slot (nil = unassigned).
    private var poolAssignment: [Float?] = []

    private let beaconVoice: ArpeggioBeaconVoice
    private var beaconNode: AVAudioSourceNode?

    // MARK: - Haptics

    let haptics = NavigationHapticEngine()

    // MARK: - World map (360° obstacle memory)

    private let worldMap = WorldObstacleMap()

    // MARK: - Zone tracking (for haptics only)

    private let memory = SurfaceMemory()

    // MARK: - Motion

    private let motion = CMMotionManager()
    private var trackPhoneOrientation = true
    /// Current phone heading in radians from CMAttitude.yaw.
    private var currentHeading: Float = 0

    // MARK: - Constants

    private let sampleRate:      Double = 44100
    private let peakObstacleVol: Float  = 0.40
    private let peakBeaconVol:   Float  = 0.30

    // MARK: - Beacon temporal state

    private var beaconConfEMA:      Float = 0
    private var beaconAzimuthEMA:   Float = 0.5
    private var beaconSustainCount: Int   = 0
    private let beaconRequiredFrames      = 18

    // MARK: - Session observers

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver:        NSObjectProtocol?
    private var foregroundObserver:   NSObjectProtocol?

    private var updateCount = 0

    // MARK: - Init

    init() {
        poolAssignment = [Float?](repeating: nil, count: poolSize)
        beaconVoice = ArpeggioBeaconVoice(sampleRate: Float(sampleRate))
        buildAudioGraph()
        registerSessionObservers()
    }

    deinit {
        [interruptionObserver, routeObserver, foregroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Called from the inference loop every frame with the latest depth map.
    func update(depthMap: [Float], width: Int, height: Int) {
        guard isEnabled, avEngine.isRunning else { return }

        let scanResult = PathFinder.scan(depthMap: depthMap, width: width, height: height)
        depthProfile = scanResult.profile
        rawPaths = scanResult.paths

        // 360° world-space obstacle audio
        let obstacles = worldMap.update(profile: scanResult.profile, heading: currentHeading)
        applyVoicePool(obstacles)

        // Beacon
        applyBeacon(scanResult.paths)

        // Haptics (zone-based)
        if hapticsEnabled {
            let rawZones = DepthZoneSampler.sample(depthMap: depthMap, width: width, height: height)
            let surfaces = memory.update(rawZones: rawZones)
            haptics.update(surfaces: surfaces)
        }

        updateCount += 1
        if updateCount % 45 == 1 { logDiagnostics(obstacles: obstacles, paths: scanResult.paths) }
    }

    /// In glasses mode the phone is in a pocket — don't use its IMU for head orientation.
    func setGlassesMode(_ glasses: Bool) {
        trackPhoneOrientation = !glasses
        if glasses {
            motion.stopDeviceMotionUpdates()
            currentHeading = 0
            environment.listenerAngularOrientation =
                AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        } else {
            startMotionTracking()
        }
    }

    // MARK: - Audio graph (built once)

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 18

        avEngine.attach(environment)
        avEngine.attach(reverb)
        avEngine.connect(environment, to: reverb, format: nil)
        avEngine.connect(reverb, to: avEngine.mainMixerNode, format: nil)

        if #available(iOS 15, *) { environment.renderingAlgorithm = .HRTFHQ }
        else                     { environment.renderingAlgorithm = .HRTF   }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

        // Distance attenuation for natural HRTF depth cues
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1.0
        environment.distanceAttenuationParameters.maximumDistance   = 15.0
        environment.distanceAttenuationParameters.rolloffFactor    = 0.5

        // --- Voice pool (8 repositionable FM obstacle sources) ---
        for i in 0..<poolSize {
            let freq = poolFrequencies[i]
            let voice = FMObstacleVoice(carrierFreq: freq, sampleRate: Float(sampleRate))
            poolVoices.append(voice)

            let node = AVAudioSourceNode(format: mono) { [voice] _, _, frameCount, abl in
                let ptr = UnsafeMutableAudioBufferListPointer(abl)
                if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                    voice.render(into: buf, frameCount: Int(frameCount))
                }
                return noErr
            }
            avEngine.attach(node)
            avEngine.connect(node, to: environment, format: mono)
            node.position = AVAudio3DPoint(x: 0, y: 0, z: -5)
            poolNodes.append(node)
        }

        // --- Path beacon (Karplus-Strong harp arpeggio) ---
        let bv = beaconVoice
        let bNode = AVAudioSourceNode(format: mono) { [bv] _, _, frameCount, abl in
            let ptr = UnsafeMutableAudioBufferListPointer(abl)
            if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                bv.render(into: buf, frameCount: Int(frameCount))
            }
            return noErr
        }
        avEngine.attach(bNode)
        avEngine.connect(bNode, to: environment, format: mono)
        bNode.position = AVAudio3DPoint(x: 0, y: 0, z: -1.5)
        beaconNode = bNode
    }

    // MARK: - Engine lifecycle

    private func startEngine() {
        configureSession()
        guard !avEngine.isRunning else { return }
        do {
            try avEngine.start()
        } catch {
            print("[SpatialAudio] Engine start failed: \(error)")
            isEnabled = false
            return
        }
        if trackPhoneOrientation { startMotionTracking() }
        haptics.start()
        print("[SpatialAudio] Started — 360° mode, \(poolSize) voice pool")
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[SpatialAudio] Session configure failed: \(error)")
        }
    }

    private func stopEngine() {
        poolVoices.forEach { $0.targetVolume = 0 }
        poolAssignment = [Float?](repeating: nil, count: poolSize)
        beaconVoice.targetVolume = 0
        beaconSustainCount    = 0
        beaconConfEMA         = 0
        activePath            = nil
        rawPaths              = []
        depthProfile          = []
        beaconSustainProgress = 0

        haptics.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.avEngine.stop()
        }
        motion.stopDeviceMotionUpdates()
        worldMap.reset()
        memory.reset()
        print("[SpatialAudio] Stopped")
    }

    // MARK: - Session observers

    private func registerSessionObservers() {
        let nc = NotificationCenter.default

        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self, self.isEnabled else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) ?? .began
            if type == .ended {
                print("[SpatialAudio] Interruption ended — restarting")
                self.configureSession()
                try? self.avEngine.start()
            }
        }

        routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self, self.isEnabled else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .categoryChange || reason == .override {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.isEnabled, !self.avEngine.isRunning else { return }
                    self.configureSession()
                    try? self.avEngine.start()
                }
            }
        }

        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.avEngine.isRunning else { return }
            print("[SpatialAudio] Foregrounded — restarting engine")
            self.configureSession()
            try? self.avEngine.start()
        }
    }

    // MARK: - Motion (phone-held mode only)

    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }
            self.currentHeading = Float(att.yaw)
            self.environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
                yaw:   Float(att.yaw   * 180 / .pi),
                pitch: Float(att.pitch * 180 / .pi),
                roll:  Float(att.roll  * 180 / .pi))
        }
    }

    // MARK: - Voice pool assignment

    /// Assigns the top world obstacles to the voice pool with stable matching.
    private func applyVoicePool(_ obstacles: [WorldObstacle]) {
        let topN = Array(obstacles.prefix(poolSize))
        var used = Set<Int>()          // pool indices already claimed
        var matched = Set<Int>()       // obstacle indices already matched
        var assignments: [(pool: Int, obstacle: Int)] = []

        // Pass 1: match obstacles to voices that were already assigned nearby
        for (oi, obs) in topN.enumerated() {
            var bestSlot = -1
            var bestDist: Float = .greatestFiniteMagnitude
            for pi in 0..<poolSize where !used.contains(pi) {
                guard let prev = poolAssignment[pi] else { continue }
                let d = bearingDistance(prev, obs.bearing)
                if d < bestDist { bestDist = d; bestSlot = pi }
            }
            if bestSlot >= 0, bestDist < 0.35 {  // ~20° tolerance
                assignments.append((bestSlot, oi))
                used.insert(bestSlot)
                matched.insert(oi)
            }
        }

        // Pass 2: assign remaining obstacles to free voices (prefer quietest)
        for (oi, _) in topN.enumerated() where !matched.contains(oi) {
            var bestSlot = -1
            var bestVol: Float = .greatestFiniteMagnitude
            for pi in 0..<poolSize where !used.contains(pi) {
                let v = poolVoices[pi].targetVolume
                if v < bestVol { bestVol = v; bestSlot = pi }
            }
            if bestSlot >= 0 {
                assignments.append((bestSlot, oi))
                used.insert(bestSlot)
            }
        }

        // Silence unassigned voices
        for pi in 0..<poolSize where !used.contains(pi) {
            poolVoices[pi].targetVolume    = 0
            poolVoices[pi].targetModIndex  = 0.15
            poolVoices[pi].targetPulseRate = 0.6
            poolAssignment[pi] = nil
        }

        // Apply parameters and position each assigned voice
        for (pi, oi) in assignments {
            let obs = topN[oi]
            poolAssignment[pi] = obs.bearing

            poolVoices[pi].targetVolume    = obstacleVolume(obs.depth)
            poolVoices[pi].targetModIndex  = obstacleModIndex(obs.depth)
            poolVoices[pi].targetPulseRate = obstaclePulseRate(depth: obs.depth, velocity: obs.velocity)

            let pos = bearingToAudioPosition(bearing: obs.bearing, depth: obs.depth)
            poolNodes[pi].position = pos
        }
    }

    /// Shortest angular distance on the unit circle (0 → π).
    private func bearingDistance(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d >  .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return abs(d)
    }

    /// Convert a world-space bearing + depth to an AVAudio3D position.
    ///
    /// Uses the same coordinate frame as CMAttitude.yaw: bearing 0 is the
    /// session-start forward direction. The HRTF + listener orientation
    /// automatically makes sources "behind" the user sound correct.
    private func bearingToAudioPosition(bearing: Float, depth: Float) -> AVAudio3DPoint {
        let audioDist = depthToAudioDistance(depth)
        let x = -sinf(bearing) * audioDist
        let z = -cosf(bearing) * audioDist
        return AVAudio3DPoint(x: x, y: 0, z: z)
    }

    /// Maps proximity depth (0=far, 1=near) to an HRTF-space distance.
    private func depthToAudioDistance(_ d: Float) -> Float {
        0.8 + (1.0 - d) * 4.5      // near → 0.8m, far → 5.3m
    }

    // MARK: - Obstacle parameter curves

    private func obstacleVolume(_ d: Float) -> Float {
        let t = max(0, (d - 0.15) / 0.75)
        return peakObstacleVol * t * t
    }

    private func obstacleModIndex(_ d: Float) -> Float {
        let t = max(0, min(1, (d - 0.15) / 0.70))
        return 0.15 + t * 0.75
    }

    private func obstaclePulseRate(depth d: Float, velocity v: Float) -> Float {
        let t = max(0, min(1, d))
        let base = 0.6 + 4.4 * powf(t, 1.5)
        return min(6.0, base + max(0, v) * 1.0)
    }

    // MARK: - Path beacon

    private func applyBeacon(_ paths: [ClearPath]) {
        guard let best = paths.first, best.confidence > 0.15 else {
            beaconSustainCount = max(0, beaconSustainCount - 2)
            beaconConfEMA *= 0.94
            beaconSustainProgress = Float(beaconSustainCount) / Float(beaconRequiredFrames)
            beaconVoice.targetVolume = 0
            activePath = nil
            return
        }

        if abs(best.azimuthFraction - beaconAzimuthEMA) > 0.30 {
            beaconSustainCount = 0
        }

        let alpha: Float = best.confidence > beaconConfEMA ? 0.12 : 0.06
        beaconConfEMA    += alpha * (best.confidence      - beaconConfEMA)
        beaconAzimuthEMA += 0.08  * (best.azimuthFraction - beaconAzimuthEMA)

        beaconSustainCount = min(beaconSustainCount + 1, beaconRequiredFrames + 1)
        beaconSustainProgress = min(1, Float(beaconSustainCount) / Float(beaconRequiredFrames))

        let smoothed = ClearPath(azimuthFraction: beaconAzimuthEMA,
                                  width: best.width,
                                  avgDepth: best.avgDepth,
                                  confidence: beaconConfEMA)

        guard beaconSustainCount >= beaconRequiredFrames else {
            beaconVoice.targetVolume = 0
            activePath = smoothed
            return
        }

        let audioX = (beaconAzimuthEMA - 0.5) * 3.6
        beaconNode?.position = AVAudio3DPoint(x: audioX, y: 0, z: -1.5)
        beaconVoice.targetVolume = min(peakBeaconVol, beaconConfEMA * 0.60)
        activePath = smoothed
    }

    // MARK: - Diagnostics

    private func logDiagnostics(obstacles: [WorldObstacle], paths: [ClearPath]) {
        let obs = obstacles.isEmpty ? "(clear)" : obstacles.prefix(3).map { o in
            let deg = Int(o.bearing * 180 / .pi)
            return "\(deg)° d=\(String(format: "%.2f", o.depth))"
        }.joined(separator: " | ")
        let pth = paths.first.map {
            "beacon \(String(format: "%.0f%%", ($0.azimuthFraction - 0.5) * 100)) conf=\(String(format: "%.2f", $0.confidence))"
        } ?? "(no path)"
        print("[SpatialAudio] \(obs)  \(pth)")
    }
}
