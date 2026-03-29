/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // WebRTC Live streaming integration
  var webrtcSessionVM: WebRTCSessionViewModel?

  weak var navigationController: NavigationController?

  // MARK: - Depth (Core ML, same feed as Gemini)

  @Published var depthFrame: UIImage?
  @Published var depthInferenceEnabled: Bool = false
  @Published var showDepthOverlay: Bool = true
  @Published var depthOverlayOpacity: Double = 0.65
  @Published var depthModelLoaded: Bool = false
  @Published var depthModelError: String?
  @Published var isUpgradingToANE: Bool = false
  @Published var computeLabel: String = ""

  /// Depth inference latency (matches old Depth benchmark stats).
  @Published var depthLatestMs: Double = 0
  @Published var depthAvgMs: Double = 0
  @Published var depthMinMs: Double = .infinity
  @Published var depthMaxMs: Double = 0
  @Published var depthTotalFrames: Int = 0
  @Published var isInRoom: Bool = false

  private let depthEngine = DepthInferenceEngine()
  private var depthInferBusy = false
  private var depthLoadStarted = false

  private let columnDepthEMA = ColumnDepthEMA()
  private let navigationAudioPolicy = NavigationAudioPolicyEngine()
  private let obstacleAnalyzer = ObstacleAnalyzer()
  private let verbalCueController = NavigationVerbalCueController()

  /// Tracks when the last proactive obstacle scan was sent to Gemini.
  private var lastObstacleScanTime: Date = .distantPast
  /// Seconds between proactive obstacle scans. Shorter when a beacon is active.
  private var obstacleScanCooldown: TimeInterval { audioEngine.beaconActive ? 5.0 : 8.0 }

  // MARK: - Spatial Audio
  let audioEngine = SpatialAudioEngine()
  /// Glasses / phone frame source for fall detection and guardian snapshot (`RayBanCameraManager`).
  let rayBanCameraManager = RayBanCameraManager()
  private var depthLatency = LatencyTracker()

  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    setupVideoDecoder()
    attachListeners()
    // Default: glasses mode (phone in pocket). Audio starts when depth inference enables.
    audioEngine.setGlassesMode(true)

    rayBanCameraManager.bind(streamViewModel: self)
    FallDetectionCoordinator.shared.cameraManager = rayBanCameraManager
    AudioOrchestrator.shared.spatialAudioHost = audioEngine
  }

  /// Load Depth Anything model once (background). Call from stream `onAppear`.
  func setDepthInferenceEnabled(_ enabled: Bool) {
    depthInferenceEnabled = enabled
    if enabled {
      if !audioEngine.isEnabled { audioEngine.isEnabled = true }
      if !depthModelLoaded { startDepthModelLoad() }
    } else {
      depthFrame = nil
      resetDepthLatencyStats()
      columnDepthEMA.reset()
      navigationAudioPolicy.reset()
      audioEngine.isEnabled = false
    }
  }

  func resetDepthLatencyStats() {
    depthLatency.reset()
    depthLatestMs = 0
    depthAvgMs = 0
    depthMinMs = .infinity
    depthMaxMs = 0
    depthTotalFrames = 0
  }

  func startDepthModelLoad() {
    guard !depthLoadStarted else { return }
    depthLoadStarted = true
    Task.detached(priority: .userInitiated) { [engine = self.depthEngine] in
      // Phase 1: fast GPU model (~2 s)
      engine.loadFast()
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.depthModelLoaded = engine.isLoaded
        self.depthModelError  = engine.loadError
        self.computeLabel     = engine.computeLabel
      }
      guard engine.isLoaded else { return }
      // Phase 2: ANE hot-swap in background (~55 s first launch only)
      await MainActor.run { [weak self] in self?.isUpgradingToANE = true }
      engine.upgradeToANE()
      await MainActor.run { [weak self] in
        self?.isUpgradingToANE = false
        self?.computeLabel = engine.computeLabel
      }
    }
  }

  private func scheduleDepthInference(on image: UIImage) {
    guard depthInferenceEnabled, depthModelLoaded, !depthInferBusy else { return }
    depthInferBusy = true
    let engine = depthEngine
    Task.detached(priority: .userInitiated) {
      do {
        let (result, ms) = try engine.infer(image: image)
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

          let obstacle: ObstacleAnalysis
          if let nav = self.navigationController {
            obstacle = nav.updatePerception(
              depthMap: result.depthMap,
              width: result.mapWidth,
              height: result.mapHeight,
              persons: self.audioEngine.detectedPersons,
              sceneLabel: self.audioEngine.detectedSceneLabel
            )
          } else {
            obstacle = self.obstacleAnalyzer.analyze(
              depthData: result.depthMap,
              width: result.mapWidth,
              height: result.mapHeight,
              persons: self.audioEngine.detectedPersons,
              sceneLabel: self.audioEngine.detectedSceneLabel
            )
          }

          let columnMeters = self.columnDepthEMA.update(
            depthMap: result.depthMap,
            width: result.mapWidth,
            height: result.mapHeight
          )
          let geminiSpeaking = self.geminiSessionVM?.isModelSpeaking ?? false

          let policyInput = AudioPolicyInput(
            obstacle: obstacle,
            columnDepthsMeters: columnMeters,
            navigationActive: self.navigationController?.isNavigating ?? false,
            guidance: self.navigationController?.currentGuidance,
            geminiSpeaking: geminiSpeaking,
            verbalCueSpeaking: self.verbalCueController.isSpeaking
          )
          let policyOut = self.navigationAudioPolicy.evaluate(policyInput)
          self.audioEngine.applyPerceptionFrame(
            depthMap: result.depthMap,
            width: result.mapWidth,
            height: result.mapHeight,
            policyOutput: policyOut
          )

          // Update shrine ping bearing from GPS navigation guidance
          if let guidance = self.navigationController?.currentGuidance,
             self.navigationController?.isNavigating == true {
            self.audioEngine.setBeaconBearing(Float(guidance.beaconAzimuth))
          }

          self.verbalCueController.process(
            activePath: self.audioEngine.activePath,
            allPaths: self.audioEngine.rawPaths,
            doorDetected: self.audioEngine.visionDetector.doorDetected,
            corridorDetected: self.audioEngine.visionDetector.corridorDetected,
            geminiSpeaking: geminiSpeaking,
            depthProfile: self.audioEngine.depthProfile,
            heading: self.audioEngine.currentHeading
          )
          self.isInRoom = self.verbalCueController.roomDetector.currentState.inRoom

          // Proactive obstacle scan: fire when something is nearby OR a beacon is
          // active (user is walking toward a target and needs to know what's in the way).
          let now = Date()
          let shouldScan = (obstacle.urgency > 0.25 || self.audioEngine.beaconActive)
            && now.timeIntervalSince(self.lastObstacleScanTime) >= self.obstacleScanCooldown
            && !(self.geminiSessionVM?.isModelSpeaking ?? false)
          if shouldScan {
            self.lastObstacleScanTime = now
            self.geminiSessionVM?.sendObstacleScan()
          }

          self.depthLatency.record(ms)
          self.depthLatestMs = ms
          self.depthAvgMs = self.depthLatency.average
          self.depthMinMs = self.depthLatency.min
          self.depthMaxMs = self.depthLatency.max
          self.depthTotalFrames += 1
          self.depthInferBusy = false
        }
      } catch {
        await MainActor.run { [weak self] in self?.depthInferBusy = false }
      }
    }
  }

  /// Switch between glasses and iPhone while already streaming.
  func switchStreamingSource(to target: StreamingMode) async {
    guard isStreaming, target != streamingMode else { return }

    if streamingMode == .iPhone {
      stopIPhoneSessionForSourceSwitch()
    } else {
      await streamSession.stop()
    }

    switch target {
    case .iPhone:
      await handleStartIPhone()
    case .glasses:
      guard hasActiveDevice else {
        showError("No glasses connected. Pair your glasses and try again.")
        return
      }
      streamingMode = .glasses
      await handleStartStreaming()
    }
  }

  /// Stops iPhone capture without forcing `streamingMode` to `.glasses` (caller sets mode next).
  private func stopIPhoneSessionForSourceSwitch() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    depthFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    NSLog("[Stream] iPhone camera stopped (source switch)")
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          self.webrtcSessionVM?.pushVideoFrame(image)
          self.scheduleDepthInference(on: image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachListeners() {
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            self.webrtcSessionVM?.pushVideoFrame(image)
            self.scheduleDepthInference(on: image)
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.currentVideoFrame = image
              if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
              self.webrtcSessionVM?.pushVideoFrame(image)
              self.scheduleDepthInference(on: image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    await streamSession.stop()
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    audioEngine.setGlassesMode(false)
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        self.webrtcSessionVM?.pushVideoFrame(image)
        self.scheduleDepthInference(on: image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    depthFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    audioEngine.isEnabled = false
    audioEngine.setGlassesMode(true)
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      depthFrame = nil
      streamingStatus = .stopped
      audioEngine.isEnabled = false
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is too hot. Let it cool down, then try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
