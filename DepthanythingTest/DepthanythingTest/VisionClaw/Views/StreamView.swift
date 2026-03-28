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
          }
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      VStack(alignment: .leading, spacing: 8) {
        if viewModel.depthInferenceEnabled {
          HStack(alignment: .top, spacing: 12) {
            if viewModel.depthModelLoaded, viewModel.depthModelError == nil {
              depthLatencyStatsCard
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
              if !viewModel.depthModelLoaded, viewModel.depthModelError == nil {
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
              aneStatusBadge
            }
          }
        }

        if geminiVM.isGeminiActive {
          GeminiStatusBar(geminiVM: geminiVM)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.top, 20)

      if geminiVM.isGeminiActive {
        VStack {
          Spacer()
          VStack(spacing: 8) {
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
          .padding(.bottom, 160)
        }
        .padding(.horizontal, 24)
      }

      if webrtcVM.isActive {
        VStack {
          WebRTCStatusBar(webrtcVM: webrtcVM)
          Spacer()
        }
        .padding(.all, 24)
      }

      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      }
      .padding(.all, 24)
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
