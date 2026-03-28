import AVFoundation
import CoreMotion
import UIKit

// MARK: - FMObstacleVoice

/// Soft, bell-like obstacle tone — warm and informational, never alarming.
///
/// Uses a 2:1 modulator:carrier ratio which produces even harmonics (bell/chime
/// character) rather than the 1:1 ratio's metallic edge. The modulation index
/// is kept very low (0.10–0.45) so the tone stays round and musical.
///
/// Proximity controls:
///   - **Mod index**: 0.10 (near-pure sine) → 0.45 (gentle bell shimmer)
///   - **Pulse**: very gentle amplitude swell, 0.4–2.5 Hz
///   - **Volume**: smooth ramp, never jarring
///
/// LP filter at ~2 kHz removes any remaining harshness.
final class FMObstacleVoice {

    var targetVolume:    Float = 0
    var targetModIndex:  Float = 0.10
    var targetPulseRate: Float = 0.4

    private let carrierFreq: Float
    private let sr: Float

    private var carrierPhase: Float = 0
    private var modPhase:     Float = 0
    private var pulsePhase:   Float = 0

    private var currentVolume:    Float = 0
    private var currentModIndex:  Float = 0.10
    private var currentPulseRate: Float = 0.4

    private var lpState: Float = 0
    private let lpAlpha: Float = 0.22          // gentler LP — warmer rolloff
    private let slewRate: Float = 0.0004

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

            // Gentle breathing — amplitude stays between 0.88 and 1.0
            let pulse = 0.88 + 0.12 * sinf(2 * .pi * pulsePhase)
            pulsePhase += max(0.3, currentPulseRate) / sr
            if pulsePhase >= 1.0 { pulsePhase -= 1.0 }

            // FM with 2:1 ratio — bell/chime character, not metallic
            let modFreq = carrierFreq * 2.0
            let mod = currentModIndex * sinf(2 * .pi * modPhase)
            modPhase += modFreq / sr
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

// MARK: - ChordBeaconVoice

/// Continuous pad-chord beacon using detuned saw-triangle hybrid oscillators
/// with built-in chorus and a Schroeder reverb tail.
///
/// Plays C5 + E5 + G5 simultaneously as a sustained chord. Each note is
/// rendered by two slightly detuned oscillators (±1.5 Hz) to create a natural
/// chorus/ensemble effect. A gentle LFO vibrato adds organic movement.
/// Four allpass-feedback delay lines create a lush reverb tail inside the
/// voice itself, so the chord shimmers even before the engine's global reverb.
///
/// The result is a warm, ambient "safe direction" pad that's immediately
/// distinct from the FM obstacle tones.
final class ChordBeaconVoice {

    var targetVolume: Float = 0

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.0006

    // Chord: C5, E5, G5 — each with a detuned pair for chorus
    private let baseFreqs: [Float] = [523.25, 659.25, 783.99]
    private let detune: Float = 1.5                       // Hz spread per voice
    private var phases: [Float]                            // 6 oscillators (2 per note)

    // Vibrato LFO
    private var lfoPhase: Float = 0
    private let lfoRate:  Float = 3.8                     // Hz — gentle shimmer
    private let lfoDepth: Float = 0.0035                  // pitch deviation

    // Sub-octave body (C4 at low volume)
    private var subPhase: Float = 0
    private let subFreq:  Float = 261.63

    // LP filter for warmth
    private var lpState: Float = 0
    private let lpAlpha: Float = 0.38

    // Built-in Schroeder reverb (4 comb lines)
    private var combBuffers: [[Float]]
    private var combIndices: [Int]
    private let combLengths: [Int]
    private let combFeedback: Float = 0.72

    init(sampleRate: Float) {
        self.sr = sampleRate
        self.phases = [Float](repeating: 0, count: 6)

        // Comb delay lengths: prime-ish sample counts for ~25-45 ms at 44100
        let lengths = [1117, 1367, 1559, 1801]
        self.combLengths = lengths
        self.combBuffers = lengths.map { [Float](repeating: 0, count: $0) }
        self.combIndices = [Int](repeating: 0, count: lengths.count)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            // LFO vibrato
            let lfo = 1.0 + lfoDepth * sinf(2 * .pi * lfoPhase)
            lfoPhase += lfoRate / sr
            if lfoPhase >= 1.0 { lfoPhase -= 1.0 }

            // Mix the 6 oscillators (2 per chord tone, detuned)
            var dry: Float = 0
            for n in 0..<3 {
                let fA = (baseFreqs[n] - detune) * lfo
                let fB = (baseFreqs[n] + detune) * lfo

                let idxA = n * 2
                let idxB = n * 2 + 1

                // Rounded-saw shape: sin + 0.3*sin(2x) gives richer harmonics than pure sine
                let oscA = sinf(2 * .pi * phases[idxA])
                       + 0.3 * sinf(4 * .pi * phases[idxA])
                let oscB = sinf(2 * .pi * phases[idxB])
                       + 0.3 * sinf(4 * .pi * phases[idxB])

                dry += (oscA + oscB) * 0.5

                phases[idxA] += fA / sr
                phases[idxB] += fB / sr
                if phases[idxA] >= 1.0 { phases[idxA] -= 1.0 }
                if phases[idxB] >= 1.0 { phases[idxB] -= 1.0 }
            }

            // Sub-octave for body
            let sub = sinf(2 * .pi * subPhase) * 0.25
            subPhase += subFreq * lfo / sr
            if subPhase >= 1.0 { subPhase -= 1.0 }

            dry = (dry / 3.0 + sub) * currentVolume

            // LP filter
            lpState = lpAlpha * dry + (1 - lpAlpha) * lpState

            // Schroeder comb reverb
            var wet: Float = 0
            for c in 0..<combLengths.count {
                let idx = combIndices[c]
                let delayed = combBuffers[c][idx]
                let mixed = lpState + delayed * combFeedback
                combBuffers[c][idx] = mixed
                combIndices[c] = (idx + 1) % combLengths[c]
                wet += delayed
            }
            wet *= 0.20

            buffer[i] = lpState * 0.70 + wet
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
///   Continuous C-major pad chord (C5 + E5 + G5) with detuned chorus,
///   sub-octave, and built-in reverb. Positioned at the widest clear gap.
///   Tells the user: "walk TOWARD this sound."
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
    private let poolFrequencies: [Float] = [349, 370, 392, 415, 440, 466, 494, 523]
    /// Currently assigned world bearing per pool slot (nil = unassigned).
    private var poolAssignment: [Float?] = []

    private let beaconVoice: ChordBeaconVoice
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
    private let peakObstacleVol: Float  = 0.30
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
        beaconVoice = ChordBeaconVoice(sampleRate: Float(sampleRate))
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
        return 0.10 + t * 0.35
    }

    private func obstaclePulseRate(depth d: Float, velocity v: Float) -> Float {
        let t = max(0, min(1, d))
        let base = 0.4 + 2.1 * powf(t, 1.5)
        return min(3.0, base + max(0, v) * 0.5)
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
