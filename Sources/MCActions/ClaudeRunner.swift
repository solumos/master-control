@preconcurrency import UserNotifications
import Foundation

/// Spawns `claude --print` subprocesses for delegated coding/research tasks.
///
/// Claude tasks routinely take 30 s – several minutes — far too long to
/// block the listener. We spawn fire-and-forget, log stdout to
/// `~/Library/Logs/MasterControl/claude/<timestamp>.log`, and post a
/// system notification when the process exits. The Anthropic agent (or
/// any caller) gets an immediate "started" response so the user hears
/// "I started Claude on that" right away.
///
/// Default permission posture is `--dangerously-skip-permissions` because
/// there's no attached terminal for Claude to prompt against; tools are
/// restricted by `--allowedTools` to the read-mostly set so the user
/// isn't surprised by silent file edits.
public final class ClaudeRunner: @unchecked Sendable {

    public struct Started: Sendable {
        public let id: UUID
        public let logURL: URL
    }

    public enum Permission: String, Sendable {
        /// Read-only research / Q&A. Safe for unattended use.
        case readOnly
        /// Full agent — Claude can edit files, run shell, fetch URLs.
        /// Use only when the user explicitly asks Claude to *change*
        /// something.
        case full

        var allowedToolsArg: [String] {
            switch self {
            case .readOnly:
                return ["--allowedTools", "Read,Grep,Glob,WebSearch,WebFetch"]
            case .full:
                return [] // no restriction; Claude can use any tool
            }
        }
    }

    private static let logsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MasterControl/claude")
    }()

    /// Looks up the `claude` binary on the user's PATH at init time so we
    /// don't shell out via /usr/bin/env on every invocation. Returns nil
    /// if Claude CLI isn't installed.
    public static func discoverBinary() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private let claudeBinary: URL?

    public init(claudeBinary: URL? = ClaudeRunner.discoverBinary()) {
        self.claudeBinary = claudeBinary
        try? FileManager.default.createDirectory(
            at: Self.logsDirectory,
            withIntermediateDirectories: true
        )
        Self.requestNotificationPermissionIfNeeded()
    }

    public var isAvailable: Bool { claudeBinary != nil }

    /// Spawn Claude in the background and return immediately. Caller gets
    /// the log URL so it can include the path in its acknowledgement
    /// ("Started — log at …"); a system notification fires when the
    /// process exits.
    public func spawn(
        task: String,
        workingDirectory: URL? = nil,
        permission: Permission = .readOnly
    ) -> Started? {
        guard let claudeBinary else { return nil }

        let id = UUID()
        let timestamp = Self.timestampString()
        let logURL = Self.logsDirectory.appendingPathComponent("\(timestamp)-\(id.uuidString.prefix(8)).log")

        let process = Process()
        process.executableURL = claudeBinary
        var args: [String] = [
            "--print",
            "--dangerously-skip-permissions",
        ]
        args.append(contentsOf: permission.allowedToolsArg)
        args.append(task)
        process.arguments = args
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Send claude's stdout/stderr to a per-task log file. We pre-create
        // it so FileHandle(forWritingTo:) succeeds.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return nil
        }
        // Header for the log so it's self-describing.
        let header = "# claude task at \(timestamp)\n# task: \(task)\n# permission: \(permission.rawValue)\n# ---\n"
        try? logHandle.write(contentsOf: Data(header.utf8))

        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { proc in
            try? logHandle.close()
            let status = proc.terminationStatus
            let summary = Self.tailLog(at: logURL, lines: 6)
            Self.postCompletionNotification(
                taskID: id,
                originalTask: task,
                exitCode: status,
                summary: summary,
                logURL: logURL
            )
        }

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            return nil
        }
        return Started(id: id, logURL: logURL)
    }

    // MARK: - Helpers

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func tailLog(at url: URL, lines: Int) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = allLines
            .filter { !$0.hasPrefix("#") }
            .suffix(lines)
        return body.joined(separator: " ")
    }

    private static func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                // Failure is non-fatal — tasks still run, we just don't
                // surface notifications.
            }
        }
    }

    private static func postCompletionNotification(
        taskID: UUID,
        originalTask: String,
        exitCode: Int32,
        summary: String,
        logURL: URL
    ) {
        let content = UNMutableNotificationContent()
        if exitCode == 0 {
            content.title = "Claude finished"
            content.body = summary.isEmpty
                ? "Task: \(originalTask)"
                : summary
        } else {
            content.title = "Claude failed (exit \(exitCode))"
            content.body = "Task: \(originalTask)"
        }
        content.userInfo = ["logPath": logURL.path]
        let request = UNNotificationRequest(
            identifier: taskID.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
