// Rune Weaver Tools — Mail session JSONL event log for IMAP session diagnostics.
//
// Purpose: records one JSON line per mail session lifecycle step into
// `~/.runeweaver/logs/mail-session.jsonl` so operators can trace spawns,
// opens, commands, and closes without ever capturing secrets. Scope: session
// layer only; pool layers may add a mailbox field through the generic emit.
// Architectural role: single owner for event shapes; session actors own the
// emission points and pass only sizes, latencies, and outcomes.

import Foundation
import RuneWeaverCore

/// JSONL event log for persistent mail sessions.
///
/// Every event carries fractional-second ISO8601 `ts`, the `event` name, the
/// owning `account`, and the helper `pid` when known. Callers add only sizes,
/// latencies, and outcomes; passwords, bodies, subjects, and request payloads
/// never enter any field. The live sink appends open-append-close per line and
/// swallows failures so diagnostics never fail a turn.
public struct MailSessionEventLog: Sendable {
    /// Receives one JSON line without a trailing newline.
    ///
    /// The live sink appends the line plus a newline under a serial queue;
    /// tests inject a collector to assert ordering and redaction hermetically.
    public typealias LineSink = @Sendable (String) -> Void

    /// Maximum stderr bytes carried in a dump event.
    ///
    /// Bounds the retained helper output so a chatty helper cannot inflate the
    /// log while still preserving the last words needed for diagnosis.
    public static let maxStderrDumpBytes = 8 * 1024

    /// Serial queue ordering live appends.
    private static let liveQueue = DispatchQueue(label: "com.runeweaver.mail.session-event", qos: .utility)

    /// Locked box around the shared timestamp formatter.
    ///
    /// `ISO8601DateFormatter` carries shared mutable state and does not
    /// conform to `Sendable`, so the box owns the single configured instance
    /// plus its lock and exposes one synchronized entry point. The box itself
    /// is `@unchecked Sendable` because every formatter access runs under the
    /// lock, keeping the static holder concurrency-safe under Swift 6.
    private final class TimestampFormatterBox: @unchecked Sendable {
        /// Underlying formatter configured once for fractional-second instants.
        private let formatter: ISO8601DateFormatter
        /// Serializes concurrent formatter access across session actors.
        private let lock = NSLock()

        /// Creates the shared formatter with internet plus fractional seconds.
        fileprivate init() {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.formatter = formatter
        }

