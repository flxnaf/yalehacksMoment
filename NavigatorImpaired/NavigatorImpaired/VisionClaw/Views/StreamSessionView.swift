/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import AVFoundation
import MWDATCore
import SwiftUI
import UIKit

/// Owns `NavigationController` with API key from `Secrets` (see plan appendix D).
@MainActor
private final class NavControllerHolder: ObservableObject {
  let navigation: NavigationController
  init() {
    navigation = NavigationController(
      locationManager: LocationManager.shared,
      googleMapsAPIKey: Secrets.googleMapsAPIKey
    )
  }
}

/// Holds `AVSpeechSynthesizer` for `NavigationController.onSpeakInstruction`.
/// If TTS is silent or conflicts with Gemini Live audio, tune `AVAudioSession` / queue when `isModelSpeaking` is false (runtime tuning).
@MainActor
private final class NavTTSOwner: ObservableObject {
  let synthesizer = AVSpeechSynthesizer()
}

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var geminiVM = GeminiSessionViewModel()
  @StateObject private var webrtcVM = WebRTCSessionViewModel()
  @StateObject private var navHolder = NavControllerHolder()
  @StateObject private var navTTSOwner = NavTTSOwner()

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      } else {
        // Pre-streaming setup view with permissions and start button
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .task {
      viewModel.geminiSessionVM = geminiVM
      viewModel.webrtcSessionVM = webrtcVM
      geminiVM.streamingMode = viewModel.streamingMode
      let nav = navHolder.navigation
      nav.onSpeakInstruction = { [weak navTTSOwner] text in
        guard let navTTSOwner else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        navTTSOwner.synthesizer.speak(utterance)
      }
      LocationManager.shared.requestPermissionAndStart()
      viewModel.navigationController = nav
      geminiVM.navigationController = nav
      geminiVM.audioEngine = viewModel.audioEngine

      if wearablesViewModel.autoStartIPhone {
        wearablesViewModel.autoStartIPhone = false
        await viewModel.handleStartIPhone()
      }
    }
    .onChange(of: viewModel.streamingMode) { newMode in
      geminiVM.streamingMode = newMode
    }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      viewModel.startDepthModelLoad()
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
