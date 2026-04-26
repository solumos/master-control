import Foundation

public enum IntentKind: String, Codable, Sendable {
    case openApp = "open_app"
    case runShortcut = "run_shortcut"
    case webResearch = "web_research"
    case codeTask = "code_task"
    case freeFormLLM = "free_form_llm"
    case visionFallback = "vision_fallback"
    case unknown
}

public struct Intent: Codable, Sendable {
    public let intent: IntentKind
    public let tool: String
    public let args: [String: ArgValue]
    public let confidence: Double
    public let needsClarification: Bool

    public enum CodingKeys: String, CodingKey {
        case intent, tool, args, confidence
        case needsClarification = "needs_clarification"
    }

    public init(
        intent: IntentKind,
        tool: String,
        args: [String: ArgValue] = [:],
        confidence: Double,
        needsClarification: Bool = false
    ) {
        self.intent = intent
        self.tool = tool
        self.args = args
        self.confidence = confidence
        self.needsClarification = needsClarification
    }
}

public enum ArgValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.typeMismatch(
            ArgValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "unsupported arg value")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

/// JSON Schema as a string, useful for embedding in a prompt body when
/// `response_format` isn't available. The router builds a structured copy
/// of this schema directly for `response_format.json_schema.schema`.
public let intentJSONSchema: String = """
{
  "type": "object",
  "properties": {
    "intent": {
      "type": "string",
      "enum": ["open_app", "run_shortcut", "web_research", "code_task", "free_form_llm", "vision_fallback"]
    },
    "tool": {"type": "string"},
    "args": {"type": "object"},
    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    "needs_clarification": {"type": "boolean"}
  },
  "required": ["intent", "tool", "args", "confidence", "needs_clarification"]
}
"""
