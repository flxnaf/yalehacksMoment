/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// Extended with Gemini Live, WebRTC, and optional Depth Anything overlay on the same feed.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel
  @ObservedObject private var guardianAlerts = GuardianAlertManager.shared

  private var depthShow: Bool {
    viewModel.depthInferenceEnabled && viewModel.showDepthOverlay
  }

  var body: some View {
    ZStack {
      Color.black
        .edgesIgnoringSafeArea(.all)

      if webrtcVM.isActive && webrtcVM.connectionState == .connected {
        PiPVideoView(
          localFrame: viewModel.currentVideoFrame,
          remoteVideoTrack: webrtcVM.remoteVideoTrack,
          hasRemoteVideo: webrtcVM.hasRemoteVideo,
          depthFrame: viewModel.depthFrame,
          showDepthOverlay: depthShow,
          depthOpacity: viewModel.depthOverlayOpacity
        )
      } else if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          ZStack {
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()
            if depthShow, let depth = viewModel.depthFrame {
              Image(uiImage: depth)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .opacity(viewModel.depthOverlayOpacity)
                .allowsHitTesting(false)
            }
            if viewModel.depthInferenceEnabled {
              VisionOverlay(
                persons: viewModel.audioEngine.detectedPersons,
                sceneLabel: viewModel.audioEngine.detectedSceneLabel,
                frameSize: geometry.size
              )
              .allowsHitTesting(false)
            }
            if viewModel.isInRoom {
              VStack {
                HStack {
                  Spacer()
                  Text("In Room")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.85))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(.top, 52)
                    .padding(.trailing, 12)
                }
                Spacer()
              }
              .allowsHitTesting(false)
            }
            // AR floating ping marker on the camera feed
            if viewModel.audioEngine.beaconActive {
              ARPingMarker(audioEngine: viewModel.audioEngine, frameSize: geometry.size)
                .allowsHitTesting(false)
            }
          }
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Top status area — compact, no overlaps
      VStack(spacing: 0) {
        // Row 1: Depth stats + ANE badge
        if viewModel.depthInferenceEnabled {
          HStack(alignment: .top, spacing: 8) {
            if viewModel.depthModelLoaded, viewModel.depthModelError == nil {
              depthLatencyStatsCard
            } else if !viewModel.depthModelLoaded, viewModel.depthModelError == nil {
              Text("Loading depth model…")
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
                .padding(8)
                .background(Capsule().fill(Color.black.opacity(0.5)))
            } else if let err = viewModel.depthModelError {
              Text(err)
                .font(.caption2)
                .foregroundColor(.orange)
                .multilineTextAlignment(.trailing)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
            }
            Spacer(minLength: 4)
            aneStatusBadge
          }
          .padding(.bottom, 4)
        }

        // Row 2: Gyro heading + locator bar
        if viewModel.audioEngine.isEnabled {
          PingIndicatorOverlay(audioEngine: viewModel.audioEngine)
            .padding(.bottom, 4)
        }

        if webrtcVM.isActive {
          WebRTCStatusBar(webrtcVM: webrtcVM)
            .padding(.bottom, 4)
        }

        if geminiVM.isGeminiActive {
          GeminiStatusBar(geminiVM: geminiVM)
            .padding(.bottom, 4)
        }

        Spacer()

        // Gemini transcript just above controls
        if geminiVM.isGeminiActive {
          VStack(spacing: 6) {
            if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
              TranscriptView(
                userText: geminiVM.userTranscript,
                aiText: geminiVM.aiTranscript
              )
            }
            ToolCallStatusView(status: geminiVM.toolCallStatus)
            if geminiVM.isModelSpeaking {
              HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                  .foregroundColor(.white)
                  .font(.system(size: 14))
                SpeakingIndicator()
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(Color.black.opacity(0.5))
              .cornerRadius(20)
            }
          }
          .padding(.bottom, 8)
        }

        ControlsView(viewModel: viewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 24)

      // Guardian fall alert overlay
      if guardianAlerts.isCountdownActive {
        Color.black.opacity(0.62)
          .ignoresSafeArea()
        VStack(spacing: 20) {
          Spacer()
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 44))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text("Fall alert countdown")
            .font(.title2.weight(.bold))
            .foregroundColor(.white)
          Text("Tap the button below to cancel.")
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
          Button {
            Task { await guardianAlerts.cancelAlert() }
          } label: {
            Text("Cancel alert")
              .font(.title3.weight(.semibold))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 18)
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .padding(.horizontal, 28)
          .accessibilityLabel("Cancel fall alert")
          .accessibilityHint("Stops the countdown and does not notify your guardian")
          Spacer()
        }
      }
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
        if geminiVM.isGeminiActive {
          geminiVM.stopSession()
        }
        if webrtcVM.isActive {
          webrtcVM.stopSession()
        }
      }
    }
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
    .alert("AI Assistant", isPresented: Binding(
      get: { geminiVM.errorMessage != nil },
      set: { if !$0 { geminiVM.errorMessage = nil } }
    )) {
      Button("OK") { geminiVM.errorMessage = nil }
    } message: {
      Text(geminiVM.errorMessage ?? "")
    }
    .alert("Live Stream", isPresented: Binding(
      get: { webrtcVM.errorMessage != nil },
      set: { if !$0 { webrtcVM.errorMessage = nil } }
    )) {
      Button("OK") { webrtcVM.errorMessage = nil }
    } message: {
      Text(webrtcVM.errorMessage ?? "")
    }
  }

  #if DEBUG
  /// Visible panel so Debug builds can exercise guardian / SOS without physical falls.
  private var sightAssistTestPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "figure.fall.circle.fill")
          .font(.title2)
          .foregroundStyle(.cyan)
        Text("SightAssist — test")
          .font(.subheadline.weight(.semibold))
          .foregroundColor(.white)
      }

      Text(
        "Fall detection runs in the background. Test SOS runs the full countdown and send pipeline; Cancel stops an active countdown."
      )
      .font(.caption)
      .foregroundColor(.white.opacity(0.88))
      .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 8) {
        Button {
          FallDetectionCoordinator.shared.triggerManualSOS()
        } label: {
          Label("Test SOS / guardian alert", systemImage: "sos")
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)

        Button {
          FallDetectionCoordinator.shared.handleDoubleTap()
        } label: {
          Text("Cancel countdown")
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(14)
    .frame(maxWidth: 400)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.cyan.opacity(0.45), lineWidth: 1)
    )
  }
  #endif

  // MARK: - Depth latency (same layout as DepthBenchmarkView statsCard)

  private var depthLatencyStatsCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Depth (ms)")
          .font(.caption2)
          .foregroundColor(.white.opacity(0.55))
        Spacer()
        if viewModel.depthTotalFrames > 0 {
          Button {
            viewModel.resetDepthLatencyStats()
          } label: {
            Image(systemName: "arrow.counterclockwise")
              .font(.caption2)
              .foregroundColor(.white.opacity(0.7))
          }
        }
      }
      if viewModel.depthTotalFrames == 0 {
        HStack(spacing: 6) {
          ProgressView().scaleEffect(0.7).tint(.white)
          Text("Waiting for frames…")
            .foregroundColor(.white.opacity(0.7))
        }
        .font(.caption)
      } else {
        depthStatRow("Now", viewModel.depthLatestMs)
        depthStatRow("Avg", viewModel.depthAvgMs)
        depthStatRow("Min", viewModel.depthMinMs)
        depthStatRow("Max", viewModel.depthMaxMs)
        Text("Frames: \(viewModel.depthTotalFrames)")
          .foregroundColor(.white.opacity(0.6))
          .font(.caption2)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Top bar: compute/ANE status

  private var aneStatusBadge: some View {
    Group {
      if viewModel.isUpgradingToANE {
        Text("⚡ Upgrading to ANE…")
          .font(.caption2)
          .foregroundColor(.orange)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Capsule().fill(Color.black.opacity(0.5)))
      } else if !viewModel.computeLabel.isEmpty && viewModel.depthModelLoaded {
        Text(viewModel.computeLabel)
          .font(.caption2)
          .foregroundColor(.white.opacity(0.7))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Capsule().fill(Color.black.opacity(0.4)))
      }
    }
  }

  private func depthStatRow(_ label: String, _ value: Double) -> some View {
    HStack(spacing: 4) {
      Text(label)
        .foregroundColor(.white.opacity(0.6))
        .frame(width: 28, alignment: .leading)
      if value.isInfinite {
        Text("—")
          .foregroundColor(.white.opacity(0.5))
          .font(.system(.caption, design: .monospaced))
      } else {
        Text(String(format: "%.1f ms", value))
          .foregroundColor(value < 40 ? .green : value < 80 ? .yellow : .red)
          .fontWeight(.semibold)
      }
    }
    .font(.system(.caption, design: .monospaced))
  }
}

