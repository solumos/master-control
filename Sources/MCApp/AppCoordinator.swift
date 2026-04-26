import AppKit
import Combine
import Foundation
import MCActions
import MCAudio
import MCCore
import MCMlx
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

            state = .starting(progress: "Qwen3-0.6B (MLX)")
            let mlx = MlxRouter()
            do {
                try await mlx.warmLoad { _ in }
            } catch {
                // Soft-fail: MLX is fallback-only. Continue with deterministic routing.
            }

            let chain = RouterChain([DeterministicRouter(), mlx])
            let dictator = Dictator()
            let dispatcher = IntentDispatcher()
            let wake = WakeWord()
            let audio = AudioFeedback()

            let listener = AppListener(
                stt: stt,
                vad: vad,
                chain: chain,
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
                }
            }
        }
    }
}
