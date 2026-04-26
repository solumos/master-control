import Foundation
import Hub
import HuggingFace
import MCCore
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// In-process Qwen3-0.6B-MLX-4bit used as a free-form response generator.
///
/// Used as the **fallthrough** for utterances the deterministic router
/// doesn't match. Instead of classifying into an intent that we'd then
/// have to defer (the prior MlxRouter behavior), this just generates a
/// short natural-language answer that the host speaks aloud — useful
/// for "what's the weather", "tell me a joke", etc.
public actor MlxResponder {

    public struct Config: Sendable {
        public var modelID: String
        public var maxTokens: Int
        public var temperature: Float

        public init(
            modelID: String = "mlx-community/Qwen3-0.6B-4bit",
            maxTokens: Int = 80,
            temperature: Float = 0.6
        ) {
            self.modelID = modelID
            self.maxTokens = maxTokens
            self.temperature = temperature
        }
    }

    public let config: Config
    private var container: ModelContainer?

    public init(config: Config = Config()) {
        self.config = config
    }

    public func warmLoad(progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws {
        guard container == nil else { return }
        let configuration = ModelConfiguration(id: config.modelID)
        let context = try await #huggingFaceLoadModel(
            configuration: configuration,
            progressHandler: { value in
                progressHandler?(value)
            }
        )
        let container = ModelContainer(context: context)
        self.container = container
        // Touch the model so the first real respond() doesn't pay cold cost.
        _ = try? await runSession(container: container, prompt: "ping")
    }

    /// Generate a brief spoken-style response to `prompt`. Caller is
    /// responsible for piping this into a TTS engine.
    public func respond(to prompt: String) async throws -> String {
        guard let container else { return "" }
        let raw = try await runSession(container: container, prompt: prompt)
        return Self.cleanForSpeech(raw)
    }

    private func runSession(container: ModelContainer, prompt: String) async throws -> String {
        var params = GenerateParameters(temperature: config.temperature)
        params.maxTokens = config.maxTokens
        let session = ChatSession(
            container,
            instructions: Self.instructions,
            generateParameters: params
        )
        return try await session.respond(to: prompt)
    }

    /// Strip Qwen3's `<think>…</think>` block (it leaks even with /no_think
    /// when the model can't avoid the wrapper) and any code fences.
    /// What's left is what we feed to TTS.
    static func cleanForSpeech(_ text: String) -> String {
        var s = text
        // Drop think blocks.
        while let openRange = s.range(of: "<think>") {
            if let closeRange = s.range(of: "</think>", range: openRange.upperBound..<s.endIndex) {
                s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                s.removeSubrange(openRange.lowerBound..<s.endIndex)
                break
            }
        }
        // Drop ``` code fences but keep their content.
        s = s.replacingOccurrences(of: "```", with: "")
        // Collapse whitespace and trim.
        let collapsed = s.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let instructions: String = """
    /no_think
    You are a brief Mac assistant. Answer the user in 1–2 short sentences \
    suitable to be read aloud. No code blocks, no markdown, no preamble — \
    just the answer.
    """
}