// MARK: - Clear Path Panel

struct ClearPathPanel: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  private var audioVM: SpatialAudioEngine { viewModel.audioEngine }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("CLEAR PATH")
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundColor(.white.opacity(0.5))
        Spacer()
        statusLabel
      }

      // Sustain progress dots
      HStack(spacing: 4) {
        ForEach(0..<18, id: \.self) { i in
          let filled = Float(i) < audioVM.beaconSustainProgress * 18
          Circle()
            .fill(filled ? Color.green : Color.white.opacity(0.15))
            .frame(width: 5, height: 5)
        }
      }

      // Azimuth bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.1))
            .frame(height: 8)

          // Raw path candidates
          ForEach(audioVM.rawPaths.prefix(4), id: \.azimuthFraction) { path in
            Circle()
              .fill(Color.yellow.opacity(0.7))
              .frame(width: 6, height: 6)
              .offset(x: CGFloat(path.azimuthFraction) * geo.size.width - 3, y: 1)
          }

          // Active path
          if let active = audioVM.activePath {
            RoundedRectangle(cornerRadius: 2)
              .fill(Color.green)
              .frame(width: 10, height: 8)
              .offset(x: CGFloat(active.azimuthFraction) * geo.size.width - 5)
          }
        }
      }
      .frame(height: 8)

      // Zone labels
      HStack {
        Text("L").font(.system(size: 8, design: .monospaced)).foregroundColor(.white.opacity(0.35))
        Spacer()
        Text("C").font(.system(size: 8, design: .monospaced)).foregroundColor(.white.opacity(0.35))
        Spacer()
        Text("R").font(.system(size: 8, design: .monospaced)).foregroundColor(.white.opacity(0.35))
      }
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private var statusLabel: some View {
    if audioVM.activePath != nil {
      Text("● CLEAR")
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(.green)
    } else if audioVM.beaconSustainProgress > 0 {
      Text("● BUILDING…")
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundColor(.yellow)
    } else {
      Text("○ NONE")
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.white.opacity(0.4))
    }
  }
}

