import Foundation
import MCActions
import MCCloud
import MCCore

/// Bridges Anthropic tool calls → IntentDispatcher actions.
///
/// Exposed as a (tools, executor) pair so AnthropicAgent can stay
/// dispatcher-agnostic. We define tools in the same shape as our
/// existing IntentKind values, so Claude's calls drop straight into
/// `dispatcher.dispatch(intent)`.
enum ToolBridge {

    static func tools() -> [AnthropicTool] {
        [
            .webSearch,

            .custom(
                name: "open_app",
                description: "Launch a Mac application by name. Use for any request to open or switch to an app — Slack, Chrome, Spotify, Notes, Calculator, etc.",
                properties: [
                    "name": .init(type: "string", description: "Display name of the app, e.g. 'Slack' or 'Visual Studio Code'."),
                ],
                required: ["name"]
            ),

            .custom(
                name: "media",
                description: "System-wide media keys. Routes to whatever app holds 'now playing' — Spotify, Apple Music, YouTube, browser audio. Use for play/pause/skip.",
                properties: [
                    "command": .init(type: "string", description: "One of: 'playpause', 'next', 'prev'."),
                ],
                required: ["command"]
            ),

            .custom(
                name: "spotify",
                description: "Control Spotify (must be running). Supports play/pause/next/prev and querying the currently-playing track.",
                properties: [
                    "command": .init(type: "string", description: "One of: 'play', 'pause', 'playpause', 'next', 'prev', 'now_playing'."),
                ],
                required: ["command"]
            ),

            .custom(
                name: "chrome",
                description: "Control the front Chrome window: tab nav and reload/back/forward.",
                properties: [
                    "command": .init(type: "string", description: "One of: 'next_tab', 'prev_tab', 'new_tab', 'close_tab', 'reload', 'back', 'forward'."),
                ],
                required: ["command"]
            ),

            .custom(
                name: "system_action",
                description: "Run a built-in system action like locking the screen or changing volume.",
                properties: [
                    "name": .init(type: "string", description: "One of: 'Lock Screen', 'Volume Up', 'Volume Down', 'Mute Microphone', 'Unmute Microphone'."),
                ],
                required: ["name"]
            ),

            .custom(
                name: "dictate",
                description: "Type the given text into the focused Mac app via synthesized keystrokes. Use when the user asks you to write or insert text into their current document/editor/chat.",
                properties: [
                    "text": .init(type: "string", description: "Plain text to type. Newlines and punctuation are typed verbatim."),
                ],
                required: ["text"]
            ),
        ]
    }

    /// Returns an executor closure suitable for `AnthropicAgent.init`.
    static func executor(
        dispatcher: IntentDispatcher,
        dictator: Dictator
    ) -> AnthropicAgent.ToolExecutor {
        return { @Sendable name, input in
            switch name {
            case "open_app":
                let appName = input.string("name") ?? ""
                let intent = Intent(
                    intent: .openApp,
                    tool: "launch",
                    args: ["name": .string(appName)],
                    confidence: 1.0
                )
                let result = await dispatcher.dispatch(intent)
                return Self.toolResult(from: result)

            case "media":
                let cmd = input.string("command") ?? ""
                let intent = Intent(
                    intent: .appCommand,
                    tool: "media",
                    args: ["app": .string("media"), "command": .string(cmd)],
                    confidence: 1.0
                )
                let result = await dispatcher.dispatch(intent)
                return Self.toolResult(from: result)

            case "spotify":
                let cmd = input.string("command") ?? ""
                let intent = Intent(
                    intent: .appCommand,
                    tool: "spotify",
                    args: ["app": .string("spotify"), "command": .string(cmd)],
                    confidence: 1.0
                )
                let result = await dispatcher.dispatch(intent)
                return Self.toolResult(from: result)

            case "chrome":
                let cmd = input.string("command") ?? ""
                let intent = Intent(
                    intent: .appCommand,
                    tool: "chrome",
                    args: ["app": .string("chrome"), "command": .string(cmd)],
                    confidence: 1.0
                )
                let result = await dispatcher.dispatch(intent)
                return Self.toolResult(from: result)

            case "system_action":
                let actionName = input.string("name") ?? ""
                let intent = Intent(
                    intent: .runShortcut,
                    tool: "shortcuts_run",
                    args: ["name": .string(actionName)],
                    confidence: 1.0
                )
                let result = await dispatcher.dispatch(intent)
                return Self.toolResult(from: result)

            case "dictate":
                let text = input.string("text") ?? ""
                _ = dictator.type(text)
                return AnthropicAgent.ToolResult(content: "Typed \(text.count) chars.")

            default:
                return AnthropicAgent.ToolResult(
                    content: "Unknown tool '\(name)'.",
                    isError: true
                )
            }
        }
    }

    private static func toolResult(from result: IntentDispatcher.Result) -> AnthropicAgent.ToolResult {
        switch result.status {
        case .executed:
            // If the action produced a spoken reply (e.g. now_playing),
            // return it so Claude can quote it in its response.
            let body = result.speak ?? "Done: \(result.label)"
            return AnthropicAgent.ToolResult(content: body)
        case .deferred:
            return AnthropicAgent.ToolResult(content: "Deferred: \(result.label)")
        case .failed(let why):
            return AnthropicAgent.ToolResult(content: "Failed: \(result.label) — \(why)", isError: true)
        }
    }
}
