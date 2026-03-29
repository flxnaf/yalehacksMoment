import ARKit
import AVFoundation
import CoreLocation
import simd
import UIKit

// MARK: - Agent debug NDJSON (session 3d0606)

fileprivate func agentSpatialDebugLog(
  hypothesisId: String,
  location: String,
  message: String,
  data: [String: Any]
) {
  // #region agent log
  let payload: [String: Any] = [
    "sessionId": "3d0606",
    "hypothesisId": hypothesisId,
    "location": location,
    "message": message,
    "data": data,
    "timestamp": Int(Date().timeIntervalSince1970 * 1000),
  ]
  guard JSONSerialization.isValidJSONObject(payload),
        let jsonData = try? JSONSerialization.data(withJSONObject: payload),
        let line = String(data: jsonData, encoding: .utf8)
  else { return }

  // Ingest server (Mac) may mirror to workspace log when reachable (Simulator / same host).
  if let ingest = URL(string: "http://127.0.0.1:7413/ingest/e985fdd7-f511-4f3d-801f-5ddb2436ce45") {
    var req = URLRequest(url: ingest)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("3d0606", forHTTPHeaderField: "X-Debug-Session-Id")
    req.httpBody = jsonData
    URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
  }

  // Primary durable log (always writable): copy this file to repo `.cursor/debug-3d0606.log` for analysis.
  if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
    let p = docs.appendingPathComponent("debug-3d0606.log")
    if !FileManager.default.fileExists(atPath: p.path) {
      FileManager.default.createFile(atPath: p.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: p) {
      defer { try? handle.close() }
      try? handle.seekToEnd()
      handle.write((line + "\n").data(using: .utf8)!)
    }
  }
  NSLog("AGENT_DEBUG_JSON:%@", line)
  // #endregion
}

// MARK: - Sheikah Sensor Voice (BOTW shrine detector)

/// Two short, crisp high-pitched tones ~120ms apart ("ding-ding"),
/// then silence until the next cycle. Pure sine with octave overtone,
/// fast exponential decay, and subtle pitch bend on attack.
final class ShrinePingVoice {

