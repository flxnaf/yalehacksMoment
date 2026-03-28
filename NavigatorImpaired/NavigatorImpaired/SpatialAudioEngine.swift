import AVFoundation
import CoreMotion
import UIKit

// MARK: - Square ping (one column)

/// 50 ms square-wave bursts at `rateHz`; silence between.
final class SquarePingVoice {

    var enabled: Bool = false
    var volume: Float = 0
    var rateHz: Float = 1
    var freqHz: Float = 400

    private let sr: Float
    private let burstSamples: Int
    private var burstLeft: Int = 0
    private var silenceLeft: Int = 0
    private var phase: Float = 0

    init(sampleRate: Float, staggerIndex: Int) {
        self.sr = sampleRate
        self.burstSamples = max(1, Int(0.05 * sampleRate))
        self.silenceLeft = (staggerIndex * max(1, Int(sampleRate / 25))) % max(1, Int(sampleRate / 2))
    }

    func resetScheduling() {
        burstLeft = 0
        silenceLeft = burstSamples
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            if !enabled || rateHz < 0.05 || volume < 0.001 {
                buffer[i] = 0
                continue
            }
            if burstLeft > 0 {
                phase += 2 * freqHz / sr
                if phase >= 1 { phase -= 1 }
                let sq: Float = phase < 0.5 ? 1 : -1
                buffer[i] = sq * volume
                burstLeft -= 1
            } else {
                buffer[i] = 0
                silenceLeft -= 1
                if silenceLeft <= 0 {
                    burstLeft = burstSamples
                    let periodSamples = Int(sr / max(rateHz, 0.01))
                    silenceLeft = max(0, periodSamples - burstSamples)
                }
            }
        }
    }
}

// MARK: - ChordBeaconVoice

/// Continuous pad-chord beacon — C5 + E5 + G5 with detuned chorus,
/// sub-octave, and built-in Schroeder reverb. Plays when a clear path is
/// sustained; positioned at the gap azimuth via HRTF.
final class ChordBeaconVoice {

    var targetVolume: Float = 0

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.0015

    private let baseFreqs: [Float] = [523.25, 659.25, 783.99]
    private let detune: Float = 1.5
    private var phases: [Float]

    private var lfoPhase: Float = 0
    private let lfoRate:  Float = 3.8
    private let lfoDepth: Float = 0.0035

    private var subPhase: Float = 0
    private let subFreq:  Float = 261.63

    private var lpState: Float = 0
    private let lpAlpha: Float = 0.38

    private var combBuffers: [[Float]]
    private var combIndices: [Int]
    private let combLengths: [Int]
    private let combFeedback: Float = 0.72

