# Voice-controlled Mac design spec

**Recommendation in one line:** push-to-talk → **FluidAudio Parakeet-TDT** (local, ANE) → **Qwen3-0.6B 4-bit on MLX** intent router → tiered action layer (Hammerspoon/AppleScript/AX → MCP/Shortcuts → cloud LLM with computer-use fallback), with **Claude Haiku 4.5** for routing-LLM duties and **Sonnet 4.6 / GPT-5.4 / Gemini 3 Pro** for heavy work. Target median voice-to-action latency **300–600 ms** for known intents, **1–3 s** for cloud-reasoned tasks, **5–30 s** for vision-grounded computer-use fallback. Steady-state cost **<$0.50/hr** of active use, near-zero for deterministic commands.

The rest of this doc is the spec, latency budget, build plan, and gotchas.

-----

## 1. Latency budget (speed-first path)

|Stage                           |Component                                    |Budget                  |Notes                                                                                  |
|--------------------------------|---------------------------------------------|------------------------|---------------------------------------------------------------------------------------|
|Trigger                         |Global hotkey (CGEventTap)                   |0 ms                    |deterministic; no wake-word penalty                                                    |
|Capture + VAD start             |AVAudioEngine + Silero VAD                   |5–20 ms                 |endpointing fires ~150–250 ms after silence                                            |
|STT (per 5–10 s utterance)      |FluidAudio Parakeet-TDT v2 (CoreML/ANE)      |80–200 ms               |110–200× RTF on M4 Pro; 1.69% WER LibriSpeech-clean                                    |
|Intent classification           |Qwen3-0.6B 4-bit MLX, JSON-schema constrained|50–150 ms               |TTFT ≤100 ms for ≤300-token prompt, ≤30-token output                                   |
|**Deterministic action path**   |Hammerspoon / AX / AppleScript / Shortcuts   |5–500 ms                |AX `kAXPressAction` 5–20 ms; AppleScript 30–80 ms in-process; Shortcuts warm 200–500 ms|
|**Cloud LLM path (tool-using)** |Haiku 4.5 ReAct + MCP                        |500 ms–2 s/turn         |$1/$5 per Mtok, prompt caching 90% off                                                 |
|**Cloud reasoning path**        |Sonnet 4.6 / GPT-5.4 / Gemini 3 Pro          |1–4 s first token       |for research/coding/multi-step                                                         |
|**Vision/computer-use fallback**|Sonnet 4.6 `computer_20251124`               |2–6 s/action × N actions|last resort; 78% OSWorld                                                               |
|Feedback render                 |SwiftUI HUD overlay                          |5–15 ms                 |non-blocking                                                                           |

**Median wins**: any voice command resolvable to a registered intent (open app, switch space, send Slack, create reminder, paste snippet, run shortcut) hits **<500 ms end-to-end**. Cloud-LLM-required tasks (write a function, search the web, summarize) hit **1.5–3 s to first visible token**.

-----

## 2. Stack selection with rationale

### 2.1 Audio capture + trigger

**Push-to-talk** as primary (right-Option, configurable) via `CGEventTap` on `cgSessionEventTap` + Input Monitoring permission. **Porcupine** wake-word (“hey mac” or custom phrase) as secondary always-on mode — 1 MB model,  ~1% of one P-core,  30–100 ms detection, custom phrase trained in seconds via Picovoice Console.  Avoid OpenWakeWord for production: model license is CC-BY-NC-SA. Skip “Hey Siri” — not exposed to third parties.

**VAD**: Silero VAD (ONNX, MIT, ~1 ms/30 ms chunk) for endpointing. If end-of-speech latency becomes the bottleneck, swap to TEN VAD (sub-200 ms vs Silero’s several-hundred-ms hangover in conversational audio). On macOS 26+ only, Apple’s `SpeechDetector`  is acceptable.

### 2.2 STT

**Primary: FluidAudio Parakeet-TDT v2 (English) or v3 (multilingual)** via CoreML on the Neural Engine. 66 MB working set, 110–200× real-time, 1.69% WER LibriSpeech-clean, ~130 ms end-to-text in production (MacParakeet, Spokenly). Streaming variant `parakeet-eou-1.1b-coreml` has built-in end-of-utterance. 

**Why not the alternatives**:

