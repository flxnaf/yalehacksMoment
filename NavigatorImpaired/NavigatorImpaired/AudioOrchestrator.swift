import AVFoundation
import UIKit

/// Priority for spoken output: higher values preempt ordering when dequeuing.
enum SpeechPriority: Int, Comparable, CaseIterable {
    case ambient = 0
    case social = 1
    case navigation = 2
    case hazard = 3

    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Queues speech into the same HRTF-HQ spatial graph as navigation when `SpatialAudioEngine` is running;
/// otherwise spins up a dedicated `AVAudioEngine` + `AVAudioEnvironmentNode` graph.
///
/// Uses `AVSpeechSynthesizer.write(_:toBufferCallback:)` so PCM is scheduled on `AVAudioPlayerNode` in 3D space (not plain `speak(_:)` routing).
@MainActor
final class AudioOrchestrator {
    static let shared = AudioOrchestrator()

    /// When set and `isSpatialPipelineRunning`, speech uses `sightAssistSpeechPlayer` on that engine.
    weak var spatialAudioHost: SpatialAudioEngine?

    private struct Item {
        let text: String
        let priority: SpeechPriority
        let sequence: Int
    }

    private var backlog: [Item] = []
    private var nextSequence = 0
    private var isSpeaking = false

    private let speechSynth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.usesApplicationAudioSession = true
        return s
    }()

    private var standaloneEngine: AVAudioEngine?
    private var standalonePlayer: AVAudioPlayerNode?

    private var synthesisFinished = false
    private var buffersPendingPlayback = 0

    /// Bumped on `stopAllSpeech` and each new utterance so TTS `write` / playback callbacks ignore stale work after cancel.
    private var speechSession: UInt64 = 0

    private init() {}

    func enqueue(_ text: String, priority: SpeechPriority) {
        backlog.append(Item(text: text, priority: priority, sequence: nextSequence))
        nextSequence += 1
        if !isSpeaking {
            pump()
        }
    }

    /// Stops spatial speech immediately (e.g. cancel alert).
    func stopAllSpeech() {
        speechSession += 1
        speechSynth.stopSpeaking(at: .immediate)
        spatialAudioHost?.sightAssistSpeechPlayer.stop()
        standalonePlayer?.stop()
        synthesisFinished = false
        buffersPendingPlayback = 0
        isSpeaking = false
        backlog.removeAll()
    }

    private func pump() {
        guard !isSpeaking else { return }
        guard let next = dequeueHighestPriority() else { return }
        isSpeaking = true
        playThroughSpatialPipeline(text: next.text)
    }

    private func dequeueHighestPriority() -> Item? {
        guard !backlog.isEmpty else { return nil }
        let idx = backlog.indices.min { a, b in
            let x = backlog[a], y = backlog[b]
            if x.priority != y.priority { return x.priority.rawValue > y.priority.rawValue }
            return x.sequence < y.sequence
        }!
        return backlog.remove(at: idx)
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func buildStandaloneIfNeeded() {
        guard standaloneEngine == nil else { return }
        let engine = AVAudioEngine()
        let environment = AVAudioEnvironmentNode()
        let reverb = AVAudioUnitReverb()
        let player = AVAudioPlayerNode()

        engine.attach(environment)
        engine.attach(reverb)
        engine.attach(player)
        engine.connect(environment, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.connect(player, to: environment, format: nil)

        if #available(iOS 15, *) {
            environment.renderingAlgorithm = .HRTFHQ
            player.renderingAlgorithm = .HRTFHQ
        } else {
            environment.renderingAlgorithm = .HRTF
            player.renderingAlgorithm = .HRTF
        }
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 18
        player.position = AVAudio3DPoint(x: 0, y: 0, z: -1)

        standaloneEngine = engine
        standalonePlayer = player
    }

    private func resolvePlayer() -> AVAudioPlayerNode {
        if let host = spatialAudioHost, host.isSpatialPipelineRunning {
            return host.sightAssistSpeechPlayer
        }
        buildStandaloneIfNeeded()
        return standalonePlayer!
    }

    @discardableResult
    private func startEngineIfNeeded(for player: AVAudioPlayerNode) -> Bool {
        if let host = spatialAudioHost, host.isSpatialPipelineRunning {
            return true
        }
        buildStandaloneIfNeeded()
        guard let eng = standaloneEngine else { return false }
        if eng.isRunning { return true }
        do {
            try eng.start()
            return true
        } catch {
            return false
        }
    }

    private func playThroughSpatialPipeline(text: String) {
        speechSession += 1
        let session = speechSession

        configureSession()
        let player = resolvePlayer()
        guard startEngineIfNeeded(for: player) else {
            finishCurrentUtterance()
            return
        }

        synthesisFinished = false
        buffersPendingPlayback = 0

        let utterance = AVSpeechUtterance(string: text)
        speechSynth.write(utterance) { [weak self] buffer in
            guard let self else { return }
            Task { @MainActor in
                guard session == self.speechSession else { return }
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    self.scheduleBuffer(pcm, player: player, session: session)
                    return
                }
                self.synthesisFinished = true
                self.tryCompleteUtterance(session: session)
            }
        }
    }

    private func scheduleBuffer(_ pcm: AVAudioPCMBuffer, player: AVAudioPlayerNode, session: UInt64) {
        guard session == speechSession else { return }
        let target = resolvedOutputFormat(for: player)
        let toPlay: AVAudioPCMBuffer
        if formatsMatchForPlayback(pcm.format, target) {
            toPlay = pcm
        } else if let converted = Self.convertPCM(pcm, to: target) {
            toPlay = converted
        } else {
            #if DEBUG
            print("[AudioOrchestrator] PCM convert failed; format in=\(pcm.format) target=\(target)")
            #endif
            buffersPendingPlayback += 1
            buffersPendingPlayback -= 1
            synthesisFinished = true
            tryCompleteUtterance(session: session)
            return
        }

        buffersPendingPlayback += 1
        player.scheduleBuffer(toPlay, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard session == self.speechSession else { return }
                self.buffersPendingPlayback -= 1
                self.tryCompleteUtterance(session: session)
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    /// Player must match the graph (44100 mono Float); TTS often emits 22.05k/24k — without conversion you get chipmunk/noise.
    private func resolvedOutputFormat(for player: AVAudioPlayerNode) -> AVAudioFormat {
        let f = player.outputFormat(forBus: 0)
        if f.sampleRate > 0, f.channelCount > 0 { return f }
        return AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }

    private func formatsMatchForPlayback(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.commonFormat == b.commonFormat
            && abs(a.sampleRate - b.sampleRate) < 0.5
            && a.channelCount == b.channelCount
    }

    private static func convertPCM(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var fed = false
        let block: AVAudioConverterInputBlock = { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        converter.convert(to: output, error: &error, withInputFrom: block)
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func tryCompleteUtterance(session: UInt64) {
        guard session == speechSession else { return }
        guard synthesisFinished && buffersPendingPlayback <= 0 else { return }
        synthesisFinished = false
        buffersPendingPlayback = 0
        finishCurrentUtterance()
    }

    private func finishCurrentUtterance() {
        isSpeaking = false
        pump()
    }
}
