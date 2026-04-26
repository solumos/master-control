import Foundation
import MCCore

/// A pluggable strategy for turning a transcribed utterance into a
/// structured `Intent`. Implementations can be deterministic (regex/alias
/// match), local-LLM-backed, or remote-LLM-backed.
public protocol Router: Sendable {
    /// Friendly name used in telemetry/logging ("deterministic", "mlx-qwen3", …).
    var name: String { get }

    /// Returns a classified `Intent` if this router can confidently handle
    /// the utterance, or `nil` to fall through to the next router in the chain.
    /// Throws on infrastructure failure (timeout, model not loaded);
    /// expressed-uncertainty should return `nil` so the chain can fall through.
    func classify(utterance: String) async throws -> Intent?
}

/// Wraps a sequence of `Router`s. The first one to return non-nil wins.
public final class RouterChain: Router, @unchecked Sendable {
    public let name = "chain"
    private let routers: [any Router]
    public private(set) var lastMatchedBy: String? = nil

    public init(_ routers: [any Router]) {
        self.routers = routers
    }

    public func classify(utterance: String) async throws -> Intent? {
        for router in routers {
            if let intent = try await router.classify(utterance: utterance) {
                lastMatchedBy = router.name
                return intent
            }
        }
        lastMatchedBy = nil
        return nil
    }
}
