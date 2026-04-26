import Foundation

/// Append-only JSONL log of `ActivityEvent`s to
/// `~/Library/Logs/MasterControl/activity.jsonl`. One JSON object per line so
/// `tail -f` works and `jq` slices cleanly. Best-effort — file IO errors are
/// swallowed (we don't want a flaky disk to break the listener).
final class ActivityLogFile: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.solumos.MasterControl.activitylog", qos: .utility)
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(url: URL = ActivityLogFile.defaultURL) {
        self.url = url
        ensureDirectoryExists()
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MasterControl/activity.jsonl")
    }

    func append(_ event: ActivityEvent) {
        guard let line = encode(event) else { return }
        queue.async { [url] in
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // File doesn't exist yet — create with the first line.
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func ensureDirectoryExists() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    private func encode(_ event: ActivityEvent) -> String? {
        let (kind, label, reason): (String, String?, String?) = {
            switch event.status {
            case .ignored:                          return ("ignored", nil, nil)
            case .dictated(let n):                  return ("dictated", "\(n) chars", nil)
            case .executed(let l):                  return ("executed", l, nil)
            case .deferred(let l):                  return ("deferred", l, nil)
            case .failed(let l, let why):           return ("failed", l, why)
            }
        }()

        var obj: [String: Any] = [
            "ts": Self.isoFormatter.string(from: event.timestamp),
            "kind": kind,
            "heard": event.heard,
        ]
        if let label  { obj["label"]  = label }
        if let reason { obj["reason"] = reason }

        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
