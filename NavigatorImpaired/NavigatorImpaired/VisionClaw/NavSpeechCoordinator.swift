/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import SwiftUI

/// Navigation TTS for `NavigationController.onSpeakInstruction` with per-utterance completion (ping advance / arrival).
/// Uses ElevenLabs when `Secrets.elevenLabsAPIKey` is set; otherwise `AVSpeechSynthesizer`.
@MainActor
final class NavSpeechCoordinator: ObservableObject {
  let synthesizer = AVSpeechSynthesizer()
  private let delegateHelper = NavSpeechDelegateHelper()
  private let audioDelegateHelper = NavAudioPlayerDelegateHelper()
  private var completionQueue: [(() -> Void)?] = []
  private var audioPlayer: AVAudioPlayer?
  private var tailTask: Task<Void, Never>?
  private var pendingDelivery: CheckedContinuation<Void, Never>?

  init() {
    delegateHelper.owner = self
    synthesizer.delegate = delegateHelper
    audioDelegateHelper.owner = self
    if Self.isElevenLabsConfigured {
      ElevenLabsTTSClient.shared.prewarm()
    }
  }

  private static var isElevenLabsConfigured: Bool {
    let k = Secrets.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return !k.isEmpty && k != "YOUR_ELEVENLABS_API_KEY"
  }

  func speak(_ text: String, completion: (() -> Void)?) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      completion?()
      return
    }
    completionQueue.append(completion)
    let prev = tailTask
    tailTask = Task { @MainActor in
      await prev?.value
      await self.deliverOne(trimmed)
    }
  }

  /// One navigation line: ElevenLabs (serial) or system TTS, then signal completion for this queue item.
  private func deliverOne(_ text: String) async {
    if Self.isElevenLabsConfigured {
      do {
        let data = try await ElevenLabsTTSClient.shared.audioData(for: text)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          self.pendingDelivery = cont
          self.playElevenLabsMP3(data, fallbackText: text)
        }
      } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          self.pendingDelivery = cont
          self.speakSystemUtterance(text)
        }
      }
    } else {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        self.pendingDelivery = cont
        self.speakSystemUtterance(text)
      }
    }
  }

  private func speakSystemUtterance(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  private func playElevenLabsMP3(_ data: Data, fallbackText: String) {
    audioPlayer?.stop()
    do {
      let player = try AVAudioPlayer(data: data)
      player.delegate = audioDelegateHelper
      audioPlayer = player
      player.play()
    } catch {
      #if DEBUG
      print("[NavSpeech] ElevenLabs playback failed (\(error.localizedDescription)); system TTS")
      #endif
      speakSystemUtterance(fallbackText)
    }
  }

  fileprivate func playbackFinished() {
    pendingDelivery?.resume()
    pendingDelivery = nil
    guard !completionQueue.isEmpty else { return }
    let done = completionQueue.removeFirst()
    done?()
  }

  fileprivate func playbackCancelled() {
    pendingDelivery?.resume()
    pendingDelivery = nil
    if !completionQueue.isEmpty { completionQueue.removeFirst() }
  }
}

private final class NavSpeechDelegateHelper: NSObject, AVSpeechSynthesizerDelegate {
  weak var owner: NavSpeechCoordinator?

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in owner?.playbackFinished() }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in owner?.playbackCancelled() }
  }
}

private final class NavAudioPlayerDelegateHelper: NSObject, AVAudioPlayerDelegate {
  weak var owner: NavSpeechCoordinator?

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in owner?.playbackFinished() }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in owner?.playbackFinished() }
  }
}
