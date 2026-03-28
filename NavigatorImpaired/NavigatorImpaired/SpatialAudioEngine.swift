import AVFoundation
import CoreMotion
import UIKit

// MARK: - Shrine Ping Voice (BOTW-inspired)

/// Emulates the Zelda: Breath of the Wild shrine detector ping.
///
/// Sound design: resonant metallic bell strike with shimmering inharmonic
/// partials, slow LFO amplitude modulation, and a long reverberant tail.
/// Pings repeat at `pingInterval` seconds. The ping gets louder/clearer
/// when the listener faces the source (handled by HRTF positioning).
final class ShrinePingVoice {

    var targetVolume: Float = 0

    /// Seconds between ping onsets.
    var pingInterval: Float = 2.4

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.003

    // Bell partials: fundamental + inharmonic overtones (metallic quality)
    private let partialFreqs: [Float] = [415.30, 831.6, 1038.0, 1245.6, 1661.2, 2076.5]
    private let partialAmps:  [Float] = [1.0,    0.55,  0.35,   0.25,   0.15,   0.08]

    // Each partial has its own decay rate (higher partials die faster)
    private let partialDecays: [Float] = [1.8, 1.4, 1.0, 0.8, 0.6, 0.4]

    private var phases: [Float]
    private var envelopes: [Float]

    // Ping scheduling
    private var samplesSincePing: Int = 0
    private var pingActive: Bool = false

    // Shimmer LFO
    private var lfoPhase: Float = 0
    private let lfoRate: Float = 5.5
    private let lfoDepth: Float = 0.12

    // Sub-bass undertone (the "presence" you feel)
    private var subPhase: Float = 0
    private let subFreq: Float = 103.83
    private var subEnvelope: Float = 0

    // Built-in comb reverb for that cavernous shrine feel
    private var combBuffers: [[Float]]
    private var combIndices: [Int]
    private let combLengths: [Int]
    private let combFeedback: Float = 0.78

    // Low-pass state for warmth
    private var lpState: Float = 0
    private let lpAlpha: Float = 0.42

    init(sampleRate: Float) {
        self.sr = sampleRate
        self.phases = [Float](repeating: 0, count: partialFreqs.count)
        self.envelopes = [Float](repeating: 0, count: partialFreqs.count)

        let lengths = [1583, 1931, 2239, 2591]
        self.combLengths = lengths
        self.combBuffers = lengths.map { [Float](repeating: 0, count: $0) }
        self.combIndices = [Int](repeating: 0, count: lengths.count)

        // Start ready to fire first ping immediately
        self.samplesSincePing = Int(pingInterval * sampleRate)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            // Check if it's time for a new ping
            samplesSincePing += 1
            let intervalSamples = Int(pingInterval * sr)
            if samplesSincePing >= intervalSamples && currentVolume > 0.001 {
                triggerPing()
                samplesSincePing = 0
            }

            // Shimmer LFO
            let lfo = 1.0 + lfoDepth * sinf(2 * .pi * lfoPhase)
            lfoPhase += lfoRate / sr
            if lfoPhase >= 1.0 { lfoPhase -= 1.0 }

            // Additive synthesis of bell partials
            var dry: Float = 0
            for p in 0..<partialFreqs.count {
                guard envelopes[p] > 0.001 else { continue }

                let freq = partialFreqs[p] * lfo
                let osc = sinf(2 * .pi * phases[p])
                    + 0.3 * sinf(4 * .pi * phases[p])  // 2nd harmonic for richness
                dry += osc * partialAmps[p] * envelopes[p]

                phases[p] += freq / sr
                if phases[p] >= 1.0 { phases[p] -= 1.0 }

                // Exponential decay
                let decayPerSample = expf(-1.0 / (partialDecays[p] * sr))
                envelopes[p] *= decayPerSample
            }

            // Sub-bass undertone
            if subEnvelope > 0.001 {
                let sub = sinf(2 * .pi * subPhase) * 0.35 * subEnvelope
                subPhase += subFreq / sr
                if subPhase >= 1.0 { subPhase -= 1.0 }
                dry += sub
                subEnvelope *= expf(-1.0 / (2.2 * sr))
            }

            dry *= currentVolume

            // Low-pass for warmth
            lpState = lpAlpha * dry + (1 - lpAlpha) * lpState

            // Comb reverb (Schroeder-style, long tail for shrine ambience)
            var wet: Float = 0
            for c in 0..<combLengths.count {
                let idx = combIndices[c]
                let delayed = combBuffers[c][idx]
                let mixed = lpState + delayed * combFeedback
                combBuffers[c][idx] = mixed
                combIndices[c] = (idx + 1) % combLengths[c]
                wet += delayed
            }
            wet *= 0.18

            buffer[i] = lpState * 0.65 + wet
        }
    }

    private func triggerPing() {
        // Reset all envelopes to 1.0 (new strike)
        for p in 0..<envelopes.count {
            envelopes[p] = 1.0
            phases[p] = 0
        }
        subEnvelope = 1.0
        subPhase = 0
    }
}

// MARK: - SpatialAudioEngine

