/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI
import UIKit

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  @StateObject private var navigationHolder = NavigationControllerHolder()
  @StateObject private var streamViewModel: StreamSessionViewModel
  @StateObject private var geminiVM = GeminiSessionViewModel()
  @StateObject private var webrtcVM = WebRTCSessionViewModel()
  @StateObject private var navSpeech = NavSpeechCoordinator()
  @StateObject private var hazardScanCoordinator = NavigationHazardScanCoordinator()

  #if DEBUG
  /// Custom tab selection so `StreamSessionView` stays mounted (lazy `TabView` was tearing it down and stopping video/Gemini context).
  @State private var debugSessionTab: Int = 0
  @State private var spatialDebugLogCopied: Bool = false
  #endif

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
    _streamViewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    if viewModel.registrationState == .registered || viewModel.hasMockDevice || viewModel.skipToIPhoneMode {
      registeredSessionRoot
        .task {
          streamViewModel.geminiSessionVM = geminiVM
          streamViewModel.webrtcSessionVM = webrtcVM
          geminiVM.streamingMode = streamViewModel.streamingMode
          let nav = navigationHolder.navigation
          nav.geminiSessionForHandoff = geminiVM
          nav.onSpeakInstruction = { text, completion in
            if geminiVM.shouldUseGeminiForNavigationVoice {
              geminiVM.speakNavigationForUser(text, completion: completion)
            } else {
              navSpeech.speak(text, completion: completion)
            }
          }
          LocationManager.shared.requestPermissionAndStart()
          streamViewModel.navigationController = nav
          geminiVM.navigationController = nav
          geminiVM.audioEngine = streamViewModel.audioEngine
          geminiVM.streamSessionViewModel = streamViewModel

          if viewModel.autoStartIPhone {
            viewModel.autoStartIPhone = false
            await streamViewModel.handleStartIPhone()
          }

          hazardScanCoordinator.attach(
            stream: streamViewModel,
            navigation: nav,
            gemini: geminiVM,
            navSpeech: navSpeech
          )
        }
        .onDisappear {
          hazardScanCoordinator.stop()
        }
        .onChange(of: streamViewModel.streamingMode) { _, newMode in
          geminiVM.streamingMode = newMode
        }
    } else {
      // User not registered - show registration/onboarding flow
      HomeScreenView(viewModel: viewModel)
    }
  }

  @ViewBuilder
  private var registeredSessionRoot: some View {
    #if DEBUG
    VStack(spacing: 0) {
      ZStack {
        StreamSessionView(
          wearables: wearables,
          wearablesVM: viewModel,
          streamViewModel: streamViewModel,
          geminiVM: geminiVM,
          webrtcVM: webrtcVM
        )
        .opacity(debugSessionTab == 0 ? 1 : 0)
        .allowsHitTesting(debugSessionTab == 0)

        if debugSessionTab == 1 {
          NavigationStack {
            RouteDebugMapView(navController: navigationHolder.navigation)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(uiColor: .systemBackground))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: 0) {
        Button {
          debugSessionTab = 0
        } label: {
          Label("Stream", systemImage: "video.fill")
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(debugSessionTab == 0 ? Color.accentColor : Color.secondary)

        Button {
          debugSessionTab = 1
        } label: {
          Label("Route", systemImage: "map")
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(debugSessionTab == 1 ? Color.accentColor : Color.secondary)

        Button {
          SpatialDebugLogExport.copyDocumentsLogToPasteboard()
          spatialDebugLogCopied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            spatialDebugLogCopied = false
          }
        } label: {
          Label(spatialDebugLogCopied ? "Copied" : "Log", systemImage: spatialDebugLogCopied ? "checkmark.circle" : "doc.on.doc")
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(spatialDebugLogCopied ? Color.green : Color.secondary)
      }
      .padding(.vertical, 10)
      .background(.bar)
    }
    #else
    StreamSessionView(
      wearables: wearables,
      wearablesVM: viewModel,
      streamViewModel: streamViewModel,
      geminiVM: geminiVM,
      webrtcVM: webrtcVM
    )
    #endif
  }
}