- **Apple SpeechAnalyzer (macOS 26)** — 45× RT, native streaming, zero install, but ≈Whisper-medium accuracy; trades ~3 WER points to Parakeet. Use as fallback if Parakeet model fails to load.
- **WhisperKit large-v3-turbo** — 2.2% WER, true streaming hypothesis at 0.45 s/word,  99-language. Use only if you need non-English coverage outside Parakeet v3’s 25 EU langs.
- **Cloud (Groq whisper-large-v3-turbo $0.04/hr, Deepgram Nova-3 $0.0077/min, ElevenLabs Scribe v2 Realtime ~150 ms)** — fast and cheap, but Parakeet on ANE is still faster and free. Reserve cloud STT for the iOS companion or for accuracy-sensitive long-form transcription modes.

### 2.3 Local intent router

**Qwen3-0.6B 4-bit on MLX** with **Outlines** or **llama.cpp grammar** (via LM Studio’s `mlx-engine`) for JSON schema-constrained output. In the public tool-calling benchmark Qwen3-0.6B tied #1 (0.880) — a non-monotonic result (Qwen3-1.7B drops to 0.670),  so don’t auto-scale up. **Llama 3.2 1B Instruct** is the conservative pick if Qwen3-0.6B misclassifies on your eval set. **Phi-3.5-mini (3.8B)** is the upgrade path if 0.6–1B is insufficient.

Output schema:

```json
{"intent": "open_app|run_shortcut|web_research|code_task|free_form_llm|vision_fallback",
 "tool": "<registered tool name>",
 "args": {...},
 "confidence": 0.0-1.0,
 "needs_clarification": false}
```

Below `confidence < 0.7`, escalate to the cloud router (Haiku 4.5) instead of acting. Keep prompt ≤300 tokens (system + tool list summary), output ≤30 tokens. Expect **50–150 ms TTFT, 10–30 ms decode** on M3/M4 Pro+.

### 2.4 Cloud LLM orchestration

- **Routing/short tool calls**: **Claude Haiku 4.5** ($1/$5 per Mtok). Cheap, fast, supports computer-use action set, MCP-native. ~500 ms–2 s/turn with cached system prompt of tool registry.
- **Coding**: **Claude Sonnet 4.6** ($3/$15) inside Claude Code via MCP, or directly. Sonnet 4.6 is the default; switch to **GPT-5.4** ($2.50/$15) for tasks where its reasoning wins or for cheaper batch. Use **Claude Code’s built-in `/voice` and `/chrome`** — `/voice` uses Anthropic-cloud STT included with Claude.ai login (doesn’t consume tokens),  `/chrome` drives a Chrome extension via Native Messaging. 
- **Research/browsing**: **Sonnet 4.6 + Stagehand v3** (TS/Python SDK, MIT) for deterministic-with-AI-fallback browser automation,  cached actions <500 ms. **browser-use** for higher-autonomy research. **Comet** (Perplexity, free agent mode  since Oct 2025) as the no-code consumer fallback. Avoid Operator unless you already pay ChatGPT Pro.
- **Vision fallback** (apps without MCP/AppleScript/AX bindings): **Sonnet 4.6 `computer_20251124` tool** in a custom Mac harness using `SCScreenshotManager` + `CGEvent` synthesis. Toggle-gated; not always on. 78% OSWorld; 2–6 s/action; ~$0.05–0.50 per task.
- **Long context / multimodal**: **Gemini 3 Pro / 3.1 Pro** for >200K-token contexts (cheaper at scale, $1.25/$10 ≤200K then $2.50/$15). 

### 2.5 Action registry — tiered

The router selects a tier; lower tiers preferred for latency.

**Tier 0 — pure deterministic (Hammerspoon, ~5–50 ms)**
Window management, focus, hotkey synthesis, app launch (`hs.application.launchOrFocus`),  URL handlers, audio device switch, clipboard manipulation. No LLM in the loop after intent classification.

**Tier 1 — Apple Events / AX (50–500 ms)**
Mail/Calendar/Reminders/Notes/Safari/Chrome via AppleScript; arbitrary Cocoa app via **AXorcist** (chainable fuzzy-matched AX queries)  or **AXSwift**. AX `kAXPressAction` / `kAXSelectedTextAttribute` for read-without-clipboard. Cold AppleScript via `NSAppleScript` in-process (30–80 ms) — **never shell out to `osascript`** (80–250 ms + TCC attribution gets confused).