// MARK: - Ping Indicator (Gyro HUD + Minecraft-style locator)

/// Inline component (NOT absolute-positioned). Shows:
/// 1. Gyro heading compass (always)
/// 2. Minecraft-style locator bar (when beacon active)
///
/// Minecraft behavior: the marker represents a fixed point in the world.
/// When the target is in your FOV (~±90°), the marker slides to show
/// its position. When it's behind you, it pins to the left/right edge
/// with a chevron — it NEVER wraps around or goes off-screen.
struct PingIndicatorOverlay: View {
  @ObservedObject var audioEngine: SpatialAudioEngine

  private var angle: Float { audioEngine.relativeBeaconAngle }

  var body: some View {
    VStack(spacing: 6) {
      // Gyro heading row
      HStack(spacing: 10) {
        // Mini compass
        ZStack {
          Circle()
            .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
            .frame(width: 36, height: 36)
          Rectangle()
            .fill(Color.white.opacity(0.4))
            .frame(width: 1, height: 5)
            .offset(y: -15.5)
          Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: 12)
            .offset(y: -6)
            .rotationEffect(.degrees(Double(-audioEngine.fusedHeadingDegrees)))
          Circle()
            .fill(Color.white.opacity(0.5))
            .frame(width: 3, height: 3)
        }

        VStack(alignment: .leading, spacing: 1) {
          Text("GYRO")
            .font(.system(size: 7, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
          Text(String(format: "%.0f°", audioEngine.fusedHeadingDegrees))
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
        }

        Spacer()

        if audioEngine.beaconActive {
          VStack(alignment: .trailing, spacing: 1) {
            Text(directionLabel)
              .font(.system(size: 9, weight: .bold, design: .monospaced))
              .foregroundColor(isOnTarget ? .green : .white.opacity(0.6))
            HStack(spacing: 6) {
              Text(String(format: "%.0f°", angle))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(isOnTarget ? .green : .cyan)
              Text(distanceLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            }
          }
        }
      }

      // Locator bar (only when beacon is active)
      if audioEngine.beaconActive {
        locatorBar
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.5)))
  }

  private var isOnTarget: Bool { abs(angle) < 10 }
  private var isInFront: Bool { abs(angle) <= 90 }

  /// Minecraft-style: FOV is ±90°. In-FOV targets map linearly onto
  /// the bar. Out-of-FOV targets pin to the edge with a chevron.
  private var locatorBar: some View {
    GeometryReader { geo in
      let barW = geo.size.width
      let halfBar = barW / 2
      let edgePad: CGFloat = 10

      // Usable range: edgePad ... barW - edgePad
      let usable = halfBar - edgePad

      ZStack(alignment: .center) {
        // Bar track
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.white.opacity(0.1))
          .frame(height: 6)

        // Center tick = 0° = on target
        Rectangle()
          .fill(Color.green.opacity(0.5))
          .frame(width: 2, height: 18)

        // Edge markers for ±90° aren't needed — the edges ARE ±90°

        if isInFront {
          // In FOV: map -90...+90 → -usable...+usable
          let xOff = CGFloat(angle / 90.0) * usable

          pingDot
            .offset(x: xOff, y: -6)
        } else {
          // Behind: pin to edge with chevron
          let pinLeft = angle < 0
          let xOff = pinLeft ? -(halfBar - edgePad) : (halfBar - edgePad)

          HStack(spacing: 2) {
            if pinLeft {
              Image(systemName: "chevron.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.cyan.opacity(0.6))
            }
            Circle()
              .fill(Color.cyan.opacity(0.4))
              .frame(width: 10, height: 10)
              .overlay(
                Circle()
                  .stroke(Color.cyan.opacity(0.6), lineWidth: 1)
              )
            if !pinLeft {
              Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.cyan.opacity(0.6))
            }
          }
          .offset(x: xOff, y: -2)
        }
      }
    }
    .frame(height: 24)
  }

