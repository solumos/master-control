import AppKit
import Foundation

/// Inline AppleScript runner. Compiles + executes `NSAppleScript` in-process
/// (~5–30 ms per call after the first compile) instead of shelling out to
/// `osascript` (30–80 ms each). The bigger win: typed return values —
/// queries like Spotify's "what's playing" come back as parsable strings
/// without us hand-parsing process stdout.
///
/// First call against any target app prompts the user for Apple Events
/// permission (one-time, persists per-binary).
public enum AppleScriptRunner {

    public struct Output: Sendable {
        public let string: String?     // nil if the script returned no string
        public let descriptor: String  // type-tagged string for logging
    }

    public enum Failure: Error, LocalizedError {
        case compileFailed(String)
        case executionFailed(code: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .compileFailed(let m):           return "AppleScript compile failed: \(m)"
            case .executionFailed(_, let m):      return m
            }
        }
    }

    /// Run the script and return its output. Errors carry the script
    /// engine's failure message (handler not found, target not running,
    /// permission denied, …).
    @discardableResult
    public static func run(_ source: String) throws -> Output {
        guard let script = NSAppleScript(source: source) else {
            throw Failure.compileFailed("NSAppleScript init returned nil")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
            throw Failure.executionFailed(code: code, message: msg)
        }
        return Output(
            string: result.stringValue,
            descriptor: result.description
        )
    }
}
