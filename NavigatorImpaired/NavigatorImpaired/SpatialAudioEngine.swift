import AVFoundation
import CoreMotion
import UIKit

// MARK: - Sheikah Sensor Voice (BOTW shrine detector)

/// Recreates the Zelda BOTW Sheikah Sensor "ding-ding" double-ping.
///
/// Each ping cycle: two short, crisp high-pitched tones ~120ms apart,
/// then silence until the next cycle. Pure sine fundamentals with a
/// subtle octave overtone for crystalline clarity, fast exponential
/// decay, and a slight pitch bend on attack.
final class ShrinePingVoice {

    var targetVolume: Float = 0

    /// Seconds between double-ping cycles.
    var pingInterval: Float = 2.0

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.008

    // Ping state machine
    private var samplesSinceCycle: Int
    private var pingState: PingState = .idle

    // Two tones: first slightly lower, second slightly higher
    private let freq1: Float = 1046.50   // C6
    private let freq2: Float = 1318.51   // E6

    private var phase: Float = 0
    private var envelope: Float = 0

    // Timing in samples
    private let pingDuration: Int      // ~80ms per ping
    private let gapBetweenPings: Int   // ~120ms gap between first and second
    private var samplesInState: Int = 0

    private enum PingState {
        case idle
        case ping1
        case gap
        case ping2
        case tail
    }

    init(sampleRate: Float) {
        self.sr = sampleRate
        self.pingDuration = Int(0.08 * sampleRate)
        self.gapBetweenPings = Int(0.12 * sampleRate)
        self.samplesSinceCycle = Int(pingInterval * sampleRate)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let tv = targetVolume

        for i in 0..<frameCount {
            currentVolume += (tv - currentVolume) * slewRate

            // Schedule new double-ping cycle
            samplesSinceCycle += 1
            if pingState == .idle && samplesSinceCycle >= Int(pingInterval * sr) && currentVolume > 0.001 {
                pingState = .ping1
                samplesInState = 0
                samplesSinceCycle = 0
                envelope = 1.0
                phase = 0
            }

            // State machine
            var sample: Float = 0
            switch pingState {
            case .idle:
                break

            case .ping1:
                let freq = freq1 + 40.0 * max(0, 1.0 - Float(samplesInState) / Float(pingDuration))
                sample = renderTone(freq: freq)
                envelope *= expf(-3.5 / sr)
                samplesInState += 1
                if samplesInState >= pingDuration {
                    pingState = .gap
                    samplesInState = 0
                }

            case .gap:
                envelope *= 0.95
                samplesInState += 1
                if samplesInState >= gapBetweenPings {
                    pingState = .ping2
                    samplesInState = 0
                    envelope = 0.85
                    phase = 0
                }

            case .ping2:
                let freq = freq2 + 30.0 * max(0, 1.0 - Float(samplesInState) / Float(pingDuration))
                sample = renderTone(freq: freq)
                envelope *= expf(-4.0 / sr)
                samplesInState += 1
                if samplesInState >= pingDuration {
                    pingState = .tail
                    samplesInState = 0
                }

            case .tail:
                sample = renderTone(freq: freq2) * 0.3
                envelope *= expf(-8.0 / sr)
                samplesInState += 1
                if envelope < 0.001 {
                    pingState = .idle
                    envelope = 0
                }
            }

            buffer[i] = sample * currentVolume
        }
    }

    private func renderTone(freq: Float) -> Float {
        let fundamental = sinf(2 * .pi * phase)
        let octave = sinf(4 * .pi * phase) * 0.25
        let result = (fundamental + octave) * envelope

        phase += freq / sr
        if phase >= 1.0 { phase -= 1.0 }

        return result
    }
}

// MARK: - SpatialAudioEngine

/// Spatial audio engine — single BOTW-style Sheikah Sensor double-ping
/// positioned in 3D via HRTF. Head rotation is always tracked via
/// CMMotionManager so the ping direction shifts as the user turns.
///
/// Callers set a beacon bearing via `setBeaconBearing(_:)` to place the
/// ping in world space. PathFinder logic is retained for future use.
@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true

    /// True when a beacon ping is actively placed.
    @Published var beaconActive: Bool = false

    /// World-space bearing in degrees (0 = ahead, -90 = left, +90 = right).
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

    var isSpatialPipelineRunning: Bool {
        isEnabled && avEngine.isRunning
    }

    /// Place the shrine ping at a bearing. 0 = ahead, -90 = left, +90 = right.
    func setBeaconBearing(_ degrees: Float) {
        beaconBearingDegrees = degrees
        beaconActive = true
        shrinePing.targetVolume = 0.65
        updateShrineNodePosition()
        print("[SpatialAudio] Shrine ping at \(degrees)°")
    }

    func clearBeacon() {
        beaconActive = false
        shrinePing.targetVolume = 0
        beaconBearingDegrees = 0
        print("[SpatialAudio] Shrine ping cleared")
    }

    /// Called each depth frame. PathFinder runs for UI; audio is bearing-only.
    func applyPerceptionFrame(
        depthMap: [Float],
        width: Int,
        height: Int,
        policyOutput: AudioPolicyOutput
    ) {
        guard isEnabled, avEngine.isRunning else { return }

        let wallHint = visionDetector.wallDetected
        let scanResult = pathFinder.scan(depthMap: depthMap, width: width, height: height,
                                         wallHint: wallHint)
        depthProfile = scanResult.profile
        rawPaths = scanResult.paths
        activePath = scanResult.paths.first

        if hapticsEnabled {
            haptics.updatePolicy(
                intensity: policyOutput.hapticIntensity,
                speechActive: policyOutput.speechActive
            )
        }

        detectedPersons = visionDetector.latestPersons
        detectedSceneLabel = visionDetector.latestSceneLabel?.identifier

        if beaconActive {
            shrinePing.targetVolume = policyOutput.duckNonSpeech * 0.65
        }

        updateCount += 1
    }

    /// Glasses mode only affects whether depth comes from glasses vs phone.
    /// Motion tracking is ALWAYS on for the shrine ping spatial audio.
    func setGlassesMode(_ glasses: Bool) {
        // Motion tracking stays on regardless — shrine ping needs it
    }

    // MARK: - Shrine node positioning

    private func updateShrineNodePosition() {
        guard beaconActive else { return }
        let rad = beaconBearingDegrees * Float.pi / 180
        let dist: Float = 4.0
        shrineNode?.position = AVAudio3DPoint(
            x: sinf(rad) * dist,
            y: 0,
            z: -cosf(rad) * dist
        )
    }

    // MARK: - Audio graph

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 12

        avEngine.attach(environment)
        avEngine.attach(reverb)
        avEngine.connect(environment, to: reverb, format: nil)
        avEngine.connect(reverb, to: avEngine.mainMixerNode, format: nil)

        if #available(iOS 15, *) { environment.renderingAlgorithm = .HRTFHQ }
        else { environment.renderingAlgorithm = .HRTF }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 0.5
        environment.distanceAttenuationParameters.maximumDistance = 20.0
        environment.distanceAttenuationParameters.rolloffFactor = 0.6

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
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -4)
        shrineNode = node

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
        startMotionTracking()
        haptics.start()
        print("[SpatialAudio] Started — motion tracking + shrine ping")
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
        motion.deviceMotionUpdateInterval = 1.0 / 60
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
