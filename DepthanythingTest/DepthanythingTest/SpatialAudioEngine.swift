import AVFoundation
import CoreMotion
import UIKit

// MARK: - SustainVoice

/// One note of the chord beacon: additive synthesis with per-harmonic amplitude envelopes.
///
/// On `retrigger()` the voice launches with a bright harmonic profile (like a key strike).
/// Higher harmonics then decay faster than the fundamental — this is physically how
/// strings and piano strings behave, and what makes them sound "real" rather than electronic.
///
/// Three slightly detuned copies run in parallel to create ensemble/chorus warmth.
/// Subtle vibrato (5.2 Hz, ±4 cents) keeps the sustained tone alive.
final class SustainVoice {

    let gain: Float

    private static let attackAmps:  [Float] = [1.00, 0.70, 0.45, 0.25, 0.12]
    private static let sustainAmps: [Float] = [1.00, 0.28, 0.07, 0.02, 0.005]
    private static let normAmp: Float = sustainAmps.reduce(0, +)  // ≈ 1.375

    private let freq: Float
    private let sr:   Float
    private let numH = 5

    // 3 chorus copies per note: −4 cents, centre, +4 cents
    private let detunings: [Float] = [-0.0023, 0.0, 0.0023]
    // phases[chorusIdx * numH + harmonicIdx]
    private var phases: [Float]

    private var harmAmps:  [Float]   // current per-harmonic amplitudes
    private var harmDecays:[Float]   // per-sample multiplier toward sustainAmps

    private var vibPhase:  Float = 0
    private let vibRate:   Float = 5.2    // Hz
    private let vibDepth:  Float = 0.0025 // ±0.25% ≈ ±4 cents

    init(freq: Float, gain: Float, sr: Float) {
        self.freq   = freq
        self.gain   = gain
        self.sr     = sr
        self.phases = Array(repeating: 0, count: 3 * 5)
        self.harmAmps = SustainVoice.attackAmps

        // Each harmonic decays from attackAmps[n] → sustainAmps[n] in ~0.5/(n+1) s
        self.harmDecays = (0..<5).map { n in
            let tau = max(0.04, 0.5 / Float(n + 1)) * sr
            return powf(SustainVoice.sustainAmps[n] / SustainVoice.attackAmps[n], 1.0 / tau)
        }
    }

    /// Restart harmonic brightness — call when the chord fades in from silence.
    /// Blends from current amp toward attackAmps rather than snapping, to avoid clicks.
    func retrigger() {
        for i in 0..<numH {
            harmAmps[i] = max(harmAmps[i], SustainVoice.attackAmps[i] * 0.5)
        }
    }

    func nextSample() -> Float {
        let vib = 1.0 + vibDepth * sinf(2 * .pi * vibPhase)
        vibPhase += vibRate / sr
        if vibPhase >= 1 { vibPhase -= 1 }

        var s: Float = 0
        for ci in 0..<3 {
            let baseFreq = freq * (1 + detunings[ci]) * vib
            for hi in 0..<numH {
                s += harmAmps[hi] * sinf(2 * .pi * phases[ci * numH + hi]) / 3.0
                phases[ci * numH + hi] += baseFreq * Float(hi + 1) / sr
                if phases[ci * numH + hi] >= 1 { phases[ci * numH + hi] -= 1 }
            }
        }

        // Decay each harmonic toward its sustain floor
        for hi in 0..<numH {
            if harmAmps[hi] > SustainVoice.sustainAmps[hi] {
                harmAmps[hi] = max(SustainVoice.sustainAmps[hi], harmAmps[hi] * harmDecays[hi])
            }
        }

        return (s / SustainVoice.normAmp) * gain
    }
}

// MARK: - ChordBeacon

