import AVFoundation
import CoreLocation
import CoreMotion
import simd
import UIKit

// MARK: - Sheikah Sensor Voice (BOTW shrine detector)

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
        if wantsPlay { offTargetFrames = 0 } else { offTargetFrames += 1 }

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

    private func playDoubleBell() {
        guard let buf = bellBuffer else { return }
        bellPlayer.stop()
        bellPlayer.scheduleBuffer(buf, at: nil, options: []) { [weak self] in _ = self }
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
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return nil }
        try? file.read(into: buffer)
        return buffer
    }
}

// MARK: - SpatialAudioEngine
//
// Restored from commit 4401cab ("Stabilize beacon with Apple sensor fusion").
// This version tracks heading via Apple's built-in .xMagneticNorthZVertical
// Kalman filter at 60 Hz and calls updateShrineNodePosition() DIRECTLY
// from the motion callback — no Task, no ARKit, no async overhead.

@MainActor
final class SpatialAudioEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? startEngine() : stopEngine() }
    }

    @Published var hapticsEnabled: Bool = true
    @Published var beaconActive: Bool = false
    @Published var beaconBearingDegrees: Float = 0
    @Published var fusedHeadingDegrees: Float = 0
    @Published var relativeBeaconAngle: Float = 0
    @Published var beaconDistanceMeters: Float = 0
    @Published var beaconInitialDistance: Float = 0

    @Published var activePath: ClearPath? = nil
    @Published var rawPaths: [ClearPath] = []
    @Published var depthProfile: [Float] = []
    @Published var beaconSustainProgress: Float = 0

    @Published var detectedPersons: [PersonDetection] = []
    @Published var detectedSceneLabel: String?

    @Published var isOnTarget: Bool = false

    // MARK: - Audio graph

    private let avEngine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()

    private let shrinePing: ShrinePingVoice
    private var shrineNode: AVAudioSourceNode?

    private let shoreAudio = ShoreAudioManager()

    let sightAssistSpeechPlayer = AVAudioPlayerNode()
    let haptics = NavigationHapticEngine()
    let pathFinder = PathFinder()
    let visionDetector = VisionDetector()

    private let motion = CMMotionManager()
    private let sampleRate: Double = 44100

    // MARK: - ARKit world tracking (primary — Snapchat-style anchor)

    weak var cameraManager: IPhoneCameraManager?
    private var waypointWorldPosition: simd_float3?
    private var pendingBeaconRequest: (bearing: Float, distance: Float)?

    // MARK: - GPS fallback (used when ARKit is unavailable)

    private var beaconCoordinate: CLLocationCoordinate2D?
    private var worldBearingOfBeacon: Float = 0
    private var arrivalThresholdMeters: Float = 3.0
    private var smoothedGPSBearing: Float = 0
    private var lockedGPSBearing: Float = 0
    private var isGPSBearingLocked: Bool = false

    /// Extra multiplier for shrine ping (navigation ducking near waypoints). Applied with policy duck.
    private var beaconVolumeScale: Float = 1.0

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
    private var lastRestartAttempt: Date = .distantPast
    private let restartCooldown: TimeInterval = 3.0

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

    var currentHeading: Float {
        fusedHeadingDegrees * Float.pi / 180
    }

    /// Called from StreamSessionViewModel — engine health check + session guard.
    /// Beacon tracking runs independently via CMMotionManager callback.
    func updateCameraTransform(_ cam: Any) {
        guard isEnabled else { return }
        if !avEngine.isRunning {
            throttledRestart(reason: "health check")
        }
    }

    private func throttledRestart(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastRestartAttempt) >= restartCooldown else { return }
        lastRestartAttempt = now
        guard !avEngine.isRunning else { return }
        print("[SpatialAudio] Engine stopped (\(reason)) — attempting restart")
        do {
            try avEngine.start()
            print("[SpatialAudio] Engine restarted OK")
        } catch {
            print("[SpatialAudio] Engine restart FAILED: \(error)")
        }
    }

    func setBeaconBearing(_ degrees: Float, distanceMeters: Float = 10) {
        if !isEnabled { isEnabled = true }

        beaconBearingDegrees = degrees
        beaconInitialDistance = distanceMeters
        beaconDistanceMeters = distanceMeters
        arrivalThresholdMeters = max(2.0, distanceMeters * 0.2)

        // ARKit world placement (primary)
        if let cam = cameraManager {
            let t = cam.latestTransform
            if t != matrix_identity_float4x4 {
                waypointWorldPosition = Self.computeWorldPosition(
                    cameraTransform: t,
                    relativeBearingDeg: degrees,
                    distance: distanceMeters
                )
                pendingBeaconRequest = nil
                print("[SpatialAudio] Beacon placed in ARKit world space at \(waypointWorldPosition!)")
            } else {
                pendingBeaconRequest = (bearing: degrees, distance: distanceMeters)
                waypointWorldPosition = nil
                print("[SpatialAudio] ARKit not ready — beacon deferred")
            }
        } else {
            pendingBeaconRequest = (bearing: degrees, distance: distanceMeters)
            waypointWorldPosition = nil
        }

        // GPS fallback setup
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
        }

        beaconActive = true
        beaconVolumeScale = 1
        shrinePing.targetVolume = 0.70
        updateShrineNodePosition()
    }

    /// Compute a 3D world position given the camera transform and a relative bearing.
    private static func computeWorldPosition(
        cameraTransform t: simd_float4x4,
        relativeBearingDeg: Float,
        distance: Float
    ) -> simd_float3 {
        let camPos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let rawFwd = simd_float2(-t.columns.2.x, -t.columns.2.z)
        let fwdLen = simd_length(rawFwd)
        let fwd = fwdLen > 0.001 ? rawFwd / fwdLen : simd_float2(0, -1)

        let rad = relativeBearingDeg * .pi / 180
        let dir = simd_float2(
            fwd.x * cos(rad) - fwd.y * sin(rad),
            fwd.x * sin(rad) + fwd.y * cos(rad)
        )
        return simd_float3(camPos.x + dir.x * distance, camPos.y, camPos.z + dir.y * distance)
    }

    func clearBeacon() {
        beaconActive = false
        waypointWorldPosition = nil
        pendingBeaconRequest = nil
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

    // MARK: - Depth / perception

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
            shrinePing.targetVolume = policyOutput.duckNonSpeech * 0.70 * beaconVolumeScale
        }

        updateCount += 1
    }

    func setGlassesMode(_ glasses: Bool) {}

    // MARK: - Angle helpers

    private static func wrapAngle(_ a: Float) -> Float {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v < -180 { v += 360 }
        return v
    }

    private static func wrapAngle360(_ a: Float) -> Float {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    private static func circularEMA(current: Float, target: Float, alpha: Float) -> Float {
        var diff = target - current
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return wrapAngle(current + diff * alpha)
    }

    // MARK: - Shrine node positioning (called 60x/sec from motion callback)

    private var posLogCount = 0

    private func updateShrineNodePosition() {
        guard beaconActive else {
            relativeBeaconAngle = 0
            shoreAudio.wantsPlay = false
            shoreAudio.update()
            isOnTarget = false
            return
        }

        // Handle deferred beacon placement
        if waypointWorldPosition == nil, let pending = pendingBeaconRequest,
           let cam = cameraManager {
            let t = cam.latestTransform
            if t != matrix_identity_float4x4 {
                waypointWorldPosition = Self.computeWorldPosition(
                    cameraTransform: t,
                    relativeBearingDeg: pending.bearing,
                    distance: pending.distance
                )
                pendingBeaconRequest = nil
                print("[SpatialAudio] Deferred beacon placed at \(waypointWorldPosition!)")
            }
        }

        var usedARKit = false

        // PRIMARY: ARKit world tracking (Snapchat-style)
        if let wp = waypointWorldPosition, let cam = cameraManager {
            let t = cam.latestTransform
            if t != matrix_identity_float4x4 {
                let camPos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                let fwd3 = simd_float2(-t.columns.2.x, -t.columns.2.z)
                let toBeacon = simd_float2(wp.x - camPos.x, wp.z - camPos.z)
                let bcnLen = simd_length(toBeacon)

                if bcnLen > 0.01 {
                    let fwdN = simd_normalize(fwd3)
                    let bcnN = toBeacon / bcnLen
                    let cross = fwdN.x * bcnN.y - fwdN.y * bcnN.x
                    let dot = simd_dot(fwdN, bcnN)
                    relativeBeaconAngle = atan2(cross, dot) * 180 / .pi
                    beaconDistanceMeters = bcnLen
                    usedARKit = true
                }
            }
        }

        // FALLBACK: compass + GPS bearing
        if !usedARKit {
            var bearingToBeacon: Float = worldBearingOfBeacon

            if let beaconCoord = beaconCoordinate,
               let userCoord = LocationManager.shared.currentCoordinate {
                let speed = LocationManager.shared.currentSpeed
                let rawBearing = Float(Self.bearing(from: userCoord, to: beaconCoord))
                if speed < 0.5 {
                    if !isGPSBearingLocked {
                        lockedGPSBearing = smoothedGPSBearing
                        isGPSBearingLocked = true
                    }
                    bearingToBeacon = lockedGPSBearing
                } else {
                    isGPSBearingLocked = false
                    smoothedGPSBearing = Self.circularEMA(
                        current: smoothedGPSBearing, target: rawBearing, alpha: 0.08
                    )
                    bearingToBeacon = smoothedGPSBearing
                }
                let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                let beaconLoc = CLLocation(latitude: beaconCoord.latitude, longitude: beaconCoord.longitude)
                let rawDist = Float(userLoc.distance(from: beaconLoc))
                beaconDistanceMeters += (rawDist - beaconDistanceMeters) * 0.08
            }
            let rawRelative = Self.wrapAngle(bearingToBeacon - fusedHeadingDegrees)
            relativeBeaconAngle = Self.circularEMA(
                current: relativeBeaconAngle, target: rawRelative, alpha: 0.15
            )
        }

        // GPS arrival detection (works with both modes)
        if let beaconCoord = beaconCoordinate,
           let userCoord = LocationManager.shared.currentCoordinate {
            let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            let beaconLoc = CLLocation(latitude: beaconCoord.latitude, longitude: beaconCoord.longitude)
            let gpsDist = Float(userLoc.distance(from: beaconLoc))
            if gpsDist < arrivalThresholdMeters {
                clearBeacon()
                AudioOrchestrator.shared.enqueue("You've arrived.", priority: .hazard)
                return
            }
        }

        // Audio spatialization
        let rad = relativeBeaconAngle * Float.pi / 180
        let audioDist: Float = 4.0
        shrineNode?.position = AVAudio3DPoint(
            x: sinf(rad) * audioDist, y: 0, z: -cosf(rad) * audioDist
        )

        let inZone = abs(relativeBeaconAngle) < 20
        shoreAudio.wantsPlay = inZone
        shoreAudio.update()
        isOnTarget = shoreAudio.isPlaying
        shrinePing.targetVolume = shoreAudio.isPlaying ? 0 : 0.70

        posLogCount += 1
        if posLogCount % 120 == 1 {
            let mode = usedARKit ? "ARKit" : (beaconCoordinate != nil ? "GPS" : "compass")
            print("[ShrinePos] [\(mode)] rel=\(String(format: "%.1f", relativeBeaconAngle))° dist=\(String(format: "%.1f", beaconDistanceMeters))m wp=\(waypointWorldPosition != nil) engine=\(avEngine.isRunning)")
        }
    }

    // MARK: - Audio graph

    private func buildAudioGraph() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

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
        if #available(iOS 15, *) { node.renderingAlgorithm = .HRTFHQ }
        else { node.renderingAlgorithm = .HRTF }
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -4)
        shrineNode = node

        shoreAudio.attach(to: avEngine, environment: environment)

        avEngine.attach(sightAssistSpeechPlayer)
        avEngine.connect(sightAssistSpeechPlayer, to: environment, format: mono)
        sightAssistSpeechPlayer.position = AVAudio3DPoint(x: 0, y: 0, z: -1.0)
        if #available(iOS 15, *) { sightAssistSpeechPlayer.renderingAlgorithm = .HRTFHQ }
        else { sightAssistSpeechPlayer.renderingAlgorithm = .HRTF }
    }

    // MARK: - Engine lifecycle

    private func startEngine() {
        forceSpatialAudioSession()
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
        print("[SpatialAudio] Started — Apple sensor fusion, heading=\(String(format: "%.0f", fusedHeadingDegrees))°")
    }

    /// Ensure mode=.default for HRTF. Skips entirely if session is already correct
    /// to avoid route-change notification loops and disrupting Gemini.
    private func forceSpatialAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord && session.mode == .default {
            return
        }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
            print("[SpatialAudio] Session reconfigured — outputs: \(route)")
        } catch {
            print("[SpatialAudio] Session configure failed: \(error)")
        }
    }

    private func stopEngine() {
        beaconVolumeScale = 1
        shrinePing.pingInterval = 2.0
        shrinePing.targetVolume = 0
        shoreAudio.stop()
        isOnTarget = false
        beaconActive = false
        waypointWorldPosition = nil
        pendingBeaconRequest = nil
        beaconCoordinate = nil
        activePath = nil
        rawPaths = []
        depthProfile = []
        beaconSustainProgress = 0

        haptics.stop()
        motion.stopDeviceMotionUpdates()

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
                self.throttledRestart(reason: "interruption ended")
            }
        }

        routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.isEnabled, !self.avEngine.isRunning else { return }
                self.throttledRestart(reason: "route change")
            }
        }

        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.throttledRestart(reason: "foreground")
        }

        backgroundObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.shrinePing.targetVolume = 0
            self.haptics.stop()
            self.motion.stopDeviceMotionUpdates()
            self.avEngine.stop()
        }
    }

    // MARK: - Apple sensor fusion (the same approach from commit 4401cab)

    private var motionLogCount = 0

    /// Uses Apple's .xMagneticNorthZVertical which runs an internal Kalman
    /// filter across gyro + accelerometer + magnetometer. Updates at 60 Hz
    /// and calls updateShrineNodePosition() DIRECTLY — no Task, no async.
    private func startMotionTracking() {
        guard motion.isDeviceMotionAvailable else {
            print("[SpatialAudio] DeviceMotion NOT available")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
            guard let self, let att = data?.attitude else { return }

            // Apple's fusion: yaw=0 → magnetic north, increases CCW.
            // Convert to compass: 0=north, increases CW.
            var heading = Float(-att.yaw * 180.0 / .pi)
            heading = Self.wrapAngle360(heading)

            self.fusedHeadingDegrees = Self.circularEMA(
                current: self.fusedHeadingDegrees,
                target: heading,
                alpha: 0.4
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
