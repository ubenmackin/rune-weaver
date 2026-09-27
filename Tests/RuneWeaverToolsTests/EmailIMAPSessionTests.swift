// Rune Weaver Tools Tests — Persistent IMAP session script coverage.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Serialized session pipe coverage: each case spawns `python3` with piped
/// stdio, so cases run one at a time to keep output drains deterministic.
@Suite("Email IMAP Session", .serialized)
struct EmailIMAPSessionTests {
    /// Fake `imaplib` fronting the session source for hermetic pipe coverage.
    ///
    /// Counts connections through `stderr` markers while serving fixed
    /// `STATUS`, `SEARCH`, and `FETCH` answers from one canned message.
    private static var stubPrelude: String {
        #"""
        import sys, json, imaplib, email, re, ssl
        class _FakeIMAP:
            def __init__(self, host, port, ssl_context=None, timeout=None, **kw):
                sys.stderr.write("CONNECT %s:%s timeout=%s\n" % (host, port, timeout))
                sys.stderr.flush()
            def login(self, user, pw):
                sys.stderr.write("LOGIN %s\n" % user)
                sys.stderr.flush()
                return ("OK", [b"ok"])
            def select(self, box, readonly=True):
                sys.stderr.write("SELECT %s readonly=%s\n" % (box, readonly))
                sys.stderr.flush()
                return ("OK", [b"1"])
            def status(self, box, req):
                sys.stderr.write("STATUS %s %s\n" % (box, req))
                sys.stderr.flush()
                return ("OK", [b'"INBOX" (UIDNEXT 2001 UIDVALIDITY 7)'])
            def uid(self, cmd, *args):
                sys.stderr.write("UID %s %s\n" % (cmd, args))
                sys.stderr.flush()
                lc = cmd.lower() if isinstance(cmd, str) else ""
                if lc == "search":
                    return ("OK", [b"1 2"])
                if lc == "fetch":
                    raw = (b"From: boss@example.com\r\nTo: you@example.com\r\nSubject: Hello\r\nDate: Mon, 01 Sep 2025 09:00:00 +0000\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello body")
                    return ("OK", [(b"1 (BODY[] {123}", raw)])
                return ("NO", None)
            def fetch(self, num, spec):
                sys.stderr.write("FETCH %s %s\n" % (num, spec))
                sys.stderr.flush()
                raw = (b"From: boss@example.com\r\nTo: you@example.com\r\nSubject: Hello\r\nDate: Mon, 01 Sep 2025 09:00:00 +0000\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello body")
                return ("OK", [(b"1 (BODY[] {123}", raw)])
            def logout(self):
                sys.stderr.write("LOGOUT\n")
                sys.stderr.flush()
                return ("BYE", [b"bye"])
        imaplib.IMAP4_SSL = _FakeIMAP
        """#
    }

    /// Failure thrown when the piped session helper misbehaves.
    private struct SessionHarnessError: Error, LocalizedError {
        /// Human-readable harness detail.
        let message: String
        /// Returns `message` for test failure display.
        var errorDescription: String? {
            message
        }
    }

    /// Minimal envelope for `open`, `close`, and failure documents.
    private struct SessionEnvelope: Decodable {
        /// Whether the turn succeeded.
        let ok: Bool
        /// Error detail when `ok` is false.
        let error: String?
    }

    /// Drives the stubbed session source with one JSON document per line.
    private static func runSession(
        inputLines: [String],
        timeoutSeconds: TimeInterval = 10
    ) throws -> (stdoutLines: [String], stderr: String, exitCode: Int32) {
        let fullSource = stubPrelude + "\n" + EmailIMAPSessionScript.source
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", fullSource]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let payloadString = inputLines.isEmpty ? "" : (inputLines.joined(separator: "\n") + "\n")
        if let payload = payloadString.data(using: .utf8), !payload.isEmpty {
            try inputPipe.fileHandleForWriting.write(contentsOf: payload)
        }
        try inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw SessionHarnessError(message: "Session helper timed out after \(timeoutSeconds)s")
        }
        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, stderr, process.terminationStatus)
    }

    /// Counts whole-line markers in captured `stderr`.
    private static func countMarker(_ marker: String, in stderr: String) -> Int {
        stderr.split(separator: "\n").filter { $0.contains(marker) }.count
    }

    /// Decodes a generic session envelope from one stdout line.
    private static func decodeEnvelope(_ line: String) throws -> SessionEnvelope {
        try JSONDecoder().decode(SessionEnvelope.self, from: Data(line.utf8))
    }

    @Test
    func `Session source parses as Python`() throws {
        try ToolsTestSupport.assertBridgeSourceParses(EmailIMAPSessionScript.source)
    }

    @Test
    func `Session source exposes five read-only ops over piped JSON`() throws {
        let source = EmailIMAPSessionScript.source
        #expect(source.contains("for line in sys.stdin"))
        #expect(source.contains("sys.stdout.flush()"))
        #expect(source.contains("op == \"open\""))
        #expect(source.contains("op == \"status\""))
        #expect(source.contains("op == \"search\""))
        #expect(source.contains("op == \"fetch\""))
        #expect(source.contains("op == \"close\""))
        #expect(source.contains("timeout=30"))
        #expect(source.contains("ssl.create_default_context()"))
        #expect(source.contains("Could not connect to %s@%s:%s: %s"))
        #expect(source.contains("IMAP login failed for %s@%s:%s: %s"))
        #expect(source.contains("unknown session op"))
        #expect(source.contains("session not open"))
        #expect(source.contains("\"uidNext\""))
        #expect(source.contains("\"uidValidity\""))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Session source stays read-only with peek fetches`() throws {
        let source = EmailIMAPSessionScript.source
        #expect(source.contains("(BODY.PEEK[])"))
        #expect(source.contains("readonly=True"))
        #expect(!source.contains("move"))
        #expect(!source.contains("append"))
        #expect(!source.contains("list"))
        #expect(!source.contains("\"move\""))
        #expect(!source.contains("\"append\""))
        #expect(!source.contains("\"list\""))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Session source quotes every select with shared quoter`() throws {
        let source = EmailIMAPSessionScript.source
        #expect(source.contains("def quote_mailbox"))
        #expect(source.components(separatedBy: "def quote_mailbox").count == 2)
        #expect(source.contains(#"name.replace("\\", "\\\\")"#))
        #expect(source.contains("conn.select(quote_mailbox(mailbox)"))
        #expect(source.contains("conn.status(quote_mailbox(status_box)"))
        #expect(source.contains("Invalid mailbox"))
        #expect(source.contains("\\r") && source.contains("\\n"))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Session source rejects CR LF and allowlists UID`() throws {
        let source = EmailIMAPSessionScript.source
        #expect(source.contains("\\r") && source.contains("\\n"))
        #expect(source.contains("Invalid search query"))
        #expect(source.contains("Invalid mailbox"))
        #expect(source.contains("Invalid message id"))
        #expect(source.contains("re.fullmatch"))
        #expect(source.contains("[0-9][0-9:,]*"))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Live session drives open status search fetch close on one connection`() throws {
        let open = #"{"op":"open","host":"mail.example.com","port":993,"username":"you@example.com","password":"test-secret"}"#
        let status = #"{"op":"status","mailbox":"INBOX"}"#
        let search = #"{"op":"search","mailbox":"INBOX","query":"hello","limit":10}"#
        let fetch = #"{"op":"fetch","mailbox":"INBOX","messageID":"1"}"#
        let close = #"{"op":"close"}"#
        let result = try Self.runSession(inputLines: [open, status, search, fetch, close])
        #expect(result.exitCode == 0)
        #expect(result.stdoutLines.count == 5)
        let opened = try Self.decodeEnvelope(result.stdoutLines[0])
        #expect(opened.ok == true)
        let mailboxStatus = try EmailBridgeParsing.parseStatusPayload(Data(result.stdoutLines[1].utf8))
        #expect(mailboxStatus.mailbox == "INBOX")
        #expect(mailboxStatus.uidNext == 2001)
        #expect(mailboxStatus.uidValidity == 7)
        let hits = try EmailBridgeParsing.parseSearchPayload(Data(result.stdoutLines[2].utf8))
        #expect(hits.count == 2)
        #expect(hits[0].id == "2")
        #expect(hits[0].mailbox == "INBOX")
        let message = try EmailBridgeParsing.parseFetchPayload(Data(result.stdoutLines[3].utf8))
        #expect(message.id == "1")
        #expect(message.subject == "Hello")
        #expect(message.body.contains("Hello body"))
        let closed = try Self.decodeEnvelope(result.stdoutLines[4])
        #expect(closed.ok == true)
        #expect(Self.countMarker("CONNECT", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGIN", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGOUT", in: result.stderr) == 1)
        #expect(result.stderr.contains("SELECT"))
        #expect(result.stderr.contains("STATUS"))
    }

    @Test
    func `Live session fails fast before open`() throws {
        let early = #"{"op":"search","mailbox":"INBOX","query":"hello","limit":10}"#
        let result = try Self.runSession(inputLines: [early])
        #expect(result.exitCode == 0)
        #expect(result.stdoutLines.count == 1)
        let envelope = try Self.decodeEnvelope(result.stdoutLines[0])
        #expect(envelope.ok == false)
        #expect((envelope.error ?? "").contains("session not open"))
        #expect(Self.countMarker("CONNECT", in: result.stderr) == 0)
        #expect(Self.countMarker("LOGIN", in: result.stderr) == 0)
    }

    @Test
    func `Live session rejects bad mailbox and message id without redial`() throws {
        let open = #"{"op":"open","host":"mail.example.com","port":993,"username":"you@example.com","password":"test-secret"}"#
        let badMailbox = "{\"op\":\"search\",\"mailbox\":\"INBOX\\nEVIL\",\"query\":\"hi\",\"limit\":10}"
        let badQuery = "{\"op\":\"search\",\"mailbox\":\"INBOX\",\"query\":\"hi\\r\\nthere\",\"limit\":10}"
        let badID = #"{"op":"fetch","mailbox":"INBOX","messageID":"abc; DROP"}"#
        let result = try Self.runSession(inputLines: [open, badMailbox, badQuery, badID])
        #expect(result.exitCode == 0)
        #expect(result.stdoutLines.count == 4)
        let opened = try Self.decodeEnvelope(result.stdoutLines[0])
        #expect(opened.ok == true)
        for line in result.stdoutLines[1...] {
            let envelope = try Self.decodeEnvelope(line)
            #expect(envelope.ok == false)
        }
        #expect(try (Self.decodeEnvelope(result.stdoutLines[1]).error ?? "").contains("Invalid mailbox"))
        #expect(try (Self.decodeEnvelope(result.stdoutLines[2]).error ?? "").contains("Invalid search query"))
        #expect(try (Self.decodeEnvelope(result.stdoutLines[3]).error ?? "").contains("Invalid message id"))
        #expect(Self.countMarker("CONNECT", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGIN", in: result.stderr) == 1)
    }

    @Test
    func `Live session rejects unknown op without redial`() throws {
        let open = #"{"op":"open","host":"mail.example.com","port":993,"username":"you@example.com","password":"test-secret"}"#
        let bogus = #"{"op":"bogus"}"#
        let result = try Self.runSession(inputLines: [open, bogus])
        #expect(result.exitCode == 0)
        #expect(result.stdoutLines.count == 2)
        #expect(try Self.decodeEnvelope(result.stdoutLines[0]).ok == true)
        let envelope = try Self.decodeEnvelope(result.stdoutLines[1])
        #expect(envelope.ok == false)
        #expect((envelope.error ?? "").contains("unknown session op"))
        #expect(Self.countMarker("CONNECT", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGIN", in: result.stderr) == 1)
    }

    @Test
    func `Live session close is idempotent with single logout`() throws {
        let open = #"{"op":"open","host":"mail.example.com","port":993,"username":"you@example.com","password":"test-secret"}"#
        let close = #"{"op":"close"}"#
        let result = try Self.runSession(inputLines: [open, close, close])
        #expect(result.exitCode == 0)
        #expect(result.stdoutLines.count == 3)
        for line in result.stdoutLines {
            #expect(try Self.decodeEnvelope(line).ok == true)
        }
        #expect(Self.countMarker("CONNECT", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGIN", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGOUT", in: result.stderr) == 1)
    }

    @Test
    func `Live session logs out on EOF without explicit close`() throws {
        let open = #"{"op":"open","host":"mail.example.com","port":993,"username":"you@example.com","password":"test-secret"}"#
        let status = #"{"op":"status","mailbox":"INBOX"}"#
        let result = try Self.runSession(inputLines: [open, status])
        #expect(result.exitCode == 0)
        #expect(result.stdoutLines.count == 2)
        #expect(try Self.decodeEnvelope(result.stdoutLines[0]).ok == true)
        let mailboxStatus = try EmailBridgeParsing.parseStatusPayload(Data(result.stdoutLines[1].utf8))
        #expect(mailboxStatus.uidNext == 2001)
        #expect(Self.countMarker("CONNECT", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGIN", in: result.stderr) == 1)
        #expect(Self.countMarker("LOGOUT", in: result.stderr) == 1)
    }

    @Test
    func `Session source orders IPv4 first before connecting`() throws {
        // The persistent helper reuses one connection across turns, so the
        // address order is fixed once at startup rather than per command.
        let source = EmailIMAPSessionScript.source
        #expect(source.contains("def prefer_ipv4"))
        #expect(source.contains("getaddrinfo"))
        #expect(source.contains("AF_INET"))
        #expect(source.contains("prefer_ipv4()"))
        if let call = source.range(of: "prefer_ipv4()"),
           let connect = source.range(of: "IMAP4_SSL")
        {
            #expect(call.lowerBound < connect.lowerBound)
        } else {
            Issue.record("Expected prefer_ipv4 call before IMAP4_SSL")
        }
        if let definition = source.range(of: "def prefer_ipv4"),
           let connect = source.range(of: "IMAP4_SSL")
        {
            #expect(definition.lowerBound < connect.lowerBound)
        } else {
            Issue.record("Expected prefer_ipv4 definition before IMAP4_SSL")
        }
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }

    @Test
    func `Session prelude prefers IPv4 with fallback over stub socket`() throws {
        // Same ordering contract through the session composition: stub
        // results starting with IPv6 must dial IPv4 first, a refused IPv4
        // must fall through, and IPv6-only hosts must stay reachable.
        let probe = #"""
        AF4 = socket.AF_INET
        AF6 = socket.AF_INET6
        def v4(addr):
            return (AF4, socket.SOCK_STREAM, 6, "", (addr, 993))
        def v6(addr):
            return (AF6, socket.SOCK_STREAM, 6, "", (addr, 993, 0, 0))
        out = {}
        socket.getaddrinfo = lambda *a, **k: [v6("2001:db8::1"), v4("192.0.2.1")]
        prefer_ipv4()
        ordered = socket.getaddrinfo("mail.example.com", 993)
        out["firstIsV4"] = (ordered[0][0] == AF4)
        dialed = []
        connected = None
        for fam, typ, proto, canon, sa in ordered:
            dialed.append("v4" if fam == AF4 else "v6")
            try:
                if fam == AF4:
                    raise OSError("refused")
                connected = sa
                break
            except OSError:
                continue
        out["dialed"] = dialed
        out["fellThrough"] = (connected is not None and dialed == ["v4", "v6"])
        socket.getaddrinfo = lambda *a, **k: [v6("2001:db8::2")]
        prefer_ipv4()
        only = socket.getaddrinfo("mail.example.com", 993)
        out["v6Only"] = (len(only) == 1 and only[0][0] == AF6)
        socket.getaddrinfo = lambda *a, **k: [v6("2001:db8::a"), v4("192.0.2.10"), v6("2001:db8::b"), v4("192.0.2.11")]
        prefer_ipv4()
        stable = socket.getaddrinfo("mail.example.com", 993)
        out["stable"] = ([s[4][0] for s in stable] == ["192.0.2.10", "192.0.2.11", "2001:db8::a", "2001:db8::b"])
        sys.stdout.write(json.dumps(out))
        """#
        let fullSource = "import sys, json, socket, re\nfrom email.header import decode_header\n"
            + EmailIMAPSharedPrelude.text + "\n" + probe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", fullSource]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        struct ProbeResult: Decodable {
            /// Whether the first entry dials IPv4.
            let firstIsV4: Bool
            /// Families dialed in order.
            let dialed: [String]
            /// Whether a refused IPv4 fell through to IPv6.
            let fellThrough: Bool
            /// Whether an IPv6-only stub connects unchanged.
            let v6Only: Bool
            /// Whether mixed lists keep relative order per family.
            let stable: Bool
        }
        let result = try JSONDecoder().decode(ProbeResult.self, from: stdoutData)
        #expect(result.firstIsV4)
        #expect(result.dialed == ["v4", "v6"])
        #expect(result.fellThrough)
        #expect(result.v6Only)
        #expect(result.stable)
    }
}

/// Hermetic actor coverage over the line-framing seam.
///
/// Each case drives `EmailIMAPSession` with in-memory transports so framing,
/// timeout, reconnect, and close behavior assert without spawning helpers.
@Suite("Email IMAP Session Actor")
struct EmailIMAPSessionActorTests {
    /// One decoded `op` field from a written session line.
    private struct WrittenOp: Decodable {
        /// Operation name carried on the line.
        let op: String
    }

    /// Counts spawns and serves fakes in order for reconnect assertions.
    private final class TestSpawner: @unchecked Sendable {
        /// Guards spawn state.
        private let lock = NSLock()
        /// Fakes served first-in first-out, one per spawn.
        private var fakes: [FakeSessionLineTransport]
        /// Number of factory calls observed.
        private var spawns = 0

        /// Creates a spawner serving the given fakes in order.
        /// - Parameter fakes: One fake per expected spawn.
        init(_ fakes: [FakeSessionLineTransport]) {
            self.fakes = fakes
        }

        /// Returns the next fake, reusing the last when over-requested.
        /// - Returns: Fake for the current spawn.
        func next() -> FakeSessionLineTransport {
            lock.lock()
            defer { lock.unlock() }
            spawns += 1
            if spawns <= fakes.count {
                return fakes[spawns - 1]
            }
            return fakes[fakes.count - 1]
        }

        /// Number of factory calls so far.
        var spawnCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return spawns
        }
    }

    /// Credentials for hermetic opens; the password never leaves the session line.
    private static func testCredentials() -> ResolvedEmailCredentials {
        ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret"
        )
    }

    /// Decodes the `op` field from one written line.
    private static func writtenOp(_ line: String) throws -> String {
        try JSONDecoder().decode(WrittenOp.self, from: Data(line.utf8)).op
    }

    /// Builds a session serving fakes from the spawner.
    private static func makeSession(
        credentials: ResolvedEmailCredentials? = nil,
        spawner: TestSpawner
    ) -> EmailIMAPSession {
        EmailIMAPSession(
            credentials: credentials ?? testCredentials(),
            transportFactory: {
                spawner.next()
            }
        )
    }

    /// Extracts the bridge detail from a thrown session error.
    private static func bridgeDetail(_ error: Error) -> String {
        if let sessionError = error as? EmailIMAPError, case let .bridgeFailed(detail) = sessionError {
            return detail
        }
        return error.localizedDescription
    }

    @Test
    func `Fake session writes one line and reads one line per command`() async throws {
        let openOK = #"{"ok": true}"#
        let statusOK = #"{"ok": true, "mailbox": "INBOX", "uidNext": 2001, "uidValidity": 7}"#
        let fake = FakeSessionLineTransport(responses: [openOK, statusOK])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        let status = try await session.status(mailbox: "INBOX")
        #expect(status.mailbox == "INBOX")
        #expect(status.uidNext == 2001)
        #expect(status.uidValidity == 7)
        #expect(fake.writeCount == 2)
        #expect(fake.readCount == 2)
        #expect(fake.writtenLines.count == 2)
        #expect(try Self.writtenOp(fake.writtenLines[0]) == "open")
        #expect(try Self.writtenOp(fake.writtenLines[1]) == "status")
        #expect(fake.readTimeouts.count == 2)
        #expect(fake.readTimeouts[0] == EmailIMAPSession.openTimeoutSeconds)
        #expect(fake.readTimeouts[1] == EmailIMAPSession.commandTimeoutSeconds)
        #expect(spawner.spawnCount == 1)
        await session.close()
    }

    @Test
    func `Fake session send before start fails fast without I O`() async throws {
        let fake = FakeSessionLineTransport(responses: [])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        do {
            _ = try await session.send(op: "status", payload: ["mailbox": "INBOX"])
            #expect(Bool(false), "Expected session not open")
        } catch {
            #expect(Self.bridgeDetail(error).contains("session not open"))
        }
        #expect(fake.writeCount == 0)
        #expect(fake.readCount == 0)
        #expect(spawner.spawnCount == 0)
        await session.close()
    }

    @Test
    func `Fake session hung command terminates with transport copy`() async throws {
        let fake = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        fake.setHang(true)
        do {
            _ = try await session.send(op: "status", payload: ["mailbox": "INBOX"])
            #expect(Bool(false), "Expected timeout")
        } catch {
            let detail = Self.bridgeDetail(error)
            #expect(detail.contains("IMAP session command timed out after 120s"))
            #expect(detail.contains("timed out"))
        }
        #expect(fake.writeCount == 2)
        #expect(fake.readCount == 2)
        #expect(fake.isTerminated)
        #expect(fake.terminateCount == 1)
        #expect(spawner.spawnCount == 1)
        await session.close()
        await session.close()
    }

    @Test
    func `Open budget outlasts worst-case dial plus login`() {
        // A stalled server must surface its honest error: the helper tries
        // IPv4 first with a 30s bound per attempt, so four addresses plus the
        // login need 150s before Swift may time out first.
        #expect(EmailIMAPSession.openTimeoutSeconds == 150)
        #expect(EmailIMAPSession.commandTimeoutSeconds == 120)
        #expect(EmailIMAPSession.closeTimeoutSeconds == 10)
        #expect(ProcessSessionLineTransport.maxStderrTailChars == 500)
    }

    @Test
    func `Fake timeout with empty stderr keeps base copy`() async throws {
        // Empty diagnostics must not perturb the long-standing timeout wording,
        // so existing assertions without a helper tail stay exact.
        let fake = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        fake.setHang(true)
        do {
            _ = try await session.send(op: "status", payload: ["mailbox": "INBOX"])
            #expect(Bool(false), "Expected timeout")
        } catch {
            let detail = Self.bridgeDetail(error)
            let base = SessionLineTimeout.timeoutMessage(timeout: EmailIMAPSession.commandTimeoutSeconds)
            #expect(detail == base)
        }
        await session.close()
    }

    @Test
    func `Fake timeout carries canned stderr after separator`() async throws {
        // The live drain and the fake share one timeout helper, so asserting
        // the canned tail here covers the live retention through the seam
        // without spawning a helper for a timing-sensitive stall.
        let fake = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        fake.setHang(true)
        fake.setStderr("helper dying words")
        do {
            _ = try await session.send(op: "status", payload: ["mailbox": "INBOX"])
            #expect(Bool(false), "Expected timeout")
        } catch {
            let detail = Self.bridgeDetail(error)
            let base = SessionLineTimeout.timeoutMessage(timeout: EmailIMAPSession.commandTimeoutSeconds)
            #expect(detail.hasPrefix(base))
            #expect(detail.contains(" | stderr: "))
            #expect(detail.contains("helper dying words"))
        }
        #expect(fake.isTerminated)
        await session.close()
    }

    @Test
    func `Fake timeout truncates overlong stderr at bound`() async throws {
        // An unbounded helper log must never inflate the error: only the last
        // 500 characters ride the timeout detail after the separator.
        let overlong = String(repeating: "x", count: 2000)
        let fake = FakeSessionLineTransport(
            responses: [#"{"ok": true}"#],
            stderrText: overlong
        )
        #expect(fake.stderrText == overlong)
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        fake.setHang(true)
        do {
            _ = try await session.send(op: "status", payload: ["mailbox": "INBOX"])
            #expect(Bool(false), "Expected timeout")
        } catch {
            let detail = Self.bridgeDetail(error)
            let base = SessionLineTimeout.timeoutMessage(timeout: EmailIMAPSession.commandTimeoutSeconds)
            #expect(detail.hasPrefix(base))
            #expect(detail.contains(" | stderr: "))
            let expectedTail = String(repeating: "x", count: ProcessSessionLineTransport.maxStderrTailChars)
            #expect(detail.hasSuffix(expectedTail))
            #expect(detail == base + " | stderr: " + expectedTail)
        }
        await session.close()
    }

    @Test
    func `Fake session reconnects once then throws`() async throws {
        // Single-ownership model: send() terminates and throws without an
        // internal respawn; the pooled caller owns the single retry.
        let first = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": false, "error": "IMAP search failed: box vanished"}"#
        ])
        let second = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": false, "error": "IMAP search failed: still gone"}"#
        ])
        let spawner = TestSpawner([first, second])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        do {
            _ = try await session.search(mailbox: "INBOX", query: "hello", limit: 10)
            #expect(Bool(false), "Expected terminated failure")
        } catch {
            #expect(Self.bridgeDetail(error).contains("IMAP search failed"))
        }
        #expect(spawner.spawnCount == 1)
        #expect(first.writeCount == 2)
        #expect(first.readCount == 2)
        #expect(first.isTerminated)
        #expect(first.terminateCount == 1)
        // No internal reconnect: the second spawn never runs, so its queues stay untouched.
        #expect(second.writeCount == 0)
        #expect(second.readCount == 0)
        #expect(second.writtenLines.isEmpty)
        await session.close()
    }

    @Test
    func `Fake session auth failure never respawns`() async throws {
        let fake = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": false, "error": "IMAP login failed for you@example.com: bad password"}"#
        ])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        do {
            _ = try await session.search(mailbox: "INBOX", query: "hello", limit: 10)
            #expect(Bool(false), "Expected auth failure")
        } catch {
            let detail = Self.bridgeDetail(error)
            #expect(detail.contains("login failed"))
        }
        #expect(spawner.spawnCount == 1)
        #expect(fake.writeCount == 2)
        #expect(fake.readCount == 2)
        await session.close()
        await session.close()
        #expect(fake.terminateCount == 1)
    }

    @Test
    func `Fake session close is idempotent and terminates`() async throws {
        let fake = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": true, "mailbox": "INBOX", "uidNext": 2001, "uidValidity": 7}"#,
            #"{"ok": true}"#
        ])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        _ = try await session.status(mailbox: "INBOX")
        await session.close()
        #expect(fake.writeCount == 3)
        #expect(try Self.writtenOp(fake.writtenLines[2]) == "close")
        #expect(fake.terminateCount == 1)
        await session.close()
        #expect(fake.writeCount == 3)
        #expect(fake.readCount == 3)
        #expect(fake.terminateCount == 1)
    }

    @Test
    func `Fake session close after failure still terminates without throwing`() async throws {
        let fake = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": false, "error": "IMAP fetch failed: gone"}"#
        ])
        // Single-ownership model: the failed command terminates without an
        // internal respawn, so close after failure only tears down once.
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        try await session.start()
        do {
            _ = try await session.fetch(mailbox: "INBOX", messageID: "1")
            #expect(Bool(false), "Expected fetch failure")
        } catch {
            #expect(Self.bridgeDetail(error).contains("IMAP fetch failed"))
        }
        #expect(spawner.spawnCount == 1)
        #expect(fake.writeCount == 2)
        #expect(fake.readCount == 2)
        await session.close()
        await session.close()
        #expect(fake.isTerminated)
    }

    @Test
    func `Fake session open failure keeps one-shot connect copy`() async throws {
        let fake = FakeSessionLineTransport(responses: [
            #"{"ok": false, "error": "Could not connect to you@mail.example.com:993: refused"}"#
        ])
        let spawner = TestSpawner([fake])
        let session = Self.makeSession(spawner: spawner)
        do {
            try await session.start()
            #expect(Bool(false), "Expected open failure")
        } catch {
            #expect(Self.bridgeDetail(error).contains("Could not connect"))
        }
        #expect(spawner.spawnCount == 1)
        #expect(fake.writeCount == 1)
        #expect(fake.readCount == 1)
        #expect(try Self.writtenOp(fake.writtenLines[0]) == "open")
        await session.close()
    }
}

/// Hermetic pool coverage over the mail index adapter.
///
/// Each case drives `EmailIMAPMailIndexGateway` with an in-memory one-shot
/// double plus an injectable session factory fronted by fakes, so reuse,
/// isolation, eviction, close, one-shot fallback, criterion, clamp, and
/// redaction parity assert without spawning helpers.
@Suite("Email IMAP Mail Index Session Pool")
struct MailIndexSessionPoolTests {
    /// Counts adapter factory calls while serving fakes in creation order.
    private final class PoolCountingFactory: @unchecked Sendable {
        /// Guards creation state.
        private let lock = NSLock()
        /// Fakes served one per session creation, last reused when over-requested.
        private var fakes: [FakeSessionLineTransport]
        /// Number of factory calls observed.
        private var calls = 0

        /// Creates a counter serving the given fakes in order.
        /// - Parameter fakes: One fake per expected session creation.
        init(_ fakes: [FakeSessionLineTransport]) {
            self.fakes = fakes
        }

        /// Number of factory calls so far.
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        /// Builds a session for credentials, counting the call.
        /// - Parameter credentials: Resolved fields for open plus re-open.
        /// - Returns: Session fronted by the next fake.
        func make(credentials: ResolvedEmailCredentials) -> EmailIMAPSession {
            lock.lock()
            calls += 1
            let index = calls - 1
            let fake: FakeSessionLineTransport = if index < fakes.count {
                fakes[index]
            } else {
                fakes[fakes.count - 1]
            }
            lock.unlock()
            return EmailIMAPSession(
                credentials: credentials,
                transportFactory: { fake }
            )
        }

        /// Factory closure injected into the adapter.
        var factory: MailIndexSessionFactory {
            { [self] credentials in self.make(credentials: credentials) }
        }
    }

    /// In-memory one-shot double recording queries plus limits.
    private struct PoolStubGateway: EmailIMAPGateway, Sendable {
        /// Hits returned by search, already newest-first.
        let hits: [EmailSearchHit]
        /// Full message returned by fetch.
        let full: EmailFullMessage?
        /// Status snapshot for the anchor probe.
        let statusValue: EmailMailboxStatus
        /// Queries observed in call order.
        let queriesBox: QueriesBox
        /// Limits observed in call order.
        let limitsBox: QueriesBox

        /// Creates a stub gateway.
        init(
            hits: [EmailSearchHit] = [],
            full: EmailFullMessage? = nil,
            statusValue: EmailMailboxStatus = EmailMailboxStatus(mailbox: "INBOX", uidNext: 11, uidValidity: 1),
            queriesBox: QueriesBox = QueriesBox(),
            limitsBox: QueriesBox = QueriesBox()
        ) {
            self.hits = hits
            self.full = full
            self.statusValue = statusValue
            self.queriesBox = queriesBox
            self.limitsBox = limitsBox
        }

        /// Lists one mailbox without dialing.
        func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
            EmailMailboxListing(mailboxes: ["INBOX"], delimiter: "/")
        }

        /// Returns the canned STATUS snapshot.
        func status(credentials _: ResolvedEmailCredentials, mailbox _: String) async throws -> EmailMailboxStatus {
            statusValue
        }

        /// Records the verbatim query plus limit and returns the clamped slice.
        func search(
            credentials _: ResolvedEmailCredentials,
            mailbox _: String,
            query: String,
            limit: Int
        ) async throws -> [EmailSearchHit] {
            await queriesBox.recordQuery(query)
            await limitsBox.recordLimit(limit)
            return Array(hits.prefix(limit))
        }

        /// Returns the canned full message.
        func fetch(credentials _: ResolvedEmailCredentials, mailbox _: String, messageID: String) async throws -> EmailFullMessage {
            if let full {
                return EmailFullMessage(
                    id: messageID,
                    subject: full.subject,
                    from: full.from,
                    to: full.to,
                    date: full.date,
                    body: full.body,
                    attachments: full.attachments
                )
            }
            return EmailFullMessage(
                id: messageID,
                subject: "Subject \(messageID)",
                from: "sender@example.com",
                to: "you@example.com",
                date: "Mon, 01 Sep 2025 09:00:00 +0000",
                body: "Body \(messageID)"
            )
        }

        /// Never serves attachment bytes; pool tests use attachment-free mail.
        func attachment(
            credentials _: ResolvedEmailCredentials,
            mailbox _: String,
            messageID _: String,
            attachmentIndex _: Int
        ) async throws -> EmailAttachmentData {
            throw EmailIMAPError.bridgeFailed("no attachment")
        }

        /// Append stub satisfying the contract; pool tests never append.
        func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {}
    }

    /// Lock-guarded box recording queries plus limits for parity assertions.
    private final class QueriesBox: @unchecked Sendable {
        /// Guards recorded values.
        private let lock = NSLock()
        /// Queries observed in call order.
        private var queries: [String] = []
        /// Limits observed in call order.
        private var limits: [Int] = []

        /// Creates an empty box.
        init() {}

        /// Records one query.
        func recordQuery(_ query: String) async {
            lock.withLock {
                queries.append(query)
            }
        }

        /// Records one limit.
        func recordLimit(_ limit: Int) async {
            lock.withLock {
                limits.append(limit)
            }
        }

        /// Returns the observed queries.
        var queriesSnapshot: [String] {
            lock.withLock {
                queries
            }
        }

        /// Returns the observed limits.
        var limitsSnapshot: [Int] {
            lock.withLock {
                limits
            }
        }
    }

    /// Credentials for hermetic pool opens; the password never leaves the session line.
    private static func poolCredentials(account: String = "personal") -> MailIndexCredentials {
        MailIndexCredentials(
            accountName: account,
            host: "mail.example.com",
            port: 993,
            username: "you@example.com",
            password: "test-secret"
        )
    }

    /// Decodes the query field from one written session line.
    private static func writtenQuery(_ line: String) throws -> String {
        struct QueryLine: Decodable {
            /// Free-text query carried on the line.
            let query: String?
        }
        return try JSONDecoder().decode(QueryLine.self, from: Data(line.utf8)).query ?? ""
    }

    /// Decodes the limit field from one written session line.
    private static func writtenLimit(_ line: String) throws -> Int {
        struct LimitLine: Decodable {
            /// Limit carried as a string field.
            let limit: String?
        }
        let decoded = try JSONDecoder().decode(LimitLine.self, from: Data(line.utf8))
        return Int(decoded.limit ?? "") ?? 0
    }

    @Test
    func `Pool reuses one session within a mailbox`() async throws {
        let fake = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": true, "mailbox": "INBOX", "uidNext": 11, "uidValidity": 1}"#,
            #"{"ok": true, "mailbox": "INBOX", "uidNext": 11, "uidValidity": 1}"#
        ])
        let counter = PoolCountingFactory([fake])
        let adapter = EmailIMAPMailIndexGateway(gateway: PoolStubGateway(), sessionFactory: counter.factory)
        let credentials = Self.poolCredentials()
        try await adapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        try await adapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        _ = try await adapter.mailboxStatus(credentials: credentials, mailbox: "INBOX")
        _ = try await adapter.mailboxStatus(credentials: credentials, mailbox: "INBOX")
        #expect(counter.count == 1)
        #expect(fake.writeCount == 3)
        await adapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(fake.writeCount == 4)
        #expect(fake.isTerminated)
    }

    @Test
    func `Pool isolates sessions across mailboxes plus accounts`() async throws {
        let inbox = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let archive = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let work = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let counter = PoolCountingFactory([inbox, archive, work])
        let adapter = EmailIMAPMailIndexGateway(gateway: PoolStubGateway(), sessionFactory: counter.factory)
        try await adapter.openMailboxSession(credentials: Self.poolCredentials(account: "personal"), mailbox: "INBOX")
        try await adapter.openMailboxSession(credentials: Self.poolCredentials(account: "personal"), mailbox: "Archive")
        try await adapter.openMailboxSession(credentials: Self.poolCredentials(account: "work"), mailbox: "INBOX")
        #expect(counter.count == 3)
        #expect(inbox.writeCount == 1)
        #expect(archive.writeCount == 1)
        #expect(work.writeCount == 1)
        await adapter.closeMailboxSession(credentials: Self.poolCredentials(account: "personal"), mailbox: "INBOX")
        #expect(inbox.isTerminated)
        #expect(!archive.isTerminated)
        #expect(!work.isTerminated)
        await adapter.closeMailboxSession(credentials: Self.poolCredentials(account: "personal"), mailbox: "Archive")
        await adapter.closeMailboxSession(credentials: Self.poolCredentials(account: "work"), mailbox: "INBOX")
        #expect(archive.isTerminated)
        #expect(work.isTerminated)
    }

    @Test
    func `Pool evicts on failure with fresh reopen`() async throws {
        let failing = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": true, "mailbox": "INBOX", "uidNext": 11, "uidValidity": 1}"#,
            #"{"ok": false, "error": "IMAP session connection closed"}"#
        ])
        let fresh = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            #"{"ok": true, "mailbox": "INBOX", "uidNext": 11, "uidValidity": 1}"#,
            #"{"ok": true, "messages": []}"#
        ])
        let counter = PoolCountingFactory([failing, fresh])
        let adapter = EmailIMAPMailIndexGateway(gateway: PoolStubGateway(), sessionFactory: counter.factory)
        let credentials = Self.poolCredentials()
        try await adapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        do {
            _ = try await adapter.messages(credentials: credentials, mailbox: "INBOX", limit: 10, mode: .peek, beforeUID: nil)
            #expect(Bool(false), "Expected session failure")
        } catch {
            #expect(error.localizedDescription.contains("connection closed"))
        }
        #expect(failing.isTerminated)
        #expect(counter.count == 1)
        try await adapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(counter.count == 2)
        let retried = try await adapter.messages(credentials: credentials, mailbox: "INBOX", limit: 10, mode: .peek, beforeUID: nil)
        #expect(retried.isEmpty)
        await adapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(fresh.isTerminated)
    }

    @Test
    func `Pool close evicts plus no-ops when absent`() async throws {
        let first = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let second = FakeSessionLineTransport(responses: [#"{"ok": true}"#])
        let counter = PoolCountingFactory([first, second])
        let adapter = EmailIMAPMailIndexGateway(gateway: PoolStubGateway(), sessionFactory: counter.factory)
        let credentials = Self.poolCredentials()
        await adapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(counter.count == 0)
        try await adapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(counter.count == 1)
        await adapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(first.isTerminated)
        #expect(first.terminateCount == 1)
        await adapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(first.terminateCount == 1)
        try await adapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(counter.count == 2)
        await adapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
        #expect(second.isTerminated)
    }

    @Test
    func `Pool falls back to one-shot when none open`() async throws {
        let hits = [
            EmailSearchHit(
                id: "1",
                subject: "Subject",
                from: "sender@example.com",
                date: "Mon, 01 Sep 2025 09:00:00 +0000",
                snippet: "snippet"
            )
        ]
        let full = EmailFullMessage(
            id: "1",
            subject: "Subject",
            from: "sender@example.com",
            to: "you@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: "Body 1"
        )
        let queriesBox = QueriesBox()
        let limitsBox = QueriesBox()
        let gateway = PoolStubGateway(hits: hits, full: full, queriesBox: queriesBox, limitsBox: limitsBox)
        let fake = FakeSessionLineTransport(responses: [])
        let counter = PoolCountingFactory([fake])
        let adapter = EmailIMAPMailIndexGateway(gateway: gateway, sessionFactory: counter.factory)
        let credentials = Self.poolCredentials()
        let messages = try await adapter.messages(credentials: credentials, mailbox: "INBOX", limit: 10, mode: .peek, beforeUID: 51)
        #expect(messages.count == 1)
        #expect(messages[0].id == "1")
        #expect(counter.count == 0)
        #expect(fake.writeCount == 0)
        #expect(queriesBox.queriesSnapshot == ["UID 1:50"])
        #expect(limitsBox.limitsSnapshot == [10])
    }

    @Test
    func `Pool keeps criterion clamp plus redaction parity with one-shot`() async throws {
        let credentialSubject = "Your verification code is 482913"
        let credentialBody = "Your verification code is 482913. Reset at https://example.com/reset?token=abc."
        let hit = EmailSearchHit(
            id: "7",
            subject: credentialSubject,
            from: "sender@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            snippet: "snippet"
        )
        let full = EmailFullMessage(
            id: "7",
            subject: credentialSubject,
            from: "sender@example.com",
            to: "you@example.com",
            date: "Mon, 01 Sep 2025 09:00:00 +0000",
            body: credentialBody
        )
        let oneShotQueries = QueriesBox()
        let oneShotLimits = QueriesBox()
        let oneShot = PoolStubGateway(hits: [hit], full: full, queriesBox: oneShotQueries, limitsBox: oneShotLimits)
        let oneShotAdapter = EmailIMAPMailIndexGateway(gateway: oneShot)
        let credentials = Self.poolCredentials()
        let oneShotMessages = try await oneShotAdapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 500,
            mode: .peek,
            beforeUID: 51
        )
        #expect(oneShotQueries.queriesSnapshot == ["UID 1:50"])
        #expect(oneShotLimits.limitsSnapshot == [50])
        #expect(oneShotMessages.count == 1)
        #expect(!oneShotMessages[0].body.contains("482913"))
        #expect(!oneShotMessages[0].body.contains("https://example.com/reset"))
        #expect(oneShotMessages[0].body.contains("[redacted"))

        let searchPayload = #"{"ok": true, "messages": [{"id": "7", "subject": "Your verification code is 482913", "from": "sender@example.com", "date": "Mon, 01 Sep 2025 09:00:00 +0000", "snippet": "snippet", "mailbox": "INBOX"}]}"#
        let fetchPayload = #"{"ok": true, "message": {"id": "7", "subject": "Your verification code is 482913", "from": "sender@example.com", "to": "you@example.com", "date": "Mon, 01 Sep 2025 09:00:00 +0000", "body": "Your verification code is 482913. Reset at https://example.com/reset?token=abc.", "attachments": [], "attachmentsDeferred": false}}"#
        let fake = FakeSessionLineTransport(responses: [
            #"{"ok": true}"#,
            searchPayload,
            fetchPayload
        ])
        let counter = PoolCountingFactory([fake])
        let sessionAdapter = EmailIMAPMailIndexGateway(gateway: PoolStubGateway(), sessionFactory: counter.factory)
        try await sessionAdapter.openMailboxSession(credentials: credentials, mailbox: "INBOX")
        let sessionMessages = try await sessionAdapter.messages(
            credentials: credentials,
            mailbox: "INBOX",
            limit: 500,
            mode: .peek,
            beforeUID: 51
        )
        #expect(sessionMessages == oneShotMessages)
        let searchLine = fake.writtenLines.first { (try? Self.writtenQuery($0)) == "UID 1:50" }
        #expect(searchLine != nil)
        if let searchLine {
            #expect(try Self.writtenLimit(searchLine) == 50)
        }
        await sessionAdapter.closeMailboxSession(credentials: credentials, mailbox: "INBOX")
    }

    @Test
    func `Session source handles UID windows verbatim`() throws {
        let source = EmailIMAPSessionScript.source
        #expect(source.contains(#"re.fullmatch(r"UID \d+:\d+", query)"#))
        try ToolsTestSupport.assertBridgeSourceParses(source)
    }
}