/// Sustained C-major chord: C5 · E5 · G5 (523 · 659 · 784 Hz).
///
/// Each note uses `SustainVoice` — bright attack that decays to warmth,
/// 3-voice chorus detuning, and vibrato. Sounds like a held keyboard or pad chord,
/// not a sine wave. Retriggered whenever the beacon fades in from silence.
final class ChordBeacon {

    // Written from main thread ————————————————————————————
    var targetVolume: Float = 0
    // ————————————————————————————————————————————————————

    private let voices: [SustainVoice]
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.0002   // gentler fade-in/out
    private var wasActive = false

    init(sampleRate: Float) {
        voices = [
            SustainVoice(freq: 523.25, gain: 1.00, sr: sampleRate),  // C5 — root
            SustainVoice(freq: 659.25, gain: 0.72, sr: sampleRate),  // E5 — major third
            SustainVoice(freq: 783.99, gain: 0.52, sr: sampleRate),  // G5 — perfect fifth
        ]
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv     = targetVolume
        let active = tv > 0.005

        // Fire the bright attack envelope whenever the chord wakes from silence.
        if active && !wasActive { voices.forEach { $0.retrigger() } }
        wasActive = active

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate
            var sample: Float = 0
            for voice in voices { sample += voice.nextSample() }
            buffer[i] = (sample / 3.0) * currentVolume
        }
    }
}

// MARK: - TremoloOscillator

/// Real-time oscillator: fundamental sine + 2nd harmonic, amplitude-modulated by an LFO.
/// All parameter changes ramp smoothly at `slewRate`/sample — completely click-free.
///
/// Aligned Float reads/writes are single-instruction on ARM64, so cross-thread
/// parameter hand-off is safe without a lock for continuously-updated values.
final class TremoloOscillator {

    // Written from main thread ————————————————————————————
    var targetVolume: Float = 0
    var lfoRate:      Float = 2.0    // Hz
    // ————————————————————————————————————————————————————

    private let carrierFreq: Float
    private let sr:          Float
    private let lfoDepth:    Float   // 0 = no mod, 1 = full cut
    private let slewRate:    Float   // per-sample ramp speed

    private var currentVolume: Float = 0
    private var carrierPhase:  Float = 0
    private var lfoPhase:      Float = 0

    init(carrierFreq: Float, sampleRate: Float,
         lfoDepth: Float = 0.85, slewRate: Float = 0.0006, harmonicMix: Float = 0.50) {
        self.carrierFreq  = carrierFreq
        self.sr           = sampleRate
        self.lfoDepth     = lfoDepth
        self.slewRate     = slewRate
        self.harmonicMix  = harmonicMix
    }

    private let harmonicMix: Float

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume
        let lr = max(0.5, lfoRate)

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            let lfo = (1 - lfoDepth) + lfoDepth * (0.5 + 0.5 * sinf(2 * .pi * lfoPhase))
            lfoPhase += lr / sr
            if lfoPhase >= 1.0 { lfoPhase -= 1.0 }

            // Fundamental + optional 2nd harmonic; normalised so peak amplitude stays 1.0
            let norm    = 1.0 + harmonicMix
            let carrier = (sinf(2 * .pi * carrierPhase) + harmonicMix * sinf(4 * .pi * carrierPhase)) / norm
            carrierPhase += carrierFreq / sr
            if carrierPhase >= 1.0 { carrierPhase -= 1.0 }

            buffer[i] = carrier * lfo * currentVolume
        }
    }
}

// MARK: - SpatialAudioEngine

