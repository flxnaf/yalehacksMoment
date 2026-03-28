import AVFoundation
import CoreMotion
import UIKit

// MARK: - Sheikah Sensor Voice (BOTW shrine detector)

/// Two short, crisp high-pitched tones ~120ms apart ("ding-ding"),
/// then silence until the next cycle. Pure sine with octave overtone,
/// fast exponential decay, and subtle pitch bend on attack.
final class ShrinePingVoice {

    var targetVolume: Float = 0
    var pingInterval: Float = 2.0

    private let sr: Float
    private var currentVolume: Float = 0
    private let slewRate: Float = 0.008

    private var samplesSinceCycle: Int
    private var pingState: PingState = .idle

    private let freq1: Float = 1046.50   // C6
    private let freq2: Float = 1318.51   // E6

    private var phase: Float = 0
    private var envelope: Float = 0

    private let pingDuration: Int
    private let gapBetweenPings: Int
    private var samplesInState: Int = 0

    private enum PingState {
        case idle, ping1, gap, ping2, tail
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

            samplesSinceCycle += 1
            if pingState == .idle && samplesSinceCycle >= Int(pingInterval * sr) && currentVolume > 0.001 {
                pingState = .ping1
                samplesInState = 0
                samplesSinceCycle = 0
                envelope = 1.0
                phase = 0
            }

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
                    pingState = .gap; samplesInState = 0
                }
            case .gap:
                envelope *= 0.95
                samplesInState += 1
                if samplesInState >= gapBetweenPings {
                    pingState = .ping2; samplesInState = 0
                    envelope = 0.85; phase = 0
                }
            case .ping2:
                let freq = freq2 + 30.0 * max(0, 1.0 - Float(samplesInState) / Float(pingDuration))
                sample = renderTone(freq: freq)
                envelope *= expf(-4.0 / sr)
                samplesInState += 1
                if samplesInState >= pingDuration {
                    pingState = .tail; samplesInState = 0
                }
            case .tail:
                sample = renderTone(freq: freq2) * 0.3
                envelope *= expf(-8.0 / sr)
                samplesInState += 1
                if envelope < 0.001 { pingState = .idle; envelope = 0 }
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

// MARK: - DepthRotationEstimator

/// Estimates horizontal rotation from consecutive depth frames by
/// tracking how the depth profile shifts left/right between frames.
/// Works as a supplementary signal to the phone IMU — especially
/// useful when the glasses are the depth source and the phone is
/// in the pocket (IMU tracks pocket, not head).
final class DepthRotationEstimator {

    private var prevProfile: [Float]?

    /// Returns estimated yaw delta in degrees since last call.
    /// Positive = turned right, negative = turned left.
    func estimateYawDelta(profile: [Float]) -> Float {
        guard let prev = prevProfile, prev.count == profile.count, profile.count >= 6 else {
            prevProfile = profile
            return 0
        }
        defer { prevProfile = profile }

        let n = profile.count
        // Cross-correlate prev and current to find the horizontal shift.
        // Search ±25% of the profile width.
        let maxShift = max(1, n / 4)
        var bestShift = 0
        var bestCorr: Float = -.greatestFiniteMagnitude

        for shift in -maxShift...maxShift {
            var corr: Float = 0
            var count = 0
            for i in 0..<n {
                let j = i + shift
                guard j >= 0, j < n else { continue }
                corr += prev[i] * profile[j]
                count += 1
            }
            if count > 0 { corr /= Float(count) }
            if corr > bestCorr {
                bestCorr = corr
                bestShift = shift
            }
        }

        // Convert column shift to degrees.
        // PathFinder uses ~24 columns spanning ~70° FOV.
        let degreesPerColumn: Float = 70.0 / Float(n)
        return Float(bestShift) * degreesPerColumn
    }

    func reset() { prevProfile = nil }
}

// MARK: - SpatialAudioEngine

/// Spatial audio engine with a single BOTW Sheikah Sensor ping.
///
/// **Key design**: Instead of rotating the HRTF listener (which Apple's
/// API doesn't apply strongly enough), we keep the listener fixed at
/// the origin facing forward and **move the source node** to the correct
/// relative position each frame. When you turn right 90°, the source
/// physically moves to x = -dist (hard left in the audio scene).
///
/// Head orientation is fused from:
/// 1. Phone IMU (CMMotionManager) — primary, 60 Hz
/// 2. Depth profile cross-correlation — supplementary, ~10 Hz
@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true

    @Published var beaconActive: Bool = false

    /// World-space bearing where the ping was placed (degrees from
    /// the heading at the moment of placement).
    @Published var beaconBearingDegrees: Float = 0

    /// Current fused heading in degrees (0 = initial forward).
    @Published var fusedHeadingDegrees: Float = 0

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