**Tier 2 — App Intents / Shortcuts (200 ms–2 s)**
`shortcuts run "<name>"` for HomeKit, Health, Music deep-links, Focus modes, Photos, Maps, plus any third-party app with App Intents (Bear, Things, OmniFocus, Drafts, Fantastical, Craft, Obsidian-via-plugin). Enumerate with `shortcuts list` at startup; auto-generate one tool per shortcut (the `dvcrn/mcp-server-siri-shortcuts` pattern with `INJECT_SHORTCUT_LIST=true`). 

**Tier 3 — MCP servers (stdio, 50–200 ms transport + LLM)**

- `FradSer/mcp-server-apple-events` (Swift + EventKit)  for Reminders/Calendar — better than AppleScript path
- `dvcrn/mcp-server-siri-shortcuts` for everything-Apple via Shortcuts 
- iTerm2 MCP (Python API + WebSocket) for terminal/coding workflows
- Filesystem MCP (`@modelcontextprotocol/server-filesystem`)
- Anthropic Connectors Directory: Linear, Slack, Notion, Asana, Atlassian, Gmail, GDrive, GCal, Stripe, Plaid (remote MCP from Anthropic’s cloud  — allowlist their IP ranges if behind firewall) 
- Distribute custom servers as `.mcpb` bundles (Claude Desktop ships Node.js so Node bundles need no local install) 

**Tier 4 — shell (Process, 30–80 ms launch)**
Any CLI: `git`, `gh`, `rg`, `llm`, `aider`, `claude`, `codex`. Always `zsh -l -c` for proper PATH/profile. Sandbox child can’t inherit, so direct distribution only.

**Tier 5 — vision-grounded computer-use (2–6 s/action)**
Sonnet 4.6 `computer_20251124` tool. Custom Mac harness (no Linux/Docker reference impl): `SCScreenshotManager.captureImage()` 30–80 ms warm, `CGEvent` synthesis 1–3 ms/event. ScreenCaptureKit stream at **2–5 fps** for agentic mode (token cost dominates over frame rate). **Don’t run 60 fps** — image tokens are ~1.5k per 1280×800 screenshot; you’ll burn $/min. Always toggled, never default.

### 2.6 Feedback / UI

Transient SwiftUI HUD overlay (status-bar-attached), 280×80 px, three states: listening (waveform), thinking (intent + tool resolved), executing (action + undo affordance). Esc cancels. Cmd+Z within 5 s undoes the last action where reversible (clipboard restore, Shortcuts inverse, AppleScript-emitted undo). For multi-step cloud-LLM tasks, expand to a 320-px right-edge sidebar with a streaming transcript of tool calls + “interrupt” button. Streaming tokens render at LLM rate; user can speak again to interrupt — VAD wake on user speech cancels the current LLM stream (Anthropic Messages API supports stream cancellation; MCP tool calls in flight will run to completion).

Context injected into every LLM call, automatically:

- frontmost app + window title (`NSWorkspace` + `CGWindowListCopyWindowInfo`)
- selected text via AX `kAXSelectedTextAttribute` (no clipboard clobber)
- list of open windows (titles only, no pixels) — no Screen Recording prompt
- working dir if frontmost is a terminal/IDE (parse from window title or AppleScript for iTerm2/Terminal/VS Code/Cursor)
- screenshot **only when** vision fallback is invoked

-----

## 3. Per-domain workflows

### 3.1 OS control

Most commands are deterministic. “Open Slack” → Tier 0 (Hammerspoon). “Reply to John saying I’ll be late” → Tier 1 (Mail/Messages AppleScript) or Tier 3 (apple-events MCP) with Haiku 4.5 phrasing the reply. “Set a reminder to renew passport in November” → Tier 3 EventKit MCP, no LLM beyond intent. “Find the email about Q4 numbers and forward it to Sarah” → Tier 3 Mail MCP + Haiku 4.5 tool-using ReAct, ~2–4 s total.

**Don’t depend on Apple Intelligence Siri.** As of April 2026 the upgraded personalized Siri (on-screen awareness, App Intents action chaining) has slipped from iOS 18.4 to “by end of 2026” per Apple, with Bloomberg reporting it likely misses 26.4 (March/April 2026).   Build assistant-schema-conformant App Intents now so you’re ready when it ships, but route through your own stack today.