/// Navigation audio engine with two distinct sound layers:
///
/// **Obstacle layer** (3 zones: left / centre / right)
///   Low carrier (220–330 Hz), rapid tremolo (1–30 Hz), warm buzzy tone.
///   Louder + faster = closer obstacle. Priority ranking silences lower-rank zones.
///
/// **Path beacon** (single moving source, C-major harp arpeggio)
///   C5→E5→G5 (523→659→784 Hz) plucked every 2.5 s. 4:5:6 ratio = zero beating.
///   Decaying sine partials give a warm harp timbre, distinctly unlike the obstacle buzz.
///   Positioned at the widest clear gap in the depth map.
///   Tells the user: "you can walk TOWARD this sound."
///
/// Two clearly different timbres let the user instantly tell
/// "danger → this direction" from "safe → walk toward this sound."
@MainActor
final class SpatialAudioEngine: ObservableObject {

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    /// Best sustained clear path currently driving the beacon (nil = suppressed / not yet sustained).
    @Published var activePath: ClearPath? = nil
    /// All raw clear paths detected this frame, before memory filtering or sustain gating.
    @Published var rawPaths: [ClearPath] = []
    /// 0→1 fraction of the required sustain window — shows beacon build-up progress.
    @Published var beaconSustainProgress: Float = 0

    // MARK: - Graph

    private let engine      = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let reverb      = AVAudioUnitReverb()

    // Obstacle oscillators + nodes (one per zone)
    private var obstacleOscs:  [DepthZone: TremoloOscillator] = [:]
    private var obstacleNodes: [DepthZone: AVAudioSourceNode] = [:]

    // Path beacon: sustained C-major chord (C5·E5·G5)
    private let chordBeacon = ChordBeacon(sampleRate: 44100)
    private var beaconNode: AVAudioSourceNode?

    // MARK: - Tracking

    private let memory = SurfaceMemory()

    // MARK: - Motion

    private let motion = CMMotionManager()
    /// When true (glasses mode), phone IMU is in pocket — don't use it for head orientation.
    private var trackPhoneOrientation = true

    // MARK: - Constants

    private let sampleRate: Double   = 44100
    private let priorityWeights: [Float] = [1.0, 0.30, 0.10]
    private let peakObstacleVol: Float   = 0.38
    private let peakBeaconVol:   Float   = 0.28

    private var updateCount = 0

    // MARK: - Beacon temporal state
    // Prevents false "clear path" signals when the camera just panned past an obstacle.

    /// Smoothed path confidence (EMA). Slow to rise, medium to fall.
    private var beaconConfEMA:      Float = 0
    /// Smoothed horizontal position so the beacon doesn't jump around.
    private var beaconAzimuthEMA:   Float = 0.5
    /// Consecutive frames the path has been consistently clear AND memory-validated.
    private var beaconSustainCount: Int   = 0
    /// Frames required before the beacon fires (~1 s at ~18 fps).
    private let beaconRequiredFrames      = 18
    private let beaconAttackAlpha:  Float = 0.12   // conservative rise
    private let beaconReleaseAlpha: Float = 0.06   // moderate decay
    private let beaconAzimuthAlpha: Float = 0.08   // smooth position drift

