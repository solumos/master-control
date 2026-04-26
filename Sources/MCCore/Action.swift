import Foundation

/// Tier-0+ action protocol. Phase 1 fills in concrete implementations
/// (AppLaunch, WindowControl, FocusMode, …). Phase 0 doesn't execute actions —
/// the spike stops at intent classification — but the protocol lives in MCCore
/// so MCRouter and MCSpike can hold strongly-typed references.
public protocol Action: Sendable {
    /// Stable identifier referenced from `intents.json`.
    static var id: String { get }

    /// Human-readable label for the HUD ("Open Slack", "Switch focus to Work").
    func label(args: [String: ArgValue]) -> String

    /// Run the action. Throws on user-visible failure (e.g. AppleScript -1743).
    func execute(args: [String: ArgValue]) async throws

    /// Optional inverse, invoked by Cmd-Z within the 5 s undo window.
    /// Default: no-op (action not reversible).
    func undo(args: [String: ArgValue]) async throws
}

public extension Action {
    func undo(args: [String: ArgValue]) async throws {}
}

public enum ActionError: Error, LocalizedError, Sendable {
    case unknownTool(String)
    case missingArg(String)
    case targetNotFound(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let t):    return "unknown tool: \(t)"
        case .missingArg(let a):     return "missing required arg: \(a)"
        case .targetNotFound(let t): return "target not found: \(t)"
        case .underlying(let m):     return m
        }
    }
}
