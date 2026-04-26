# MasterControl

Voice-controlled Mac assistant. Always-on listening, local STT/TTS, fuzzy app launching, native AppleScript automation, and a Claude-powered agent for everything that doesn't fit a deterministic rule.

Say **"master control, …"** and it does the thing.

Design source of truth: [`docs/SPEC.md`](docs/SPEC.md).

## What it does

The mic is always on. Speak naturally — utterances are split on silence by an on-device VAD. Anything starting with the wake phrase **"master control"** is acted on; everything else is silently ignored.

The router tries explicit phrase patterns first (sub-millisecond), then falls through to Claude with tool access for compositional and free-form requests.

### Open any installed app

Fuzzy-matched against your `/Applications`, `/System/Applications`, and `~/Applications`, so you don't have to know the canonical name:

| You say | What launches |
|---|---|
| "master control, open Slack" | Slack.app |
| "master control, open Chrome" | Google Chrome.app (word match) |
| "master control, launch Claude" | Claude.app (Levenshtein for STT slips like "claw") |
| "master control, switch to Cursor" | Cursor.app |

### Control music + media (universal)

Routes to whatever app currently holds "now playing" — Spotify, Apple Music, YouTube in any browser, Podcasts, etc.

| You say | What happens |
|---|---|
| "master control, play" / "master control, pause" | media key playPause |
| "master control, skip" / "next song" | media key next |
| "master control, previous song" | media key previous |
| "master control, what's playing" | speaks the current Spotify track + artist |

### Drive Chrome (front window)

| You say | What happens |
|---|---|
| "master control, next tab" / "previous tab" | switches tabs |
| "master control, new tab" / "close tab" | …obvious |
| "master control, reload" / "refresh" | reloads the active tab |
| "master control, go back" / "go forward" | nav history |

### System actions

| You say | What happens |
|---|---|
| "master control, lock screen" | screen locks (Cmd-Ctrl-Q) |
| "master control, volume up" / "louder" | output volume +10 |
| "master control, volume down" / "quieter" | output volume −10 |

### Run whitelisted Terminal commands

| You say | What runs in Terminal.app |
|---|---|
| "master control, git status" | `git status` |
| "master control, git log" | `git log --oneline -20` |
| "master control, list files" / "ls" | `ls -la` |
| "master control, pwd" / "where am i" | `pwd` |
| "master control, clear terminal" | `clear` |

Free-form text into the terminal stays on the dictation path (no Enter key) for safety.

### Dictate + navigate any app

| You say | What happens |
|---|---|
| "master control, type hello world" | "hello world" types into the focused app |
| "master control, send running 5 min late" | types "running 5 min late" + presses Enter (chat-app send pattern; works in Slack, Messages, WhatsApp, anywhere) |
| "master control, post just landed" / "master control, reply on it" | same as send — `post` and `reply` are aliases |
| "master control, press tab" | Tab key |
| "master control, tab three times" | three tabs in a row |
| "master control, save the file" | Cmd+S (the agent picks the right key combo) |
| "master control, press escape" / "press enter" | …obvious |
| "master control, arrow down" / "press up" | arrow keys |

Dictation uses Unicode-string events for typed text; the `press_key` tool uses proper virtual-key codes for Tab/arrows/Cmd-shortcuts so apps see them as real keystrokes (Tab moves focus, Cmd+S saves, etc.). Both use `cghidEventTap` and require **Accessibility** permission for delivery to other apps — first use prompts you, or add `MasterControl.app` in System Settings → Privacy & Security → Accessibility.

### Ask anything

For anything the deterministic patterns don't catch, Claude (Haiku 4.5) takes over with `web_search` plus 7 custom tools (`open_app`, `media`, `spotify`, `chrome`, `system_action`, `dictate`, `claude_task`). Claude can compose multi-step requests:

| You say | What Claude does |
|---|---|
| "master control, what's the weather in Lisbon" | calls `web_search`, speaks the answer |
| "master control, who won the Champions League this year" | searches, summarizes |
| "master control, open Spotify and play something" | calls `open_app(Spotify)` then `media(playpause)` |
| "master control, switch to Chrome and reload" | two tool calls in sequence |
| "master control, tell me a joke" | answers directly, no search |

### Delegate to Claude Code

If `claude` is on your PATH, the agent can hand off long-running coding/research tasks to a Claude Code subagent in the background:

| You say | What happens |
|---|---|
| "master control, have Claude review my latest commit" | spawns `claude --print` with the task; Haiku immediately confirms ("Started Claude on that"); a system notification fires when Claude finishes, with the result |
| "master control, ask Claude to research Swift macros" | same — read-only tool set by default |

Claude tasks run in `~/` by default. Output is logged to `~/Library/Logs/MasterControl/claude/<timestamp>.log`. The default permission posture is **read-only** (`Read,Grep,Glob,WebSearch,WebFetch`) — Claude can answer and search but can't edit files. Ask explicitly to "have Claude *change*" / "have Claude *implement*" and the agent will pass `permission: "full"`, lifting the restriction.

