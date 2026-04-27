import Foundation
import MCCore

/// Anthropic Messages API agent with multi-turn tool-use support.
///
/// Calls `/v1/messages`, follows `tool_use` blocks by invoking the host's
/// `executor` closure, and feeds `tool_result` blocks back into the
/// conversation until Claude returns a final `end_turn`. Lets the user
/// say compositional commands like "open Slack and message Tom" — Claude
/// emits two tool calls in sequence; we execute each and feed the
/// outcomes back so it can produce the spoken summary.
///
/// Replaces the prior `AnthropicResponder` (single-shot, no custom tools).
public actor AnthropicAgent: Responder {

    public nonisolated var name: String { "anthropic-agent" }

    public typealias ToolExecutor = @Sendable (String, AnthropicToolInput) async -> ToolResult

    public struct ToolResult: Sendable {
        public let content: String
        public let isError: Bool
        public init(content: String, isError: Bool = false) {
            self.content = content
            self.isError = isError
        }
    }

    public struct Config: Sendable {
        public var apiKey: String
        public var modelID: String
        public var maxTokens: Int
        public var systemPrompt: String
        public var endpoint: URL
        public var timeout: TimeInterval
        public var debug: Bool
        public var maxToolRounds: Int

        public init(
            apiKey: String,
            modelID: String = "claude-haiku-4-5",
            maxTokens: Int = 600,
            systemPrompt: String = AnthropicAgent.defaultSystemPrompt,
            endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
            timeout: TimeInterval = 30.0,
            debug: Bool = false,
            maxToolRounds: Int = 5
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.maxTokens = maxTokens
            self.systemPrompt = systemPrompt
            self.endpoint = endpoint
            self.timeout = timeout
            self.debug = debug
            self.maxToolRounds = maxToolRounds
        }
    }

    public static let defaultSystemPrompt = """
    You are MasterControl, a brief Mac assistant the user controls by voice. \
    Their query will be read aloud back, so:

    - Keep replies to 1–2 short sentences.
    - No markdown, no lists, no preamble. Just the answer or the action.
    - You have tools that operate the user's Mac. Use them when the user \
      asks for an action ("open Slack", "next track"). Use web_search for \
      live info (weather, scores, news).
    - When you take an action, briefly confirm what you did in one phrase. \
      Don't read URLs or citation markers aloud.
    - Bias toward acting, not asking. Never ask "which app?" for keystroke \
      or dictate requests — those always target the focused app. Phrases \
      like "press command N", "press cmd S", "press shift tab", \
      "command space", or "control C" are unambiguous press_key calls; \
      execute them immediately. The transcript may run modifiers and keys \
      together ("commandn", "cmds") — split them yourself.
    """

    /// Convenience constructor. Resolution order, first non-empty wins:
    ///   1. `apiKeyOverride` — caller-supplied (Keychain via Settings)
    ///   2. `ANTHROPIC_API_KEY` in the process environment
    ///   3. `ANTHROPIC_API_KEY` from `~/Downloads/.env`
    /// Returns nil if no key is available so the host can degrade.
    public static func fromEnvironment(
        apiKeyOverride: String? = nil,
        modelID: String = "claude-haiku-4-5",
        debug: Bool = false,
        tools: [AnthropicTool],
        executor: @escaping ToolExecutor
    ) -> AnthropicAgent? {
        let candidates: [String?] = [
            apiKeyOverride,
            ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
            EnvFile.value(for: "ANTHROPIC_API_KEY"),
        ]
        let key = candidates.compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        guard !key.isEmpty else { return nil }
        return AnthropicAgent(
            config: .init(apiKey: key, modelID: modelID, debug: debug),
            tools: tools,
            executor: executor
        )
    }

    public let config: Config
    private let tools: [AnthropicTool]
    private let executor: ToolExecutor
    private let session: URLSession

    public init(config: Config, tools: [AnthropicTool], executor: @escaping ToolExecutor) {
        self.config = config
        self.tools = tools
        self.executor = executor
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Responder conformance

    public func respond(to prompt: String) async throws -> String {
        var messages: [Message] = [
            Message(role: "user", content: [.text(prompt)])
        ]
        for round in 0..<config.maxToolRounds {
            let response = try await call(messages: messages)
            // Append the assistant's full content back into the transcript
            // before sending tool_results — Anthropic requires the
            // assistant's tool_use blocks to immediately precede the
            // matching user-role tool_result blocks.
            messages.append(Message(role: "assistant", content: response.content))

            switch response.stopReason {
            case "end_turn", "max_tokens", "stop_sequence", nil:
                return Self.concatText(response.content)
            case "tool_use":
                let toolUses = response.content.compactMap { block -> (id: String, name: String, input: AnthropicToolInput)? in
                    if case .toolUse(let id, let name, let input) = block {
                        return (id, name, input)
                    }
                    return nil
                }
                if toolUses.isEmpty {
                    // Defensive: stop_reason said tool_use but no blocks.
                    return Self.concatText(response.content)
                }
                var resultBlocks: [ContentBlock] = []
                for tu in toolUses {
                    let result = await executor(tu.name, tu.input)
                    if config.debug {
                        FileHandle.standardError.write(Data(
                            "[anthropic] tool=\(tu.name) result=\(result.content)\n".utf8))
                    }
                    resultBlocks.append(.toolResult(
                        toolUseId: tu.id,
                        content: result.content,
                        isError: result.isError
                    ))
                }
                messages.append(Message(role: "user", content: resultBlocks))
                if round == config.maxToolRounds - 1 {
                    if config.debug {
                        FileHandle.standardError.write(Data(
                            "[anthropic] hit maxToolRounds (\(config.maxToolRounds))\n".utf8))
                    }
                    return "(reached tool-use limit)"
                }
            default:
                return Self.concatText(response.content)
            }
        }
        return "(unreachable)"
    }

    // MARK: - HTTP

    private func call(messages: [Message]) async throws -> ChatResponse {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = MessagesRequest(
            model: config.modelID,
            maxTokens: config.maxTokens,
            system: config.systemPrompt,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            if config.debug {
                FileHandle.standardError.write(Data(
                    "[anthropic] HTTP \(http.statusCode): \(payload)\n".utf8))
            }
            throw AnthropicError.httpStatus(http.statusCode, payload)
        }

        return try ChatResponse(jsonData: data)
    }

    private static func concatText(_ blocks: [ContentBlock]) -> String {
        let text = blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire types

struct Message: Encodable, Sendable {
    let role: String
    let content: [ContentBlock]
}

enum ContentBlock: Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: AnthropicToolInput)
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

extension ContentBlock: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: AnyKey("type"))
            try c.encode(t, forKey: AnyKey("text"))
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: AnyKey("type"))
            try c.encode(id, forKey: AnyKey("id"))
            try c.encode(name, forKey: AnyKey("name"))
            // Encode input as JSON object — pass through the raw values.
            var inputContainer = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("input"))
            for (k, v) in input.raw {
                try inputContainer.encode(EncodableJSON(v), forKey: AnyKey(k))
            }
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode("tool_result", forKey: AnyKey("type"))
            try c.encode(toolUseId, forKey: AnyKey("tool_use_id"))
            try c.encode(content, forKey: AnyKey("content"))
            if isError { try c.encode(true, forKey: AnyKey("is_error")) }
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct EncodableJSON: Encodable {
    let value: SendableJSONValue
    init(_ value: SendableJSONValue) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .string(let s):    try c.encode(s)
        case .number(let n):    try c.encode(n)
        case .bool(let b):      try c.encode(b)
        case .null:             try c.encodeNil()
        case .array(let arr):   try c.encode(arr.map(EncodableJSON.init))
        case .object(let obj):
            var oc = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in obj {
                try oc.encode(EncodableJSON(v), forKey: AnyKey(k))
            }
        }
    }
}

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let tools: [AnthropicTool]?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools
        case maxTokens = "max_tokens"
    }
}

struct ChatResponse: Sendable {
    let content: [ContentBlock]
    let stopReason: String?

    init(jsonData: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]]
        else {
            throw AnthropicError.malformedResponse
        }
        var parsed: [ContentBlock] = []
        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let t = block["text"] as? String { parsed.append(.text(t)) }
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any]
                else { continue }
                var sendable: [String: SendableJSONValue] = [:]
                for (k, v) in input {
                    if let sv = SendableJSONValue(v) { sendable[k] = sv }
                }
                parsed.append(.toolUse(id: id, name: name, input: AnthropicToolInput(raw: sendable)))
            default:
                // server_tool_use, web_search_tool_result, etc. — ignore for
                // now (Claude has produced/consumed them server-side).
                continue
            }
        }
        self.content = parsed
        self.stopReason = obj["stop_reason"] as? String
    }
}
