# MasterControl

Voice-controlled Mac assistant. Push-to-talk → on-device speech-to-text (FluidAudio Parakeet) → on-device intent router (Qwen3-0.6B via LM Studio) → tiered action layer.

Design source of truth: [`docs/SPEC.md`](docs/SPEC.md).

## Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Latency spike — CLI tool to validate `hotkey → STT → intent` p50 < 250 ms on this Mac | in progress |
| 1 | MVP menu-bar app with 20 deterministic intents | not started |
| 2+ | Cloud-LLM escalation, MCP, vision fallback, polish | roadmap |

## Requirements

- macOS 14+ (developed on macOS 26.1 Tahoe)
- Apple Silicon (M-series)
- Swift 6+ toolchain (Xcode 16+ or `xcode-select` Command Line Tools)

Everything runs locally and in-process: Parakeet STT, Silero VAD, and Qwen3-0.6B-MLX as the LLM-fallback router. No separate runtime, no cloud calls.

## Phase 0 — running the latency spike

### One-time setup

1. **Build** (downloads dependencies + Parakeet + Silero VAD on first build, ~400 MB):

   ```bash
   scripts/build.sh
   ```

   We build via `xcodebuild` rather than `swift build` because mlx-swift's Metal shaders (used by the spike's local-LLM measurement path) need Xcode to compile to `.metallib`. Everything else compiles fine either way.

2. **Permissions** — first run prompts for Microphone (allow). Dictation may need Accessibility (System Settings → Privacy & Security → Accessibility) for keystrokes to land in other apps. First Chrome / Terminal command will prompt for Apple Events (one-time per target app).

3. **Anthropic API key** for the LLM-fallback responder (the system speaks the response when your utterance doesn't match a hardcoded command):

   ```bash
   export ANTHROPIC_API_KEY=sk-ant-...
   ```

   Default model is `claude-haiku-4-5` (cheapest + fastest). If the key isn't set the app still runs — un-classified utterances just don't get a spoken response.

### Running

Two surfaces share the same pipeline (STT + VAD + wake-phrase + router + dispatcher):

```bash
# Menu-bar app — runs continuously, microphone icon in the menu bar
scripts/run-app.sh

# CLI spike — runs N utterances, prints histogram, exits
scripts/run.sh --iterations 10

# CLI spike with no LLM fallback (deterministic routing only)
scripts/run.sh --no-llm --iterations 10
```

The menu-bar app is the user-facing form: click the icon to see recent activity, pause/resume, or quit. The CLI spike stays as a measurement harness.

**No hotkeys.** The mic is always on. Speak naturally — VAD splits the stream into utterances. Only utterances that begin with the wake phrase **"master control"** are acted on; everything else is ignored.

Modes are selected by the word that follows the wake phrase:

| Speak | Result |
|---|---|
| `master control, open Slack` | route → deterministic match → action fires |
| `master control, lock screen` | route → action fires |
| `master control, type hello world this is a test` | dictate → typed into the focused app |

Each *accepted* utterance counts toward `--iterations`. Ignored ones (no wake word) don't.

### Expected output

```
[setup] warm-loading Parakeet…
[setup] warming router (qwen3-0.6b-mlx-4bit)…
[ready] hold right-Option to record, release to transcribe.
          30 iterations · Ctrl-C to abort early.
[1/30] capture   850 ms · stt 142.3 ms · intent  78.1 ms · stt+intent 220.4 ms
       text: "open slack"
       {"intent":"open_app","tool":"launch","args":{"name":"Slack"},"confidence":0.94,"needs_clarification":false}
...

==== latency histogram (n=30) ====
stage             p50      p99      min      max
capture        850.0 ms 1200.0 ms  600.0 ms 1450.0 ms
stt            140.5 ms  210.2 ms   95.1 ms  234.7 ms
intent          75.3 ms  180.4 ms   55.2 ms  195.8 ms
stt+intent     220.1 ms  380.7 ms  155.4 ms  410.6 ms
total         1070.1 ms 1580.7 ms  755.4 ms 1860.6 ms
==================================
✅ Phase 0 acceptance (stt+intent): p50=220.1 ms (target <250 ms), p99=380.7 ms (target <400 ms)
```

### Acceptance criteria

- p50 STT+intent **< 250 ms**
- p99 STT+intent **< 400 ms**

Commit `phase0-results.log` to the repo as evidence the latency budget is real on the target hardware.

### Troubleshooting

- **Falls back to CPU instead of ANE** — STT p50 will be 3-5× slower. Confirm Apple Silicon: `sysctl -n machdep.cpu.brand_string`. Confirm CoreML is using ANE: Activity Monitor → ANE column should pin during transcription.
- **Router timing dominates (intent > 200 ms)** — LM Studio prefill cost. Check that the router warm-up happened (look for "warming router" log). Consider trimming the system prompt, or swap to a smaller Qwen variant.
- **Hotkey doesn't fire** — Input Monitoring not granted *for this exact binary path*. macOS TCC tracks by code-signing identity + path; rebuilding may invalidate the grant. Re-add `mc-spike` in System Settings → Privacy & Security → Input Monitoring, or run `tccutil reset ListenEvent` and re-grant.
- **Microphone returns silence** — first run may fail if Mic was granted *during* the run. Quit and re-launch.
- **`Connection refused` on the router** — LM Studio server isn't started, or it's bound to a different port. Re-check `curl http://localhost:1234/v1/models`.

If the run fails the budget, the per-stage histogram identifies the culprit. See `docs/SPEC.md` §1 (latency budget) and §7 (gotchas) for mitigations.

## Project layout

```
Sources/
├── MCCore/      shared types — Intent schema, telemetry, permissions
├── MCAudio/     AVAudioEngine capture
├── MCSTT/       FluidAudio Parakeet wrapper
├── MCInput/     CGEventTap push-to-talk
├── MCRouter/    LM Studio HTTP client, JSON-mode intent classification
└── MCSpike/     Phase 0 CLI executable (target: mc-spike)
```

Phase 1 adds an `App/` Xcode project for the menu-bar SwiftUI app and `Sources/MCActions/` for the deterministic action layer.

## License

TBD