    // MARK: - Session / lifecycle observers

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        buildAudioGraph()
        registerSessionObservers()
    }

    deinit {
        [interruptionObserver, routeObserver, foregroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Called from the inference loop every frame.
    func update(depthMap: [Float], width: Int, height: Int) {
        guard isEnabled, engine.isRunning else { return }

        let rawZones  = DepthZoneSampler.sample(depthMap: depthMap, width: width, height: height)
        let surfaces  = memory.update(rawZones: rawZones)
        applyObstacles(surfaces)

        let paths = PathFinder.findClearPaths(depthMap: depthMap, width: width, height: height)
        rawPaths = paths
        applyBeacon(paths, surfaces: surfaces)

        updateCount += 1
        if updateCount % 45 == 1 { log(surfaces: surfaces, paths: paths) }
    }

    /// Call when switching between phone camera and glasses.
    /// In glasses mode the phone is in pocket — its orientation doesn't track the head.
    func setGlassesMode(_ glasses: Bool) {
        trackPhoneOrientation = !glasses
        if glasses {
            motion.stopDeviceMotionUpdates()
            // Fixed forward-facing listener: camera left = user left = left ear.
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
        reverb.wetDryMix = 22

        engine.attach(environment)
        engine.attach(reverb)
        engine.connect(environment, to: reverb,               format: nil)
        engine.connect(reverb,      to: engine.mainMixerNode, format: nil)

        if #available(iOS 15, *) { environment.renderingAlgorithm = .HRTFHQ }
        else                     { environment.renderingAlgorithm = .HRTF   }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.rolloffFactor   = 0
        environment.distanceAttenuationParameters.maximumDistance = 1_000

        // --- Obstacle nodes ---
        for zone in DepthZone.allCases {
            let osc  = TremoloOscillator(carrierFreq: zone.carrierFrequency,
                                         sampleRate: Float(sampleRate),
                                         lfoDepth: 0.60)
            obstacleOscs[zone] = osc
            let node = makeSourceNode(osc: osc, format: mono)
            engine.attach(node)
            engine.connect(node, to: environment, format: mono)
            node.position = zone.audioPosition
            obstacleNodes[zone] = node
        }

        // --- Path beacon: C-major harp arpeggio ---
        let beacon = chordBeacon
        let bNode = AVAudioSourceNode(format: mono) { [beacon] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let buf = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                beacon.render(into: buf, frameCount: Int(frameCount))
            }
            return noErr
        }
        engine.attach(bNode)
        engine.connect(bNode, to: environment, format: mono)
        bNode.position = AVAudio3DPoint(x: 0, y: 0, z: -1.5)
        beaconNode = bNode
    }

    private func makeSourceNode(osc: TremoloOscillator, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [osc] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let buf = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                osc.render(into: buf, frameCount: Int(frameCount))
            }
            return noErr
        }
    }

    // MARK: - Engine lifecycle

    private func startEngine() {
        configureSession()
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("[SpatialAudio] Engine start failed: \(error)")
            isEnabled = false
            return
        }
        if trackPhoneOrientation { startMotionTracking() }
        print("[SpatialAudio] Started ✓")
    }

    /// Configure session to be compatible with Gemini (.playAndRecord, .mixWithOthers).
    /// Called at start and after any session interruption.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use .playAndRecord so we coexist with Gemini/mic without category conflicts.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[SpatialAudio] Session configure failed: \(error)")
        }
    }

    private func stopEngine() {
        obstacleOscs.values.forEach { $0.targetVolume = 0 }
        chordBeacon.targetVolume = 0
        beaconSustainCount    = 0
        beaconConfEMA         = 0
        activePath            = nil
        rawPaths              = []
        beaconSustainProgress = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.engine.stop()
        }
        motion.stopDeviceMotionUpdates()
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
                print("[SpatialAudio] Session interruption ended — restarting")
                self.configureSession()
                try? self.engine.start()
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
            // Category changes (e.g. Gemini starting) can stop our engine — restart it.
            if reason == .categoryChange || reason == .override {
                print("[SpatialAudio] Route change (\(reason?.rawValue ?? 0)) — restarting")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.isEnabled, !self.engine.isRunning else { return }
                    self.configureSession()
                    try? self.engine.start()
                }
            }
        }

        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.engine.isRunning else { return }
            print("[SpatialAudio] Foregrounded — restarting engine")
            self.configureSession()
            try? self.engine.start()
        }
    }

    // MARK: - Motion (phone-held mode only)

    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let att = data?.attitude else { return }
            self?.environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
                yaw:   Float(att.yaw   * 180 / .pi),
                pitch: Float(att.pitch * 180 / .pi),
                roll:  Float(att.roll  * 180 / .pi))
        }
    }

    // MARK: - Obstacle audio

    private func applyObstacles(_ surfaces: [SurfaceSnapshot]) {
        obstacleOscs.values.forEach { $0.targetVolume = 0; $0.lfoRate = 1.5 }
        for (idx, s) in surfaces.enumerated() {
            guard let osc = obstacleOscs[s.zone] else { continue }
            let weight = idx < priorityWeights.count ? priorityWeights[idx] : priorityWeights.last!
            osc.targetVolume = obstacleVolume(s.depth) * weight
            osc.lfoRate      = obstacleLFO(depth: s.depth, velocity: s.velocity)
        }
    }

    /// Silent below d=0.25, quadratic ramp → peak at d≥0.85.
    private func obstacleVolume(_ d: Float) -> Float {
        let t = (d - 0.25) / 0.60
        return peakObstacleVol * max(0, min(1, t)) * max(0, min(1, t))
    }

    /// 0.8 Hz (distant) → 9 Hz (urgent). Approach velocity adds up to +2 Hz.
    private func obstacleLFO(depth d: Float, velocity v: Float) -> Float {
        let base = 0.8 + 8.2 * powf(max(0, d), 1.8)
        return min(9.0, base + max(0, v) * 2.0)
    }

    // MARK: - Path beacon

    private func applyBeacon(_ paths: [ClearPath], surfaces: [SurfaceSnapshot]) {
        func silence() {
            chordBeacon.targetVolume = 0
            activePath = nil
        }

        // --- Step 1: bail if no confident path in current frame ---
        guard let best = paths.first, best.confidence > 0.15 else {
            beaconSustainCount = max(0, beaconSustainCount - 2)
            beaconConfEMA     *= (1 - beaconReleaseAlpha)
            beaconSustainProgress = Float(beaconSustainCount) / Float(beaconRequiredFrames)
            silence()
            return
        }

        // --- Step 2: reset sustain if direction changed significantly ---
        if abs(best.azimuthFraction - beaconAzimuthEMA) > 0.30 {
            beaconSustainCount = 0
        }

        // --- Step 3: smooth confidence and azimuth ---
        let confAlpha = best.confidence > beaconConfEMA ? beaconAttackAlpha : beaconReleaseAlpha
        beaconConfEMA    += confAlpha          * (best.confidence        - beaconConfEMA)
        beaconAzimuthEMA += beaconAzimuthAlpha * (best.azimuthFraction   - beaconAzimuthEMA)

        // --- Step 4: require path to be consistently clear for ~1 s before beacon fires ---
        beaconSustainCount = min(beaconSustainCount + 1, beaconRequiredFrames + 1)
        beaconSustainProgress = min(1, Float(beaconSustainCount) / Float(beaconRequiredFrames))

        guard beaconSustainCount >= beaconRequiredFrames else {
            chordBeacon.targetVolume = 0
            activePath = ClearPath(azimuthFraction: beaconAzimuthEMA,
                                   width: best.width, avgDepth: best.avgDepth,
                                   confidence: beaconConfEMA)
            return
        }

        // --- Step 5: position source and fire beacon ---
        let audioX = (beaconAzimuthEMA - 0.5) * 3.6
        beaconNode?.position = AVAudio3DPoint(x: audioX, y: 0, z: -1.5)
        chordBeacon.targetVolume = min(peakBeaconVol, beaconConfEMA * 0.55)
        activePath = ClearPath(azimuthFraction: beaconAzimuthEMA,
                               width: best.width, avgDepth: best.avgDepth,
                               confidence: beaconConfEMA)
    }

    // MARK: - Diagnostics

    private func log(surfaces: [SurfaceSnapshot], paths: [ClearPath]) {
        let obs = surfaces.isEmpty ? "(no obstacles)" : surfaces.enumerated().map { i, s in
            "#\(i+1)\(s.zone) d=\(String(format:"%.2f",s.depth)) lfo=\(String(format:"%.0f",obstacleLFO(depth:s.depth,velocity:s.velocity)))Hz"
        }.joined(separator: " | ")
        let pth = paths.first.map { "beacon→\(String(format:"%.0f",($0.azimuthFraction-0.5)*100))% conf=\(String(format:"%.2f",$0.confidence))" } ?? "(no clear path)"
        print("[SpatialAudio] \(obs)   \(pth)")
    }
}
