import AVFoundation
import CoreLocation
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

// MARK: - Shore Audio Manager (file-based bell + ocean)

/// Plays real audio files (bell_chime.caf, ocean_waves.caf).
/// Bell pitched up +1200 cents (1 octave), double ding-ding via scheduling.
/// Ocean fades out within ~1 second when user looks away.
final class ShoreAudioManager {

    var wantsPlay: Bool = false
    private(set) var isPlaying: Bool = false

    private let bellPlayer = AVAudioPlayerNode()
    private let bellPitch = AVAudioUnitTimePitch()
    private let oceanPlayer = AVAudioPlayerNode()

    private var bellBuffer: AVAudioPCMBuffer?
    private var oceanBuffer: AVAudioPCMBuffer?

    private var oceanVol: Float = 0
    private var bellCooldownFrames: Int = 0
    private let bellRepeatInterval: Int = 44100 * 4
    private var offTargetFrames: Int = 0

    func loadBuffers() {
        bellBuffer = Self.loadCAF(named: "bell_chime")
        oceanBuffer = Self.loadCAF(named: "ocean_waves")
        if bellBuffer == nil { print("[ShoreAudio] ⚠️ bell_chime.caf not found") }
        if oceanBuffer == nil { print("[ShoreAudio] ⚠️ ocean_waves.caf not found") }
    }

    func attach(to engine: AVAudioEngine, environment: AVAudioEnvironmentNode) {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

        bellPitch.pitch = 1200
        bellPitch.rate = 1.0
        engine.attach(bellPlayer)
        engine.attach(bellPitch)
        engine.connect(bellPlayer, to: bellPitch, format: bellBuffer?.format ?? mono)
        engine.connect(bellPitch, to: environment, format: nil)
        bellPlayer.volume = 0.75

        engine.attach(oceanPlayer)
        engine.connect(oceanPlayer, to: environment, format: oceanBuffer?.format ?? mono)
        oceanPlayer.renderingAlgorithm = .equalPowerPanning
        oceanPlayer.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        oceanPlayer.volume = 0
    }

    func update() {
        if wantsPlay && !isPlaying {
            isPlaying = true
            offTargetFrames = 0
            startOceanLoop()
            playDoubleBell()
        }

        if wantsPlay {
            offTargetFrames = 0
        } else {
            offTargetFrames += 1
        }

        let target: Float = wantsPlay ? 0.45 : 0
        let slew: Float = wantsPlay ? 0.03 : 0.06
        oceanVol += (target - oceanVol) * slew
        oceanPlayer.volume = oceanVol

        if isPlaying {
            bellCooldownFrames += 1024
            if bellCooldownFrames >= bellRepeatInterval && wantsPlay {
                playDoubleBell()
                bellCooldownFrames = 0
            }

            if !wantsPlay && offTargetFrames > 60 {
                isPlaying = false
                oceanPlayer.stop()
                bellPlayer.stop()
                oceanVol = 0
                oceanPlayer.volume = 0
            }
        }
    }

    func stop() {
        wantsPlay = false
        isPlaying = false
        oceanPlayer.stop()
        bellPlayer.stop()
        oceanVol = 0
        oceanPlayer.volume = 0
    }

