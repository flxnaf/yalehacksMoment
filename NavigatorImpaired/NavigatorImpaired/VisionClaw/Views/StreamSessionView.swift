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

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @ObservedObject private var viewModel: StreamSessionViewModel
  @ObservedObject private var geminiVM: GeminiSessionViewModel
  @ObservedObject private var webrtcVM: WebRTCSessionViewModel

  init(
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    streamViewModel: StreamSessionViewModel,
    geminiVM: GeminiSessionViewModel,
    webrtcVM: WebRTCSessionViewModel
  ) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    _viewModel = ObservedObject(wrappedValue: streamViewModel)
    _geminiVM = ObservedObject(wrappedValue: geminiVM)
    _webrtcVM = ObservedObject(wrappedValue: webrtcVM)
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
    .overlay(alignment: .topTrailing) {
      HStack(spacing: 8) {
        if let logURL = SpatialDebugLogExport.documentsLogFileURLIfPresent() {
          ShareLink(
            item: logURL,
            subject: Text("Spatial debug log"),
            message: Text("NDJSON from SpatialAudioEngine (session 3d0606). Save as .cursor/debug-3d0606.log on Mac.")
          ) {
            Image(systemName: "square.and.arrow.up")
              .font(.body.weight(.medium))
              .foregroundStyle(.primary)
              .padding(10)
              .background(.ultraThinMaterial, in: Circle())
          }
          .accessibilityLabel("Share spatial debug log")
        }
        Button {
          SpatialDebugLogExport.copyDocumentsLogToPasteboard()
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Copy spatial debug log")
      }
      .padding(.top, 8)
      .padding(.trailing, 8)
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