  private var pingDot: some View {
    ZStack {
      if isOnTarget {
        Circle()
          .fill(Color.green.opacity(0.25))
          .frame(width: 26, height: 26)
      }
      Circle()
        .fill(isOnTarget ? Color.green : Color.cyan)
        .frame(width: 12, height: 12)
        .shadow(color: (isOnTarget ? Color.green : Color.cyan).opacity(0.5), radius: 6)
      Circle()
        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
        .frame(width: 12, height: 12)
    }
  }

  private var directionLabel: String {
    let a = angle
    if abs(a) < 10 { return "ON TARGET" }
    if abs(a) < 30 { return a < 0 ? "SLIGHT LEFT" : "SLIGHT RIGHT" }
    if abs(a) <= 90 { return a < 0 ? "TURN LEFT" : "TURN RIGHT" }
    return a < 0 ? "BEHIND LEFT" : "BEHIND RIGHT"
  }

  private var distanceLabel: String {
    let d = audioEngine.beaconDistanceMeters
    if d < 1 { return "<1m" }
    return String(format: "%.0fm", d)
  }
}

// MARK: - AR Ping Marker (floating on camera feed)

/// Floating marker overlaid on the camera video. When the ping is in
/// the camera's FOV (~±35° horizontal), a glowing orb is drawn at the
/// correct horizontal position. Includes distance readout.
struct ARPingMarker: View {
  @ObservedObject var audioEngine: SpatialAudioEngine
  let frameSize: CGSize

  private var angle: Float { audioEngine.relativeBeaconAngle }
  private var cameraFOV: Float { 70 }

  var body: some View {
    let halfFOV = cameraFOV / 2
    let inView = abs(angle) <= halfFOV

    ZStack {
      if inView {
        let xFrac = CGFloat(angle / halfFOV)
        let xPos = frameSize.width / 2 + xFrac * (frameSize.width / 2 - 30)
        let yPos = frameSize.height * 0.4
        let dist = audioEngine.beaconDistanceMeters
        let onTarget = abs(angle) < 8

        VStack(spacing: 6) {
          // Distance label
          Text(dist < 1 ? "<1m" : String(format: "%.0fm", dist))
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.5)))

          // Glowing orb
          ZStack {
            // Outer pulse ring
            Circle()
              .stroke(
                (onTarget ? Color.green : Color.cyan).opacity(0.3),
                lineWidth: 2
              )
              .frame(width: 44, height: 44)

            // Mid glow
            Circle()
              .fill(
                RadialGradient(
                  colors: [
                    (onTarget ? Color.green : Color.cyan).opacity(0.4),
                    Color.clear
                  ],
                  center: .center,
                  startRadius: 0,
                  endRadius: 22
                )
              )
              .frame(width: 44, height: 44)

            // Core
            Circle()
              .fill(onTarget ? Color.green : Color.cyan)
              .frame(width: 16, height: 16)
              .shadow(color: (onTarget ? Color.green : Color.cyan).opacity(0.8), radius: 12)

            Circle()
              .stroke(Color.white, lineWidth: 2)
              .frame(width: 16, height: 16)
          }

          // Down arrow connecting to "ground"
          Image(systemName: "arrowtriangle.down.fill")
            .font(.system(size: 10))
            .foregroundColor((onTarget ? Color.green : Color.cyan).opacity(0.6))
        }
        .position(x: xPos, y: yPos)
      }
    }
  }
}