    var targetVolume: Float = 0
    var pingInterval: Float = 2.0 {
        didSet {
            if pingInterval < oldValue {
                samplesSinceCycle = min(samplesSinceCycle, max(0, Int(pingInterval * sr) - 1))
            }
        }
    }

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
            // Gate new cycles on *target* volume so cadence does not stall while `currentVolume` slews up from zero.
            if pingState == .idle && samplesSinceCycle >= Int(pingInterval * sr) && tv > 0.001 {
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
/// Double ding-ding via back-to-back scheduling on the bell player.
/// Ocean fades out within ~1 second when user looks away.
final class ShoreAudioManager {

    var wantsPlay: Bool = false
    private(set) var isPlaying: Bool = false

    private let bellPlayer = AVAudioPlayerNode()
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

        engine.attach(bellPlayer)
        engine.connect(bellPlayer, to: environment, format: bellBuffer?.format ?? mono)
        bellPlayer.renderingAlgorithm = .equalPowerPanning
        bellPlayer.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
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

    /// Schedule the bell file twice back-to-back for "ding-ding".
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
/// **Key design**: The listener stays fixed at the origin facing forward.
/// We **move the source node** to the correct relative position each
/// frame. Direction and distance are derived from ARKit's visual-inertial
/// odometry (6DOF camera tracking), which is rock-solid indoors and out.
/// GPS coordinates serve as an outdoor fallback for distance only.
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

    private let sampleRate: Double = 44100

    private var shrineDistanceEQ: AVAudioUnitEQ?
    private var lastDistanceEQCutoffHz: Float = 20_000

    private let indoorFoundItProximityMeters: Float = 0.5
    private let elevationScale: Float = 0.4

    // MARK: - ARKit waypoint tracking

    /// The ARSession from IPhoneCameraManager.
    var arSession: ARSession?

    /// The waypoint's fixed position in ARKit world space.
    private var waypointWorldPosition: simd_float3?

    /// Deferred beacon: stored when setBeaconBearing is called before any
    /// AR frame has arrived (latestCameraTransform is nil).
    private var pendingBeacon: (degrees: Float, distance: Float)?

    /// GPS coordinate of the beacon (for outdoor distance fallback).
    private var beaconCoordinate: CLLocationCoordinate2D?

    /// Threshold distance to auto-clear the beacon (meters).
    private var arrivalThresholdMeters: Float = 3.0

    /// True when the beacon was set by `setBeacon(atWorldPosition:)` (indoor object finding).
    /// False when set by `setBeaconBearing(_:distanceMeters:)` (outdoor GPS navigation).
    private var beaconIsIndoorObject: Bool = false

    /// When the current beacon was set — used for the indoor 30 s auto-clear timeout.
    private var beaconSetTime: Date = Date()

    /// Depth obstacle scan: brief spatial cue before Gemini TTS.
    private var obstacleFlashUntil: Date?
    private var obstacleFlashBearingDeg: Float?

    /// The latest ARFrame camera transform, updated every frame (~60 fps).
    private var latestCameraTransform: simd_float4x4?

    /// When true, navigation must not overwrite the beacon (`set_ping` / `find_object`).
    private var beaconControlledByUserTools = false

    /// When true, skip auto-clear on arrival (approximate world positions from room scan).
    private var suppressArrivalAutoClear = false

    /// Extra multiplier for shrine ping (navigation ducking near waypoints). Applied with policy duck.
    private var beaconVolumeScale: Float = 1.0

    /// Latest navigation audio policy duck (1 = no duck). Updated from `applyPerceptionFrame` only; AR path multiplies ping volume by this.
    private var lastDuckNonSpeech: Float = 1.0

    /// Hysteresis for on-target shore zone (reduces ping ↔ shore flutter at the boundary).
    private var onTargetZoneLatched: Bool = false
    private let onTargetEnterDegrees: Float = 20
    private let onTargetExitDegrees: Float = 28

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

    /// One-shot: log when AR updates run but no beacon (H3).
    private var agentLoggedNoBeaconYet = false

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

    func setNavigationPingInterval(_ seconds: Float) {
        let clamped = max(0.3, min(5.0, seconds))
        shrinePing.pingInterval = clamped
    }

    /// When true, `StreamSessionViewModel` sets ping cadence from turn-by-turn distance; engine does not override.
    var navigationPingCadenceFromStream = false

    /// True when `set_ping` / `find_object` owns the beacon; turn-by-turn must not overwrite it.
    var isBeaconOwnedByUserTool: Bool { beaconControlledByUserTools }

    /// Glasses / depth path: update head pose when ARKit frames are unavailable (same math as `updateFromARFrame`).
    func updateCameraPose(_ transform: simd_float4x4) {
        latestCameraTransform = transform
        if let pending = pendingBeacon {
            waypointWorldPosition = computeWorldPosition(degrees: pending.degrees, distance: pending.distance, camera: transform)
            pendingBeacon = nil
            print("[SpatialAudio] Deferred beacon placed at \(waypointWorldPosition!) (pose)")
        }
        updateShrineNodePosition(cameraTransform: transform)
    }

    /// Brief spatial ping in the direction of depth-derived obstacle cue (before Gemini TTS).
    func flashObstacleCue(from obstacle: ObstacleAnalysis) {
        guard shrineNode != nil, avEngine.isRunning else { return }
        let deg: Float
        switch obstacle.recommendedDirection {
        case "left": deg = -75
        case "right": deg = 75
        case "stop": deg = 0
        default: deg = 0
        }
        obstacleFlashBearingDeg = deg
        obstacleFlashUntil = Date().addingTimeInterval(0.5)
    }

    func setBeaconVolumeScale(_ scale: Float) {
        beaconVolumeScale = max(0, min(1, scale))
    }

    /// Release user/tool beacon ownership so navigation can drive the ping again (e.g. before `navigate_to`).
    func releaseUserBeaconControlForNavigation() {
        beaconControlledByUserTools = false
        suppressArrivalAutoClear = false
    }

    /// Place the shrine ping at a bearing relative to where the user is
    /// currently facing. 0 = ahead, -90 = left, +90 = right.
    /// `distanceMeters` sets how far away the beacon is (default 10m).
    /// Pass `fromUserTool: true` for `set_ping` so turn-by-turn does not overwrite every frame.
    func setBeaconBearing(_ degrees: Float, distanceMeters: Float = 10, fromUserTool: Bool = false) {
        if fromUserTool {
            beaconControlledByUserTools = true
        } else if beaconControlledByUserTools {
            return
        }

        if !isEnabled {
            isEnabled = true
        }

        beaconIsIndoorObject = false
        beaconBearingDegrees = degrees
        beaconInitialDistance = distanceMeters
        beaconDistanceMeters = distanceMeters
        arrivalThresholdMeters = max(2.0, distanceMeters * 0.2)

        // Place waypoint immediately if we have a camera transform, otherwise defer
        if let cam = latestCameraTransform {
            waypointWorldPosition = computeWorldPosition(degrees: degrees, distance: distanceMeters, camera: cam)
            pendingBeacon = nil
            print("[SpatialAudio] Beacon placed at \(waypointWorldPosition!) (\(distanceMeters)m, \(degrees)° rel)")
        } else {
            waypointWorldPosition = nil
            pendingBeacon = (degrees, distanceMeters)
            print("[SpatialAudio] No camera yet — beacon deferred")
        }

        // GPS coordinate as outdoor fallback
        let compassBearing = Double(Self.wrapAngle360(fusedHeadingDegrees + degrees))
        if let userCoord = LocationManager.shared.currentCoordinate {
            beaconCoordinate = Self.destinationCoordinate(
                from: userCoord,
                bearingDegrees: compassBearing,
                distanceMeters: Double(distanceMeters)
            )
        } else {
            beaconCoordinate = nil
        }

        beaconActive = true
        // Do not reset `beaconVolumeScale` here — `StreamSessionViewModel` / `setBeaconVolumeScale` may have set nav ducking.
        shrinePing.targetVolume = 0.70
        relativeBeaconAngle = degrees
        Self.logBeaconAudioRoute(context: "setBeaconBearing")
    }

    /// Updates turn-by-turn beacon geometry without resetting ping volume or snapping `relativeBeaconAngle`.
    /// Call each depth frame while navigating; use `setBeaconBearing` when first activating the beacon.
    func refreshNavigationBeacon(degrees: Float, distanceMeters: Float) {
        if beaconControlledByUserTools { return }
        guard beaconActive else { return }

        beaconIsIndoorObject = false
        beaconBearingDegrees = degrees
        beaconInitialDistance = distanceMeters
        beaconDistanceMeters = distanceMeters
        arrivalThresholdMeters = max(2.0, distanceMeters * 0.2)

        if let cam = latestCameraTransform {
            waypointWorldPosition = computeWorldPosition(degrees: degrees, distance: distanceMeters, camera: cam)
            pendingBeacon = nil
        } else {
            waypointWorldPosition = nil
            pendingBeacon = (degrees, distanceMeters)
        }

        let compassBearing = Double(Self.wrapAngle360(fusedHeadingDegrees + degrees))
        if let userCoord = LocationManager.shared.currentCoordinate {
            beaconCoordinate = Self.destinationCoordinate(
                from: userCoord,
                bearingDegrees: compassBearing,
                distanceMeters: Double(distanceMeters)
            )
        } else {
            beaconCoordinate = nil
        }
    }

    /// Place the shrine ping at a fixed world position (e.g. from room scan / object map).
    func setBeacon(atWorldPosition position: simd_float3) {
        if !isEnabled {
            isEnabled = true
        }
        beaconControlledByUserTools = true
        suppressArrivalAutoClear = true
        beaconIsIndoorObject = true
        beaconSetTime = Date()
        waypointWorldPosition = position
        pendingBeacon = nil
        beaconActive = true
        beaconVolumeScale = 1
        shrinePing.targetVolume = 0.70
        beaconCoordinate = nil

        if let cam = latestCameraTransform {
            let camPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let dist = simd_length(position - camPos)
            beaconDistanceMeters = dist
            beaconInitialDistance = dist
            arrivalThresholdMeters = max(2.0, dist * 0.2)

            let localPos = cam.inverse * simd_float4(position.x, position.y, position.z, 1)
            let rawAngle = atan2(localPos.x, -localPos.z) * 180 / .pi
            beaconBearingDegrees = Self.wrapAngle(rawAngle)
            relativeBeaconAngle = beaconBearingDegrees
        } else {
            beaconBearingDegrees = 0
            relativeBeaconAngle = 0
        }

        NSLog(
            "[SpatialAudio] Beacon set at world position (%.2f, %.2f, %.2f)",
            position.x, position.y, position.z)
        Self.logBeaconAudioRoute(context: "setBeaconWorldPosition")
    }

    /// Logs output route when a beacon activates so we can confirm stereo vs mono (phone speaker, BT profile).
    private static func logBeaconAudioRoute(context: String) {
        let session = AVAudioSession.sharedInstance()
        let routeDesc = session.currentRoute.outputs.map { out in
            "\(out.portName)|\(out.portType.rawValue)"
        }.joined(separator: ";")
        let outCh = session.outputNumberOfChannels
        let speakerDemo = SettingsManager.shared.speakerOutputEnabled
        NSLog(
            "[SpatialAudio] Beacon route [%@] outputChannels=%d speakerOutput=%@ outputs=%@",
            context, outCh, speakerDemo ? "ON" : "OFF", routeDesc.isEmpty ? "(none)" : routeDesc)
    }

    /// Compute a 3D world position from bearing + distance relative to the camera.
    private func computeWorldPosition(degrees: Float, distance: Float, camera cam: simd_float4x4) -> simd_float3 {
        let camPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let rawFwd = simd_float3(cam.columns.2.x, 0, cam.columns.2.z)
        let forward = -simd_normalize(rawFwd)
        let bearingRad = degrees * .pi / 180
        let cosB = cos(bearingRad), sinB = sin(bearingRad)
        let direction = simd_normalize(simd_float3(
            forward.x * cosB + forward.z * sinB,
            0,
            -forward.x * sinB + forward.z * cosB
        ))
        return camPos + direction * distance
    }

    func clearBeacon() {
        beaconActive = false
        beaconControlledByUserTools = false
        suppressArrivalAutoClear = false
        beaconIsIndoorObject = false
        beaconCoordinate = nil
        waypointWorldPosition = nil
        pendingBeacon = nil
        beaconVolumeScale = 1
        lastDuckNonSpeech = 1.0
        onTargetZoneLatched = false
        shrinePing.targetVolume = 0
        shoreAudio.stop()
        isOnTarget = false
        beaconBearingDegrees = 0
        beaconDistanceMeters = 0
        beaconInitialDistance = 0
        obstacleFlashUntil = nil
        obstacleFlashBearingDeg = nil
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

        // Single source of policy duck; AR path applies `rawPing * lastDuckNonSpeech * beaconVolumeScale`.
        lastDuckNonSpeech = policyOutput.duckNonSpeech

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

    /// Called every AR frame (~60 fps). Always updates — never skips frames.
    func updateFromARFrame(_ frame: ARFrame) {
        let cam = frame.camera.transform
        latestCameraTransform = cam

        // Place deferred beacon on the very first frame
        if let pending = pendingBeacon {
            waypointWorldPosition = computeWorldPosition(degrees: pending.degrees, distance: pending.distance, camera: cam)
            pendingBeacon = nil
            print("[SpatialAudio] Deferred beacon placed at \(waypointWorldPosition!)")
        }

        // Update compass heading for UI (cosmetic)
        let compassHeading = Float(LocationManager.shared.currentHeading)
        if compassHeading > 0 {
            fusedHeadingDegrees = Self.circularEMA(
                current: fusedHeadingDegrees,
                target: compassHeading,
                alpha: 0.05
            )
            fusedHeadingDegrees = Self.wrapAngle360(fusedHeadingDegrees)
        }

        updateShrineNodePosition(cameraTransform: cam)
    }

    private func updateShrineNodePosition(cameraTransform cam: simd_float4x4) {
        let now = Date()
        let flashActive = obstacleFlashUntil.map { now < $0 } ?? false

        // Obstacle scan flash only (no navigation beacon)
        if !beaconActive, flashActive, obstacleFlashBearingDeg != nil {
            let fb = obstacleFlashBearingDeg!
            let rad = fb * Float.pi / 180
            shrineNode?.position = AVAudio3DPoint(x: sinf(rad) * 1.0, y: 0, z: -cosf(rad) * 1.0)
            shrinePing.targetVolume = 0.45 * lastDuckNonSpeech
            shoreAudio.wantsPlay = false
            shoreAudio.update()
            isOnTarget = false
            if let until = obstacleFlashUntil, now >= until {
                obstacleFlashUntil = nil
                obstacleFlashBearingDeg = nil
                shrinePing.targetVolume = 0
            }
            return
        }

        guard beaconActive else {
            relativeBeaconAngle = 0
            shoreAudio.wantsPlay = false
            shoreAudio.update()
            isOnTarget = false
            // #region agent log
            if !agentLoggedNoBeaconYet {
                agentLoggedNoBeaconYet = true
                agentSpatialDebugLog(
                  hypothesisId: "H3",
                  location: "SpatialAudioEngine.updateShrineNodePosition",
                  message: "beacon_inactive_skip_spatial",
                  data: [
                    "beaconActive": false,
                    "avEngineRunning": avEngine.isRunning,
                  ])
            }
            // #endregion
            return
        }

        // --- Project world position into camera-local space ---
        if let wp = waypointWorldPosition {
            let localPos = cam.inverse * simd_float4(wp.x, wp.y, wp.z, 1)
            let rawAngleDeg = Self.wrapAngle(atan2(localPos.x, -localPos.z) * 180 / .pi)
            // Indoor object beacons need slower angle EMA — raw pan was fighting the smoother
            // and made the shrine ping sound like it was thrashing even with a stable world target.
            let angleAlpha: Float = beaconIsIndoorObject ? 0.14 : 0.28
            relativeBeaconAngle = Self.circularEMA(
                current: relativeBeaconAngle,
                target: rawAngleDeg,
                alpha: angleAlpha
            )

            let camPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let dist = simd_length(wp - camPos)
            beaconDistanceMeters += (dist - beaconDistanceMeters) * 0.2

            if !beaconIsIndoorObject && !suppressArrivalAutoClear && beaconDistanceMeters < arrivalThresholdMeters {
                clearBeacon()
                AudioOrchestrator.shared.enqueue("You've arrived.", priority: .hazard)
                return
            } else if beaconIsIndoorObject && beaconDistanceMeters < indoorFoundItProximityMeters {
                clearBeacon()
                AudioOrchestrator.shared.enqueue("Found it.", priority: .hazard)
                return
            } else if beaconIsIndoorObject && Date().timeIntervalSince(beaconSetTime) > 30.0 {
                clearBeacon()
                AudioOrchestrator.shared.enqueue("Found it.", priority: .hazard)
                return
            }
        }

        if !navigationPingCadenceFromStream {
            setNavigationPingInterval(SheikahPinger.sheikahInterval(distanceMeters: beaconDistanceMeters))
        }

        // --- Audio spatialization: distance scale + elevation + horizontal pan ---
        // Use EMA-smoothed relativeBeaconAngle (instant raw pan caused audible jitter).
        let panDeg: Float = {
            if flashActive, let fb = obstacleFlashBearingDeg { return fb }
            return relativeBeaconAngle
        }()

        let rad = panDeg * Float.pi / 180
        var audioScale: Float = 1.0
        var yElev: Float = 0
        var clampedDist: Float = 4.0
        if let wp = waypointWorldPosition {
            let camPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let realDist = simd_length(wp - camPos)
            clampedDist = min(max(realDist, 0.5), 10.0)
            audioScale = 0.5 + (clampedDist / 10.0) * 1.5
            yElev = (wp.y - camPos.y) * elevationScale
        }

        shrineNode?.position = AVAudio3DPoint(
            x: sinf(rad) * audioScale,
            y: yElev,
            z: -cosf(rad) * audioScale
        )

        updateDistanceMuffleEQ(clampedDistanceMeters: clampedDist)

        // --- Shore audio (on-target zone with hysteresis) ---
        let absPan = abs(panDeg)
        if absPan <= onTargetEnterDegrees {
            onTargetZoneLatched = true
        } else if absPan >= onTargetExitDegrees {
            onTargetZoneLatched = false
        }
        shoreAudio.wantsPlay = onTargetZoneLatched
        shoreAudio.update()
        isOnTarget = shoreAudio.isPlaying

        var rawPing: Float = onTargetZoneLatched ? 0 : 0.70
        if flashActive, obstacleFlashBearingDeg != nil {
            rawPing = max(rawPing, 0.55)
        }
        var combined = rawPing * lastDuckNonSpeech * beaconVolumeScale
        if beaconIsIndoorObject {
            combined = shrinePing.targetVolume * 0.78 + combined * 0.22
        }
        shrinePing.targetVolume = combined

        posLogCount += 1
        if posLogCount % 120 == 1 {
            let status = waypointWorldPosition != nil ? "placed" : (pendingBeacon != nil ? "pending" : "none")
            print("[ShrinePos] rel=\(String(format: "%.1f", relativeBeaconAngle))° dist=\(String(format: "%.1f", beaconDistanceMeters))m onTarget=\(onTargetZoneLatched) wp=\(status)")
            // #region agent log
            agentSpatialDebugLog(
              hypothesisId: "H4_H5",
              location: "SpatialAudioEngine.updateShrineNodePosition",
              message: "spatial_ping_tick",
              data: [
                "relativeBeaconAngleDeg": Double(relativeBeaconAngle),
                "beaconDistanceM": Double(beaconDistanceMeters),
                "shrineNodeNil": shrineNode == nil,
                "shrinePingTargetVol": Double(shrinePing.targetVolume),
                "inOnTargetShoreZone": onTargetZoneLatched,
                "waypointStatus": status,
              ])
            // #endregion
        }

        if let until = obstacleFlashUntil, now >= until {
            obstacleFlashUntil = nil
            obstacleFlashBearingDeg = nil
        }
    }

    private func updateDistanceMuffleEQ(clampedDistanceMeters: Float) {
        guard let eq = shrineDistanceEQ, eq.bands.count > 0 else { return }
        let band = eq.bands[0]
        let targetCutoff: Float = clampedDistanceMeters > 3.0
            ? max(800, 20_000 - (clampedDistanceMeters - 3.0) * 2_200)
            : 20_000
        if abs(targetCutoff - lastDistanceEQCutoffHz) < 40 { return }
        lastDistanceEQCutoffHz = targetCutoff
        band.frequency = min(20_000, max(400, targetCutoff))
        band.bypass = targetCutoff >= 19_000
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

        let reverbParams = environment.reverbParameters
        reverbParams.enable = true
        reverbParams.level = -22
        reverbParams.loadFactoryReverbPreset(.smallRoom)

        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .lowPass
        eq.bands[0].frequency = 20_000
        eq.bands[0].bandwidth = 1.0
        eq.bands[0].bypass = true
        avEngine.attach(eq)
        shrineDistanceEQ = eq

        let voice = shrinePing
        let node = AVAudioSourceNode(format: mono) { [voice] _, _, frameCount, abl in
            let ptr = UnsafeMutableAudioBufferListPointer(abl)
            if let buf = ptr.first?.mData?.assumingMemoryBound(to: Float.self) {
                voice.render(into: buf, frameCount: Int(frameCount))
            }
            return noErr
        }
        avEngine.attach(node)
        avEngine.connect(node, to: eq, format: mono)
        avEngine.connect(eq, to: environment, format: mono)
        node.renderingAlgorithm = .equalPowerPanning
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        shrineNode = node

        // #region agent log
        agentSpatialDebugLog(
          hypothesisId: "H1",
          location: "SpatialAudioEngine.buildAudioGraph",
          message: "hrtf_graph_built",
          data: [
            "environmentHRTF": true,
            "shrineNodeAttached": shrineNode != nil,
            "sampleRate": sampleRate,
          ])
        // #endregion

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
        configureSessionIfNeeded()
        if !avEngine.isRunning {
            do {
                try avEngine.start()
            } catch {
                print("[SpatialAudio] Engine start failed: \(error)")
                // #region agent log
                agentSpatialDebugLog(
                  hypothesisId: "H2",
                  location: "SpatialAudioEngine.startEngine",
                  message: "avengine_start_failed",
                  data: ["error": String(describing: error)])
                // #endregion
                isEnabled = false
                return
            }
        }
        // #region agent log
        agentSpatialDebugLog(
          hypothesisId: "H2",
          location: "SpatialAudioEngine.startEngine",
          message: "avengine_running",
          data: [
            "isRunning": avEngine.isRunning,
            "isEnabled": isEnabled,
          ])
        // #endregion
        LocationManager.shared.requestPermissionAndStart()
        fusedHeadingDegrees = Float(LocationManager.shared.currentHeading)
        haptics.start()
        print("[SpatialAudio] Started — ARKit tracking active, heading=\(String(format: "%.0f", fusedHeadingDegrees))°")
    }

    /// Only configure the audio session if it hasn't already been set up
    /// (e.g., by Gemini's AudioManager). Avoids stomping on an active session.
    private func configureSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord {
            print("[SpatialAudio] Session already configured (likely by Gemini), skipping")
            return
        }
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
        beaconVolumeScale = 1
        lastDuckNonSpeech = 1.0
        onTargetZoneLatched = false
        navigationPingCadenceFromStream = false
        obstacleFlashUntil = nil
        obstacleFlashBearingDeg = nil
        lastDistanceEQCutoffHz = 20_000
        shrinePing.pingInterval = 2.0
        shrinePing.targetVolume = 0
        shoreAudio.stop()
        isOnTarget = false
        beaconActive = false
        beaconCoordinate = nil
        waypointWorldPosition = nil
        pendingBeacon = nil
        latestCameraTransform = nil
        activePath = nil
        rawPaths = []
        depthProfile = []
        beaconSustainProgress = 0

        haptics.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.avEngine.stop()
        }
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
                self.configureSessionIfNeeded()
                try? self.avEngine.start()
            }
        }

        routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let session = AVAudioSession.sharedInstance()
            let reasonCode = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let outputs = session.currentRoute.outputs
            let portTypes = outputs.map { $0.portType.rawValue }.joined(separator: ", ")
            NSLog("[SpatialAudio] Route change: reason=%u output: %@", reasonCode, portTypes)

            guard let self, self.isEnabled else { return }
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonCode)
            if reason == .categoryChange || reason == .override {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.isEnabled, !self.avEngine.isRunning else { return }
                    self.configureSessionIfNeeded()
                    try? self.avEngine.start()
                }
            }
        }

        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.avEngine.isRunning else { return }
            self.configureSessionIfNeeded()
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
        }
    }

    // Motion tracking is now handled by ARKit via updateFromARFrame().
    // CMMotionManager is no longer used for waypoint direction.
}
