import AppKit
import Combine
import Foundation
import MCActions
import MCAudio
import MCCloud
import MCCore
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
            case .running(.idle):           return "mic.fill"
            case .running(.hearingSpeech):  return "waveform"
            case .running(.processing):    return "bolt.fill"
            case .paused:                   return "mic.slash.fill"
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

            state = .starting(progress: "Anthropic responder")
            let responder: (any Responder)? = AnthropicResponder.fromEnvironment()
            if responder == nil {
                NSLog("[MasterControl] ANTHROPIC_API_KEY not set; LLM fallback disabled. Un-classified utterances will be logged but won't get a spoken response.")
            }

            state = .starting(progress: "Kokoro TTS")
            let kokoro = KokoroSpeaker()
            var loadedSpeaker: (any MCCore.Speaker)? = nil
            do {
                try await kokoro.warmLoad()
                loadedSpeaker = kokoro
            } catch {
                NSLog("[MasterControl] Kokoro TTS failed to load (\(error.localizedDescription)); responses will be logged but not spoken.")
            }

            let installedApps = InstalledApps.discover()
            NSLog("[MasterControl] indexed \(installedApps.names.count) installed apps for fuzzy matching")
            let chain = RouterChain([DeterministicRouter(installedApps: installedApps)])
            let dictator = Dictator()
            let dispatcher = IntentDispatcher()
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
            self.listener = listener
            self.bridge.listener = listener
            self.consumeTask = Task { [weak self] in
                await self?.consumeEvents(stream: listener.stream)
            }

            let capture = AudioCapture()
            try capture.start { [bridge] samples in
                bridge.feed(samples)
            }
            self.capture = capture

            state = .running(.idle)
        } catch {
            state = .error(error.localizedDescription)
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
