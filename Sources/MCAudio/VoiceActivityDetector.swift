import FluidAudio
import Foundation
import MCCore

/// Streaming voice activity detector wrapping FluidAudio's Silero VAD.
/// Feed it audio in `chunkSize`-sized slices (4096 samples = 256 ms at
/// 16 kHz). Each `process` call returns a `VadStreamEvent?` —
/// `.speechStart` when speech begins, `.speechEnd` when a sufficient
/// silence hangover is detected, or nil between events.
///
/// The detector owns the streaming `VadStreamState` so the caller doesn't
/// have to thread it through.
public actor VoiceActivityDetector {
    public static let chunkSize = VadManager.chunkSize  // 4096
    public static let sampleRate = VadManager.sampleRate  // 16_000

    private var manager: VadManager?
    private var state: VadStreamState?

    public init() {}

    public var isLoaded: Bool { manager != nil }

    public func warmLoad() async throws {
        guard manager == nil else { return }
        let m: VadManager
        if let root = ModelsLocation.bundledRoot() {
            // VadManager appends "Models/silero-vad" to the directory it's
            // given, so pass the install root verbatim.
            m = try await VadManager(config: .default, modelDirectory: root)
        } else {
            m = try await VadManager(config: .default)
        }
        self.manager = m
        self.state = await m.makeStreamState()
    }

    /// Feed exactly `chunkSize` samples (16 kHz mono Float32). Returns
    /// the VAD event triggered by this chunk, if any.
    public func process(chunk: [Float]) async throws -> VadStreamEvent? {
        guard let manager, let s = state else { throw VadError.notLoaded }
        let result = try await manager.processStreamingChunk(chunk, state: s)
        self.state = result.state
        return result.event
    }

    /// Reset streaming state — call after a transcription cycle finishes
    /// so the next utterance starts cleanly.
    public func reset() async {
        guard let manager else { return }
        self.state = await manager.makeStreamState()
    }
}

public enum VadError: Error, LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "VoiceActivityDetector.warmLoad() was not called before process()."
        }
    }
}
