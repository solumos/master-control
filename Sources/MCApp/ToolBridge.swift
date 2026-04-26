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

    static func tools(claudeAvailable: Bool) -> [AnthropicTool] {
        var t: [AnthropicTool] = [
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
        if claudeAvailable {
            t.append(.custom(
                name: "claude_task",
                description: "Delegate a substantial coding/research task to a Claude Code subagent. Use when the user wants something deeper than a one-shot answer — e.g. 'have Claude review my latest commit', 'ask Claude to research Swift macros', 'have Claude refactor this file'. Returns immediately while the agent runs in the background; the user gets a system notification when it finishes. Works in their home directory by default.",
                properties: [
                    "task": .init(type: "string", description: "The full prompt to send to Claude. Be descriptive — Claude won't have follow-up turns."),
                    "permission": .init(type: "string", description: "'read_only' (default — Claude can read files, search, and use the web but can't edit) or 'full' (Claude can also edit files and run shell commands). Use 'full' only when the user explicitly asks to *change* something."),
                ],
                required: ["task"]
            ))
        }
        return t
    }

    /// Returns an executor closure suitable for `AnthropicAgent.init`.
    static func executor(
        dispatcher: IntentDispatcher,
        dictator: Dictator,
        claudeRunner: ClaudeRunner?
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

            case "claude_task":
                guard let claudeRunner else {
                    return AnthropicAgent.ToolResult(
                        content: "Claude CLI not installed on this machine.",
                        isError: true
                    )
                }
                let task = input.string("task") ?? ""
                guard !task.isEmpty else {
                    return AnthropicAgent.ToolResult(
                        content: "Empty task — provide a prompt.",
                        isError: true
                    )
                }
                let perm: ClaudeRunner.Permission =
                    (input.string("permission") == "full") ? .full : .readOnly
                if let started = claudeRunner.spawn(task: task, permission: perm) {
                    return AnthropicAgent.ToolResult(
                        content: "Started Claude (\(perm.rawValue)). Notification will fire when it finishes. Log: \(started.logURL.path)"
                    )
                } else {
                    return AnthropicAgent.ToolResult(
                        content: "Failed to launch Claude.",
                        isError: true
                    )
                }

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
