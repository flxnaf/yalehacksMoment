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

/// Clean warm pad for the clear-path beacon.
///
/// Three chord tones (C5 · E5 · G5) rendered with very gentle FM (mod index 0.2,
/// 2:1 ratio for a soft octave harmonic) plus chorus detuning. The result is a
/// smooth, inviting drone — like a soft synth pad, clearly distinct from the
/// obstacle tones. No inharmonic beating, no metallic character.
final class FMBeaconVoice {

    var targetVolume: Float = 0

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.0003

    private struct Partial {
        var carrierPhase: Float = 0
        var modPhase:     Float = 0
        var vibPhase:     Float
        let carrierFreq:  Float
        let modFreq:      Float
        let modIndex:     Float
        let gain:         Float
        let vibRate:      Float
        let vibDepth:     Float
    }

    private var partials: [Partial]
    private let normFactor: Float

    init(sampleRate: Float) {
        self.sr = sampleRate

        let notes: [(freq: Float, gain: Float)] = [
            (523.25, 1.00),   // C5 — root
            (659.25, 0.65),   // E5 — major third
            (783.99, 0.42),   // G5 — fifth
        ]

        var parts: [Partial] = []
        var totalGain: Float = 0

        for note in notes {
            for detune in [-0.0012, 0.0012] as [Float] {
                let f = note.freq * (1.0 + detune)
                let g = note.gain * 0.5
                totalGain += g
                parts.append(Partial(
                    vibPhase: Float.random(in: 0..<1),
                    carrierFreq: f,
                    modFreq: f * 2.0,    // 2:1 ratio — clean octave harmonic, no dissonance
                    modIndex: 0.2,       // very gentle — adds warmth without weirdness
                    gain: g,
                    vibRate: Float.random(in: 3.8...4.6),
                    vibDepth: 0.0012     // ±0.12% ≈ ±2 cents — subtle shimmer
                ))
            }
        }
        self.partials = parts
        self.normFactor = totalGain > 0 ? 1.0 / totalGain : 1.0
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            var sample: Float = 0
            for p in 0..<partials.count {
                let vib = 1.0 + partials[p].vibDepth * sinf(2 * .pi * partials[p].vibPhase)
                partials[p].vibPhase += partials[p].vibRate / sr
                if partials[p].vibPhase >= 1.0 { partials[p].vibPhase -= 1.0 }

                let cFreq = partials[p].carrierFreq * vib
                let mFreq = partials[p].modFreq * vib

                let mod = partials[p].modIndex * sinf(2 * .pi * partials[p].modPhase)
                partials[p].modPhase += mFreq / sr
                if partials[p].modPhase >= 1.0 { partials[p].modPhase -= 1.0 }

                sample += partials[p].gain * sinf(2 * .pi * partials[p].carrierPhase + mod)
                partials[p].carrierPhase += cFreq / sr
                if partials[p].carrierPhase >= 1.0 { partials[p].carrierPhase -= 1.0 }
            }

            buffer[i] = sample * normFactor * currentVolume
        }
    }
}

// MARK: - SpatialAudioEngine

