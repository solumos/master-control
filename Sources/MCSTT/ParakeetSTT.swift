import AVFoundation
import FluidAudio
import Foundation
import MCCore

/// Wraps FluidAudio's `AsrManager` with the Parakeet-TDT v2 model
/// (English-only, ANE-loaded). Call `warmLoad()` once at startup so the
/// first real transcription doesn't pay the model-load cost.
public actor ParakeetSTT {
    private var asr: AsrManager?

    public init() {}

    public var isLoaded: Bool { asr != nil }

    public func warmLoad() async throws {
        guard asr == nil else { return }
        let manager = AsrManager(config: .default)
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        try await manager.loadModels(models)
        self.asr = manager
    }

    /// Transcribe 16 kHz mono Float32 samples (matching `AudioCapture`'s
    /// output format). Returns the recognized text.
    ///
    /// A fresh `TdtDecoderState` is created per call: utterances are
    /// independent in push-to-talk mode, so we don't need to thread state
    /// across calls. Phase 1 may switch to a persistent state for
    /// streaming/EOU.
    public func transcribe(samples: [Float]) async throws -> String {
        guard let asr else { throw STTError.notLoaded }
        guard !samples.isEmpty else { return "" }
        var state = TdtDecoderState.make(decoderLayers: 2)
        let result = try await asr.transcribe(samples, decoderState: &state)
        return result.text
    }
}

public enum STTError: Error, LocalizedError {
    case notLoaded
    case empty

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "ParakeetSTT.warmLoad() was not called before transcribe()."
        case .empty:     return "Empty audio buffer; nothing to transcribe."
        }
    }
}
