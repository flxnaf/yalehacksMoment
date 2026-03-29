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

// MARK: - Shore Ambient Voice (on-target reward sound)

/// High crystal double-chime over ocean wave wash. Once triggered by
/// entering the on-target zone, the full cycle (~3.5s) always plays to
/// completion — even if the user briefly looks away. If still on-target
/// when the cycle ends, it repeats. The voice only truly silences after
/// the current cycle finishes AND the user has left the zone.
final class ShoreAmbientVoice {

    /// true = user is in the on-target zone right now.
    var wantsPlay: Bool = false

    /// Whether a cycle is currently sounding (read by engine to mute shrine).
    private(set) var isPlaying: Bool = false

    private let sr: Float
    private var masterVol: Float = 0
    private let volSlew: Float = 0.004

    // MARK: Bell (crystal chime, high register)

    private enum ChimeState { case idle, ding1, gap, ding2, ring }
    private var chimeState: ChimeState = .idle
    private var chimeSamples: Int = 0
    private var chimeEnv: Float = 0
    private var chimePhases: [Float] = [0, 0, 0, 0]

    // C7, E7, G#7, C8 — bright crystal / wind-chime partials
    private let chimeFreqs: [Float] = [2093.0, 2637.0, 3322.4, 4186.0]
    private let chimeAmps: [Float]  = [1.0,    0.6,    0.35,   0.2]

    private let ding1Len: Int
    private let gapLen: Int
    private let ding2Len: Int
    private let cycleLen: Int
    private var cyclePos: Int = 0

    // MARK: Ocean wave wash (3 bands for realistic surf)

    private var noiseState: UInt32 = 0xDEADBEEF

    private var lpLo: Float = 0   // low rumble  ~100 Hz
    private var lpMid: Float = 0  // mid wash    ~400 Hz
    private var lpHi: Float = 0   // high hiss   ~2 kHz
    private var bpMid: Float = 0

    private var wavePhase: Float = 0
    private let waveHz: Float = 0.13

    init(sampleRate: Float) {
        sr = sampleRate
        ding1Len = Int(0.07 * sampleRate)
        gapLen   = Int(0.11 * sampleRate)
        ding2Len = Int(0.07 * sampleRate)
        cycleLen = Int(3.5 * sampleRate)
    }

