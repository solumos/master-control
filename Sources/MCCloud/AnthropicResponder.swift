import Foundation
import MCCore

/// Generates a free-form spoken response by calling Anthropic's Messages API.
///
/// Used as the **fallthrough** for utterances the deterministic router
/// doesn't match. Replaces the in-process MLX path: latency is dominated
/// by network (~500 ms–2 s vs. MLX's ~700 ms–10 s on Qwen3-0.6B), the
/// quality is dramatically higher, and we no longer need the
/// metallib-compilation Xcode pivot for the LLM tier.
///
/// Defaults to Claude Haiku 4.5 — cheapest + fastest model in the line,
/// matching spec §2.4's recommendation for the routing/short-answer tier.
public actor AnthropicResponder: Responder {

    public nonisolated var name: String { "anthropic-haiku" }

    public struct Config: Sendable {
        public var apiKey: String
        public var modelID: String
        public var maxTokens: Int
        public var systemPrompt: String
        public var endpoint: URL
        public var timeout: TimeInterval
        public var debug: Bool
        /// Provide Anthropic's managed `web_search` tool. Claude decides
        /// per-query whether to use it. Web-search calls add ~2–4 s of
        /// latency and ~$0.01 each, but unlock fresh data ("weather",
        /// "today's score", "current stock price", etc.).
        public var enableWebSearch: Bool

        public init(
            apiKey: String,
            modelID: String = "claude-haiku-4-5",
            maxTokens: Int = 400,
            systemPrompt: String = AnthropicResponder.defaultSystemPrompt,
            endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
            timeout: TimeInterval = 30.0,
            debug: Bool = false,
            enableWebSearch: Bool = true
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.maxTokens = maxTokens
            self.systemPrompt = systemPrompt
            self.endpoint = endpoint
            self.timeout = timeout
            self.debug = debug
            self.enableWebSearch = enableWebSearch
        }
    }

    public static let defaultSystemPrompt = """
    You are a brief Mac assistant. The user is asking by voice and your \
    answer will be read aloud, so:

    - Keep it to 1–2 short sentences.
    - No markdown, no lists, no code blocks, no preamble.
    - If the question needs current information (weather, scores, news, \
      stock prices, etc.) use the web_search tool. Don't speculate when \
      a search will give a real answer.
    - When you do search, summarize in your own words. Don't read URLs \
      or citation markers aloud.
    """

    /// Convenience constructor that pulls the API key from the environment
    /// or, failing that, from `~/Downloads/.env`. Returns nil if neither
    /// source has it, so the host can gracefully degrade to "no LLM
    /// available."
    public static func fromEnvironment(
        modelID: String = "claude-haiku-4-5",
        debug: Bool = false
    ) -> AnthropicResponder? {
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let fileKey = EnvFile.value(for: "ANTHROPIC_API_KEY")
        let key = (envKey?.isEmpty == false ? envKey : fileKey) ?? ""
        guard !key.isEmpty else { return nil }
        return AnthropicResponder(config: .init(apiKey: key, modelID: modelID, debug: debug))
    }

    public let config: Config
    private let session: URLSession

    public init(config: Config) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout
        self.session = URLSession(configuration: sessionConfig)
    }

    public func respond(to prompt: String) async throws -> String {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let tools: [MessagesRequest.Tool]? = config.enableWebSearch
            ? [.init(type: "web_search_20250305", name: "web_search")]
            : nil
        let body = MessagesRequest(
            model: config.modelID,
            maxTokens: config.maxTokens,
            system: config.systemPrompt,
            messages: [.init(role: "user", content: prompt)],
            tools: tools
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            if config.debug {
                FileHandle.standardError.write(Data("[anthropic] HTTP \(http.statusCode): \(payload)\n".utf8))
            }
            throw AnthropicError.httpStatus(http.statusCode, payload)
        }

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        // Web-search responses can contain multiple text blocks (one per
        // search round-trip). Concatenate all text blocks into the final
        // spoken answer; non-text blocks (tool_use, server_tool_use,
        // web_search_tool_result) are intermediate state we don't need
        // to surface.
        let textBlocks = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }
        let combined = textBlocks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw AnthropicError.malformedResponse
        }
        if config.debug {
            FileHandle.standardError.write(Data("[anthropic] blocks=\(decoded.content.count) text=\"\(combined)\"\n".utf8))
        }
        return combined
    }
}

public enum AnthropicError: Error, LocalizedError {
    case missingAPIKey
    case httpStatus(Int, String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:                return "ANTHROPIC_API_KEY is not set."
        case .httpStatus(let code, _):      return "Anthropic HTTP \(code)"
        case .malformedResponse:            return "Anthropic returned an unexpected response shape."
        }
    }
}

private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Tool: Encodable {
        let type: String
        let name: String
    }
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let tools: [Tool]?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools
        case maxTokens = "max_tokens"
    }
}

private struct MessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}
