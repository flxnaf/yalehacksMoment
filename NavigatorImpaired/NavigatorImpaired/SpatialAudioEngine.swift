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

// MARK: - Beacon sine pulse

/// 800 Hz sine, 100 ms bursts at ~1 Hz (when `targetVolume` > 0).
final class BeaconSinePulseVoice {

    var targetVolume: Float = 0
    private let sr: Float
    private let burstSamples: Int
    private let beaconFreq: Float = 800
    private var burstLeft: Int = 0
    private var silenceLeft: Int = 0
    private var phase: Float = 0
    private var currentVolume: Float = 0
    private let slew: Float = 0.002

    init(sampleRate: Float) {
        self.sr = sampleRate
        self.burstSamples = max(1, Int(0.10 * sampleRate))
        self.silenceLeft = Int(sampleRate)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            currentVolume += (targetVolume - currentVolume) * slew
            if currentVolume < 0.001 {
                buffer[i] = 0
                continue
            }
            if burstLeft > 0 {
                let s = sinf(2 * .pi * phase) * currentVolume
                phase += beaconFreq / sr
                if phase >= 1 { phase -= 1 }
                buffer[i] = s
                burstLeft -= 1
            } else {
                buffer[i] = 0
                silenceLeft -= 1
                if silenceLeft <= 0 {
                    burstLeft = burstSamples
                    let periodSamples = Int(sr)
                    silenceLeft = max(0, periodSamples - burstSamples)
                }
            }
        }
    }
}

// MARK: - SpatialAudioEngine

/// Spatial audio: up to six discrete obstacle pings + one beacon pulse (HRTF via `AVAudioEnvironmentNode`).
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

    private let beaconVoice: BeaconSinePulseVoice
    private var beaconNode: AVAudioSourceNode?

    /// Front-center HRTF source for `AudioOrchestrator` spatial TTS (`write` pipeline).
    let sightAssistSpeechPlayer = AVAudioPlayerNode()

    let haptics = NavigationHapticEngine()

    private let pathFinder = PathFinder()

    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private var trackPhoneOrientation = true

    private let sampleRate: Double = 44100

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private var updateCount = 0

    // MARK: - Init

    init() {
        beaconVoice = BeaconSinePulseVoice(sampleRate: Float(sampleRate))
        buildAudioGraph()
        registerSessionObservers()
    }

    deinit {
        [interruptionObserver, routeObserver, foregroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Single entry: depth for UI + vision; policy output drives all spatial audio.
    func applyPerceptionFrame(
        depthMap: [Float],
        width: Int,
        height: Int,
        policyOutput: AudioPolicyOutput
    ) {
        guard isEnabled, avEngine.isRunning else { return }

        let scanResult = pathFinder.scan(depthMap: depthMap, width: width, height: height)
        depthProfile = scanResult.profile
        rawPaths = scanResult.paths

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

        if policyOutput.beaconEnabled {
            beaconVoice.targetVolume = policyOutput.beaconVolume * duck
            let deg = Float(policyOutput.beaconAzimuthDegrees)
            let rad = deg * Float.pi / 180
            let dist: Float = 2.0
            beaconNode?.position = AVAudio3DPoint(
                x: -sin(rad) * dist,
                y: 0,
                z: -cos(rad) * dist
            )
        } else {
            beaconVoice.targetVolume = 0
        }

        activePath = scanResult.paths.first

        beaconSustainProgress = policyOutput.beaconEnabled ? 1 : 0

        if hapticsEnabled {
            haptics.updatePolicy(
                intensity: policyOutput.hapticIntensity,
                speechActive: policyOutput.speechActive
            )
        }

        detectedPersons = visionDetector.latestPersons
        detectedSceneLabel = visionDetector.latestSceneLabel?.identifier

        updateCount += 1
        if updateCount % 45 == 1 {
            // debug
        }
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

    // MARK: - Audio graph

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        reverb.loadFactoryPreset(.smallRoom)
        // Light wet — obstacle pings are discrete; heavy reverb smears spatial cues.
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
        print("[SpatialAudio] Started — column pings + beacon pulse")
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
    }

    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }
            self.environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
                yaw: Float(att.yaw * 180 / .pi),
                pitch: Float(att.pitch * 180 / .pi),
                roll: Float(att.roll * 180 / .pi))
        }
    }
}
