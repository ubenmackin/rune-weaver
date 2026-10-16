// Rune Weaver Tools — Mail session JSONL event log for IMAP session diagnostics.

import Foundation
import RuneWeaverCore

/// JSONL event log for persistent mail sessions. Callers add only sizes, latencies, and outcomes;
/// passwords, bodies, subjects, and request payloads never enter any field.
public struct MailSessionEventLog: Sendable {
    /// Receives one JSON line without a trailing newline.
    public typealias LineSink = @Sendable (String) -> Void

    /// Maximum stderr bytes carried in a dump event. Bounds the retained helper output so a chatty
    /// helper cannot inflate the log while still preserving the last words needed for diagnosis.
    public static let maxStderrDumpBytes = 8 * 1024

    /// Serial queue ordering live appends.
    private static let liveQueue = DispatchQueue(label: "com.runeweaver.mail.session-event", qos: .utility)

    /// Sendable format style for fractional-second ISO8601 timestamps.
    private static let timestampStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    /// Sink invoked with each encoded JSON line.
    private let sink: LineSink

    /// Creates a log fronted by an injectable sink.
    /// - Parameter sink: Receiver for one JSON line per event.
    public init(sink: @escaping LineSink) {
        self.sink = sink
    }

    /// Silent log dropping all events.
    public static let silent = MailSessionEventLog { _ in }

    /// Whether the current process is running inside an automated test harness.
    public static var isRunningInTestEnvironment: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["RUNEWEAVER_FORCE_LIVE_EVENT_LOG"] == "1" {
            return false
        }
        if env["XCTestConfigurationFilePath"] != nil ||
            env["XCTestBundlePath"] != nil ||
            env["SWIFT_DETERMINISTIC_HASHING"] != nil
        {
            return true
        }
        let processName = ProcessInfo.processInfo.processName
        if processName.range(of: "test", options: .caseInsensitive) != nil {
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(where: {
            $0.contains(".xctest") || $0.contains("swift-testing") || $0.contains("swift-test")
        }) {
            return true
        }
        if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil {
            return true
        }
        return false
    }

