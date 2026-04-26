import Foundation
import Hub
import HuggingFace
import MCCore
import MCRouter
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// In-process intent router backed by Qwen3-0.6B-MLX-4bit running on
/// Apple Neural Engine via mlx-swift-lm. Replaces the previous LM Studio
/// HTTP path: no separate process, no localhost transport, no JSON-schema
/// constrained decoding (we prompt the model and parse its output).
///
/// Latency target on M-series: ~50–150 ms TTFT for ≤300-token prompts.
/// On parse failure (malformed JSON), returns nil so the chain can fall
/// through to whatever's next.
public actor MlxRouter: Router {
    public let name = "mlx-qwen3"

    public struct Config: Sendable {
        public var modelID: String
        public var maxTokens: Int
        public var temperature: Float

        public init(
            modelID: String = "mlx-community/Qwen3-0.6B-4bit",
            maxTokens: Int = 80,
            temperature: Float = 0.0
        ) {
            self.modelID = modelID
            self.maxTokens = maxTokens
            self.temperature = temperature
        }
    }

    public let config: Config
    private let toolSummary: String
    private var container: ModelContainer?

    public init(
        config: Config = Config(),
        toolRegistrySummary: String = MlxRouter.defaultToolSummary
    ) {
        self.config = config
        self.toolSummary = toolRegistrySummary
    }

    /// Download (if needed) and load the model. Call once at startup.
    /// First call may take 30–60 s for the download; subsequent calls
    /// are 1–3 s on warm storage.
    ///
    /// Stores a `ModelContainer` (Sendable, internally serialized) rather
    /// than a `ChatSession` directly: ChatSession isn't Sendable, so we
    /// build a transient one per `classify` call against the shared
    /// container.
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

        // Touch the model so the first real classify doesn't pay cold cost.
        _ = try? await runSession(container: container, prompt: "ping")
    }

    public func classify(utterance: String) async throws -> Intent? {
        guard let container else { return nil }
        let response = try await runSession(container: container, prompt: utterance)
        return parseIntent(from: response)
    }

    private func runSession(container: ModelContainer, prompt: String) async throws -> String {
        let params = GenerateParameters(temperature: config.temperature)
        let session = ChatSession(
            container,
            instructions: Self.buildInstructions(toolSummary: toolSummary),
            generateParameters: params
        )
        return try await session.respond(to: prompt)
    }

    private func parseIntent(from response: String) -> Intent? {
        // Qwen3 sometimes wraps JSON in code fences or adds preamble.
        // Extract the first balanced {...} block.
        guard let jsonText = Self.extractJSONObject(from: response) else {
            return nil
        }
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Intent.self, from: data)
    }

    static func extractJSONObject(from text: String) -> String? {
        // Find the first '{' and walk forward tracking brace depth.
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < text.endIndex {
            let c = text[idx]
            if escape {
                escape = false
            } else if c == "\\" && inString {
                escape = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    public static let defaultToolSummary = """
    open_app(name): launch a Mac app by name.
    run_shortcut(name): run an Apple Shortcut by name.
    web_research(query): research something on the web.
    code_task(prompt): a coding task.
    free_form_llm(prompt): ambiguous request — defer to a stronger LLM.
    vision_fallback(prompt): visual computer-use fallback.
    """

    private static func buildInstructions(toolSummary: String) -> String {
        // /no_think disables Qwen3's reasoning mode so it goes straight to
        // the JSON response. Schema is described in plain English; we
        // recover from minor formatting noise via extractJSONObject.
        """
        /no_think
        You are an intent router for a voice-controlled Mac assistant.
        Read the user's spoken command and respond with ONLY a JSON object
        of this shape:

        {
          "intent": "open_app" | "run_shortcut" | "web_research" | "code_task" | "free_form_llm" | "vision_fallback",
          "tool": "<short tool id>",
          "args": { ...as needed... },
          "confidence": 0.0-1.0,
          "needs_clarification": false
        }

        Tools:
        \(toolSummary)

        - Output JSON only, no prose, no code fences.
        - Set confidence below 0.7 for ambiguous commands.
        """
    }
}
