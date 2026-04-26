import Foundation

/// Minimal `.env` file reader. We pull the Anthropic API key from
/// `~/Downloads/.env` so the key survives launches that don't inherit
/// the user's shell environment (Finder double-click, login items,
/// launchd LaunchAgents).
///
/// Format:
///   KEY=value
///   QUOTED="value with spaces"
///   # comment
///
/// Empty lines and `#`-comments are ignored. Values may be wrapped
/// in single or double quotes. Whitespace around `=` and at line ends
/// is stripped.
public enum EnvFile {
    /// Default location. The user explicitly chose `~/Downloads/.env`
    /// for this project; the file is .gitignored upstream.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/.env")
    }

    /// Returns the value for `key` from the file at `url`. Returns nil
    /// if the file doesn't exist, can't be read, or the key isn't set.
    public static func value(for key: String, at url: URL = defaultURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let lhs = parts[0].trimmingCharacters(in: .whitespaces)
            guard lhs == key else { continue }
            var rhs = parts[1].trimmingCharacters(in: .whitespaces)
            // Strip optional surrounding quotes.
            if (rhs.hasPrefix("\"") && rhs.hasSuffix("\""))
                || (rhs.hasPrefix("'") && rhs.hasSuffix("'")) {
                rhs = String(rhs.dropFirst().dropLast())
            }
            return rhs
        }
        return nil
    }
}