### 3.2 Coding

Voice → Cursor or Claude Code. Three sub-modes:

1. **Dictation into chat/Composer**: Parakeet → text injection into focused IDE field. <300 ms.
1. **Voice-to-Claude-Code**: invoke `claude` CLI with `--print` and the transcript as prompt; or pipe through Claude Code’s built-in `/voice` (Cmd+Space hold). Use the **Spokenly MCP** (`mcp__spokenly__ask_user_dictation`) so the agent can voice-prompt the user for clarification mid-task. 
1. **Terminal voice control**: iTerm2 MCP for “split this pane and tail the staging logs” → AppleScript-driven iTerm2 Python API.

VS Code path: Microsoft `VS Code Speech` extension (free, on-device,   `accessibility.voice.keywordActivation` for “Hey Code”)  + Copilot Chat agent with MCP. Use this if user is on Copilot rather than Claude Code.

### 3.3 Research / browsing

Three escalation tiers:

1. **Quick Q&A** (“what’s the population of Latvia”): cloud LLM direct, no browser. Haiku 4.5 with web search tool. <1.5 s to first token.
1. **Real research** (“compare these three vendors and summarize”): Sonnet 4.6 + Stagehand (deterministic + AI fallback,  cached actions sub-second) or browser-use for full autonomy. Open results in a split right-pane in user’s existing Chrome via AppleScript `do JavaScript`. 5–30 s typical.
1. **Form-filling / authenticated workflows**: Claude in Chrome via Claude Code `/chrome` (works on Chrome/Edge, **not Brave/Arc/WSL**) or Comet (free agent mode). Be aware of Anthropic-published prompt-injection attack rate: **23.6% without mitigations, 11.2% with**.  Run with the prompt-injection classifier on; require user confirmation for any payment/credentials/destructive action.

-----

## 4. Permissions model and onboarding

**Distribution**: Developer ID + notarytool, Sparkle for updates. **App Store path is closed** — Accessibility, Apple Events to arbitrary apps, Full Disk Access, persistent Screen Recording are incompatible with App Sandbox. Stable code-signing identity is mandatory; resigning under a different team ID drops every TCC entry.

**Onboarding sequence** (each prompt is unbatchable; walk the user through one at a time with a “Test” button that intentionally trips it):

1. **Microphone** — `AVCaptureDevice.requestAccess(for: .audio)`. Info.plist `NSMicrophoneUsageDescription`. Hardened entitlement `com.apple.security.device.audio-input`.
1. **Accessibility** — `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.  User toggles in System Settings; deep-link via `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. 
1. **Screen Recording** — `CGRequestScreenCaptureAccess()`. Info.plist `NSScreenCaptureUsageDescription`.  **Sequoia/Tahoe show a monthly re-consent prompt**  that is unsuppressible without the undocumented `com.apple.developer.persistent-content-capture` entitlement (Apple-gated, not granted to general devs)  or an MDM PPPC profile. Plan UX around it; prefer AX + window-list metadata where pixels aren’t required.
1. **Automation (Apple Events)** — per-target prompt on first event. Hardened entitlement `com.apple.security.automation.apple-events` plus Info.plist `NSAppleEventsUsageDescription`. Without these, AppleScript silently fails with errAEPrivilegeError -1743.
1. **Input Monitoring** — `CGRequestListenEventAccess()`. Needed only if you use a separate `CGEventTap` for the global hotkey alongside Accessibility (some configurations require both).
1. **Full Disk Access** — only if reading `~/Library/Mail`, `~/Library/Messages/chat.db`. No programmatic request; user must drag binary into FDA list. Skip unless feature requires it.

**Hardened Runtime entitlements** to set: `com.apple.security.automation.apple-events`, `com.apple.security.device.audio-input`, `com.apple.security.cs.allow-jit` (for MLX/Metal). Sign inside-out, **never `--deep`**.

-----

## 5. Cost model

For a moderately heavy day (3 hours active use, ~200 voice commands, ~30 cloud-LLM-requiring, ~5 vision-fallback tasks):

