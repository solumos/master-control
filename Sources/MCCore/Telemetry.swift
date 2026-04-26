import Foundation

public enum Stage: String, CaseIterable, Sendable {
    case capture
    case stt
    case intent
    case action
    case sttPlusIntent = "stt+intent"
    case total
}

public struct StageTimings: Sendable {
    public var captureMs: Double = 0
    public var sttMs: Double = 0
    public var intentMs: Double = 0
    public var actionMs: Double = 0

    public init() {}

    public var sttPlusIntentMs: Double { sttMs + intentMs }
    public var totalMs: Double { captureMs + sttMs + intentMs + actionMs }
}

public actor Histogram {
    private var samples: [Stage: [Double]] = [:]

    public init() {}

    public func record(_ timings: StageTimings) {
        samples[.capture, default: []].append(timings.captureMs)
        samples[.stt, default: []].append(timings.sttMs)
        samples[.intent, default: []].append(timings.intentMs)
        samples[.action, default: []].append(timings.actionMs)
        samples[.sttPlusIntent, default: []].append(timings.sttPlusIntentMs)
        samples[.total, default: []].append(timings.totalMs)
    }

    public func count() -> Int {
        samples[.total]?.count ?? 0
    }

    public func summary() -> [Stage: StageStats] {
        var out: [Stage: StageStats] = [:]
        for (stage, vals) in samples where !vals.isEmpty {
            out[stage] = StageStats(values: vals)
        }
        return out
    }
}

public struct StageStats: Sendable {
    public let p50: Double
    public let p99: Double
    public let min: Double
    public let max: Double
    public let mean: Double
    public let n: Int

    public init(values: [Double]) {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        self.n = sorted.count
        self.min = sorted.first!
        self.max = sorted.last!
        self.mean = sorted.reduce(0, +) / Double(sorted.count)
        self.p50 = Self.percentile(sorted, 0.50)
        self.p99 = Self.percentile(sorted, 0.99)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let idx = Swift.max(0, Swift.min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[idx]
    }
}

/// Monotonic clock helper. Use `Clock.now()` then `Clock.elapsedMs(since:)`
/// instead of `Date()` to avoid wall-clock skew during measurement.
public enum Clock {
    public static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public static func elapsedMs(since start: UInt64) -> Double {
        let delta = DispatchTime.now().uptimeNanoseconds &- start
        return Double(delta) / 1_000_000.0
    }
}
