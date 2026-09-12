// RuneWeaver - Tests - Shared email/memory fixtures
import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools

/// Namespace for shared email and memory test fixtures.
///
/// All helpers live under `ToolsTestSupport` so the `RuneWeaverToolsTests`
/// target namespace stays clean and future globals (for example a new
/// `searchFixture`) cannot collide with these shared fixtures.
enum ToolsTestSupport {
    /// Search bridge stdout fixture with two hits, newest-first.
    ///
    /// Shared by email unit tests and the smoke harness so both parse the
    /// same canned payload instead of hardcoding duplicate hits.
    static let searchFixture = """
    {"ok": true, "messages": [
      {"id": "42", "subject": "Quarterly report", "from": "boss@example.com", "date": "Mon, 01 Sep 2025 09:00:00 +0000", "snippet": "Please review the quarterly numbers"},
      {"id": "41", "subject": "Lunch?", "from": "friend@example.com", "date": "Sun, 31 Aug 2025 12:00:00 +0000", "snippet": "Want to grab lunch tomorrow"}
    ]}
    """

    /// Test email config with one self-hosted account.
    ///
    /// Single `personal` account over `mail.yourdomain.com:993` shared by
    /// schema, email, and smoke suites.
    /// - Returns: Config with a single `personal` account.
    static func testEmailConfig() -> EmailConfig {
        EmailConfig(accounts: [
            EmailAccount(name: "personal", type: "imap", host: "mail.yourdomain.com", port: 993, username: "you@yourdomain.com")
        ])
    }

    /// Canned search hits parsed from the shared fixture, newest-first.
    ///
    /// Parses `searchFixture` through the production bridge parser so the
    /// smoke harness observes the same decoding path as the unit suite.
    /// - Returns: Quarterly report followed by a lunch note.
    /// - Throws: When the shared fixture fails to decode.
    static func sharedSearchHits() throws -> [EmailSearchHit] {
        try EmailBridgeParsing.parseSearchPayload(Data(searchFixture.utf8))
    }

    /// Failure thrown when the assembled bridge source fails Python parsing.
    ///
    /// Carries the parser child's stderr (or a timeout notice) so the
    /// failing test reports the syntax detail without re-reading pipes.
    struct BridgeParseError: Error, LocalizedError, Sendable {
        /// Human-readable parse failure including stderr.
        let message: String

        /// Returns `message` for test failure display.
        var errorDescription: String? {
            message
        }
    }

