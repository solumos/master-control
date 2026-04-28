import AppKit
import Combine
import Foundation
import MCActions
import MCAudio
import MCCloud
import MCCore
import MCInput
import MCRouter
import MCSTT

/// MainActor-isolated controller. Owns the listener pipeline and the
/// app's published state. SwiftUI views observe this directly.
@MainActor
final class AppCoordinator: ObservableObject {

    enum LifecycleState: Sendable, Equatable {
        case starting(progress: String)
        case running(AppListener.LiveState)
        case paused
        case error(String)

        /// SF Symbol name for the menu-bar icon.
        var symbolName: String {
            switch self {
            case .starting:                 return "ellipsis.circle"
            case .running(.idle):           return "desktopcomputer"
            case .running(.hearingSpeech):  return "desktopcomputer"
            case .running(.processing):     return "desktopcomputer"
            case .paused:                   return "desktopcomputer.trianglebadge.exclamationmark"
            case .error:                    return "exclamationmark.triangle.fill"
            }
        }

        var label: String {
            switch self {
            case .starting(let p):          return "Starting — \(p)"
            case .running(.idle):           return "Listening"
            case .running(.hearingSpeech):  return "Hearing speech…"
            case .running(.processing):     return "Processing…"
            case .paused:                   return "Paused"
            case .error(let e):             return "Error: \(e)"
            }
        }
    }

    @Published private(set) var state: LifecycleState = .starting(progress: "loading")
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var paused = false

    private static let maxEvents = 50

    private var capture: AudioCapture?
    private var listener: AppListener?
    private let bridge = AppListenerBridge()
    private var consumeTask: Task<Void, Never>?
    private let logFile = ActivityLogFile()

    // Strong typed reference held in addition to the protocol-typed
    // `speaker` injected into the listener — Settings changes need to
    // call the Kokoro-specific `setOutputDeviceUID`.
    private var kokoro: KokoroSpeaker?

    // Toolbox needed to rebuild the Anthropic agent when the API key
    // changes at runtime.
    private var anthropicTools: [AnthropicTool] = []
    private var anthropicExecutor: AnthropicAgent.ToolExecutor?

    private let settings = AppSettings.shared
    private var cancellables: Set<AnyCancellable> = []

    private var toggleHotkey: PushToTalk?

    init() {
        Task { await bootstrap() }
    }