/// Spatial audio engine — produces a single BOTW-style shrine detector ping
/// positioned in 3D via HRTF. The ping's apparent direction tracks with head
/// rotation (CMMotionManager yaw updates the listener orientation).
///
/// Callers set a beacon bearing via `setBeaconBearing(_:)` to place the ping
/// in world space. PathFinder logic is retained for future use but does not
/// drive audio output.
@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true

    /// True when a beacon ping is actively placed (navigation target set).
    @Published var beaconActive: Bool = false

    /// The world-space bearing (degrees, 0 = straight ahead at time of
    /// placement, negative = left, positive = right) of the ping target.
    @Published var beaconBearingDegrees: Float = 0

    // PathFinder results kept for future use / UI
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

    private let shrinePing: ShrinePingVoice
    private var shrineNode: AVAudioSourceNode?

    let sightAssistSpeechPlayer = AVAudioPlayerNode()

    let haptics = NavigationHapticEngine()

    let pathFinder = PathFinder()

    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private var trackPhoneOrientation = true

    private let sampleRate: Double = 44100

    // MARK: - Observers

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    private var updateCount = 0

    // MARK: - Init

    init() {
        shrinePing = ShrinePingVoice(sampleRate: Float(sampleRate))
        buildAudioGraph()
        registerSessionObservers()
    }

    deinit {
        [interruptionObserver, routeObserver, foregroundObserver, backgroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// True when the HRTF graph is running.
    var isSpatialPipelineRunning: Bool {
        isEnabled && avEngine.isRunning
    }

    /// Place a beacon ping at a world-space bearing relative to the user's
    /// current forward direction. The ping will be audible from that direction
    /// and will track head rotation automatically via HRTF.
    ///
    /// - Parameter degrees: Bearing in degrees (0 = ahead, -90 = left, +90 = right).
    func setBeaconBearing(_ degrees: Float) {
        beaconBearingDegrees = degrees
        beaconActive = true
        shrinePing.targetVolume = 0.55
        updateShrineNodePosition()
        print("[SpatialAudio] Shrine ping set at \(degrees)°")
    }

    /// Remove the active beacon ping.
    func clearBeacon() {
        beaconActive = false
        shrinePing.targetVolume = 0
        beaconBearingDegrees = 0
        print("[SpatialAudio] Shrine ping cleared")
    }

    /// Called each depth frame. Runs PathFinder (for future use / UI) and
    /// vision detection. Does NOT drive audio — the shrine ping is entirely
    /// bearing-based.
    func applyPerceptionFrame(
        depthMap: [Float],
        width: Int,
        height: Int,
        policyOutput: AudioPolicyOutput
    ) {
        guard isEnabled, avEngine.isRunning else { return }

        // PathFinder scan (retained for UI / future use)
        let wallHint = visionDetector.wallDetected
        let scanResult = pathFinder.scan(depthMap: depthMap, width: width, height: height,
                                         wallHint: wallHint)
        depthProfile = scanResult.profile
        rawPaths = scanResult.paths
        activePath = scanResult.paths.first

        // Haptics (retained)
        if hapticsEnabled {
            haptics.updatePolicy(
                intensity: policyOutput.hapticIntensity,
                speechActive: policyOutput.speechActive
            )
        }

        // Vision state for UI
        detectedPersons = visionDetector.latestPersons
        detectedSceneLabel = visionDetector.latestSceneLabel?.identifier

        // Duck shrine ping during speech
        if beaconActive {
            shrinePing.targetVolume = policyOutput.duckNonSpeech * 0.55
        }

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

    // MARK: - Shrine node positioning

    /// Places the shrine ping source at the beacon bearing in 3D space.
    /// Called when bearing is set and on each motion update.
    private func updateShrineNodePosition() {
        guard beaconActive else { return }
        let rad = beaconBearingDegrees * Float.pi / 180
        let dist: Float = 3.0
        shrineNode?.position = AVAudio3DPoint(
            x: sinf(rad) * dist,
            y: 0,
            z: -cosf(rad) * dist
        )
    }

    // MARK: - Audio graph

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Reverb for spatial depth
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 18

        avEngine.attach(environment)
        avEngine.attach(reverb)
        avEngine.connect(environment, to: reverb, format: nil)
        avEngine.connect(reverb, to: avEngine.mainMixerNode, format: nil)

        if #available(iOS 15, *) { environment.renderingAlgorithm = .HRTFHQ }
        else { environment.renderingAlgorithm = .HRTF }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1.0
        environment.distanceAttenuationParameters.maximumDistance = 20.0
        environment.distanceAttenuationParameters.rolloffFactor = 0.3

        // Shrine ping source node
        let voice = shrinePing
        let node = AVAudioSourceNode(format: mono) { [voice] _, _, frameCount, abl in
            let ptr = UnsafeMutableAudioBufferListPointer(abl)
            if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                voice.render(into: buf, frameCount: Int(frameCount))
            }
            return noErr
        }
        avEngine.attach(node)
        avEngine.connect(node, to: environment, format: mono)
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -3)
        shrineNode = node

        // SightAssist speech player (for AudioOrchestrator HRTF routing)
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
        print("[SpatialAudio] Started — shrine ping beacon")
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
        shrinePing.targetVolume = 0
        beaconActive = false
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
            self.shrinePing.targetVolume = 0
            self.haptics.stop()
            self.avEngine.stop()
            self.motion.stopDeviceMotionUpdates()
        }
    }

    /// Current device heading in radians (from CMAttitude.yaw).
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