    /// Schedule the bell file twice with a 150ms gap for "ding-ding".
    /// Both at the same pitch (bellPitch handles the octave shift).
    private func playDoubleBell() {
        guard let buf = bellBuffer else { return }
        bellPlayer.stop()
        bellPlayer.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            // Second ding after first finishes — runs on audio thread
        }
        bellPlayer.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        bellPlayer.play()
    }

    private func startOceanLoop() {
        guard let buf = oceanBuffer else { return }
        oceanPlayer.stop()
        oceanPlayer.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        oceanPlayer.play()
    }

    private static func loadCAF(named name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else {
            return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return nil
        }
        try? file.read(into: buffer)
        return buffer
    }
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
/// 1. CLHeading magnetometer compass — absolute anchor, drift-free
/// 2. CMMotionManager gyro deltas — smooth 60 Hz interpolation
@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true

    @Published var beaconActive: Bool = false

    /// The relative bearing Gemini requested (for UI display).
    @Published var beaconBearingDegrees: Float = 0

    /// Current fused heading in degrees (compass-referenced, 0 = north).
    @Published var fusedHeadingDegrees: Float = 0

    /// Smoothed angle of the shrine ping relative to the user's current facing.
    /// 0 = ahead, negative = left, positive = right. Range: -180...180.
    @Published var relativeBeaconAngle: Float = 0

    /// Distance from user to the beacon in meters. Updated every frame.
    @Published var beaconDistanceMeters: Float = 0

    /// The initial distance when the beacon was placed (for UI progress).
    @Published var beaconInitialDistance: Float = 0

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

    private let shoreAudio = ShoreAudioManager()

    /// Whether the on-target shore ambient is currently playing.
    @Published var isOnTarget: Bool = false

    let sightAssistSpeechPlayer = AVAudioPlayerNode()

    let haptics = NavigationHapticEngine()

    let pathFinder = PathFinder()
    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private let sampleRate: Double = 44100

    // MARK: - Head tracking (gyro-relative — no magnetometer for direction)

    /// GPS coordinate of the beacon (for distance only, not direction).
    private var beaconCoordinate: CLLocationCoordinate2D?

    /// Threshold distance to auto-clear the beacon (meters).
    private var arrivalThresholdMeters: Float = 3.0

    // Gyro-relative tracking: the beacon's direction is tracked purely from
    // gyroscope rotation deltas since placement. The magnetometer and GPS are
    // NOT used for direction — only the gyro, which is rock-solid indoors.

    /// The relative angle of the beacon at placement time (degrees).
    private var initialRelativeAngle: Float = 0

    /// The raw gyro yaw (radians) at the moment the beacon was placed.
    private var gyroYawAtPlacement: Double = .nan

    /// Latest raw gyro yaw (radians), updated every frame at 60 Hz.
    private var currentGyroYaw: Double = .nan

    // MARK: - Observers

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    private var updateCount = 0

    // MARK: - Init

    init() {
        shrinePing = ShrinePingVoice(sampleRate: Float(sampleRate))
        shoreAudio.loadBuffers()
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

    /// Heading in radians for legacy callers (verbal cue controller, etc.).
    var currentHeading: Float {
        fusedHeadingDegrees * Float.pi / 180
    }

    /// Place the shrine ping at a bearing relative to where the user is
    /// currently facing. 0 = ahead, -90 = left, +90 = right.
    /// `distanceMeters` sets how far away the beacon is (default 10m).
    func setBeaconBearing(_ degrees: Float, distanceMeters: Float = 10) {
        beaconBearingDegrees = degrees
        beaconInitialDistance = distanceMeters
        beaconDistanceMeters = distanceMeters
        arrivalThresholdMeters = max(2.0, distanceMeters * 0.2)

        // Snapshot gyro yaw at placement. Direction will be tracked
        // purely from gyro rotation deltas — no magnetometer.
        initialRelativeAngle = degrees
        gyroYawAtPlacement = currentGyroYaw

        // GPS coordinate for distance tracking (not direction)
        let compassBearing = Double(Self.wrapAngle360(fusedHeadingDegrees + degrees))
        if let userCoord = LocationManager.shared.currentCoordinate {
            beaconCoordinate = Self.destinationCoordinate(
                from: userCoord,
                bearingDegrees: compassBearing,
                distanceMeters: Double(distanceMeters)
            )
            print("[SpatialAudio] Beacon GPS: \(beaconCoordinate!.latitude), \(beaconCoordinate!.longitude) (\(distanceMeters)m)")
        } else {
            beaconCoordinate = nil
        }
        print("[SpatialAudio] Beacon placed: \(degrees)° relative, gyroYaw=\(String(format: "%.3f", currentGyroYaw))")

        beaconActive = true
        shrinePing.targetVolume = 0.70
        relativeBeaconAngle = degrees
        updateShrineNodePosition()
    }

    func clearBeacon() {
        beaconActive = false
        beaconCoordinate = nil
        shrinePing.targetVolume = 0
        shoreAudio.stop()
        isOnTarget = false
        beaconBearingDegrees = 0
        beaconDistanceMeters = 0
        beaconInitialDistance = 0
        print("[SpatialAudio] Beacon cleared")
    }

    // MARK: - GPS math

    /// Compute destination coordinate given start, bearing, and distance.
    private static func destinationCoordinate(
        from origin: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let brng = bearingDegrees * .pi / 180
        let d = distanceMeters / R

        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1),
                                 cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi,
                                       longitude: lon2 * 180 / .pi)
    }

    /// Bearing in degrees from one coordinate to another (0 = north, CW).
    private static func bearing(from: CLLocationCoordinate2D,
                                to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var b = atan2(y, x) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }

    /// Called each depth frame. Runs PathFinder for UI.
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
            shrinePing.targetVolume = policyOutput.duckNonSpeech * 0.70
        }

        updateCount += 1
    }

    func setGlassesMode(_ glasses: Bool) {
        // Motion tracking stays on regardless — shrine ping needs it
    }

    // MARK: - Shrine node positioning (the core spatial logic)

    private var posLogCount = 0

    /// Normalize any angle into -180...+180.
    private static func wrapAngle(_ a: Float) -> Float {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v < -180 { v += 360 }
        return v
    }

    /// Normalize any angle into 0...360.
    private static func wrapAngle360(_ a: Float) -> Float {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    /// Circular EMA: smoothly interpolates angles, handling the
    /// ±180° wrap-around so the value never snaps across the boundary.
    private static func circularEMA(current: Float, target: Float, alpha: Float) -> Float {
        var diff = target - current
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return wrapAngle(current + diff * alpha)
    }

    private func updateShrineNodePosition() {
        guard beaconActive else {
            relativeBeaconAngle = 0
            shoreAudio.wantsPlay = false
            shoreAudio.update()
            isOnTarget = false
            return
        }

        // --- Direction: gyro-relative + GPS recalibration when walking ---
        if !gyroYawAtPlacement.isNaN && !currentGyroYaw.isNaN {
            var yawDelta = currentGyroYaw - gyroYawAtPlacement
            if yawDelta > .pi { yawDelta -= 2 * .pi }
            if yawDelta < -.pi { yawDelta += 2 * .pi }
            let gyroRelative = initialRelativeAngle + Float(yawDelta * 180.0 / .pi)
            let rawRelative = Self.wrapAngle(gyroRelative)

            relativeBeaconAngle = Self.circularEMA(
                current: relativeBeaconAngle,
                target: rawRelative,
                alpha: 0.25
            )
        }

        // --- GPS: distance + lateral movement correction ---
        if let beaconCoord = beaconCoordinate,
           let userCoord = LocationManager.shared.currentCoordinate {
            let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            let beaconLoc = CLLocation(latitude: beaconCoord.latitude, longitude: beaconCoord.longitude)
            let rawDist = Float(userLoc.distance(from: beaconLoc))
            beaconDistanceMeters += (rawDist - beaconDistanceMeters) * 0.08

            if beaconDistanceMeters < arrivalThresholdMeters {
                clearBeacon()
                AudioOrchestrator.shared.enqueue("You've arrived.", priority: .hazard)
                return
            }

            // When walking, GPS bearing accounts for lateral movement
            // (sidestepping). Gently recalibrate the gyro baseline so
            // the ping shifts to reflect the new geometric angle.
            let speed = LocationManager.shared.currentSpeed
            if speed > 0.5 && !currentGyroYaw.isNaN {
                let gpsBearing = Float(Self.bearing(from: userCoord, to: beaconCoord))
                let compassHeading = Float(LocationManager.shared.currentHeading)
                guard compassHeading > 0 else { return }
                let gpsRelative = Self.wrapAngle(gpsBearing - compassHeading)

                var yawDelta = currentGyroYaw - gyroYawAtPlacement
                if yawDelta > .pi { yawDelta -= 2 * .pi }
                if yawDelta < -.pi { yawDelta += 2 * .pi }
                let gyroRelative = initialRelativeAngle + Float(yawDelta * 180.0 / .pi)

                let correction = Self.wrapAngle(gpsRelative - gyroRelative)
                initialRelativeAngle += correction * 0.03
            }
        }

        // --- Audio spatialization ---
        let rad = relativeBeaconAngle * Float.pi / 180
        let audioDist: Float = 4.0
        shrineNode?.position = AVAudio3DPoint(
            x: sinf(rad) * audioDist, y: 0, z: -cosf(rad) * audioDist
        )

        // --- Shore audio (on-target zone ±20°) ---
        let inZone = abs(relativeBeaconAngle) < 20
        shoreAudio.wantsPlay = inZone
        shoreAudio.update()
        isOnTarget = shoreAudio.isPlaying

        shrinePing.targetVolume = shoreAudio.isPlaying ? 0 : 0.70

        posLogCount += 1
        if posLogCount % 120 == 1 {
            print("[ShrinePos] gyro-rel heading=\(String(format: "%.0f", fusedHeadingDegrees))° rel=\(String(format: "%.1f", relativeBeaconAngle))° dist=\(String(format: "%.1f", beaconDistanceMeters))m zone=\(inZone) shore=\(shoreAudio.isPlaying)")
        }
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
        if #available(iOS 15, *) {
            node.renderingAlgorithm = .HRTFHQ
        } else {
            node.renderingAlgorithm = .HRTF
        }
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -4)
        shrineNode = node

        shoreAudio.attach(to: avEngine, environment: environment)

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
        LocationManager.shared.requestPermissionAndStart()
        fusedHeadingDegrees = Float(LocationManager.shared.currentHeading)
        startMotionTracking()
        haptics.start()
        print("[SpatialAudio] Started — compass + gyro fusion, heading=\(String(format: "%.0f", fusedHeadingDegrees))°")
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let route = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
            print("[SpatialAudio] Session active — outputs: \(route)")
        } catch {
            print("[SpatialAudio] Session configure failed: \(error)")
        }
    }

    private func stopEngine() {
        shrinePing.targetVolume = 0
        shoreAudio.stop()
        isOnTarget = false
        beaconActive = false
        beaconCoordinate = nil
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

    private var motionLogCount = 0

    /// Pure gyroscope tracking at 60 Hz. No magnetometer in the loop —
    /// the beacon direction is computed entirely from gyro rotation deltas
    /// since placement. This is rock-solid indoors where magnetometers fail.
    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else {
            print("[SpatialAudio] DeviceMotion NOT available")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }

            self.currentGyroYaw = att.yaw

            // fusedHeadingDegrees still used for UI compass display
            // (gently pulled toward CLHeading for cosmetic accuracy)
            let compassHeading = Float(LocationManager.shared.currentHeading)
            if compassHeading > 0 {
                self.fusedHeadingDegrees = Self.circularEMA(
                    current: self.fusedHeadingDegrees,
                    target: compassHeading,
                    alpha: 0.03
                )
                self.fusedHeadingDegrees = Self.wrapAngle360(self.fusedHeadingDegrees)
            }

            self.updateShrineNodePosition()

            self.motionLogCount += 1
            if self.motionLogCount % 120 == 1 {
                print("[Heading] gyroYaw=\(String(format: "%.3f", att.yaw)) compass=\(String(format: "%.0f", compassHeading))° beacon=\(self.beaconActive) rel=\(String(format: "%.1f", self.relativeBeaconAngle))°")
            }
        }
        print("[SpatialAudio] Gyro-relative tracking started (60 Hz, no magnetometer)")
    }
}
