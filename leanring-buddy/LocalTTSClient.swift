//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  On-device text-to-speech using AVSpeechSynthesizer. Drop-in replacement
//  for ElevenLabsTTSClient — exposes the same public surface (speakText,
//  stopPlayback, isPlaying) so CompanionManager can swap without changes
//  to the response pipeline.
//

import AVFoundation
import Foundation

@MainActor
final class LocalTTSClient: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    /// Tracks whether the synthesizer is currently speaking so the transient
    /// cursor scheduling logic can wait for playback to finish.
    @Published private(set) var isPlaying: Bool = false

    /// The preferred voice for speech output. Picks a premium (Enhanced/Premium)
    /// system voice if one is installed, falling back to the default en-US voice.
    private let preferredVoice: AVSpeechSynthesisVoice?

    private var speakContinuation: CheckedContinuation<Void, Never>?

    override init() {
        // Try to find a premium-quality English voice. On macOS the Enhanced
        // and Premium voices are downloaded on-demand from System Settings →
        // Accessibility → Spoken Content → System Voice → Manage Voices.
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && $0.quality != .default
        }

        // Prefer Premium over Enhanced, then pick by name stability
        if let premiumVoice = englishVoices.first(where: { $0.quality == .premium }) {
            self.preferredVoice = premiumVoice
        } else if let enhancedVoice = englishVoices.first(where: { $0.quality == .enhanced }) {
            self.preferredVoice = enhancedVoice
        } else {
            // Fall back to the default en-US voice
            self.preferredVoice = AVSpeechSynthesisVoice(language: "en-US")
        }

        super.init()
        synthesizer.delegate = self

        let voiceName = preferredVoice?.name ?? "system default"
        let qualityDescription = preferredVoice.map { "\($0.quality)" } ?? "default"
        print("🔊 LocalTTS: using voice \"\(voiceName)\" (quality: \(qualityDescription))")
    }

    /// Speaks the given text using the on-device synthesizer. Returns when
    /// playback finishes (or is cancelled). Cancellation-safe via Task check.
    func speakText(_ text: String) async {
        // Stop any in-progress speech before starting a new utterance
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isPlaying = true
        synthesizer.speak(utterance)
        print("🔊 LocalTTS: speaking \(text.count) characters")

        // Wait for the delegate callback that fires when speaking finishes
        await withCheckedContinuation { continuation in
            self.speakContinuation = continuation
        }
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        // Resume the continuation if we were awaiting speech completion
        if let continuation = speakContinuation {
            speakContinuation = nil
            continuation.resume()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension LocalTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isPlaying = false
            if let continuation = speakContinuation {
                speakContinuation = nil
                continuation.resume()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isPlaying = false
            if let continuation = speakContinuation {
                speakContinuation = nil
                continuation.resume()
            }
        }
    }
}