|Layer                                                                 |Per active hour          |Notes                                     |
|----------------------------------------------------------------------|-------------------------|------------------------------------------|
|STT (local Parakeet)                                                  |$0                       |electricity only                          |
|Intent router (local MLX)                                             |$0                       |                                          |
|Routing LLM (Haiku 4.5, ~10 commands/hr × 1k in / 200 out)            |~$0.02                   |with 90% prompt cache hit on system prompt|
|Heavy LLM (Sonnet 4.6, ~5 tasks/hr × 5k in / 1k out)                  |~$0.10                   |                                          |
|Vision fallback (Sonnet 4.6 + screenshots, ~1.5 tasks/hr × 30 actions)|~$0.20                   |the dominant cost; toggle-gate it         |
|Browser automation (Stagehand, model tokens only)                     |~$0.05                   |varies wildly by task                     |
|**Total**                                                             |**~$0.30–0.50/hr active**|scales sublinearly with caching           |

Bypass-LLM-entirely commands (the majority of OS-control intents) cost **$0**. The vision fallback is the cost-sensitive lever — restrict it.

If you’d rather use cloud STT (Groq whisper-large-v3-turbo at $0.04/hr  is the floor; Deepgram Nova-3 $0.46/hr; AssemblyAI Universal-Streaming effectively ~$0.20/hr after session-time billing),  it adds roughly $0.10–0.50/hr but doesn’t beat Parakeet-on-ANE on speed.

-----

## 6. Phased build plan

### Phase 0 — Spike (1 week)

Validate latency assumptions on the user’s actual hardware. Build a CLI tool: hotkey → AVAudioEngine → FluidAudio Parakeet → stdout. Measure p50/p99 end-to-text. Run Qwen3-0.6B in LM Studio with a fixed intent schema, hit it via OpenAI-compatible API, measure TTFT and decode. Confirm <250 ms combined STT+intent. If FluidAudio install hits friction, fall back to WhisperKit large-v3-turbo.

### Phase 1 — MVP (2–3 weeks)

A menu-bar Swift app with:

- Push-to-talk hotkey + HUD overlay
- Parakeet STT, Silero VAD, intent router via local LM Studio server
- **Tier 0 actions only**: app launch, window management, focus modes, paste-snippet, audio device switch, hotkey macros. All via Hammerspoon-as-library (or reimplemented in Swift).
- 20 hand-curated intents
- Onboarding flow for Microphone + Accessibility permissions

Shippable to the user. Solves “open Slack”, “switch to focus mode”, “paste my address”, “mute the mic”, etc. Latency target: **<300 ms p50**.

### Phase 2 — Tier 1+2 actions and routing LLM (3–4 weeks)

Add:

- AppleScript via `NSAppleScript` for Mail/Calendar/Reminders/Safari/Chrome
- AXorcist-based AX driver for arbitrary Cocoa apps
- App Intents / Shortcuts enumeration at startup, auto-tooled
- Haiku 4.5 escalation when local intent confidence <0.7 — gives free-form natural-language understanding for unknown intents
- Selected-text context injection via AX

Now solves “create a reminder to call mom tomorrow”, “reply to Sam saying yes”, “summarize this selection”. Latency: **<800 ms p50** for Haiku-routed paths.

### Phase 3 — MCP and coding/research (3–4 weeks)

- MCP client implementation (use Anthropic’s TS SDK or Swift SDK)
- Bundled MCP servers: `mcp-server-apple-events`, iTerm2 MCP, filesystem, plus user-installed ones via `.mcpb` bundles
- Claude Code integration: `/voice`, `/chrome`, Spokenly-style MCP for agent → user voice clarification
- Sonnet 4.6 for research/coding tasks
- Stagehand v3 in-process for browser automation; spawn Chromium with `--remote-debugging-port` for headless tasks

Adds the coding and research domains. Latency: **1.5–4 s p50** for cloud-reasoned tasks.

### Phase 4 — Vision fallback and polish (3–4 weeks)

- Sonnet 4.6 computer-use harness: `SCScreenshotManager` + `CGEvent` synthesis, toggle-gated
- Prompt-injection classifier on for vision mode and for Claude-in-Chrome usage
- Undo affordance (5-second window on reversible actions)
- Always-on Porcupine wake word as opt-in
- Telemetry: latency histograms per intent, intent-classification confusion matrix for retraining

### Phase 5 — Optional

- Streaming partials for “live dictation” mode (WhisperKit hypothesis stream or Parakeet-EOU streaming)
- iOS companion app using Apple SpeechAnalyzer (macOS 26 stack mirrors)
- Custom-trained intent classifier on user’s actual command logs (DistilBERT-class, runs in 5–10 ms)
- Eye tracking via Talon’s gaze infrastructure for UI element targeting (Tobii 5)

