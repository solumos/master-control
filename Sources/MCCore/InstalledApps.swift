import Foundation

/// Index of `.app` bundles installed on this machine, populated at app
/// startup. Used by `DeterministicRouter` to fuzzy-resolve the
/// heard name on a generic "open X" command — Parakeet often slips on
/// short proper nouns ("claw" → "Claude", "shopify" → "Spotify").
public struct InstalledApps: Sendable {

    /// Display names with `.app` stripped. Sorted for stable iteration.
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }

    /// Walk the standard application directories and collect `.app` bundle
    /// names. Cheap operation (~5–20 ms on a typical Mac).
    public static func discover() -> InstalledApps {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs: [String] = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            home.appendingPathComponent("Applications").path,
        ]
        var names: Set<String> = []
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                names.insert(String(entry.dropLast(4)))
            }
        }
        return InstalledApps(names: Array(names).sorted())
    }

    /// Best match for the heard name, or nil if nothing's close enough.
    /// Lookup priority:
    ///   1. exact (case-insensitive) name match
    ///   2. heard name matches any whole word in an installed name
    ///      ("chrome" → "Google Chrome", "code" → "Visual Studio Code")
    ///   3. one full name is a prefix of the other (≥ 3 characters)
    ///   4. Levenshtein distance ≤ max(2, len/3)
    public func bestMatch(for heard: String) -> String? {
        guard !heard.isEmpty else { return nil }
        let lower = heard.lowercased()

        // 1. Exact case-insensitive
        if let exact = names.first(where: { $0.lowercased() == lower }) {
            return exact
        }

        // 2. Word-level match — any whole word in an installed name matches
        // the heard name (equality or prefix-related). Catches the very
        // common "Chrome" → "Google Chrome", "Word" → "Microsoft Word".
        // Prefer the shortest matching name to avoid "Chrome Helper"-style
        // siblings beating "Google Chrome".
        if lower.count >= 3 {
            let wordMatches = names.filter { name in
                let words = name.lowercased().split(separator: " ").map(String.init)
                return words.contains { word in
                    word.count >= 3 && (
                        word == lower
                            || word.hasPrefix(lower)
                            || lower.hasPrefix(word)
                    )
                }
            }
            if let best = wordMatches.min(by: { $0.count < $1.count }) {
                return best
            }
        }

        // 3. Prefix match on full name (either direction). Catches "claud"
        // → "Claude" without going through Levenshtein.
        let prefixMatches = names.filter { name in
            let n = name.lowercased()
            return n.hasPrefix(lower) || lower.hasPrefix(n)
        }.filter { min($0.count, lower.count) >= 3 }
        if let best = prefixMatches.min(by: { $0.count < $1.count }) {
            return best
        }

        // 4. Levenshtein.
        let threshold = max(2, lower.count / 3)
        let scored: [(String, Int)] = names.compactMap { name in
            let d = Self.levenshtein(lower, name.lowercased())
            return d <= threshold ? (name, d) : nil
        }
        return scored.min { lhs, rhs in
            // Lowest distance wins. Ties broken by shorter name.
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.count < rhs.0.count
        }?.0
    }

    /// Standard iterative DP. Strings are short (app names ≤ ~30 chars)
    /// so the O(n*m) cost is trivial.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = Swift.min(
                    curr[j - 1] + 1,        // insertion
                    prev[j] + 1,            // deletion
                    prev[j - 1] + cost      // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