        /// Formats an instant under the lock.
        /// - Parameter date: Instant to stamp.
        /// - Returns: Fractional-second ISO8601 string.
        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.string(from: date)
        }
    }

    /// Shared timestamp formatter reused across emissions.
    ///
    /// Allocated once because construction is measurably costly on the hot
    /// backfill path where every spawn, sent, read, result, and command line
    /// stamps a fractional-second instant. The box serializes access so
    /// concurrent session and pool actors share one instance safely.
    private static let sharedTimestampFormatter = TimestampFormatterBox()

    /// Sink invoked with each encoded JSON line.
    private let sink: LineSink

    /// Creates a log fronted by an injectable sink.
    /// - Parameter sink: Receiver for one JSON line per event.
    public init(sink: @escaping LineSink) {
        self.sink = sink
    }

    /// Live log appending to the default file.
    ///
    /// Always on with no configuration knob; failures are swallowed so event
    /// logging never fails a session turn. Production-only by convention:
    /// every test injects a silent or collecting sink instead of touching
    /// this default, so hermetic suites write zero bytes to the live path.
    public static var live: MailSessionEventLog {
        MailSessionEventLog { line in
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

    /// Emits one event with the shared envelope plus caller fields.
    ///
    /// The envelope owns `ts`, `event`, `account`, and `pid`; `fields` carries
    /// only sizes, latencies, and outcomes so secrets cannot enter the log.
    /// Unencodable field values are dropped rather than failing the caller.
    /// - Parameters:
    ///   - event: Event name such as `session.spawn`.
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known, nil for hermetic fakes.
    ///   - fields: Extra outcome fields without any secret content.
    public func emit(event: String, account: String, pid: Int32?, fields: [String: Any] = [:]) {
        let timestamp = Self.sharedTimestampFormatter.string(from: Date())
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
    ///
    /// Emitted after transport creation so the pid is known; the executable is
    /// the exact string handed to exec while the argv summary names only the
    /// leading flags without the script body. Only paths, counts, and sizes
    /// ride the event so arguments plus secrets stay out of the log.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - executable: Exact executable string handed to exec.
    ///   - argvCount: Number of argv entries handed to exec.
    ///   - argvPreview: Leading flags without the script body.
    ///   - scriptBytes: UTF-8 bytes of the script carried as the last arg.
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
    ///
    /// Carries only sizes plus credential field presence so the request line
    /// itself stays out of the log and host, username, and password values
    /// never enter any field. All sizes count UTF-8 bytes so multibyte
    /// spellings stay comparable with the wire `byteCount`. Grouping keeps
    /// the emit entry point within the parameter budget.
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

        /// Builds the shape with UTF-8 sizes and presence, never values.
        /// - Parameters:
        ///   - byteCount: UTF-8 bytes written for the open line.
        ///   - host: Host field whose UTF-8 size and presence ride the event.
        ///   - port: Port number carried on the open line.
        ///   - username: Username field whose UTF-8 size and presence ride the event.
        ///   - password: Password field whose UTF-8 size and presence ride the event.
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

    /// Records the open request shape after the write.
    ///
    /// Only sizes plus credential field presence ride the event; the request
    /// line itself stays out so host, username, and password values never
    /// enter the log.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - shape: Byte count plus credential presence and lengths.
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

    /// Records one transport read with its outcome plus wait.
    ///
    /// Emitted for every open and command read; only the op name, outcome
    /// token, wait, and byte size ride the event while response bodies stay
    /// out. Outcomes are `first-byte` for a received line, `eof` for a closed
    /// pipe, and `timeout` for an expired budget. Cancellation never logs a
    /// read: callers propagate `CancellationError` before classifying so a
    /// cancelled wait stays absent instead of masquerading as closure.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - op: Session operation owning the read such as `open` or `search`.
    ///   - outcome: Typed outcome token mapped to its string at emit.
    ///   - waitMs: Milliseconds spent waiting for the line.
    ///   - bytes: UTF-8 bytes of the received line, or nil when none arrived.
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

    /// Records one pool claim with its wait.
    ///
    /// Emitted once per open bracket before the handshake starts; only the
    /// mailbox plus the claim wait ride the event so credentials stay out.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Pooled helper pid when already known, nil for a fresh handle.
    ///   - mailbox: Mailbox the bracket will read.
    ///   - waitMs: Milliseconds spent claiming the pooled handle.
    public func logClaim(account: String, pid: Int32?, mailbox: String, waitMs: Double) {
        emit(event: "pool.claim", account: account, pid: pid, fields: ["mailbox": mailbox, "waitMs": waitMs])
    }

    /// Redacts email-shaped identity from an error detail before logging.
    ///
    /// The helper contract keeps identity out of failure envelopes, but older
    /// envelopes or transport wording can still carry `user@host`; scrubbing
    /// here keeps host and username values out of every field even when a
    /// caller forwards verbatim detail. Session actors additionally strip
    /// their exact credential values before calling.
    /// - Parameter error: Raw failure detail.
    /// - Returns: Detail with email addresses replaced by a placeholder.
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

    /// Records the open outcome with write-to-line latency.
    ///
    /// Success carries `ok` true; failure carries the sanitized helper detail
    /// so stalled servers stay honest without adding payload content or
    /// identity. Email-shaped tokens are redacted at emit so host and
    /// username values never enter any field.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - ok: Whether the open handshake succeeded.
    ///   - error: Sanitized helper detail when `ok` is false.
    ///   - latencyMs: Milliseconds from write to response line.
    public func logOpenResult(account: String, pid: Int32?, ok: Bool, error: String?, latencyMs: Double) {
        var fields: [String: Any] = ["ok": ok, "latencyMs": latencyMs]
        if let error, !ok {
            fields["error"] = Self.redactedErrorDetail(error)
        }
        emit(event: "session.open.result", account: account, pid: pid, fields: fields)
    }

    /// Records the full retained stderr dump for a failed open.
    ///
    /// Carries up to 8KB of newest helper bytes; callers pass the transport's
    /// retained dump which already caps at the bound. The helper script
    /// contract keeps secrets out of stderr, and only sizes plus diagnostics
    /// ride this event.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - stderr: Retained helper stderr, newest bytes first-capped.
    public func logStderr(account: String, pid: Int32?, stderr: String) {
        let capped = Self.cappedDump(stderr)
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        emit(event: "session.stderr", account: account, pid: pid, fields: ["stderr": capped])
    }

    /// Records one command exchange with latency and outcome.
    ///
    /// Emitted for every send that reaches the wire; only the op name, timing,
    /// and outcome ride the event while query text and payloads stay out.
    /// Failure details are sanitized like open results so identity never
    /// enters the log. Cancellation never logs a command: callers propagate
    /// `CancellationError` before reaching this failure path.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - op: Session operation such as `status`, `search`, or `fetch`.
    ///   - latencyMs: Milliseconds from write to response line.
    ///   - ok: Whether the exchange succeeded.
    ///   - error: Sanitized helper detail when `ok` is false.
    public func logCommand(account: String, pid: Int32?, op: String, latencyMs: Double, ok: Bool, error: String? = nil) {
        var fields: [String: Any] = ["op": op, "latencyMs": latencyMs, "ok": ok]
        if let error, !ok {
            fields["error"] = Self.redactedErrorDetail(error)
        }
        emit(event: "session.command", account: account, pid: pid, fields: fields)
    }

    /// Records session close with a clean or terminate outcome.
    ///
    /// Clean means the close handshake wrote and read without throwing;
    /// terminate covers every other teardown including a missing transport.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - outcome: `clean` or `terminate`.
    public func logClose(account: String, pid: Int32?, outcome: String) {
        emit(event: "session.close", account: account, pid: pid, fields: ["outcome": outcome])
    }

    /// Outcome tokens for transport reads.
    ///
    /// Single owner for the read outcome vocabulary so session and pool layers
    /// share one wording: a received line is `first-byte`, a closed pipe is
    /// `eof`, and an expired budget is `timeout`.
    public enum SessionReadOutcome: String, Sendable {
        /// One response line arrived within budget.
        case firstByte = "first-byte"
        /// The pipe closed before a line arrived.
        case eof
        /// The budget expired before a line arrived.
        case timeout
    }

    /// Classifies a read failure into a read outcome token.
    ///
    /// Timeout wording maps to `timeout` while every other transport failure
    /// maps to `eof` so closed pipes plus unknown details stay in one bucket
    /// without carrying payload text. Cancellation is never classified:
    /// callers must propagate `CancellationError` before calling so a
    /// cancelled wait never masquerades as a transport closure.
    /// - Parameter error: Read failure under test, never `CancellationError`.
    /// - Returns: Typed outcome token for `session.read` events.
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
    ///
    /// Single owner for the stderr dump shape: the live transport sizes its
    /// retained dump with `maxStderrDumpBytes` and the hermetic fake caps
    /// through this helper so the bound cannot drift between paths. A raw
    /// byte suffix can start mid-scalar, so leading continuation bytes are
    /// walked past until the remainder decodes strictly; the result stays
    /// within the bound and never emits a replacement character for the cut.
    /// - Parameter text: Full retained stderr text.
    /// - Returns: Newest bytes up to the dump bound as text.
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