/// Navigation audio engine with two perceptually distinct layers:
///
/// **Obstacle layer** (3 zones: left / centre / right)
///   FM bell/mallet tones (185–262 Hz). Proximity drives modulation index
///   (warmer → brighter), volume, and pulse rate. HRTF-positioned so stereo
///   panning tells the user *where*; intensity tells them *how close*.
///
/// **Path beacon** (single moving source)
///   FM singing-bowl pad (C5 · E5 · G5 chord). Warm, ethereal timbre clearly
///   distinct from the obstacle bells. Positioned at the widest clear gap.
///   Tells the user: "walk TOWARD this sound."
///
/// **Haptics** (via NavigationHapticEngine)
///   Continuous vibration with intensity/sharpness mapped to proximity.
///   Multi-object differentiation via time-multiplexed haptic slots.
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
    /// 0→1 fraction of the required sustain window.
    @Published var beaconSustainProgress: Float = 0

    // MARK: - Audio graph

    private let avEngine     = AVAudioEngine()
    private let environment  = AVAudioEnvironmentNode()
    private let reverb       = AVAudioUnitReverb()

    private var obstacleVoices: [DepthZone: FMObstacleVoice] = [:]
    private var obstacleNodes:  [DepthZone: AVAudioSourceNode] = [:]

    private let beaconVoice: FMBeaconVoice
    private var beaconNode: AVAudioSourceNode?

    // MARK: - Haptics

    let haptics = NavigationHapticEngine()

    // MARK: - Tracking

    private let memory = SurfaceMemory()

    // MARK: - Motion

    private let motion = CMMotionManager()
    private var trackPhoneOrientation = true

    // MARK: - Constants

    private let sampleRate:       Double = 44100
    private let peakObstacleVol:  Float  = 0.40
    private let peakBeaconVol:    Float  = 0.30

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
        beaconVoice = FMBeaconVoice(sampleRate: Float(sampleRate))
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

        let rawZones = DepthZoneSampler.sample(depthMap: depthMap, width: width, height: height)
        let surfaces = memory.update(rawZones: rawZones)
        applyObstacles(surfaces)

        let paths = PathFinder.findClearPaths(depthMap: depthMap, width: width, height: height)
        rawPaths = paths
        applyBeacon(paths)

        if hapticsEnabled {
            haptics.update(surfaces: surfaces)
        }

        updateCount += 1
        if updateCount % 45 == 1 { logDiagnostics(surfaces: surfaces, paths: paths) }
    }

    /// In glasses mode the phone is in a pocket — don't use its IMU for head orientation.
    func setGlassesMode(_ glasses: Bool) {
        trackPhoneOrientation = !glasses
        if glasses {
            motion.stopDeviceMotionUpdates()
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
        environment.distanceAttenuationParameters.rolloffFactor   = 0
        environment.distanceAttenuationParameters.maximumDistance = 1_000

        // --- Obstacle nodes (one FM voice per zone) ---
        for zone in DepthZone.allCases {
            let voice = FMObstacleVoice(carrierFreq: zone.carrierFrequency,
                                         sampleRate: Float(sampleRate))
            obstacleVoices[zone] = voice

            let node = AVAudioSourceNode(format: mono) { [voice] _, _, frameCount, abl in
                let ptr = UnsafeMutableAudioBufferListPointer(abl)
                if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                    voice.render(into: buf, frameCount: Int(frameCount))
                }
                return noErr
            }
            avEngine.attach(node)
            avEngine.connect(node, to: environment, format: mono)
            node.position = zone.audioPosition
            obstacleNodes[zone] = node
        }

        // --- Path beacon (FM singing-bowl pad) ---
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
        print("[SpatialAudio] Started")
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
        obstacleVoices.values.forEach { $0.targetVolume = 0 }
        beaconVoice.targetVolume = 0
        beaconSustainCount    = 0
        beaconConfEMA         = 0
        activePath            = nil
        rawPaths              = []
        beaconSustainProgress = 0

        haptics.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.avEngine.stop()
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
            guard let att = data?.attitude else { return }
            self?.environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
                yaw:   Float(att.yaw   * 180 / .pi),
                pitch: Float(att.pitch * 180 / .pi),
                roll:  Float(att.roll  * 180 / .pi))
        }
    }

    // MARK: - Obstacle audio

    private func applyObstacles(_ surfaces: [SurfaceSnapshot]) {
        obstacleVoices.values.forEach {
            $0.targetVolume    = 0
            $0.targetModIndex  = 0.15
            $0.targetPulseRate = 0.6
        }

        let weights: [Float] = [1.0, 0.30, 0.10]
        for (idx, s) in surfaces.enumerated() {
            guard let voice = obstacleVoices[s.zone] else { continue }
            let w = idx < weights.count ? weights[idx] : weights.last!

            voice.targetVolume    = obstacleVolume(s.depth) * w
            voice.targetModIndex  = obstacleModIndex(s.depth)
            voice.targetPulseRate = obstaclePulseRate(depth: s.depth, velocity: s.velocity)
        }
    }

    /// Silent below 0.20, quadratic ramp to peak at 0.85+.
    private func obstacleVolume(_ d: Float) -> Float {
        let t = max(0, (d - 0.20) / 0.65)
        return peakObstacleVol * t * t
    }

    /// Mod index: 0.15 (near-pure sine) → 0.9 (warm overtones, never metallic).
    private func obstacleModIndex(_ d: Float) -> Float {
        let t = max(0, min(1, (d - 0.15) / 0.70))
        return 0.15 + t * 0.75
    }

    /// Pulse rate: 0.6 Hz (slow breathing) → 5 Hz (alert). Velocity adds up to +1 Hz.
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

        // Direction changed significantly → reset sustain counter
        if abs(best.azimuthFraction - beaconAzimuthEMA) > 0.30 {
            beaconSustainCount = 0
        }

        // Smooth confidence and azimuth
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
        beaconVoice.targetVolume = min(peakBeaconVol, beaconConfEMA * 0.70)
        activePath = smoothed
    }

    // MARK: - Diagnostics

    private func logDiagnostics(surfaces: [SurfaceSnapshot], paths: [ClearPath]) {
        let obs = surfaces.isEmpty ? "(clear)" : surfaces.map { s in
            "\(s.zone) d=\(String(format: "%.2f", s.depth))"
        }.joined(separator: " | ")
        let pth = paths.first.map {
            "beacon \(String(format: "%.0f%%", ($0.azimuthFraction - 0.5) * 100)) conf=\(String(format: "%.2f", $0.confidence))"
        } ?? "(no path)"
        print("[SpatialAudio] \(obs)  \(pth)")
    }
}