    private let shrinePing: ShrinePingVoice
    private var shrineNode: AVAudioSourceNode?

    let sightAssistSpeechPlayer = AVAudioPlayerNode()

    let haptics = NavigationHapticEngine()

    let pathFinder = PathFinder()
    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private let sampleRate: Double = 44100

    // MARK: - Head tracking

    /// World-space heading captured at the moment the beacon was placed.
    private var headingAtPlacement: Float = 0

    /// Raw IMU yaw in degrees (cumulative from CMMotionManager).
    private var imuYawDegrees: Float = 0

    /// Depth-based rotation estimator for supplementary tracking.
    private let depthRotation = DepthRotationEstimator()

    /// Accumulated depth-based yaw correction in degrees.
    private var depthYawAccum: Float = 0

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

    /// Place the shrine ping at a bearing relative to where the user is
    /// currently facing. 0 = ahead, -90 = left, +90 = right.
    func setBeaconBearing(_ degrees: Float) {
        headingAtPlacement = fusedHeadingDegrees
        beaconBearingDegrees = degrees
        beaconActive = true
        shrinePing.targetVolume = 0.70
        updateShrineNodePosition()
        print("[SpatialAudio] Shrine ping placed at \(degrees)° from current heading (\(fusedHeadingDegrees)°)")
    }

    func clearBeacon() {
        beaconActive = false
        shrinePing.targetVolume = 0
        beaconBearingDegrees = 0
        print("[SpatialAudio] Shrine ping cleared")
    }

    /// Called each depth frame. Runs PathFinder for UI and feeds the
    /// depth rotation estimator for supplementary head tracking.
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

        // Depth-based rotation: cross-correlate depth profiles
        let depthDelta = depthRotation.estimateYawDelta(profile: scanResult.profile)
        depthYawAccum += depthDelta
        // Blend into fused heading (low weight — IMU is primary)
        fusedHeadingDegrees = imuYawDegrees + depthYawAccum * 0.15

        // Update shrine node position based on new heading
        updateShrineNodePosition()

        if hapticsEnabled {
            haptics.updatePolicy(
                intensity: policyOutput.hapticIntensity,
                speechActive: policyOutput.speechActive
            )
        }

        detectedPersons = visionDetector.latestPersons
        detectedSceneLabel = visionDetector.latestSceneLabel?.identifier

        if beaconActive {
            shrinePing.targetVolume = policyOutput.duckNonSpeech * 0.70
        }

        updateCount += 1
    }

    func setGlassesMode(_ glasses: Bool) {
        // Motion tracking stays on regardless — shrine ping needs it
    }

    // MARK: - Shrine node positioning (the core spatial logic)

    /// Computes where the user has turned since placement, then places
    /// the source node at the correct relative angle so HRTF pans it.
    ///
    /// Example: beacon at 0° (ahead), user turns right 90° →
    /// relative angle = -90° → source at (-dist, 0, 0) = hard left ear.
    private func updateShrineNodePosition() {
        guard beaconActive else { return }

        // World-space angle of the beacon
        let worldAngle = headingAtPlacement + beaconBearingDegrees

        // How much the user has turned since placement
        let relativeAngle = worldAngle - fusedHeadingDegrees

        // Convert to radians for 3D positioning
        let rad = relativeAngle * Float.pi / 180
        let dist: Float = 4.0

        // Place source in listener-relative coordinates:
        // +x = right ear, -x = left ear, -z = forward
        shrineNode?.position = AVAudio3DPoint(
            x: sinf(rad) * dist,
            y: 0,
            z: -cosf(rad) * dist
        )
    }

    // MARK: - Audio graph

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Listener stays fixed at origin, facing forward.
        // We move the SOURCE to pan it — much more reliable than
        // rotating the listener via listenerAngularOrientation.
        avEngine.attach(environment)
        avEngine.connect(environment, to: avEngine.mainMixerNode, format: nil)

        if #available(iOS 15, *) { environment.renderingAlgorithm = .HRTFHQ }
        else { environment.renderingAlgorithm = .HRTF }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 0.5
        environment.distanceAttenuationParameters.maximumDistance = 20.0
        environment.distanceAttenuationParameters.rolloffFactor = 1.0

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
        print("[SpatialAudio] Started — source-movement spatial + IMU + depth rotation")
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .allowBluetooth])
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
        depthRotation.reset()
        depthYawAccum = 0
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

    /// IMU updates at 60 Hz. Each update moves the source node.
    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }
            self.currentHeading = Float(att.yaw)
            self.imuYawDegrees = Float(att.yaw * 180.0 / .pi)
            // Update fused heading (depth correction applied in applyPerceptionFrame)
            self.fusedHeadingDegrees = self.imuYawDegrees + self.depthYawAccum * 0.15
            // Move source node to match new head orientation
            self.updateShrineNodePosition()
        }
    }
}
