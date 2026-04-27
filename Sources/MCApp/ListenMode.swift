import Foundation

/// How the app decides which utterances to act on.
enum ListenMode: String, CaseIterable, Identifiable, Sendable {
    /// Always-on listening, gated by the "master control" wake phrase.
    /// Utterances without the wake phrase are silently ignored.
    case wakeWord = "wake_word"

    /// Mic is closed by default. Tap right Option (⌥) to toggle
    /// listening on (no wake phrase needed — every utterance is acted
    /// on) and tap again to close it.
    case optionToggle = "option_toggle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wakeWord:     return "Wake word (\u{201C}master control, …\u{201D})"
        case .optionToggle: return "Tap right Option (\u{2325}) to toggle listening"
        }
    }
}
