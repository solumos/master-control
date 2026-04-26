import ArgumentParser
import CoreFoundation
import FluidAudio
import Foundation
import MCActions
import MCAudio
import MCCore
import MCMlx
import MCRouter
import MCSTT

@main
struct MCSpike: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "mc-spike",
        abstract: """
        Phase-0 latency spike for MasterControl. Always-on voice control: \
        say "MC directive, <command>" and the system routes it. Say \
        "MC directive, type <text>" to dictate into the focused app. \
        Prints per-utterance timings and a p50/p99 histogram on completion.
        """
    )

    @Option(name: .long, help: "Number of accepted utterances before printing the summary.")
    var iterations: Int = 10

    @Flag(name: .long, help: "Skip the MLX LLM fallback (deterministic-only routing).")
    var noLlm: Bool = false

    func run() async throws {
        guard checkPermissions() else { return }

        print("[setup] warm-loading Parakeet…")
        let stt = ParakeetSTT()
        try await stt.warmLoad()

        print("[setup] warm-loading Silero VAD…")
        let vad = VoiceActivityDetector()
        try await vad.warmLoad()

        var routers: [any Router] = [DeterministicRouter()]
        if !noLlm {
            print("[setup] warm-loading Qwen3-0.6B (MLX) — first run downloads ~350 MB…")
            let mlx = MlxRouter()
            try await mlx.warmLoad { progress in
                if Int(progress.fractionCompleted * 100) % 25 == 0 {
                    print("       \(Int(progress.fractionCompleted * 100))% downloaded")
                }
            }
            routers.append(mlx)
            print("[setup] router chain: deterministic → mlx-qwen3")
        } else {
            print("[setup] router chain: deterministic only (--no-llm)")
        }
        let chain = RouterChain(routers)
        let dictator = Dictator()
        let wake = WakeWord()
        let histogram = Histogram()
        let total = self.iterations

        print("""
        [ready] always-on listening. Wake phrase: "MC directive, <command>"
                 \(total) accepted utterances · Ctrl-C to abort early.
                 Try: "MC directive, open Slack" · "MC directive, type hello world"
        """)

        let listener = Listener(
            iterations: total,
            stt: stt,
            vad: vad,
            chain: chain,
            dictator: dictator,
            wake: wake,
            histogram: histogram
        )

        let bridge = ListenerBridge()
        bridge.listener = listener

        let capture = AudioCapture()
        try capture.start { samples in
            bridge.feed(samples)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = ResumeOnce(cont: cont)
            Task {
                await listener.setCompletion { resumed.resume() }
            }
        }

        capture.stop()

        await Self.printSummary(histogram: histogram)
    }

    private func checkPermissions() -> Bool {
        // Always-on listening only needs Microphone. Hotkeys are gone, so
        // no Input Monitoring requirement. Dictation may need Accessibility
        // for some apps, but we let the user discover that and grant on
        // first failure rather than blocking startup on it.
        let micStatus = Permissions.microphoneStatus()
        switch micStatus {
        case .authorized: return true
        case .notDetermined:
            print("[perm] requesting microphone access…")
            let granted = Self.runSync { await Permissions.requestMicrophone() }
            if !granted {
                print("[error] microphone access denied.")
                return false
            }
            return true
        case .denied, .restricted:
            print("[error] microphone access denied. Open System Settings to grant.")
            Permissions.openSystemSettings(for: .microphone)
            return false
        @unknown default:
            return false
        }
    }

    private static func runSync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = UnsafeMutableBox<T?>(value: nil)
        Task.detached {
            box.value = await body()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    private static func printSummary(histogram: Histogram) async {
        let stats = await histogram.summary()
        let n = await histogram.count()
        guard n > 0 else {
            print("[summary] no utterances accepted.")
            return
        }
        print("\n==== latency histogram (n=\(n)) ====")
        let stages: [Stage] = [.capture, .stt, .intent, .sttPlusIntent, .total]
        // %@ for Swift String — %s expects a C string and segfaults.
        print(String(format: "%-14@ %8@ %8@ %8@ %8@", "stage", "p50", "p99", "min", "max"))
        for stage in stages {
            guard let s = stats[stage], s.n > 0 else { continue }
            print(String(format: "%-14@ %6.1f ms %6.1f ms %6.1f ms %6.1f ms",
                         stage.rawValue as NSString, s.p50, s.p99, s.min, s.max))
        }
        print("==================================")
        if let s = stats[.sttPlusIntent] {
            // For always-on, the meaningful target is end-of-speech → action.
            // The spec budget (250 ms p50) was for hotkey-released → action,
            // which is comparable since VAD silence-hangover ≈ hotkey release.
            let pass = s.p50 < 250 && s.p99 < 400
            let badge = pass ? "✅" : "❌"
            print("\(badge) Phase 0 acceptance (stt+post-action): p50=\(String(format: "%.1f", s.p50)) ms (target <250 ms), p99=\(String(format: "%.1f", s.p99)) ms (target <400 ms)")
        }
    }
}

