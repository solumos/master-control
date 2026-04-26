import AppKit
@preconcurrency import AVFoundation
import Foundation

/// Audible UX. Two channels:
/// - **Chime**: short system sound on successful action execution.
///   We use macOS system sounds (NSSound) so the cues match the OS's
///   typical feedback vocabulary instead of feeling app-specific.
/// - **TTS**: AVSpeechSynthesizer for "thinking" announcements while
///   the LLM router is running. Useful because the deterministic
///   path is silent (~150 ms) but the LLM path takes ~1 s — without
///   audio feedback the user can't tell whether the system is
///   working or stuck.
public final class AudioFeedback: @unchecked Sendable {

    /// macOS bundles ~12 system sounds in /System/Library/Sounds.
    /// Names omit the .aiff extension. Picked subjectively for tone:
    /// success = Glass (soft bell), failure = Basso (low thunk).
    public enum Cue: String, Sendable {
        case success = "Glass"
        case failure = "Basso"
        case heard = "Tink"      // very short tick — wake phrase recognized
    }

    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    public init(voiceLanguage: String = "en-US") {
        self.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
    }

    public func play(_ cue: Cue) {
        // NSSound caches and plays asynchronously off the main thread.
        // Failures (e.g. missing system sound on a future OS) are silent.
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    /// Speak a short string. Cancels any in-flight utterance so a
    /// stale "thinking" announcement doesn't talk over the result.
    public func speak(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        guard !text.isEmpty else { return }
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        synth.speak(utterance)
    }

    public func stopSpeaking() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }
}
