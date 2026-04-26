import FluidAudio
import Foundation
import MCActions
import MCAudio
import MCCore
import MCRouter
import MCSTT

/// Always-on listener for the menu-bar app. Same pipeline as MCSpike
/// (VAD → STT → wake → route/dictate → dispatch) but instead of printing
/// to stdout, emits structured events through an `AsyncStream` for the
/// UI coordinator to consume.
actor AppListener {

    enum Event: Sendable {
        /// Live state for the menu-bar icon.
        case stateChange(LiveState)
        /// A completed cycle that resulted in an activity log row.
        case activity(ActivityEvent)
    }

    enum LiveState: Sendable {
        case idle
        case hearingSpeech
        case processing
    }

    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let stt: ParakeetSTT
    private let vad: VoiceActivityDetector
    private let chain: RouterChain
    private let responder: (any Responder)?
    private let speaker: (any MCCore.Speaker)?
    private let dictator: Dictator
    private let dispatcher: IntentDispatcher
    private let wake: WakeWord
    private let audio: AudioFeedback

    private var pendingSamples: [Float] = []
    private var utteranceSamples: [Float] = []
    private var triggered = false
    private var paused = false

    init(
        stt: ParakeetSTT,
        vad: VoiceActivityDetector,
        chain: RouterChain,
        responder: (any Responder)?,
        speaker: (any MCCore.Speaker)?,
        dictator: Dictator,
        dispatcher: IntentDispatcher,
        wake: WakeWord,
        audio: AudioFeedback
    ) {
        self.stt = stt
        self.vad = vad
        self.chain = chain
        self.responder = responder
        self.speaker = speaker
        self.dictator = dictator
        self.dispatcher = dispatcher
        self.wake = wake
        self.audio = audio

        var cont: AsyncStream<Event>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    func setPaused(_ value: Bool) {
        self.paused = value
        if value {
            // Drop in-flight buffers so resuming doesn't pop a stale
            // utterance.
            pendingSamples.removeAll(keepingCapacity: true)
            utteranceSamples.removeAll(keepingCapacity: true)
            triggered = false
        }
        continuation.yield(.stateChange(.idle))
    }

    func processSamples(_ samples: [Float]) async {
        guard !paused else { return }
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
            return
        }

        if triggered {
            utteranceSamples.append(contentsOf: chunk)
        }

        guard let event else { return }
        switch event.kind {
        case .speechStart:
            triggered = true
            utteranceSamples = chunk
            continuation.yield(.stateChange(.hearingSpeech))
        case .speechEnd:
            let samples = utteranceSamples
            utteranceSamples.removeAll(keepingCapacity: true)
            triggered = false
            continuation.yield(.stateChange(.processing))
            await handleUtterance(samples: samples)
            continuation.yield(.stateChange(.idle))
        }
    }

    private func handleUtterance(samples: [Float]) async {
        let text: String
        do {
            text = try await stt.transcribe(samples: samples)
        } catch {
            return
        }

        guard let match = wake.match(utterance: text) else {
            continuation.yield(.activity(.init(
                timestamp: Date(),
                heard: text,
                status: .ignored
            )))
            return
        }

        // Wake phrase recognized — short tick so the user knows we
        // heard them, before the (possibly multi-second) action runs.
        audio.play(.heard)

        switch match.kind {
        case .route:
            do {
                if let intent = try await chain.classify(utterance: match.payload) {
                    let result = await dispatcher.dispatch(intent)
                    let status: ActivityEvent.Status
                    switch result.status {
                    case .executed:
                        status = .executed(label: result.label)
                        audio.play(.success)
                    case .deferred:
                        status = .deferred(label: result.label)
                    case .failed(let why):
                        status = .failed(label: result.label, reason: why)
                        audio.play(.failure)
                    }
                    continuation.yield(.activity(.init(
                        timestamp: Date(),
                        heard: match.payload,
                        status: status
                    )))
                } else if let responder {
                    // Deterministic chain didn't match — ask the LLM for a
                    // free-form response and speak it. The user said the
                    // wake phrase, so silence here would feel broken.
                    let answer: String
                    do {
                        answer = try await responder.respond(to: match.payload)
                    } catch {
                        audio.play(.failure)
                        continuation.yield(.activity(.init(
                            timestamp: Date(),
                            heard: match.payload,
                            status: .failed(label: "responder", reason: error.localizedDescription)
                        )))
                        return
                    }
                    if !answer.isEmpty, let speaker {
                        try? await speaker.speak(answer)
                    }
                    continuation.yield(.activity(.init(
                        timestamp: Date(),
                        heard: match.payload,
                        status: .executed(label: answer.isEmpty ? "(empty response)" : "“\(answer)”")
                    )))
                } else {
                    continuation.yield(.activity(.init(
                        timestamp: Date(),
                        heard: match.payload,
                        status: .deferred(label: "no router matched")
                    )))
                }
            } catch {
                audio.play(.failure)
                continuation.yield(.activity(.init(
                    timestamp: Date(),
                    heard: match.payload,
                    status: .failed(label: "router", reason: error.localizedDescription)
                )))
            }
        case .dictate:
            _ = dictator.type(match.payload)
            audio.play(.success)
            continuation.yield(.activity(.init(
                timestamp: Date(),
                heard: match.payload,
                status: .dictated(charCount: match.payload.count)
            )))
        }
    }

    deinit {
        continuation.finish()
    }
}

/// Bridges AudioCapture's worker-thread callback to the actor.
final class AppListenerBridge: @unchecked Sendable {
    weak var listener: AppListener?
    func feed(_ samples: [Float]) {
        guard let listener else { return }
        Task { await listener.processSamples(samples) }
    }
}