private final class UnsafeMutableBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(value: T) { self.value = value }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?

    init(cont: CheckedContinuation<Void, Never>) {
        self.cont = cont
    }

    func resume() {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume()
    }
}

/// Owns the always-on pipeline. Receives raw 16 kHz samples from
/// AudioCapture, re-buffers them into VAD-sized chunks, runs VAD, and
/// on speech-end transcribes the buffered utterance and dispatches it.
///
/// Marked `actor` so all internal state is implicitly serialized — callers
/// hand off via the non-isolated `feed(samples:)` shim.
private actor Listener {
    private let iterations: Int
    private let stt: ParakeetSTT
    private let vad: VoiceActivityDetector
    private let chain: RouterChain
    private let dictator: Dictator
    private let wake: WakeWord
    private let histogram: Histogram

    private var pendingSamples: [Float] = []   // pre-VAD (waiting to fill 4096)
    private var utteranceSamples: [Float] = [] // accumulated while triggered
    private var triggered = false
    private var index = 0
    private var completion: (@Sendable () -> Void)?

    init(
        iterations: Int,
        stt: ParakeetSTT,
        vad: VoiceActivityDetector,
        chain: RouterChain,
        dictator: Dictator,
        wake: WakeWord,
        histogram: Histogram
    ) {
        self.iterations = iterations
        self.stt = stt
        self.vad = vad
        self.chain = chain
        self.dictator = dictator
        self.wake = wake
        self.histogram = histogram
    }

    func setCompletion(_ handler: @escaping @Sendable () -> Void) {
        self.completion = handler
    }

    func processSamples(_ samples: [Float]) async {
        pendingSamples.append(contentsOf: samples)
        while pendingSamples.count >= VoiceActivityDetector.chunkSize {
            let chunk = Array(pendingSamples.prefix(VoiceActivityDetector.chunkSize))
            pendingSamples.removeFirst(VoiceActivityDetector.chunkSize)
            await processChunk(chunk)
        }
    }

    private func processChunk(_ chunk: [Float]) async {
        let event: VadStreamEvent?
        do {
            event = try await vad.process(chunk: chunk)
        } catch {
            print("[vad] error: \(error.localizedDescription)")
            return
        }

        // While triggered (between start and end), accumulate.
        if triggered {
            utteranceSamples.append(contentsOf: chunk)
        }

        guard let event else { return }
        switch event.kind {
        case .speechStart:
            triggered = true
            utteranceSamples = chunk  // include the chunk that triggered
        case .speechEnd:
            let samples = utteranceSamples
            utteranceSamples.removeAll(keepingCapacity: true)
            triggered = false
            await handleUtterance(samples: samples)
        }
    }

    private func handleUtterance(samples: [Float]) async {
        let endOfSpeech = Clock.now()
        var timings = StageTimings()
        timings.captureMs = Double(samples.count) / Double(VoiceActivityDetector.sampleRate) * 1000

        let sttStart = Clock.now()
        let text: String
        do {
            text = try await stt.transcribe(samples: samples)
        } catch {
            print("[stt] error: \(error.localizedDescription)")
            return
        }
        timings.sttMs = Clock.elapsedMs(since: sttStart)

        guard let match = wake.match(utterance: text) else {
            print("[ignored] (no wake phrase) \"\(text)\"")
            return
        }

        let actionStart = Clock.now()
        var trailing = ""
        switch match.kind {
        case .route:
            do {
                if let intent = try await chain.classify(utterance: match.payload) {
                    let json = (try? JSONEncoder().encode(intent))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "<encode failed>"
                    trailing = "matched: \(chain.lastMatchedBy ?? "?") · \(json)"
                } else {
                    trailing = "matched: none · (\"\(match.payload)\")"
                }
            } catch {
                trailing = "router error: \(error.localizedDescription)"
            }
        case .dictate:
            _ = dictator.type(match.payload)
            trailing = "dictated \(match.payload.count) chars"
        }
        timings.intentMs = Clock.elapsedMs(since: actionStart)

        let totalLatency = Clock.elapsedMs(since: endOfSpeech)
        await histogram.record(timings)

        index += 1
        let i = index
        let done = index >= iterations

        print(String(
            format: "[%d/%d] %@ · spoke %5.0f ms · stt %5.1f ms · post %5.1f ms · end→action %5.1f ms",
            i, iterations, match.kind == .route ? "route  " : "dictate",
            timings.captureMs, timings.sttMs, timings.intentMs, totalLatency
        ))
        print("       text: \"\(text)\"")
        print("       \(trailing)")

        if done { completion?() }
    }
}

/// Bridges AudioCapture's synchronous worker-thread callback to the
/// `Listener` actor. Holds a weak reference so listener teardown isn't
/// blocked by in-flight Tasks.
private final class ListenerBridge: @unchecked Sendable {
    weak var listener: Listener?
    func feed(_ samples: [Float]) {
        guard let listener else { return }
        Task { await listener.processSamples(samples) }
    }
}