    private func startCycle() {
        chimeState = .ding1
        chimeSamples = 0
        chimeEnv = 1.0
        cyclePos = 0
        for j in 0..<chimePhases.count { chimePhases[j] = 0 }
        isPlaying = true
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            let target: Float = isPlaying ? 0.65 : 0
            masterVol += (target - masterVol) * volSlew

            // Start a new cycle if wanted and not currently playing
            if !isPlaying && wantsPlay {
                startCycle()
            }

            var sample: Float = 0

            // --- Ocean wave wash (3-band filtered noise) ---
            if isPlaying {
                let n = nextNoise()
                lpLo  += (n - lpLo) * 0.015          // ~100 Hz LP
                lpMid += (n - lpMid) * 0.06           // ~420 Hz LP
                bpMid = lpMid - lpLo                   // bandpass ~100-420
                lpHi  += (n - lpHi) * 0.18            // ~1.3 kHz LP
                let hiPass = lpHi - lpMid              // bandpass ~420-1300

                wavePhase += waveHz / sr
                if wavePhase >= 1.0 { wavePhase -= 1.0 }

                let phase2 = wavePhase * 0.41 + 0.6
                let crest  = powf(sinf(.pi * wavePhase), 2)          // sharp crest
                let foam   = powf(sinf(.pi * phase2), 2) * 0.5       // secondary foam
                let env    = min(crest + foam, 1.0)

                let wave = lpLo * 0.3 + bpMid * 0.5 + hiPass * 0.4
                sample += wave * env * 0.7

                // --- Double chime ---
                chimeSamples += 1
                cyclePos += 1

                switch chimeState {
                case .idle:
                    if cyclePos >= cycleLen {
                        if wantsPlay {
                            startCycle()
                        } else {
                            isPlaying = false
                        }
                    }
                case .ding1:
                    sample += renderChime(pitchMult: 1.0)
                    chimeEnv *= expf(-5.0 / sr)
                    if chimeSamples >= ding1Len {
                        chimeState = .gap; chimeSamples = 0
                    }
                case .gap:
                    chimeEnv *= 0.96
                    if chimeSamples >= gapLen {
                        chimeState = .ding2; chimeSamples = 0
                        chimeEnv = 0.85
                        for j in 0..<chimePhases.count { chimePhases[j] = 0 }
                    }
                case .ding2:
                    sample += renderChime(pitchMult: 1.19)   // major 3rd up
                    chimeEnv *= expf(-5.5 / sr)
                    if chimeSamples >= ding2Len {
                        chimeState = .ring; chimeSamples = 0
                    }
                case .ring:
                    sample += renderChime(pitchMult: 1.19) * 0.2
                    chimeEnv *= expf(-8.0 / sr)
                    if chimeEnv < 0.001 {
                        chimeState = .idle; chimeEnv = 0
                    }
                }
            }

            buffer[i] = sample * masterVol
        }
    }

    private func renderChime(pitchMult: Float) -> Float {
        var out: Float = 0
        for j in 0..<chimeFreqs.count {
            out += sinf(2 * .pi * chimePhases[j]) * chimeAmps[j]
            chimePhases[j] += (chimeFreqs[j] * pitchMult) / sr
            if chimePhases[j] >= 1.0 { chimePhases[j] -= 1.0 }
        }
        return out * chimeEnv * 0.45
    }

    private func nextNoise() -> Float {
        noiseState = noiseState &* 1664525 &+ 1013904223
        return Float(Int32(bitPattern: noiseState)) / Float(Int32.max)
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

    private let shoreAmbient: ShoreAmbientVoice
    private var shoreNode: AVAudioSourceNode?

    /// Whether the on-target shore ambient is currently playing.
    @Published var isOnTarget: Bool = false

    let sightAssistSpeechPlayer = AVAudioPlayerNode()

    let haptics = NavigationHapticEngine()

    let pathFinder = PathFinder()
    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private let sampleRate: Double = 44100

    // MARK: - Head tracking (compass + gyro fusion)

    /// GPS coordinate of the beacon. Drift-proof anchor.
    private var beaconCoordinate: CLLocationCoordinate2D?

    /// Fallback: compass bearing if GPS isn't available when beacon is placed.
    private var worldBearingOfBeacon: Float = 0

    /// Threshold distance to auto-clear the beacon (meters).
    private var arrivalThresholdMeters: Float = 3.0

    /// Smoothed GPS-derived bearing to beacon (prevents jitter from GPS noise).
    private var smoothedGPSBearing: Float = 0

    /// Frozen GPS bearing used when the user is stationary (speed < threshold).
    /// GPS bearing is only updated when the user is actually moving.
    private var lockedGPSBearing: Float = 0
    private var isGPSBearingLocked: Bool = false

    // (prevGyroYaw removed — Apple's .xMagneticNorthZVertical handles fusion internally)

    // MARK: - Observers

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    private var updateCount = 0

    // MARK: - Init

    init() {
        shrinePing = ShrinePingVoice(sampleRate: Float(sampleRate))
        shoreAmbient = ShoreAmbientVoice(sampleRate: Float(sampleRate))
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

        let worldBearing = Double(Self.wrapAngle360(fusedHeadingDegrees + degrees))
        worldBearingOfBeacon = Float(worldBearing)
        smoothedGPSBearing = Float(worldBearing)
        lockedGPSBearing = Float(worldBearing)
        isGPSBearingLocked = false

        if let userCoord = LocationManager.shared.currentCoordinate {
            beaconCoordinate = Self.destinationCoordinate(
                from: userCoord,
                bearingDegrees: worldBearing,
                distanceMeters: Double(distanceMeters)
            )
            print("[SpatialAudio] Beacon GPS: \(beaconCoordinate!.latitude), \(beaconCoordinate!.longitude) (\(distanceMeters)m at \(String(format: "%.0f", worldBearing))°)")
        } else {
            beaconCoordinate = nil
            print("[SpatialAudio] No GPS — using compass bearing \(String(format: "%.0f", worldBearing))° as fallback")
        }

        beaconActive = true
        shrinePing.targetVolume = 0.70
        updateShrineNodePosition()
    }

    func clearBeacon() {
        beaconActive = false
        beaconCoordinate = nil
        shrinePing.targetVolume = 0
        shoreAmbient.wantsPlay = false
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
            shoreAmbient.wantsPlay = false
            isOnTarget = false
            return
        }

        var bearingToBeacon = Double(worldBearingOfBeacon)
        if let beaconCoord = beaconCoordinate,
           let userCoord = LocationManager.shared.currentCoordinate {

            let rawGPSBearing = Float(Self.bearing(from: userCoord, to: beaconCoord))
            let speed = LocationManager.shared.currentSpeed
            let isMoving = speed > 0.5

            if isMoving {
                // User is walking — GPS positions are reliable. Update bearing.
                smoothedGPSBearing = Self.circularEMA(
                    current: smoothedGPSBearing,
                    target: rawGPSBearing,
                    alpha: 0.15
                )
                lockedGPSBearing = smoothedGPSBearing
                isGPSBearingLocked = false
            } else {
                // User is stationary — GPS jitters wildly. Freeze bearing.
                if !isGPSBearingLocked {
                    lockedGPSBearing = smoothedGPSBearing
                    isGPSBearingLocked = true
                }
            }
            bearingToBeacon = Double(lockedGPSBearing)

            let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            let beaconLoc = CLLocation(latitude: beaconCoord.latitude, longitude: beaconCoord.longitude)
            let rawDist = Float(userLoc.distance(from: beaconLoc))
            beaconDistanceMeters += (rawDist - beaconDistanceMeters) * 0.08

            if beaconDistanceMeters < arrivalThresholdMeters {
                clearBeacon()
                AudioOrchestrator.shared.enqueue("You've arrived.", priority: .hazard)
                return
            }
        }

        let rawRelative = Self.wrapAngle(Float(bearingToBeacon) - fusedHeadingDegrees)

        relativeBeaconAngle = Self.circularEMA(
            current: relativeBeaconAngle,
            target: rawRelative,
            alpha: 0.10
        )

        let rad = relativeBeaconAngle * Float.pi / 180
        let audioDist: Float = 4.0
        let x = sinf(rad) * audioDist
        let z = -cosf(rad) * audioDist

        shrineNode?.position = AVAudio3DPoint(x: x, y: 0, z: z)

        // On-target zone: ±20° triggers the shore chime. Once triggered
        // the full cycle plays out even if the user briefly drifts outside.
        let inZone = abs(relativeBeaconAngle) < 20
        shoreAmbient.wantsPlay = inZone
        let shoreActive = shoreAmbient.isPlaying || inZone
        isOnTarget = shoreActive

        if shoreActive {
            shrinePing.targetVolume = 0
        } else {
            shrinePing.targetVolume = 0.70
        }

        posLogCount += 1
        if posLogCount % 120 == 1 {
            let gpsMode = beaconCoordinate != nil ? "GPS" : "compass"
            let speed = LocationManager.shared.currentSpeed
            let locked = isGPSBearingLocked ? "LOCKED" : "live"
            print("[ShrinePos] [\(gpsMode)|\(locked)] heading=\(String(format: "%.0f", fusedHeadingDegrees))° bearing=\(String(format: "%.0f", bearingToBeacon))° rel=\(String(format: "%.1f", relativeBeaconAngle))° dist=\(String(format: "%.1f", beaconDistanceMeters))m speed=\(String(format: "%.1f", speed))m/s zone=\(inZone) playing=\(shoreAmbient.isPlaying)")
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

        // Shore ambient (on-target reward): centered ahead, non-spatialized so it
        // feels like a gentle ambient wash rather than a point source.
        let shore = shoreAmbient
        let shNode = AVAudioSourceNode(format: mono) { [shore] _, _, frameCount, abl in
            let ptr = UnsafeMutableAudioBufferListPointer(abl)
            if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                shore.render(into: buf, frameCount: Int(frameCount))
            }
            return noErr
        }
        avEngine.attach(shNode)
        avEngine.connect(shNode, to: environment, format: mono)
        shNode.renderingAlgorithm = .equalPowerPanning
        shNode.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        shoreNode = shNode

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
        shoreAmbient.wantsPlay = false
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

    /// Uses Apple's built-in sensor fusion (.xMagneticNorthZVertical) which
    /// runs an internal Kalman filter across gyro + accelerometer + magnetometer.
    /// This is the same heading source ARKit/MapKit use and is far more stable
    /// than a manual complementary filter.
    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else {
            print("[SpatialAudio] DeviceMotion NOT available — falling back to compass only")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }

            // Apple's fusion gives yaw relative to magnetic north.
            // yaw = 0 → magnetic north, increases CCW.
            // Convert to compass convention: 0 = north, increases CW.
            var heading = Float(-att.yaw * 180.0 / .pi)
            heading = Self.wrapAngle360(heading)

            // Smooth heavily to prevent the ping from jittering.
            // Alpha 0.15 ≈ 10-frame lag (~170ms) which feels responsive
            // for head turns but kills magnetometer micro-noise.
            self.fusedHeadingDegrees = Self.circularEMA(
                current: self.fusedHeadingDegrees,
                target: heading,
                alpha: 0.15
            )
            self.fusedHeadingDegrees = Self.wrapAngle360(self.fusedHeadingDegrees)

            self.updateShrineNodePosition()

            self.motionLogCount += 1
            if self.motionLogCount % 120 == 1 {
                let compass = LocationManager.shared.currentHeading
                let speed = LocationManager.shared.currentSpeed
                print("[Heading] fused=\(String(format: "%.0f", self.fusedHeadingDegrees))° apple=\(String(format: "%.0f", heading))° compass=\(String(format: "%.0f", compass))° speed=\(String(format: "%.1f", speed))m/s beacon=\(self.beaconActive) rel=\(String(format: "%.1f", self.relativeBeaconAngle))°")
            }
        }
        print("[SpatialAudio] Apple sensor fusion started (.xMagneticNorthZVertical, 60 Hz)")
    }
}
