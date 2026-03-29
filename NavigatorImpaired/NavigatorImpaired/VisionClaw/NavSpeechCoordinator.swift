/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import SwiftUI

/// AVSpeech adapter for `NavigationController.onSpeakInstruction` with per-utterance completion (ping advance / arrival).
@MainActor
final class NavSpeechCoordinator: ObservableObject {
  let synthesizer = AVSpeechSynthesizer()
  private let delegateHelper = NavSpeechDelegateHelper()
  private var completionQueue: [(() -> Void)?] = []

  init() {
    delegateHelper.owner = self
    synthesizer.delegate = delegateHelper
  }

  func speak(_ text: String, completion: (() -> Void)?) {
    completionQueue.append(completion)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  fileprivate func synthesizerDidFinishUtterance() {
    guard !completionQueue.isEmpty else { return }
    let done = completionQueue.removeFirst()
    done?()
  }

  fileprivate func synthesizerDidCancelUtterance() {
    if !completionQueue.isEmpty { completionQueue.removeFirst() }
  }
}

private final class NavSpeechDelegateHelper: NSObject, AVSpeechSynthesizerDelegate {
  weak var owner: NavSpeechCoordinator?

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in owner?.synthesizerDidFinishUtterance() }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in owner?.synthesizerDidCancelUtterance() }
  }
}