    /// Asserts the assembled bridge source parses as Python without executing it.
    ///
    /// Runs `python3 -c "import ast, sys; ast.parse(sys.stdin.read())"` with
    /// `source` on stdin so syntax regressions fail fast without importing
    /// or executing the bridge. The stdin handle is closed with `try` (not
    /// `try?`) so a close failure propagates instead of leaving the child
    /// blocked on EOF, and the child is terminated when it outlives
    /// `timeoutSeconds` so a stuck parser cannot hang the suite.
    /// - Parameters:
    ///   - source: Assembled bridge source to parse.
    ///   - timeoutSeconds: Maximum seconds to wait for the parser child.
    /// - Throws: When the child cannot run, times out, or reports a syntax error with stderr.
    static func assertBridgeSourceParses(_ source: String, timeoutSeconds: TimeInterval = 10) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw BridgeParseError(message: "Bridge source Python parse timed out after \(timeoutSeconds)s")
        }
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let detail = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeParseError(message: "Bridge source failed Python parse: \(detail)")
        }
    }

    /// Builds an isolated memory engine on a fresh temporary directory.
    ///
    /// Single shared builder for tool suites so temporary-directory layout and
    /// engine paths never drift between suites. Each caller gets its own
    /// episodes database, vector directory, and profile file so fixture writes
    /// never leak between tests.
    /// - Returns: Engine plus the base directory owning its files.
    /// - Throws: When the directory cannot be created.
    static func makeIsolatedMemoryEngine() throws -> (engine: MemoryEngine, base: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("runeweaver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let engine = MemoryEngine(
            episodesDBPath: base.appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        return (engine, base)
    }

    /// Removes a temporary engine directory best-effort.
    /// - Parameter base: Directory created by `makeIsolatedMemoryEngine()`.
    static func cleanupIsolatedEngineBase(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    /// Box capturing the normalized query seen by the gateway without touching the network.
    final class QueryCapture: @unchecked Sendable {
        /// Guard for the captured query.
        private let lock = NSLock()
        /// Last query passed to `search`, if any.
        private var stored: String?

        /// Records the query.
        /// - Parameter value: Normalized query from the tool.
        func set(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            stored = value
        }

        /// Returns the last recorded query.
        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Locked box capturing memory audit events across concurrency domains.
    final class AuditCapture: @unchecked Sendable {
        /// Guarded events.
        private var events: [MemoryAuditEvent] = []
        /// Guards `events`.
        private let lock = NSLock()

        /// Records an event.
        /// - Parameter event: Audit event to keep.
        func record(_ event: MemoryAuditEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        /// Returns captured events.
        /// - Returns: Events in capture order.
        func captured() -> [MemoryAuditEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    /// Stub gateway returning canned results without touching the network.
    ///
    /// Search returns the canned hits newest-first capped by `limit` while
    /// recording the normalized query into the optional capture box so
    /// wildcard mapping stays observable. Fetch and attachment return
    /// canned payloads or a bridge failure. Mailbox fan-out is stubbed via
    /// `listedMailboxes` plus `hitsByMailbox`: `listMailboxes` reports the
    /// canned folders and per-mailbox `search` returns that folder's hits
    /// labeled with the folder, so fan-out merge stays observable without
    /// a live server.
    struct StubEmailGateway: EmailIMAPGateway, Sendable {
        /// Hits returned by `search`, already newest-first.
        let hits: [EmailSearchHit]
        /// Message returned by `fetch`.
        let message: EmailFullMessage?
        /// Bytes returned by `attachment`.
        let attachment: EmailAttachmentData?
        /// Error thrown instead of returning, when set.
        let failure: String?
        /// Box receiving the normalized query passed to `search`.
        let capture: QueryCapture?
        /// Selectable mailboxes reported by `listMailboxes` (nil means `["INBOX"]`).
        let listedMailboxes: [String]?
        /// Per-mailbox hits for fan-out (nil means every folder returns `hits`).
        let hitsByMailbox: [String: [EmailSearchHit]]?
        /// Box receiving the mailbox passed to per-mailbox `search`, when set.
        let mailboxCapture: QueryCapture?

        /// Creates a stub gateway.
        /// - Parameters:
        ///   - hits: Canned search hits, newest-first.
        ///   - message: Canned fetch message.
        ///   - attachment: Canned attachment bytes.
        ///   - failure: Bridge failure to throw, when set.
        ///   - capture: Query capture box.
        ///   - listedMailboxes: Selectable mailboxes for `listMailboxes`.
        ///   - hitsByMailbox: Per-mailbox hits for fan-out.
        ///   - mailboxCapture: Mailbox capture box.
        init(
            hits: [EmailSearchHit] = [],
            message: EmailFullMessage? = nil,
            attachment: EmailAttachmentData? = nil,
            failure: String? = nil,
            capture: QueryCapture? = nil,
            listedMailboxes: [String]? = nil,
            hitsByMailbox: [String: [EmailSearchHit]]? = nil,
            mailboxCapture: QueryCapture? = nil
        ) {
            self.hits = hits
            self.message = message
            self.attachment = attachment
            self.failure = failure
            self.capture = capture
            self.listedMailboxes = listedMailboxes
            self.hitsByMailbox = hitsByMailbox
            self.mailboxCapture = mailboxCapture
        }

        /// Returns canned hits capped by `limit`.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - query: Normalized query recorded into the capture box.
        ///   - limit: Maximum hits to return.
        /// - Returns: Canned hits newest-first.
        func search(credentials _: ResolvedEmailCredentials, query: String, limit: Int) async throws -> [EmailSearchHit] {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            capture?.set(query)
            return Array(hits.prefix(limit))
        }

        /// Returns the canned message.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - messageID: Requested message identifier.
        /// - Returns: Canned message.
        func fetch(credentials _: ResolvedEmailCredentials, messageID: String) async throws -> EmailFullMessage {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            guard let message else {
                throw EmailIMAPError.bridgeFailed("Message \(messageID) not found")
            }
            return message
        }

        /// Returns canned attachment bytes.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - messageID: Requested message identifier.
        ///   - attachmentIndex: Requested part position.
        /// - Returns: Canned attachment bytes.
        func attachment(
            credentials _: ResolvedEmailCredentials,
            messageID: String,
            attachmentIndex: Int
        ) async throws -> EmailAttachmentData {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            guard let attachment else {
                throw EmailIMAPError.bridgeFailed("Attachment \(attachmentIndex) for message \(messageID) not found")
            }
            return attachment
        }

        /// Returns canned selectable mailboxes.
        /// - Parameter credentials: Ignored resolved credentials.
        /// - Returns: Canned folders in server order.
        func listMailboxes(credentials _: ResolvedEmailCredentials) async throws -> [String] {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            return listedMailboxes ?? ["INBOX"]
        }

        /// Returns canned per-mailbox hits labeled with the folder.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - mailbox: Requested mailbox recorded into the mailbox capture box.
        ///   - query: Normalized query recorded into the capture box.
        ///   - limit: Maximum hits to return.
        /// - Returns: That folder's hits newest-first labeled with `mailbox`.
        func search(credentials _: ResolvedEmailCredentials, mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit] {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            capture?.set(query)
            mailboxCapture?.set(mailbox)
            if let hitsByMailbox, let canned = hitsByMailbox[mailbox] {
                return Array(canned.prefix(limit)).map {
                    EmailSearchHit(id: $0.id, subject: $0.subject, from: $0.from, date: $0.date, snippet: $0.snippet, mailbox: mailbox)
                }
            }
            if hitsByMailbox != nil {
                return []
            }
            return Array(hits.prefix(limit)).map {
                EmailSearchHit(id: $0.id, subject: $0.subject, from: $0.from, date: $0.date, snippet: $0.snippet, mailbox: mailbox)
            }
        }

        /// Returns the canned message for one mailbox.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - mailbox: Requested mailbox recorded into the mailbox capture box.
        ///   - messageID: Requested message identifier.
        /// - Returns: Canned message.
        func fetch(credentials _: ResolvedEmailCredentials, mailbox: String, messageID: String) async throws -> EmailFullMessage {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            mailboxCapture?.set(mailbox)
            guard let message else {
                throw EmailIMAPError.bridgeFailed("Message \(messageID) not found")
            }
            return message
        }

        /// Returns canned attachment bytes for one mailbox.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - mailbox: Requested mailbox recorded into the mailbox capture box.
        ///   - messageID: Requested message identifier.
        ///   - attachmentIndex: Requested part position.
        /// - Returns: Canned attachment bytes.
        func attachment(
            credentials _: ResolvedEmailCredentials,
            mailbox: String,
            messageID: String,
            attachmentIndex: Int
        ) async throws -> EmailAttachmentData {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            mailboxCapture?.set(mailbox)
            guard let attachment else {
                throw EmailIMAPError.bridgeFailed("Attachment \(attachmentIndex) for message \(messageID) not found")
            }
            return attachment
        }
    }

    /// Process-wide gate serializing test credential environment mutation.
    ///
    /// `Smoke Harness` and `Email Tools` both install stub passwords via
    /// `setenv`, which is process-global and POSIX-unsafe under concurrency.
    /// `.serialized` only serializes within one suite, not across suites, so
    /// parallel `swift test` execution would otherwise race: one suite's
    /// restore could clear the other's credential mid-`execute`, falling
    /// through to Keychain (non-hermetic) or flaky auth failure. All scoped
    /// credential helpers below run through this gate for the whole body and
    /// restore the prior value afterwards, providing cross-suite exclusion.
    ///
    /// `NSLock` cannot be held across `await` (unavailable from asynchronous
    /// contexts), so exclusion uses this actor-guarded FIFO gate instead: the
    /// `locked` flag stays set while `body` runs, even across suspensions,
    /// with waiters queued via continuations for async-safe scoped locking.
    private actor TestCredentialEnvGate {
        /// Whether a scoped body currently holds the gate.
        private var locked = false
        /// FIFO waiters queued while the gate is held.
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Acquires the gate, suspending until the current holder releases it.
        private func acquire() async {
            if !locked {
                locked = true
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        /// Releases the gate, resuming the next waiter when present.
        private func release() {
            if waiters.isEmpty {
                locked = false
            } else {
                let next = waiters.removeFirst()
                next.resume()
            }
        }

        /// Runs `body` with the stub credential installed.
        /// - Parameters:
        ///   - envVar: Environment variable to install.
        ///   - value: Stub value to install.
        ///   - body: Work requiring the stub credential.
        func run(envVar: String, value: String, _ body: @Sendable () async throws -> Void) async rethrows {
            await acquire()
            defer { release() }
            let saved: String? = envVar.withCString { keyPtr in
                getenv(keyPtr).map { String(cString: $0) }
            }
            setenv(envVar, value, 1)
            defer {
                if let saved {
                    setenv(envVar, saved, 1)
                } else {
                    unsetenv(envVar)
                }
            }
            try await body()
        }
    }

    /// Shared gate serializing test credential environment mutation.
    private static let testCredentialGate = TestCredentialEnvGate()

    /// Installs a stub credential in the environment for the duration of `body`.
    ///
    /// Saves the prior value with `getenv` and restores it afterwards (instead
    /// of blind `unsetenv`) so a pre-existing ambient value is never lost, and
    /// holds `testCredentialGate` across the whole body for cross-suite
    /// exclusion.
    /// - Parameters:
    ///   - envVar: Environment variable to install.
    ///   - value: Stub value to install.
    ///   - body: Work requiring the stub credential.
    /// - Returns: Body result.
    static func withTestCredential(envVar: String, value: String, _ body: @Sendable () async throws -> Void) async rethrows {
        try await testCredentialGate.run(envVar: envVar, value: value, body)
    }

    /// Sets the stub account password in the environment for credential resolution.
    ///
    /// Environment-first credential resolution then never reaches the
    /// Keychain, keeping suites hermetic. The password is installed with
    /// `setenv` for the duration of `body` under `testCredentialGate` with
    /// the prior value restored afterwards for cross-suite safety.
    /// - Parameter body: Work requiring the stub credential.
    /// - Returns: Body result.
    static func withTestPassword(_ body: @Sendable () async throws -> Void) async rethrows {
        try await withTestCredential(envVar: "EMAIL_PERSONAL_PASSWORD", value: "test-secret", body)
    }

    /// Sets the iCloud account password in the environment for credential resolution.
    ///
    /// Same cross-suite contract as `withTestPassword` but for the iCloud
    /// account variable, sharing `testCredentialGate` so personal and
    /// iCloud credential scopes never interleave.
    /// - Parameter body: Work requiring the stub credential.
    /// - Returns: Body result.
    static func withICloudTestPassword(_ body: @Sendable () async throws -> Void) async rethrows {
        try await withTestCredential(envVar: "EMAIL_ICLOUD_PASSWORD", value: "test-icloud-secret", body)
    }
}
