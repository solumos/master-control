import Foundation
import MCCore

/// Maps a classified `Intent` to a concrete macOS action and runs it.
///
/// Tier-0 actions (deterministic, low-latency):
///   - `open_app(name)` → `/usr/bin/open -a <name>`
///   - `run_shortcut(name)` → built-in handler if available, else
///     `/usr/bin/shortcuts run <name>`
///
/// Higher-tier intents (web_research, code_task, free_form_llm,
/// vision_fallback) are returned as `.deferred` results today —
/// they'll wire into Phase 2's cloud-LLM ReAct loop.
public actor IntentDispatcher {

    public struct Result: Sendable {
        public enum Status: Sendable {
            case executed   // ran successfully
            case deferred   // intent recognized but not handled in this phase
            case failed(String)
        }
        public let label: String
        public let status: Status
    }

    public init() {}

    public func dispatch(_ intent: Intent) async -> Result {
        switch intent.intent {
        case .openApp:
            return await openApp(args: intent.args)
        case .runShortcut:
            return await runShortcut(args: intent.args)
        case .webResearch, .codeTask, .freeFormLLM, .visionFallback:
            return Result(
                label: "\(intent.intent.rawValue) (\(intent.args["query"]?.stringValue ?? intent.args["prompt"]?.stringValue ?? ""))",
                status: .deferred
            )
        case .unknown:
            return Result(label: "unrecognized intent", status: .deferred)
        }
    }

    // MARK: - open_app

    private func openApp(args: [String: ArgValue]) async -> Result {
        guard let name = args["name"]?.stringValue, !name.isEmpty else {
            return Result(label: "open_app (missing name)", status: .failed("missing 'name' arg"))
        }
        return await runProcess(
            executable: "/usr/bin/open",
            arguments: ["-a", name],
            label: "Open \(name)"
        )
    }

    // MARK: - run_shortcut

    private func runShortcut(args: [String: ArgValue]) async -> Result {
        guard let name = args["name"]?.stringValue, !name.isEmpty else {
            return Result(label: "run_shortcut (missing name)", status: .failed("missing 'name' arg"))
        }

        // Built-in handlers for things that aren't really shortcuts.
        if let result = await builtinHandler(name: name, args: args) {
            return result
        }

        // Fall through to /usr/bin/shortcuts run "<name>"
        return await runProcess(
            executable: "/usr/bin/shortcuts",
            arguments: ["run", name],
            label: "Run “\(name)”"
        )
    }

    /// Recognized names that don't go through the Shortcuts CLI. Kept tight
    /// so users can override by creating an actual Shortcut with a different
    /// name; we only intercept the verbatim phrases the deterministic
    /// router is configured to emit.
    private func builtinHandler(name: String, args: [String: ArgValue]) async -> Result? {
        switch name {
        case "Lock Screen":
            return await runProcess(
                executable: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
                ],
                label: "Lock screen"
            )
        case "Volume Up":
            return await runProcess(
                executable: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "set volume output volume (output volume of (get volume settings) + 10)"
                ],
                label: "Volume up"
            )
        case "Volume Down":
            return await runProcess(
                executable: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "set volume output volume (output volume of (get volume settings) - 10)"
                ],
                label: "Volume down"
            )
        case "Mute Microphone", "Unmute Microphone":
            // No supported native API for system-wide mic mute on macOS.
            // Phase 2 will integrate the Shortcuts "Set Microphone Mute"
            // when Apple ships it on macOS 26.x.
            return Result(
                label: name,
                status: .deferred
            )
        default:
            return nil
        }
    }

    // MARK: - Process runner

    private func runProcess(executable: String, arguments: [String], label: String) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return Result(label: label, status: .failed("launch: \(error.localizedDescription)"))
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return Result(label: label, status: .executed)
        } else {
            return Result(label: label, status: .failed("exit code \(process.terminationStatus)"))
        }
    }
}
