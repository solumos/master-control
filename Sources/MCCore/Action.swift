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

/// Generates a free-form natural-language response to an utterance.
/// Implementations may run in-process (e.g. MLX) or call out to a cloud
/// LLM (e.g. Anthropic). The host pipes the result into TTS.
public protocol Responder: Sendable {
    /// Friendly name used in telemetry/logging ("anthropic-haiku", "mlx-qwen3", …).
    var name: String { get }

    func respond(to prompt: String) async throws -> String
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