Because there's no terminal attached to prompt against, Claude runs with `--dangerously-skip-permissions`. Combined with the read-only tool set this is reasonable; if you grant `full` permission via voice, anything Claude is willing to do, it will do unattended. Calibrate trust accordingly.

Responses are spoken via local **Kokoro neural TTS** (FluidAudio) — no cloud TTS, no per-character cost, sounds dramatically more natural than `AVSpeechSynthesizer`.

### Audible feedback

- **Tink** when the wake phrase is recognized
- **Tink** when an action completes
- **Basso** if an action fails

The menu-bar dropdown shows the recent activity log; everything is also written to `~/Library/Logs/MasterControl/activity.jsonl`.

## How it works

```
   mic ──► AVAudioEngine ──► Silero VAD ──► Parakeet STT ──► WakeWord
                                                                 │
                            ┌────────────────────────────────────┘
                            ▼
                   DeterministicRouter ──── match? ──► IntentDispatcher
                            │                              │
                            ▼ no match                     ▼
                   Anthropic Haiku 4.5         /usr/bin/open • osascript
                   (web_search + tool use)     • CGEvent media keys
                            │                  • CGEvent keystrokes
                            ▼
                      Kokoro TTS ──► system audio
```

All on-device except the Anthropic call (only used when deterministic doesn't match). 9 SwiftPM modules under `Sources/`:

| Module | Job |
|---|---|
| `MCCore` | shared types — Intent, Action, Speaker, InstalledApps |
| `MCAudio` | mic capture, Silero VAD, Kokoro TTS |
| `MCSTT` | FluidAudio Parakeet wrapper |
| `MCRouter` | wake-phrase filter, deterministic patterns, fuzzy app matcher |
| `MCActions` | Tier-0/1 action handlers (open_app, AppleScript, media keys, dictation) |
| `MCMlx` | local MLX Qwen3 (used only by the spike for measurement now) |
| `MCCloud` | Anthropic agent + tool definitions + dotenv loader |
| `MCApp` | menu-bar SwiftUI shell, AppListener actor, ToolBridge |
| `MCInput` | CGEventTap (legacy push-to-talk; unused by the app, retained for the spike) |

## Install

### One-time setup

1. **macOS 14+ on Apple Silicon.** Tested on macOS 26.1 Tahoe (M-series).

2. **Drop your Anthropic key** into `~/Downloads/.env` for the LLM-fallback responder. (The path is hardcoded today; survives Finder launches that don't inherit your shell env.) If you skip this, deterministic actions still work — just no spoken answers for free-form questions.

   ```bash
   echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/Downloads/.env
   ```

3. **Build and install** as a real `.app`:

   ```bash
   scripts/install.sh
   ```

   This compiles via `xcodebuild` (we need Xcode for the MLX Metal shaders), wraps the binary in `MasterControl.app` with a proper `Info.plist` + hardened-runtime entitlements + the SwiftPM resource bundles for Kokoro / MLX / Tokenizers, ad-hoc signs it, and drops it in `/Applications/MasterControl.app`.

4. **Launch:**

   ```bash
   open /Applications/MasterControl.app
   ```

   First launch prompts for **Microphone**. First Chrome / Spotify / Terminal command prompts for **Apple Events** (one-time per app).

5. **Optionally add to login items** — System Settings → General → Login Items → "+" → MasterControl. (Settings UI to do this in-app is on the roadmap.)

The app currently uses **ad-hoc signing** — fine for installing on your own Mac, but Gatekeeper will warn if you copy the bundle to someone else's machine. Distributable Developer ID + notarytool flow is on the roadmap.

## Develop

```bash
# Build both schemes (mc-spike + MasterControl)
scripts/build.sh

# Run the menu-bar app from the build dir (without installing)
scripts/run-app.sh

# Run the latency-measurement CLI
scripts/run.sh --iterations 10
```

The `mc-spike` CLI is the original Phase 0 measurement harness — same pipeline as the app, but bounded to N utterances, prints a p50/p99 histogram, and exits. Useful for regression-testing latency or comparing model swaps.

## Roadmap

The full roadmap lives in [`docs/SPEC.md`](docs/SPEC.md) and the per-wave plan is in `.planning/`. Current next batch:

- **Wave 1**: Anthropic tool-use ✅, persistent activity log ✅. Next: Mail / iMessage / WhatsApp send via AppleScript + `CNContactStore` fuzzy contact matching, Calendar/Reminders via EventKit, audio output device switching.
- **Wave 2**: window management (left/right half, fullscreen, center), Apple Music control, Spotify play-by-name.
- **Wave 3**: Developer ID signing + notarization, login items, onboarding flow, settings UI, Sparkle auto-updates.
- **Wave 4**: streaming Parakeet (lower latency), VAD tuning, optionally Porcupine wake word.

Skipped intentionally: Notes (gimped AppleScript surface), dark-mode toggle, Slack/Discord/Notion (no AppleScript — wait for MCP), reading iMessages (sandboxed off), computer-use vision (last-resort).

## License

TBD