-----

## 7. Gotchas

**Permissions**:

- **Each TCC service prompts separately on first use; no batch grant** outside MDM. Onboarding must walk through them sequentially.
- **Notarized vs non-notarized builds get different TCC entries** — the Designated Requirement string changes; permissions evaporate when you add notarization mid-development. Use `tccutil reset All com.your.bundle` and re-grant.
- **Sequoia+ monthly Screen Recording re-prompt is unsuppressible** for general developers. The persistent-content-capture entitlement is Apple-gated. Design UX to assume the prompt will reappear; minimize Screen Recording dependence.
- **`com.apple.security.automation.apple-events` only permits prompting**, it doesn’t pre-approve. Without it, hardened apps fail silently with -1743.
- **Don’t sign with `--deep`** — sign helpers/frameworks first, then outer app. (Apple DTS: “–deep Considered Harmful”.)

**Action layer**:

- **Notes app AppleScript is gimped** — no checklists, lossy HTML body. Use Bear/Drafts/SideNotes for note actions, or AX-automate Notes UI.
- **Messages reading is sandboxed off** in modern macOS even via AppleScript. Send works; read doesn’t. FDA + reading `~/Library/Messages/chat.db` is the workaround but fragile.
- **Slack/Discord/Notion have zero AppleScript surface**; AX-only, partial trees in Slack (Electron). Combine AX + screenshot+OCR fallback.
- **Firefox has no AppleScript dictionary** — AX or use a separate CDP-controlled Chromium instance.
- **`postToPid` keystrokes are unreliable** when target isn’t frontmost; many apps ignore non-`cghidEventTap` events. Activate target first, then post.
- **Shortcuts cold-start is 800–2000 ms**, warm 200–500 ms. Don’t put it in the hot path for sub-500 ms targets.
- **JXA still works but is unmaintained since ~2016**; stick to AppleScript for new code.

**LLM stack**:

- **Apple Intelligence Siri’s promised personalized actions are not shipping in time** — Bloomberg reports it likely misses macOS 26.4 (Mar/Apr 2026), possibly slipping to 26.5 or iOS 27 (Sept 2026). Don’t make Siri the action layer.
- **Claude in Chrome doesn’t work on Brave, Arc, or WSL.** Chrome and Edge only.
- **Anthropic prompt-injection rate is 23.6% unmitigated, 11.2% with mitigations** for Claude in Chrome — non-trivial. Require user confirmation for all destructive/financial actions.
- **Tool-call benchmark scores are non-monotonic with size** in the small-LLM regime (Qwen3-0.6B beats Qwen3-1.7B). Don’t auto-scale up; build an eval set on your actual intents.
- **OpenAI whisper-1 has ~2 s median latency**; never use it for interactive paths. Use gpt-4o-transcribe Realtime API or Groq instead.
- **LM Studio’s displayed token speed can be misleading** at long context (UI shows decode rate, not effective rate including prefill). Measure end-to-end TTFT, not the on-screen number.
- **Some “2026” model names floating around** (Qwen 3.5/3.6, Gemma 4, Opus 4.7) are mixed primary-source / third-party-aggregator. Pin to specific snapshot IDs in your `model` parameter and verify on the vendor’s release-notes page before committing.

## 8. Conclusion

The hot path is local. **Hotkey → Parakeet → Qwen3-0.6B → deterministic action** is achievable in <500 ms on current Apple Silicon, and that path covers the bulk of OS-control intents at zero marginal cost. Cloud LLMs handle the long tail — research, coding, ambiguous natural-language commands, and the vision-grounded fallback for apps without integration points. MCP is the right contract for app-specific control, and the ecosystem is rich enough on Mac (apple-events, Shortcuts, iTerm2, plus the Anthropic Connectors Directory) to avoid most AppleScript brittleness. Apple Intelligence’s slipped Siri rebuild means there’s a real product gap through 2026; build assistant-schema App Intents now to be ready, but ship your own stack today. The two binding constraints are not technical — they’re TCC permission UX (unbatchable, monthly re-prompts) and prompt-injection risk on vision-grounded computer use (10–24% empirically). Both are manageable with discipline; neither is solved.