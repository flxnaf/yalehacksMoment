import SwiftUI
import Combine

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
    @Published var activeSource: CameraSource = .phone
    @Published var glassesStatus: String = "Disconnected"

    let phoneCam = PhoneCameraManager()
    private(set) var glassesCam: GlassesStreamManager?

    private let engine = DepthInferenceEngine()
    private var latency = LatencyTracker()
    private var isInferring = false
    private var cancellables = Set<AnyCancellable>()

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
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.modelLoaded && self.modelError == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if self.modelLoadProgress < 0.85 { self.modelLoadProgress += 0.03 }
            }
        }
        Task.detached(priority: .background) { [engine = self.engine] in
            engine.load()
            await MainActor.run { [weak self] in
                self?.modelLoaded = engine.isLoaded
                self?.modelError = engine.loadError
                self?.modelLoadProgress = engine.isLoaded ? 1.0 : 0
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

        switch source {
        case .phone:
            phoneCam.start()

        case .glasses:
            appVM.configureIfNeeded()
            guard let wearables = appVM.wearables else { return }

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

            Task { await glassesCam?.startStreaming() }
        }
    }

    func stopCurrentSource() {
        switch activeSource {
        case .phone:   phoneCam.stop()
        case .glasses: Task { await glassesCam?.stopStreaming() }
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
                let (depth, ms) = try capturedEngine.infer(image: image)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.depthFrame = depth
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
