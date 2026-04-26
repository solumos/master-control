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

    /// - Parameters:
    ///   - phrases: Wake phrases (any one matches). Should be normalized
    ///     (lowercase, no punctuation).
    ///   - dictateTriggers: First word AFTER the wake phrase that switches
    ///     the action from routing to dictation. Default: `["type", "dictate"]`.
    public init(
        phrases: [String] = WakeWord.masterControlVariants,
        dictateTriggers: Set<String> = ["type", "dictate"]
    ) {
        self.phrases = phrases
        self.trigger = Set(phrases.map(WakeWord.normalize))
        // For the fuzzy fallback, take the first 5 chars of the last word
        // of each registered phrase (e.g. "control" → "contr"). Any utterance
        // whose 2nd or 3rd word starts with one of these prefixes gets
        // accepted, catching STT slips like "master patrol" → matches "patro"…
        // wait, that wouldn't. Match by last-word prefix, lowering false
        // negatives at the cost of slightly more false positives.
        self.triggerLastWordPrefixes = phrases.compactMap { phrase in
            let words = phrase.split(separator: " ")
            guard let last = words.last else { return nil }
            let prefixLen = Swift.min(5, last.count)
            return String(last.prefix(prefixLen))
        }
        self.dictateTriggers = dictateTriggers
    }

    public struct Match: Sendable {
        public enum Kind: Sendable {
            case route
            case dictate
        }
        public let kind: Kind
        /// The portion of the utterance after the wake word (and after
        /// the dictate trigger if present), trimmed.
        public let payload: String
    }

    /// Try to match the wake word at the start of `utterance`.
    /// Returns `nil` if the utterance isn't a directive to us.
    public func match(utterance: String) -> Match? {
        let norm = Self.normalize(utterance)
        // First, try the explicit phrase list (longest-match-first).
        let sortedTriggers = trigger.sorted { $0.count > $1.count }
        var remainder: String
        if let hit = sortedTriggers.first(where: { norm.hasPrefix($0) }) {
            remainder = String(norm.dropFirst(hit.count))
        } else if let r = fuzzyTriggerPrefix(norm) {
            // Fallback: any 1–2 short opening words followed by a token
            // that begins with one of the registered phrases' last-word
            // prefixes (e.g. "contr" → catches "control", "controlled",
            // "controls", "controlling").
            remainder = r
        } else {
            return nil
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for dictate trigger word.
        if let firstSpace = remainder.firstIndex(where: \.isWhitespace) {
            let firstWord = String(remainder[..<firstSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
            if dictateTriggers.contains(firstWord) {
                let body = String(remainder[firstSpace...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return Match(kind: .dictate, payload: body)
            }
        } else if dictateTriggers.contains(remainder) {
            return Match(kind: .dictate, payload: "")
        }

        return Match(kind: .route, payload: remainder)
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
