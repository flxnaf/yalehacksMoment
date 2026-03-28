import SwiftUI
import Combine
import MWDATCore

@MainActor
class DepthBenchmarkViewModel: ObservableObject {

    @Published var currentFrame: UIImage?
    @Published var depthFrame: UIImage?
    @Published var latestMs: Double = 0
    @Published var avgMs: Double = 0
    @Published var minMs: Double = .infinity
    @Published var maxMs: Double = 0
    @Published var totalFrames: Int = 0
    @Published var inferenceEnabled: Bool = true
    @Published var showDepthOverlay: Bool = true
    @Published var overlayOpacity: Double = 0.65
    @Published var modelLoaded: Bool = false
    @Published var modelError: String?
    @Published var modelLoadProgress: Double = 0
    @Published var isUpgradingToANE: Bool = false
    @Published var computeLabel: String = ""
    @Published var activeSource: CameraSource = .phone
    @Published var glassesStatus: String = "Disconnected"

    let phoneCam = PhoneCameraManager()
    private(set) var glassesCam: GlassesStreamManager?

    let audioEngine = SpatialAudioEngine()

    private let engine = DepthInferenceEngine()
    private var latency = LatencyTracker()
    private var isInferring = false
    private var cancellables = Set<AnyCancellable>()
    /// Serializes stop/start so a delayed `stopStreaming()` cannot run after a new `startStreaming()`.
    private var glassesPipelineTask: Task<Void, Never>?

    init() {
        // Route phone frames into currentFrame
        phoneCam.$currentFrame
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in
                guard let self, self.activeSource == .phone, let frame else { return }
                self.currentFrame = frame
                self.scheduleInference(on: frame)
            }
            .store(in: &cancellables)
    }

    // MARK: - Model loading

    func startModelLoad() {
        // Animate progress bar while waiting.
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.modelLoaded && self.modelError == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if self.modelLoadProgress < 0.85 { self.modelLoadProgress += 0.05 }
            }
        }

        // Phase 1: CPU+GPU — fast (~5 s). User sees depth almost immediately.
        Task.detached(priority: .userInitiated) { [engine = self.engine] in
            engine.loadFast()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.modelLoaded     = engine.isLoaded
                self.modelError      = engine.loadError
                self.computeLabel    = engine.computeLabel
                self.modelLoadProgress = engine.isLoaded ? 1.0 : 0
            }
            guard engine.isLoaded else { return }

            // Phase 2: ANE — hot-swap in background (~55 s, first launch only).
            await MainActor.run { [weak self] in self?.isUpgradingToANE = true }
            engine.upgradeToANE()
            await MainActor.run { [weak self] in
                self?.isUpgradingToANE = false
                self?.computeLabel = engine.computeLabel
            }
        }
    }

    // MARK: - Source switching

    func selectSource(_ source: CameraSource, appVM: AppViewModel) {
        guard source != activeSource else { return }
        stopCurrentSource()
        activeSource = source
        currentFrame = nil
        depthFrame = nil
        resetStats()
        // Phone in pocket when using glasses — listener orientation must not track phone IMU.
        audioEngine.setGlassesMode(source == .glasses)

        switch source {
        case .phone:
            phoneCam.start()

        case .glasses:
            appVM.configureIfNeeded()
            let wearables = appVM.wearables

            if glassesCam == nil {
                let cam = GlassesStreamManager(wearables: wearables)
                glassesCam = cam

                // Route glasses frames into currentFrame
                cam.$currentFrame
                    .receive(on: RunLoop.main)
                    .sink { [weak self] frame in
                        guard let self, self.activeSource == .glasses, let frame else { return }
                        self.currentFrame = frame
                        self.scheduleInference(on: frame)
                    }
                    .store(in: &cancellables)

                cam.$statusText
                    .receive(on: RunLoop.main)
                    .sink { [weak self] status in self?.glassesStatus = status }
                    .store(in: &cancellables)
            }

            beginGlassesStreaming(appVM: appVM)
        }
    }

    /// StreamSession only sees glasses after Meta registration completes (`.registered`).
    private func beginGlassesStreaming(appVM: AppViewModel) {
        switch appVM.registrationState {
        case .registered:
            runGlassesPipeline { [self] in await glassesCam?.startStreaming() }
        case .available:
            glassesStatus = "Sign in with Meta…"
            appVM.connect()
        case .registering:
            glassesStatus = "Connecting to Meta…"
        case .unavailable:
            glassesStatus = "Open Meta AI app and try again"
        }
    }

    /// After OAuth completes (non-registered → registered), start streaming once registration can see the device.
    func onGlassesRegistrationReady() {
        guard activeSource == .glasses, glassesCam != nil else { return }
        runGlassesPipeline { [self] in await glassesCam?.startStreaming() }
    }

    private func runGlassesPipeline(_ work: @escaping @MainActor () async -> Void) {
        let previous = glassesPipelineTask
        glassesPipelineTask = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func stopCurrentSource() {
        switch activeSource {
        case .phone:   phoneCam.stop()
        case .glasses: runGlassesPipeline { [self] in await glassesCam?.stopStreaming() }
        }
    }

    // MARK: - Stats

    func resetStats() {
        latency.reset()
        latestMs = 0; avgMs = 0; minMs = .infinity; maxMs = 0; totalFrames = 0
    }

    // MARK: - Inference

    private func scheduleInference(on image: UIImage) {
        guard inferenceEnabled, !isInferring, engine.isLoaded else { return }
        isInferring = true
        let capturedEngine = engine
        Task.detached(priority: .userInitiated) {
            do {
                let (result, ms) = try capturedEngine.infer(image: image)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.depthFrame = result.colorized
                    self.audioEngine.visionDetector.detectPersons(
                        image: image,
                        depthMap: result.depthMap,
                        depthWidth: result.mapWidth,
                        depthHeight: result.mapHeight
                    )
                    self.audioEngine.visionDetector.classifyScene(image: image)
                    self.audioEngine.update(depthMap: result.depthMap,
                                            width: result.mapWidth,
                                            height: result.mapHeight)
                    self.latency.record(ms)
                    self.latestMs = ms
                    self.avgMs = self.latency.average
                    self.minMs = self.latency.min
                    self.maxMs = self.latency.max
                    self.totalFrames += 1
                    self.isInferring = false
                }
            } catch {
                await MainActor.run { [weak self] in self?.isInferring = false }
            }
        }
    }
}
