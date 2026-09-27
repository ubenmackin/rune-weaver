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
    /// logging never fails a session turn.
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
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

    /// Records helper spawn with the interpreter path.
    ///
    /// Emitted after transport creation so the pid is known; the binary path
    /// identifies the interpreter without capturing arguments or secrets.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - binaryPath: Interpreter path used for the spawn.
    public func logSpawn(account: String, pid: Int32?, binaryPath: String) {
        emit(event: "session.spawn", account: account, pid: pid, fields: ["binaryPath": binaryPath])
    }

    /// Records the open request size after the write.
    ///
    /// Only the byte count rides the event; the request line itself stays out
    /// so the password never enters the log.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - byteCount: UTF-8 bytes written for the open line.
    public func logOpenSent(account: String, pid: Int32?, byteCount: Int) {
        emit(event: "session.open.sent", account: account, pid: pid, fields: ["bytes": byteCount])
    }

    /// Records the open outcome with write-to-line latency.
    ///
    /// Success carries `ok` true; failure carries the verbatim helper detail
    /// so stalled servers stay honest without adding payload content.
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - ok: Whether the open handshake succeeded.
    ///   - error: Verbatim helper detail when `ok` is false.
    ///   - latencyMs: Milliseconds from write to response line.
    public func logOpenResult(account: String, pid: Int32?, ok: Bool, error: String?, latencyMs: Double) {
        var fields: [String: Any] = ["ok": ok, "latencyMs": latencyMs]
        if let error, !ok {
            fields["error"] = error
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
    /// - Parameters:
    ///   - account: Owning account nickname.
    ///   - pid: Helper child pid when known.
    ///   - op: Session operation such as `status`, `search`, or `fetch`.
    ///   - latencyMs: Milliseconds from write to response line.
    ///   - ok: Whether the exchange succeeded.
    ///   - error: Verbatim helper detail when `ok` is false.
    public func logCommand(account: String, pid: Int32?, op: String, latencyMs: Double, ok: Bool, error: String? = nil) {
        var fields: [String: Any] = ["op": op, "latencyMs": latencyMs, "ok": ok]
        if let error, !ok {
            fields["error"] = error
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
