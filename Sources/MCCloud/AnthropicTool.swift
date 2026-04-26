import Foundation

/// Tool definition sent to Anthropic's `/v1/messages`. Two flavors:
///
/// - **Custom tool** — name + description + JSON schema for inputs. Claude
///   emits a `tool_use` block; we execute it and return a `tool_result`.
/// - **Server tool** — Anthropic-managed (e.g. `web_search_20250305`).
///   Claude executes it server-side; we just see the final answer.
public struct AnthropicTool: Encodable, Sendable {
    public let type: String?            // server-tool type, nil for custom
    public let name: String
    public let description: String?
    public let inputSchema: AnthropicToolSchema?

    private enum CodingKeys: String, CodingKey {
        case type, name, description
        case inputSchema = "input_schema"
    }

    public static let webSearch = AnthropicTool(
        type: "web_search_20250305",
        name: "web_search",
        description: nil,
        inputSchema: nil
    )

    public static func custom(
        name: String,
        description: String,
        properties: [String: AnthropicToolSchema.Property] = [:],
        required: [String] = []
    ) -> AnthropicTool {
        AnthropicTool(
            type: nil,
            name: name,
            description: description,
            inputSchema: .init(properties: properties, required: required)
        )
    }
}

public struct AnthropicToolSchema: Encodable, Sendable {
    public let type: String                                // always "object"
    public let properties: [String: Property]
    public let required: [String]

    public init(properties: [String: Property], required: [String] = []) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }

    public struct Property: Encodable, Sendable {
        public let type: String        // "string" / "number" / "boolean"
        public let description: String?
        public init(type: String, description: String? = nil) {
            self.type = type
            self.description = description
        }
    }
}

/// Inputs to a `tool_use` block. Anthropic sends `[String: Any]`-shaped JSON;
/// we decode it as a typed wrapper so the tool executor can pull out values
/// without re-encoding.
public struct AnthropicToolInput: Sendable {
    public let raw: [String: SendableJSONValue]

    public func string(_ key: String) -> String? {
        if case .string(let s) = raw[key] { return s }
        return nil
    }
    public func number(_ key: String) -> Double? {
        if case .number(let n) = raw[key] { return n }
        return nil
    }
    public func bool(_ key: String) -> Bool? {
        if case .bool(let b) = raw[key] { return b }
        return nil
    }
}

/// Sendable JSON value (since Foundation's `Any` isn't Sendable). Used to
/// move tool_use inputs across actor boundaries.
public indirect enum SendableJSONValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([SendableJSONValue])
    case object([String: SendableJSONValue])

    init?(_ any: Any) {
        switch any {
        case let v as String:                       self = .string(v)
        case let v as NSNumber:
            // NSNumber covers both bools and numbers — distinguish via objCType.
            if String(cString: v.objCType) == "c" { self = .bool(v.boolValue) }
            else { self = .number(v.doubleValue) }
        case is NSNull:                             self = .null
        case let v as [Any]:
            self = .array(v.compactMap(SendableJSONValue.init))
        case let v as [String: Any]:
            var obj: [String: SendableJSONValue] = [:]
            for (k, av) in v {
                if let sv = SendableJSONValue(av) { obj[k] = sv }
            }
            self = .object(obj)
        default:
            return nil
        }
    }
}
