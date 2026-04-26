import AppKit
import Foundation

/// Chime cues. Plays short macOS system sounds (NSSound) on
/// state transitions: wake-phrase heard, action succeeded, action
/// failed. TTS is handled separately by a `Speaker` (see MCCore).
public final class AudioFeedback: @unchecked Sendable {

    /// macOS bundles ~12 system sounds in /System/Library/Sounds.
    /// We use Tink for both "heard you" and "action complete" — quiet
    /// and consistent.
    public enum Cue: Sendable {
        case heard
        case success
        case failure

        var soundName: String {
            switch self {
            case .heard, .success:  return "Tink"
            case .failure:          return "Basso"
            }
        }
    }

    public init() {}

    public func play(_ cue: Cue) {
        // NSSound caches and plays asynchronously off the main thread.
        // Failures (e.g. missing system sound on a future OS) are silent.
        NSSound(named: NSSound.Name(cue.soundName))?.play()
    }
}
