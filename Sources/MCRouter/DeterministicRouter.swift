import Foundation
import MCCore

/// Sub-millisecond intent matcher. Walks a hand-curated list of phrase
/// → intent mappings and returns on the first phrase that's contained in
/// the utterance after lowercasing + punctuation stripping + filler-word
/// removal.
///
/// Designed for the spec's Tier-0 intents (open app, focus mode, paste
/// snippet, audio device, lock screen). Anything that doesn't match here
/// falls through to the next router in the chain.
public struct DeterministicRouter: Router {
    public let name = "deterministic"

    public struct Pattern: Sendable {
        /// Phrases that should match this pattern, in normalized form
        /// (lowercase, no punctuation, no filler words). Match is
        /// substring-anchored: any phrase that's contained in the
        /// normalized utterance fires the rule.
        public let phrases: [String]
        /// Intent emitted on match. Confidence baked into the static
        /// definition so the caller can distinguish high-confidence
        /// deterministic matches from low-confidence fallbacks.
        public let intent: Intent

        public init(phrases: [String], intent: Intent) {
            self.phrases = phrases
            self.intent = intent
        }
    }

    private let patterns: [Pattern]
    private let normalizer: Normalizer

    public init(patterns: [Pattern] = .seedSet, normalizer: Normalizer = Normalizer()) {
        self.patterns = patterns
        self.normalizer = normalizer
    }

    public func classify(utterance: String) async throws -> Intent? {
        let normalized = normalizer.normalize(utterance)
        for pattern in patterns {
            for phrase in pattern.phrases {
                if normalized == phrase || normalized.contains(phrase) {
                    return pattern.intent
                }
            }
        }
        return nil
    }
}

/// Lowercase, strip punctuation, drop common filler prefixes ("let's",
/// "please", "could you", "can you", "i want to", "i'd like to"). The
/// stripping is intentionally conservative — false negatives just defer
/// to the LLM fallback.
public struct Normalizer: Sendable {
    private static let fillerPrefixes: [String] = [
        "let's ", "lets ", "please ", "could you please ", "could you ",
        "can you please ", "can you ", "i want to ", "i would like to ",
        "i'd like to ", "i need to ", "would you ",
    ]

    public init() {}

    public func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.components(separatedBy: .punctuationCharacters).joined()
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for prefix in Self.fillerPrefixes where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
            break
        }
        return t
    }
}

extension Array where Element == DeterministicRouter.Pattern {
    /// Initial seed set for the Phase 0 spike. Phase 1 will move this to
    /// `Resources/intents.json` and ship with ~20 intents.
    public static var seedSet: [DeterministicRouter.Pattern] {
        [
            // App launches
            .openApp("Slack",                 phrases: ["open slack", "launch slack", "go to slack"]),
            .openApp("Visual Studio Code",    phrases: ["open vs code", "open vscode", "open visual studio code", "launch vs code"]),
            .openApp("Terminal",              phrases: ["open terminal", "open the terminal", "launch terminal"]),
            .openApp("Google Chrome",         phrases: ["open chrome", "launch chrome", "open google chrome"]),
            .openApp("Safari",                phrases: ["open safari", "launch safari"]),
            .openApp("Finder",                phrases: ["open finder", "show finder"]),
            .openApp("Notes",                 phrases: ["open notes", "open notes app"]),
            .openApp("Mail",                  phrases: ["open mail", "open email", "open mail app"]),
            .openApp("Messages",              phrases: ["open messages", "open imessage"]),
            .openApp("Calendar",              phrases: ["open calendar", "open the calendar"]),

            // System actions (run_shortcut for now — Phase 1 will add Tier-0 native handlers)
            .runShortcut("Lock Screen",       phrases: ["lock screen", "lock my screen", "lock the screen"]),
            .runShortcut("Mute Microphone",   phrases: ["mute mic", "mute microphone", "mute the mic"]),
            .runShortcut("Unmute Microphone", phrases: ["unmute mic", "unmute microphone"]),
            .runShortcut("Volume Up",         phrases: ["volume up", "increase volume", "louder"]),
            .runShortcut("Volume Down",       phrases: ["volume down", "decrease volume", "quieter"]),
        ]
    }
}

extension DeterministicRouter.Pattern {
    /// Convenience constructor for `open_app` intents.
    public static func openApp(_ name: String, phrases: [String], confidence: Double = 0.98) -> Self {
        .init(
            phrases: phrases,
            intent: .init(
                intent: .openApp,
                tool: "launch",
                args: ["name": .string(name)],
                confidence: confidence,
                needsClarification: false
            )
        )
    }

    /// Convenience constructor for `run_shortcut` intents.
    public static func runShortcut(_ name: String, phrases: [String], confidence: Double = 0.98) -> Self {
        .init(
            phrases: phrases,
            intent: .init(
                intent: .runShortcut,
                tool: "shortcuts_run",
                args: ["name": .string(name)],
                confidence: confidence,
                needsClarification: false
            )
        )
    }
}
