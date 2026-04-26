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
        /// Optional natural-language string the host should speak aloud
        /// (used by query-style actions like "what's playing"). Nil for
        /// fire-and-forget commands.
        public let speak: String?

        public init(label: String, status: Status, speak: String? = nil) {
            self.label = label
            self.status = status
            self.speak = speak
        }
    }

    public init() {}

    public func dispatch(_ intent: Intent) async -> Result {
        switch intent.intent {
        case .openApp:
            return await openApp(args: intent.args)
        case .runShortcut:
            return await runShortcut(args: intent.args)
        case .appCommand:
            return await appCommand(args: intent.args)
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

    // MARK: - app_command

    private func appCommand(args: [String: ArgValue]) async -> Result {
        guard let app = args["app"]?.stringValue else {
            return Result(label: "app_command (missing app)", status: .failed("missing 'app' arg"))
        }
        switch app {
        case "chrome":
            return await chromeCommand(args: args)
        case "terminal":
            return await terminalCommand(args: args)
        case "media":
            return mediaCommand(args: args)
        case "spotify":
            return spotifyCommand(args: args)
        default:
            return Result(label: "\(app) (unsupported)", status: .deferred)
        }
    }

    // MARK: - media (universal media keys)

    /// System-wide media keys. Don't target a specific app — macOS routes
    /// to whatever holds "now playing" (Spotify, Music, browser, etc.).
    private nonisolated func mediaCommand(args: [String: ArgValue]) -> Result {
        guard let command = args["command"]?.stringValue else {
            return Result(label: "Media (missing command)", status: .failed("missing 'command' arg"))
        }
        let key: MediaKeys.Key
        let label: String
        switch command {
        case "playpause":
            key = .playPause; label = "Play/pause"
        case "next":
            key = .next; label = "Next track"
        case "prev":
            key = .previous; label = "Previous track"
        default:
            return Result(label: "Media \(command)", status: .failed("unknown command"))
        }
        MediaKeys.post(key)
        return Result(label: label, status: .executed)
    }

    // MARK: - spotify (in-app AppleScript)

    /// Spotify-specific commands via NSAppleScript. Used when we need
    /// more than play/pause — querying current track, playing a named
    /// track, etc. First invocation prompts for Apple Events on Spotify.
    private nonisolated func spotifyCommand(args: [String: ArgValue]) -> Result {
        guard let command = args["command"]?.stringValue else {
            return Result(label: "Spotify (missing command)", status: .failed("missing 'command' arg"))
        }
        switch command {
        case "play":
            return runSpotifyScript("tell application \"Spotify\" to play", label: "Spotify: play")
        case "pause":
            return runSpotifyScript("tell application \"Spotify\" to pause", label: "Spotify: pause")
        case "playpause":
            return runSpotifyScript("tell application \"Spotify\" to playpause", label: "Spotify: play/pause")
        case "next":
            return runSpotifyScript("tell application \"Spotify\" to next track", label: "Spotify: next")
        case "prev":
            return runSpotifyScript("tell application \"Spotify\" to previous track", label: "Spotify: previous")
        case "now_playing":
            return spotifyNowPlaying()
        default:
            return Result(label: "Spotify \(command)", status: .failed("unknown command"))
        }
    }

    private nonisolated func runSpotifyScript(_ source: String, label: String) -> Result {
        do {
            try AppleScriptRunner.run(source)
            return Result(label: label, status: .executed)
        } catch {
            return Result(label: label, status: .failed(error.localizedDescription))
        }
    }

    private nonisolated func spotifyNowPlaying() -> Result {
        let script = """
        tell application "Spotify"
          if player state is playing or player state is paused then
            set t to name of current track
            set a to artist of current track
            return t & " by " & a
          else
            return "Nothing is playing"
          end if
        end tell
        """
        do {
            let out = try AppleScriptRunner.run(script)
            let text = out.string ?? "Nothing is playing"
            return Result(
                label: "Now playing: \(text)",
                status: .executed,
                speak: text
            )
        } catch {
            return Result(
                label: "Spotify: now playing",
                status: .failed(error.localizedDescription)
            )
        }
    }

    /// Chrome AppleScript bindings. Targets Google Chrome explicitly so the
    /// command works whether or not Chrome is the frontmost app. Each first
    /// invocation against a target prompts for Apple Events permission.
    private func chromeCommand(args: [String: ArgValue]) async -> Result {
        guard let command = args["command"]?.stringValue else {
            return Result(label: "Chrome (missing command)", status: .failed("missing 'command' arg"))
        }
        let app = "Google Chrome"
        let (script, label): (String, String) = {
            switch command {
            case "next_tab":
                return ("""
                tell application "\(app)"
                  activate
                  tell front window
                    set N to count of tabs
                    set i to active tab index
                    if i < N then set active tab index to i + 1
                  end tell
                end tell
                """, "Chrome: next tab")
            case "prev_tab":
                return ("""
                tell application "\(app)"
                  activate
                  tell front window
                    set i to active tab index
                    if i > 1 then set active tab index to i - 1
                  end tell
                end tell
                """, "Chrome: previous tab")
            case "new_tab":
                return ("""
                tell application "\(app)"
                  activate
                  tell front window to make new tab at end of tabs
                end tell
                """, "Chrome: new tab")
            case "close_tab":
                return ("""
                tell application "\(app)"
                  tell front window to close active tab
                end tell
                """, "Chrome: close tab")
            case "reload":
                return ("""
                tell application "\(app)"
                  tell active tab of front window to reload
                end tell
                """, "Chrome: reload")
            case "back":
                return ("""
                tell application "\(app)"
                  tell active tab of front window to go back
                end tell
                """, "Chrome: back")
            case "forward":
                return ("""
                tell application "\(app)"
                  tell active tab of front window to go forward
                end tell
                """, "Chrome: forward")
            default:
                return ("", "Chrome: \(command)")
            }
        }()
        guard !script.isEmpty else {
            return Result(label: label, status: .failed("unknown command"))
        }
        return await runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            label: label
        )
    }

    /// Terminal AppleScript bindings. Only runs whitelisted commands —
    /// the deterministic router emits a fixed `shell` string per match.
    /// Free-form text-into-terminal stays on the dictate path so we don't
    /// hand voice commands an Enter keystroke.
    private func terminalCommand(args: [String: ArgValue]) async -> Result {
        guard args["command"]?.stringValue == "run" else {
            return Result(label: "Terminal (missing run command)", status: .failed("expected 'run'"))
        }
        guard let shell = args["shell"]?.stringValue, !shell.isEmpty else {
            return Result(label: "Terminal (missing shell)", status: .failed("missing 'shell' arg"))
        }
        // Escape double-quotes for the AppleScript string literal.
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          activate
          if (count of windows) = 0 then
            do script "\(escaped)"
          else
            do script "\(escaped)" in front window
          end if
        end tell
        """
        return await runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            label: "Terminal: \(shell)"
        )
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