// MARK: - Controls

struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel

  var body: some View {
    VStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Source")
          .font(.caption2)
          .foregroundColor(.white.opacity(0.55))
        Picker("Source", selection: Binding(
          get: { viewModel.streamingMode },
          set: { mode in
            Task { await viewModel.switchStreamingSource(to: mode) }
          }
        )) {
          Text("Ray-Ban").tag(StreamingMode.glasses)
          Text("iPhone").tag(StreamingMode.iPhone)
        }
        .pickerStyle(.segmented)

        Toggle(isOn: Binding(
          get: { viewModel.depthInferenceEnabled },
          set: { viewModel.setDepthInferenceEnabled($0) }
        )) {
          Text("Depth map")
            .font(.subheadline)
            .foregroundColor(.white)
        }
        .tint(.green)

        if viewModel.depthInferenceEnabled {
          HStack {
            Text("Opacity")
              .font(.caption2)
              .foregroundColor(.white.opacity(0.75))
            Slider(value: $viewModel.depthOverlayOpacity, in: 0.15...1.0)
              .tint(.cyan)
          }
          Toggle(isOn: $viewModel.showDepthOverlay) {
            Text("Show depth overlay")
              .font(.caption)
              .foregroundColor(.white)
          }
          .tint(.gray)
        }

        Divider().background(Color.white.opacity(0.2))

        Toggle(isOn: Binding(
          get: { viewModel.audioEngine.isEnabled },
          set: { viewModel.audioEngine.isEnabled = $0 }
        )) {
          HStack(spacing: 6) {
            Image(systemName: viewModel.audioEngine.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
              .foregroundColor(viewModel.audioEngine.isEnabled ? .green : .gray)
            Text("Spatial Audio")
              .font(.subheadline)
              .foregroundColor(.white)
            if viewModel.isUpgradingToANE {
              Text("· upgrading to ANE…")
                .font(.caption2)
                .foregroundColor(.orange)
            } else if !viewModel.computeLabel.isEmpty {
              Text("· \(viewModel.computeLabel)")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
            }
          }
        }
        .tint(.green)

        if viewModel.audioEngine.isEnabled && viewModel.depthInferenceEnabled {
          ClearPathPanel(viewModel: viewModel)
        }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.5)))

      HStack(spacing: 8) {
        CustomButton(
          title: "Stop streaming",
          style: .destructive,
          isDisabled: false
        ) {
          Task {
            await viewModel.stopSession()
          }
        }

        if viewModel.streamingMode == .glasses {
          CircleButton(icon: "camera.fill", text: nil) {
            viewModel.capturePhoto()
          }
        }

        CircleButton(
          icon: geminiVM.isGeminiActive ? "waveform.circle.fill" : "waveform.circle",
          text: "AI"
        ) {
          Task {
            if geminiVM.isGeminiActive {
              geminiVM.stopSession()
            } else {
              await geminiVM.startSession()
            }
          }
        }
        .opacity(webrtcVM.isActive ? 0.4 : 1.0)
        .disabled(webrtcVM.isActive)

        CircleButton(
          icon: webrtcVM.isActive
            ? "antenna.radiowaves.left.and.right.circle.fill"
            : "antenna.radiowaves.left.and.right.circle",
          text: "Live"
        ) {
          Task {
            if webrtcVM.isActive {
              webrtcVM.stopSession()
            } else {
              await webrtcVM.startSession()
            }
          }
        }
        .opacity(geminiVM.isGeminiActive ? 0.4 : 1.0)
        .disabled(geminiVM.isGeminiActive)
      }
    }
  }
}
