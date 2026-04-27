import Foundation
import MCCore

/// Detects the configured wake phrase in a transcribed utterance and
/// returns the remainder (the actual command) with the wake phrase
/// stripped. Returns `nil` if the utterance isn't directed at us.
///
/// Match is case-insensitive after light normalization (lowercase,
/// punctuation stripped). The detector accepts a short list of phrase
/// variants so transcription quirks don't drop valid commands —
/// "MC directive" might come back as "M C directive", "emcee directive",
/// or "mc directive."
public struct WakeWord: Sendable {

    /// Built-in phrase variants for the default "master control" wake
    /// word. All strings here are pre-normalized. Includes phonetic
    /// alternates Parakeet has been observed producing in practice.
    public static let masterControlVariants: [String] = [
        "master control",
        "master controls",
        "master controlled",
        "mastercontrol",
        "mister control",
        "matter control",
        "master patrol",     // observed STT slip
    ]

    public let phrases: [String]
    public let trigger: Set<String>
    public let triggerLastWordPrefixes: [String]
    public let dictateTriggers: Set<String>
    public let sendTriggers: Set<String>

    /// - Parameters:
    ///   - phrases: Wake phrases (any one matches). Should be normalized
    ///     (lowercase, no punctuation).
    ///   - dictateTriggers: First word AFTER the wake phrase that switches
    ///     the action from routing to dictation. Default: `["type", "dictate"]`.
    ///   - sendTriggers: First word AFTER the wake phrase that switches the
    ///     action to dictate-then-press-Enter (chat-app send). Default:
    ///     `["send", "post", "reply"]`.
    public init(
        phrases: [String] = WakeWord.masterControlVariants,
        dictateTriggers: Set<String> = ["type", "dictate"],
        sendTriggers: Set<String> = ["send", "post", "reply"]
    ) {
        self.phrases = phrases
        self.trigger = Set(phrases.map(WakeWord.normalize))
        self.triggerLastWordPrefixes = phrases.compactMap { phrase in
            let words = phrase.split(separator: " ")
            guard let last = words.last else { return nil }
            let prefixLen = Swift.min(5, last.count)
            return String(last.prefix(prefixLen))
        }
        self.dictateTriggers = dictateTriggers
        self.sendTriggers = sendTriggers
    }

    public struct Match: Sendable {
        public enum Kind: Sendable {
            /// Route through the deterministic chain or fall through to the
            /// LLM agent.
            case route
            /// Type the payload via synthesized keystrokes.
            case dictate
            /// Type the payload AND press Enter — chat-app send pattern.
            case send
        }
        public let kind: Kind
        /// The portion of the utterance after the wake word (and after
        /// the mode-trigger word, if present), trimmed.
        public let payload: String

        public init(kind: Kind, payload: String) {
            self.kind = kind
            self.payload = payload
        }
    }

    /// Try to match the wake word at the start of `utterance`.
    /// Returns `nil` if the utterance isn't a directive to us.
    public func match(utterance: String) -> Match? {
        let norm = Self.normalize(utterance)
        let sortedTriggers = trigger.sorted { $0.count > $1.count }
        var remainder: String
        if let hit = sortedTriggers.first(where: { norm.hasPrefix($0) }) {
            remainder = String(norm.dropFirst(hit.count))
        } else if let r = fuzzyTriggerPrefix(norm) {
            remainder = r
        } else if let r = wakePhraseAnywhere(norm, triggers: sortedTriggers) {
            remainder = r
        } else if let r = bareControlPrefix(norm) {
            remainder = r
        } else {
            return nil
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for a mode trigger as the first word after the wake phrase.
        if let firstSpace = remainder.firstIndex(where: \.isWhitespace) {
            let firstWord = String(remainder[..<firstSpace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(remainder[firstSpace...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sendTriggers.contains(firstWord) {
                return Match(kind: .send, payload: body)
            }
            if dictateTriggers.contains(firstWord) {
                return Match(kind: .dictate, payload: body)
            }
        } else {
            // Single trailing word after the wake phrase — only meaningful
            // for dictate/send if we somehow have an empty payload, but
            // include for symmetry.
            if sendTriggers.contains(remainder) {
                return Match(kind: .send, payload: "")
            }
            if dictateTriggers.contains(remainder) {
                return Match(kind: .dictate, payload: "")
            }
        }

        return Match(kind: .route, payload: remainder)
    }

    /// Find the last occurrence of any wake phrase inside the utterance
    /// and return the text after it. Catches two real-world cases the
    /// start-anchored matchers miss: TTS feedback prepended to the user's
    /// command (e.g. "Pasted from clipboard. Master Control, press
    /// Command V."), and false-start chatter that VAD bundles together
    /// with the directive ("Go say something nice to Roger. Master
    /// control, press pause."). Latest position wins because the
    /// freshest wake hit is the user's most recent intent.
    func wakePhraseAnywhere(_ norm: String, triggers: [String]) -> String? {
        var bestEnd: String.Index? = nil
        for phrase in triggers {
            var searchStart = norm.startIndex
            while searchStart < norm.endIndex,
                  let range = norm.range(of: phrase, range: searchStart..<norm.endIndex) {
                // Require word boundaries on each side so embedded
                // substrings (e.g. "remastercontrol") don't fire.
                let leftOK = range.lowerBound == norm.startIndex
                    || norm[norm.index(before: range.lowerBound)].isWhitespace
                let rightOK = range.upperBound == norm.endIndex
                    || norm[range.upperBound].isWhitespace
                if leftOK && rightOK {
                    if bestEnd == nil || range.upperBound > bestEnd! {
                        bestEnd = range.upperBound
                    }
                }
                searchStart = range.upperBound
            }
        }
        guard let end = bestEnd else { return nil }
        let payload = String(norm[end...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    /// Bare leading "control " followed by at least one more word. Parakeet
    /// routinely drops the soft initial "master" before audio fully ramps
    /// in, leaving "control press enter" / "control type X" — which is
    /// unambiguously a directive in practice. Refusing to match these is
    /// the single largest source of ignored utterances in the activity log.
    func bareControlPrefix(_ norm: String) -> String? {
        let prefix = "control "
        guard norm.hasPrefix(prefix) else { return nil }
        let rest = String(norm.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// If the utterance starts with 1–2 short tokens followed by a token
    /// that starts with one of the configured `triggerLastWordPrefixes`,
    /// returns the remainder after that prefix. Returns nil otherwise.
    ///
    /// Catches STT slips on the wake phrase that aren't in the explicit
    /// `phrases` list — e.g. "master controls", "matter control", "mister
    /// control" all match because their second word starts with "contr".
    func fuzzyTriggerPrefix(_ norm: String) -> String? {
        let words = norm.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard words.count >= 2 else { return nil }
        for splitIdx in 1...min(2, words.count - 1) {
            let candidate = String(words[splitIdx])
            if triggerLastWordPrefixes.contains(where: { candidate.hasPrefix($0) }) {
                return words[(splitIdx + 1)...].joined(separator: " ")
            }
        }
        return nil
    }

    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.components(separatedBy: .punctuationCharacters).joined()
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