    init(sampleRate: Float) {
        self.sr = sampleRate
        self.phases = [Float](repeating: 0, count: 6)
        let lengths = [1117, 1367, 1559, 1801]
        self.combLengths = lengths
        self.combBuffers = lengths.map { [Float](repeating: 0, count: $0) }
        self.combIndices = [Int](repeating: 0, count: lengths.count)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            let lfo = 1.0 + lfoDepth * sinf(2 * .pi * lfoPhase)
            lfoPhase += lfoRate / sr
            if lfoPhase >= 1.0 { lfoPhase -= 1.0 }

            var dry: Float = 0
            for n in 0..<3 {
                let fA = (baseFreqs[n] - detune) * lfo
                let fB = (baseFreqs[n] + detune) * lfo
                let idxA = n * 2
                let idxB = n * 2 + 1

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

            let sub = sinf(2 * .pi * subPhase) * 0.25
            subPhase += subFreq * lfo / sr
            if subPhase >= 1.0 { subPhase -= 1.0 }

            dry = (dry / 3.0 + sub) * currentVolume

            lpState = lpAlpha * dry + (1 - lpAlpha) * lpState

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

/// Spatial audio: obstacle pings (driven by policy) + chord beacon (driven
/// by internal PathFinder sustain/EMA logic from the working earlier version).
@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true

    @Published var activePath: ClearPath? = nil
    @Published var rawPaths: [ClearPath] = []
    @Published var depthProfile: [Float] = []
    @Published var beaconSustainProgress: Float = 0

    @Published var detectedPersons: [PersonDetection] = []
    @Published var detectedSceneLabel: String?

    // MARK: - Audio graph

    private let avEngine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let reverb = AVAudioUnitReverb()

    private let obstacleColumnCount = 6
    private let columnAzimuthDegrees: [Float] = [-35, -21, -7, 7, 21, 35]
    private var obstacleVoices: [SquarePingVoice] = []
    private var obstacleNodes: [AVAudioSourceNode] = []

    private let beaconVoice: ChordBeaconVoice
    private var beaconNode: AVAudioSourceNode?

    let sightAssistSpeechPlayer = AVAudioPlayerNode()

    let haptics = NavigationHapticEngine()

    private let pathFinder = PathFinder()

    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private var trackPhoneOrientation = true

    private let sampleRate: Double = 44100

    // MARK: - Beacon sustain/EMA state (from old working version)

    private let beaconRequiredFrames = 6
    private let peakBeaconVol: Float = 0.40
    private var beaconSustainCount = 0
    private var beaconConfEMA: Float = 0
    private var beaconAzimuthEMA: Float = 0.5

    // MARK: - Observers

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    private var updateCount = 0

    // MARK: - Init

    init() {
        beaconVoice = ChordBeaconVoice(sampleRate: Float(sampleRate))
        buildAudioGraph()
        registerSessionObservers()
    }

    deinit {
        [interruptionObserver, routeObserver, foregroundObserver, backgroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Called each depth frame. Obstacle pings from policy; beacon from internal PathFinder logic.
    func applyPerceptionFrame(
        depthMap: [Float],
        width: Int,
        height: Int,
        policyOutput: AudioPolicyOutput
    ) {
        guard isEnabled, avEngine.isRunning else { return }

        // 1. Path scan + beacon (old working logic)
        let wallHint = visionDetector.wallDetected
        let scanResult = pathFinder.scan(depthMap: depthMap, width: width, height: height,
                                         wallHint: wallHint)
        depthProfile = scanResult.profile
        rawPaths = scanResult.paths
        applyBeacon(scanResult.paths, duck: policyOutput.duckNonSpeech)

        // 2. Obstacle pings (from policy engine)
        let duck = policyOutput.duckNonSpeech
        for i in 0..<obstacleColumnCount {
            let on = policyOutput.obstacleColumnsActive[i]
            obstacleVoices[i].enabled = on
            obstacleVoices[i].volume = policyOutput.obstacleVolume[i] * duck
            obstacleVoices[i].rateHz = policyOutput.obstaclePingRateHz[i]
            obstacleVoices[i].freqHz = policyOutput.obstaclePingFreqHz[i]
            if !on {
                obstacleVoices[i].resetScheduling()
            }
        }

        // 3. Haptics
        if hapticsEnabled {
            haptics.updatePolicy(
                intensity: policyOutput.hapticIntensity,
                speechActive: policyOutput.speechActive
            )
        }

        // 4. Vision state for UI
        detectedPersons = visionDetector.latestPersons
        detectedSceneLabel = visionDetector.latestSceneLabel?.identifier

        updateCount += 1
    }

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

    // MARK: - Beacon sustain/EMA logic (from old working version)

    private func applyBeacon(_ paths: [ClearPath], duck: Float) {
        guard let best = paths.first, best.confidence > 0.08 else {
            beaconSustainCount = max(0, beaconSustainCount - 3)
            beaconConfEMA *= 0.82
            beaconSustainProgress = Float(beaconSustainCount) / Float(beaconRequiredFrames)
            beaconVoice.targetVolume = 0
            activePath = nil
            return
        }

        // If path jumps far from the EMA, snap azimuth to it
        if abs(best.azimuthFraction - beaconAzimuthEMA) > 0.35 {
            beaconAzimuthEMA = best.azimuthFraction
        }

        let alpha: Float = best.confidence > beaconConfEMA ? 0.35 : 0.18
        beaconConfEMA    += alpha * (best.confidence      - beaconConfEMA)
        beaconAzimuthEMA += 0.30  * (best.azimuthFraction - beaconAzimuthEMA)

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
        beaconVoice.targetVolume = min(peakBeaconVol, beaconConfEMA * 0.60) * duck
        activePath = smoothed
    }

    // MARK: - Audio graph

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 6

        avEngine.attach(environment)
        avEngine.attach(reverb)
        avEngine.connect(environment, to: reverb, format: nil)
        avEngine.connect(reverb, to: avEngine.mainMixerNode, format: nil)

        if #available(iOS 15, *) { environment.renderingAlgorithm = .HRTFHQ }
        else { environment.renderingAlgorithm = .HRTF }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1.0
        environment.distanceAttenuationParameters.maximumDistance = 15.0
        environment.distanceAttenuationParameters.rolloffFactor = 0.4

        for i in 0..<obstacleColumnCount {
            let voice = SquarePingVoice(sampleRate: Float(sampleRate), staggerIndex: i)
            obstacleVoices.append(voice)

            let node = AVAudioSourceNode(format: mono) { [voice] _, _, frameCount, abl in
                let ptr = UnsafeMutableAudioBufferListPointer(abl)
                if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                    voice.render(into: buf, frameCount: Int(frameCount))
                }
                return noErr
            }
            avEngine.attach(node)
            avEngine.connect(node, to: environment, format: mono)
            let deg = columnAzimuthDegrees[i] * Float.pi / 180
            let dist: Float = 2.0
            node.position = AVAudio3DPoint(x: -sin(deg) * dist, y: 0, z: -cos(deg) * dist)
            obstacleNodes.append(node)
        }

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
        bNode.position = AVAudio3DPoint(x: 0, y: 0, z: -2)
        beaconNode = bNode

        avEngine.attach(sightAssistSpeechPlayer)
        avEngine.connect(sightAssistSpeechPlayer, to: environment, format: mono)
        sightAssistSpeechPlayer.position = AVAudio3DPoint(x: 0, y: 0, z: -1.0)
        if #available(iOS 15, *) {
            sightAssistSpeechPlayer.renderingAlgorithm = .HRTFHQ
        } else {
            sightAssistSpeechPlayer.renderingAlgorithm = .HRTF
        }
    }

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
        print("[SpatialAudio] Started — chord beacon + column pings")
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
        obstacleVoices.forEach { $0.enabled = false; $0.volume = 0 }
        beaconVoice.targetVolume = 0
        beaconSustainCount = 0
        beaconConfEMA = 0
        activePath = nil
        rawPaths = []
        depthProfile = []
        beaconSustainProgress = 0

        haptics.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.avEngine.stop()
        }
        motion.stopDeviceMotionUpdates()
        pathFinder.reset()
        print("[SpatialAudio] Stopped")
    }

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
            self.configureSession()
            try? self.avEngine.start()
        }

        backgroundObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.obstacleVoices.forEach { $0.enabled = false; $0.volume = 0 }
            self.beaconVoice.targetVolume = 0
            self.haptics.stop()
            self.avEngine.stop()
            self.motion.stopDeviceMotionUpdates()
        }
    }

    /// Current device heading in radians (from CMAttitude.yaw). Read by room detector.
    private(set) var currentHeading: Float = 0

    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }
            self.currentHeading = Float(att.yaw)
            self.environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
                yaw: Float(att.yaw * 180 / .pi),
                pitch: Float(att.pitch * 180 / .pi),
                roll: Float(att.roll * 180 / .pi))
        }
    }
}
