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

        public init(
            apiKey: String,
            modelID: String = "claude-haiku-4-5",
            maxTokens: Int = 200,
            systemPrompt: String = AnthropicResponder.defaultSystemPrompt,
            endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
            timeout: TimeInterval = 15.0,
            debug: Bool = false
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.maxTokens = maxTokens
            self.systemPrompt = systemPrompt
            self.endpoint = endpoint
            self.timeout = timeout
            self.debug = debug
        }
    }

    public static let defaultSystemPrompt = """
    You are a brief Mac assistant. Answer the user in 1–2 short sentences \
    suitable to be spoken aloud. No markdown, no lists, no preamble — just \
    the answer. If you don't know something (live data, the user's local \
    context), say so briefly and move on.
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

        let body = MessagesRequest(
            model: config.modelID,
            maxTokens: config.maxTokens,
            system: config.systemPrompt,
            messages: [.init(role: "user", content: prompt)]
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
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw AnthropicError.malformedResponse
        }
        if config.debug {
            FileHandle.standardError.write(Data("[anthropic] response: \(text)\n".utf8))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
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