    /// Live log appending to the default file. Always on with no configuration knob in production;
    /// failures are swallowed so event logging never fails a session turn.
    public static var live: MailSessionEventLog {
        guard !isRunningInTestEnvironment else {
            return .silent
        }
        return MailSessionEventLog { line in
            let url = defaultLogURL()
            let payload = Data((line + "\n").utf8)
            liveQueue.async {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: url.path) {
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: payload)
                    } else {
                        try payload.write(to: url, options: .atomic)
                    }
                } catch {
                    // Best-effort: event failures never fail the session.
                    RuneWeaverLog.tools.debug("MailSessionEventLog append failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Default event file URL.
    /// - Returns: `~/.runeweaver/logs/mail-session.jsonl` as a file URL.
    public static func defaultLogURL() -> URL {
        let expanded = ("~/.runeweaver/logs" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).appendingPathComponent("mail-session.jsonl")
    }

    /// Emits one event with the shared envelope plus caller fields. The envelope owns `ts`,
    /// `event`, `account`, and `pid`; `fields` carries only sizes, latencies, and outcomes so
    /// secrets cannot enter the log.
    public func emit(event: String, account: String, pid: Int32?, fields: [String: Any] = [:]) {
        let timestamp = Date().formatted(Self.timestampStyle)
        var object: [String: Any] = [
            "ts": timestamp,
            "event": event,
            "account": account
        ]
        if let pid {
            object["pid"] = Int(pid)
        }
        for (key, value) in fields {
            // Envelope keys win so callers cannot spoof identity fields.
            guard object[key] == nil else { continue }
            object[key] = value
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        sink(line)
    }

    /// Records helper spawn with the exact executable plus an argv summary.
    public func logSpawn(
        account: String,
        pid: Int32?,
        executable: String,
        argvCount: Int,
        argvPreview: String,
        scriptBytes: Int
    ) {
        emit(
            event: "session.spawn",
            account: account,
            pid: pid,
            fields: [
                "executable": executable,
                "argvCount": argvCount,
                "argvPreview": argvPreview,
                "scriptBytes": scriptBytes
            ]
        )
    }

    /// Shape of the open request for the sent event without values.
    public struct OpenSentShape: Sendable {
        /// UTF-8 bytes written for the open line.
        public let byteCount: Int
        /// UTF-8 byte count of the host field.
        public let hostChars: Int
        /// Port number carried on the open line.
        public let port: Int
        /// UTF-8 byte count of the username field.
        public let usernameChars: Int
        /// UTF-8 byte count of the password field.
        public let passwordChars: Int
        /// Whether the host field is non-empty.
        public let hasHost: Bool
        /// Whether the username field is non-empty.
        public let hasUsername: Bool
        /// Whether the password field is non-empty.
        public let hasPassword: Bool

        /// Builds the shape with UTF-8 sizes and presence, never values. byteCount:
        /// UTF-8 bytes written for the open line.
        public init(byteCount: Int, host: String, port: Int, username: String, password: String) {
            self.byteCount = byteCount
            self.hostChars = host.utf8.count
            self.port = port
            self.usernameChars = username.utf8.count
            self.passwordChars = password.utf8.count
            self.hasHost = !host.isEmpty
            self.hasUsername = !username.isEmpty
            self.hasPassword = !password.isEmpty
        }
    }

    /// Records the open request shape after the write. Only sizes plus credential field presence
    /// ride the event; the request line itself stays out so host, username, and password values
    /// never enter the log.
    public func logOpenSent(
        account: String,
        pid: Int32?,
        shape: OpenSentShape
    ) {
        emit(
            event: "session.open.sent",
            account: account,
            pid: pid,
            fields: [
                "bytes": shape.byteCount,
                "hostChars": shape.hostChars,
                "port": shape.port,
                "usernameChars": shape.usernameChars,
                "passwordChars": shape.passwordChars,
                "hasHost": shape.hasHost,
                "hasUsername": shape.hasUsername,
                "hasPassword": shape.hasPassword
            ]
        )
    }

    /// Records one transport read with its outcome plus wait. Emitted for every open and command
    /// read; only the op name, outcome token, wait, and byte size ride the event while response
    /// bodies stay out.
    public func logRead(
        account: String,
        pid: Int32?,
        op: String,
        outcome: SessionReadOutcome,
        waitMs: Double,
        bytes: Int? = nil
    ) {
        var fields: [String: Any] = ["op": op, "outcome": outcome.rawValue, "waitMs": waitMs]
        if let bytes {
            fields["bytes"] = bytes
        }
        emit(event: "session.read", account: account, pid: pid, fields: fields)
    }

    /// Records one pool claim with its wait. Emitted once per open bracket before the handshake
    /// starts; only the mailbox plus the claim wait ride the event so credentials stay out.
    public func logClaim(account: String, pid: Int32?, mailbox: String, waitMs: Double) {
        emit(event: "pool.claim", account: account, pid: pid, fields: ["mailbox": mailbox, "waitMs": waitMs])
    }

    /// Redacts email-shaped identity from an error detail before logging.
    static func redactedErrorDetail(_ error: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: "[A-Z0-9._%+\\-]+@[A-Z0-9.\\-]+\\.[A-Z]{2,}",
            options: [.caseInsensitive]
        ) else {
            return error
        }
        let range = NSRange(error.startIndex ..< error.endIndex, in: error)
        return pattern.stringByReplacingMatches(in: error, options: [], range: range, withTemplate: "[redacted]")
    }

    /// Records the open outcome with write-to-line latency. Success carries `ok` true; failure
    /// carries the sanitized helper detail so stalled servers stay honest without adding payload
    /// content or identity.
    public func logOpenResult(account: String, pid: Int32?, ok: Bool, error: String?, latencyMs: Double) {
        var fields: [String: Any] = ["ok": ok, "latencyMs": latencyMs]
        if let error, !ok {
            fields["error"] = Self.redactedErrorDetail(error)
        }
        emit(event: "session.open.result", account: account, pid: pid, fields: fields)
    }

    /// Records the full retained stderr dump for a failed open. Carries up to 8KB of newest helper
    /// bytes; callers pass the transport's retained dump which already caps at the bound.
    public func logStderr(account: String, pid: Int32?, stderr: String) {
        let capped = Self.cappedDump(stderr)
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        emit(event: "session.stderr", account: account, pid: pid, fields: ["stderr": capped])
    }

    /// Records one command exchange with latency and outcome. Emitted for every send that reaches
    /// the wire; only the op name, timing, and outcome ride the event while query text and payloads
    /// stay out.
    public func logCommand(account: String, pid: Int32?, op: String, latencyMs: Double, ok: Bool, error: String? = nil) {
        var fields: [String: Any] = ["op": op, "latencyMs": latencyMs, "ok": ok]
        if let error, !ok {
            fields["error"] = Self.redactedErrorDetail(error)
        }
        emit(event: "session.command", account: account, pid: pid, fields: fields)
    }

    /// Records session close with a clean or terminate outcome.
    public func logClose(account: String, pid: Int32?, outcome: String) {
        emit(event: "session.close", account: account, pid: pid, fields: ["outcome": outcome])
    }

    /// Outcome tokens for transport reads.
    public enum SessionReadOutcome: String, Sendable {
        /// One response line arrived within budget.
        case firstByte = "first-byte"
        /// The pipe closed before a line arrived.
        case eof
        /// The budget expired before a line arrived.
        case timeout
    }

    /// Classifies a read failure into a read outcome token.
    public static func readOutcome(for error: Error) -> SessionReadOutcome {
        if let sessionError = error as? EmailIMAPError, case let .bridgeFailed(detail) = sessionError {
            if detail.range(of: "timed out", options: .caseInsensitive) != nil {
                return .timeout
            }
            return .eof
        }
        let described = error.localizedDescription
        if described.range(of: "timed out", options: .caseInsensitive) != nil {
            return .timeout
        }
        return .eof
    }

    /// Caps a dump to the newest retained bytes aligned to a UTF-8 boundary.
    static func cappedDump(_ text: String) -> String {
        let bytes = Data(text.utf8)
        guard bytes.count > maxStderrDumpBytes else { return text }
        var tail = bytes.suffix(maxStderrDumpBytes)
        // The source string is valid UTF-8, so only the leading edge can be
        // torn; drop at most the bytes of one scalar until strict decoding
        // succeeds, keeping the cut on a scalar boundary.
        while !tail.isEmpty, String(data: Data(tail), encoding: .utf8) == nil {
            tail = tail.dropFirst()
        }
        return String(bytes: tail, encoding: .utf8) ?? ""
    }
}
