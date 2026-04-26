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

    /// Built-in phrase variants for the default "MC directive" wake word.
    /// All strings here are pre-normalized.
    public static let mcDirectiveVariants: [String] = [
        "mc directive",
        "m c directive",
        "emcee directive",
        "mcdirective",
        "m.c. directive",
    ]

    public let phrases: [String]
    public let trigger: Set<String>
    public let dictateTriggers: Set<String>

    /// - Parameters:
    ///   - phrases: Wake phrases (any one matches). Should be normalized
    ///     (lowercase, no punctuation).
    ///   - dictateTriggers: First word AFTER the wake phrase that switches
    ///     the action from routing to dictation. Default: `["type", "dictate"]`.
    public init(
        phrases: [String] = WakeWord.mcDirectiveVariants,
        dictateTriggers: Set<String> = ["type", "dictate"]
    ) {
        self.phrases = phrases
        self.trigger = Set(phrases.map(WakeWord.normalize))
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
        // Find the longest matching wake phrase. Iterate sorted by length
        // descending so multi-word variants win over single-word.
        let sortedTriggers = trigger.sorted { $0.count > $1.count }
        guard let hit = sortedTriggers.first(where: { norm.hasPrefix($0) }) else {
            return nil
        }
        var remainder = String(norm.dropFirst(hit.count))
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

    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.components(separatedBy: .punctuationCharacters).joined()
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