    func togglePause() {
        paused.toggle()
        let nowPaused = paused
        Task {
            await listener?.setPaused(nowPaused)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.state = nowPaused ? .paused : .running(.idle)
            }
        }
    }

    func quit() {
        consumeTask?.cancel()
        capture?.stop()
        NSApp.terminate(nil)
    }

    func clearEvents() {
        events.removeAll()
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        do {
            state = .starting(progress: "Parakeet (STT)")
            let stt = ParakeetSTT()
            try await stt.warmLoad()

            state = .starting(progress: "Silero VAD")
            let vad = VoiceActivityDetector()
            try await vad.warmLoad()

            state = .starting(progress: "Anthropic agent")
            let installedApps = InstalledApps.discover()
            NSLog("[MasterControl] indexed \(installedApps.names.count) installed apps for fuzzy matching")
            let dispatcher = IntentDispatcher(installedApps: installedApps)
            let dictator = Dictator()
            let claudeRunner = ClaudeRunner()
            if claudeRunner.isAvailable {
                NSLog("[MasterControl] claude CLI detected — claude_task tool enabled")
            } else {
                NSLog("[MasterControl] claude CLI not on PATH — claude_task tool disabled")
            }
            let tools = ToolBridge.tools(claudeAvailable: claudeRunner.isAvailable)
            let executor = ToolBridge.executor(
                dispatcher: dispatcher,
                dictator: dictator,
                claudeRunner: claudeRunner.isAvailable ? claudeRunner : nil
            )
            self.anthropicTools = tools
            self.anthropicExecutor = executor

            let responder: (any Responder)? = AnthropicAgent.fromEnvironment(
                apiKeyOverride: settings.anthropicAPIKey.isEmpty ? nil : settings.anthropicAPIKey,
                tools: tools,
                executor: executor
            )
            if responder == nil {
                NSLog("[MasterControl] ANTHROPIC_API_KEY not set; LLM fallback disabled. Un-classified utterances will be logged but won't get a spoken response.")
            }

            state = .starting(progress: "Kokoro TTS")
            let kokoro = KokoroSpeaker()
            await kokoro.setOutputDeviceUID(settings.outputDeviceUID)
            var loadedSpeaker: (any MCCore.Speaker)? = nil
            do {
                try await kokoro.warmLoad()
                loadedSpeaker = kokoro
                self.kokoro = kokoro
            } catch {
                NSLog("[MasterControl] Kokoro TTS failed to load (\(error.localizedDescription)); responses will be logged but not spoken.")
            }

            let chain = RouterChain([DeterministicRouter(installedApps: installedApps)])
            let wake = WakeWord()
            let audio = AudioFeedback()

            let listener = AppListener(
                stt: stt,
                vad: vad,
                chain: chain,
                responder: responder,
                speaker: loadedSpeaker,
                dictator: dictator,
                dispatcher: dispatcher,
                wake: wake,
                audio: audio
            )
            await listener.setMode(settings.listenMode)
            self.listener = listener
            self.bridge.listener = listener
            self.consumeTask = Task { [weak self] in
                await self?.consumeEvents(stream: listener.stream)
            }

            // In option-toggle mode the mic is closed by default — the
            // user taps right Option to open it. In wake-word mode we
            // listen always.
            if settings.listenMode == .optionToggle {
                self.paused = true
                await listener.setPaused(true)
            }

            let capture = AudioCapture()
            try capture.start(inputDeviceUID: settings.inputDeviceUID) { [bridge] samples in
                bridge.feed(samples)
            }
            self.capture = capture

            installSettingsObservers()
            applyModeBinding(settings.listenMode)

            state = paused ? .paused : .running(.idle)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Apply mode-specific bindings: install/uninstall the toggle
    /// hotkey. Caller is responsible for the listener's `mode` and the
    /// paused state — this function only owns the global hotkey
    /// side-effect.
    private func applyModeBinding(_ mode: ListenMode) {
        switch mode {
        case .wakeWord:
            toggleHotkey?.uninstall()
            toggleHotkey = nil
        case .optionToggle:
            installToggleHotkey()
        }
    }

    /// Tap Fn (🌐) to toggle pause. Requires Input Monitoring permission.
    /// Fn is preferred over Option because either Option key produces
    /// special characters when held with letters, so users who tap left
    /// vs right inconsistently get a confusing experience. Fn has no
    /// such overload.
    private func installToggleHotkey() {
        guard toggleHotkey == nil else { return }
        let toggle = PushToTalk(
            keyCode: PushToTalk.fnKeyCode,
            label: "fn-toggle",
            onPress: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.togglePause()
                }
            },
            onRelease: {}  // Fire on press only — each tap toggles once.
        )
        if toggle.install() {
            self.toggleHotkey = toggle
            NSLog("[MasterControl] Fn toggle installed (tap 🌐 to pause/resume)")
        } else {
            NSLog("[MasterControl] Fn toggle disabled — grant Input Monitoring in System Settings")
        }
    }

    // MARK: - Live settings updates

    private func installSettingsObservers() {
        // Drop the initial value — bootstrap already applied them.
        settings.$inputDeviceUID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] uid in
                Task { @MainActor [weak self] in
                    self?.applyInputDevice(uid)
                }
            }
            .store(in: &cancellables)

        settings.$outputDeviceUID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] uid in
                Task { @MainActor [weak self] in
                    await self?.kokoro?.setOutputDeviceUID(uid)
                }
            }
            .store(in: &cancellables)

        settings.$anthropicAPIKey
            .dropFirst()
            .removeDuplicates()
            // Debounce so we don't rebuild the agent on every keystroke
            // in the SecureField — only after the user stops typing.
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] key in
                Task { @MainActor [weak self] in
                    self?.applyAnthropicKey(key)
                }
            }
            .store(in: &cancellables)

        settings.$listenMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                Task { @MainActor [weak self] in
                    self?.applyMode(mode)
                }
            }
            .store(in: &cancellables)
    }

    private func applyMode(_ mode: ListenMode) {
        let listener = self.listener
        Task {
            await listener?.setMode(mode)
        }
        applyModeBinding(mode)
        // Switching to option-toggle mode closes the mic and waits
        // for the user's first ⌥ tap. Switching to wake-word mode
        // opens it.
        let shouldPause = (mode == .optionToggle)
        if paused != shouldPause {
            paused = shouldPause
            Task {
                await listener?.setPaused(shouldPause)
            }
            state = shouldPause ? .paused : .running(.idle)
        }
        NSLog("[MasterControl] listen mode switched to \(mode.rawValue)")
    }

    private func applyInputDevice(_ uid: String?) {
        guard let oldCapture = capture else { return }
        oldCapture.stop()
        let newCapture = AudioCapture()
        do {
            try newCapture.start(inputDeviceUID: uid) { [bridge] samples in
                bridge.feed(samples)
            }
            self.capture = newCapture
            NSLog("[MasterControl] switched input device to \(uid ?? "system default")")
        } catch {
            NSLog("[MasterControl] failed to switch input device: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    private func applyAnthropicKey(_ key: String) {
        guard let executor = anthropicExecutor else { return }
        let newResponder = AnthropicAgent.fromEnvironment(
            apiKeyOverride: key.isEmpty ? nil : key,
            tools: anthropicTools,
            executor: executor
        )
        let listener = self.listener
        Task {
            await listener?.setResponder(newResponder)
        }
        if newResponder == nil {
            NSLog("[MasterControl] no Anthropic key available — LLM fallback disabled")
        } else {
            NSLog("[MasterControl] Anthropic key updated; LLM fallback re-enabled")
        }
    }

    private func consumeEvents(stream: AsyncStream<AppListener.Event>) async {
        for await event in stream {
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch event {
                case .stateChange(let live):
                    if !self.paused { self.state = .running(live) }
                case .activity(let activity):
                    self.events.append(activity)
                    if self.events.count > Self.maxEvents {
                        self.events.removeFirst(self.events.count - Self.maxEvents)
                    }
                    self.logFile.append(activity)
                }
            }
        }
    }
}
