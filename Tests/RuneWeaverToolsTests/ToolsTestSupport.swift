// Rune Weaver Tools Tests — Shared email and memory fixtures for tool suites.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools

/// Namespace for shared email and memory test fixtures.
enum ToolsTestSupport {
    /// Search bridge stdout fixture with two hits, newest-first.
    static let searchFixture = """
    {"ok": true, "messages": [
      {"id": "42", "subject": "Quarterly report", "from": "boss@example.com", "date": "Mon, 01 Sep 2025 09:00:00 +0000", "snippet": "Please review the quarterly numbers"},
      {"id": "41", "subject": "Lunch?", "from": "friend@example.com", "date": "Sun, 31 Aug 2025 12:00:00 +0000", "snippet": "Want to grab lunch tomorrow"}
    ]}
    """

    /// Test email config with one self-hosted account.
    static func testEmailConfig() -> EmailConfig {
        EmailConfig(accounts: [
            EmailAccount(name: "personal", type: "imap", host: "mail.yourdomain.com", port: 993, username: "you@yourdomain.com")
        ])
    }

    /// Smoke-test shell policy for the tool suite.
    /// Default deny with `*` ask, `echo` allow, and `rm` deny in rule order.
    static func smokeBashConfig() -> BashConfig {
        BashConfig(
            defaultAction: .deny,
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "rm", action: .deny)
            ]
        )
    }

    /// Canned search hits parsed from the shared fixture, newest-first.
    static func sharedSearchHits() throws -> [EmailSearchHit] {
        try EmailBridgeParsing.parseSearchPayload(Data(searchFixture.utf8))
    }

    /// Failure thrown when the assembled bridge source fails Python parsing.
    struct BridgeParseError: Error, LocalizedError, Sendable {
        /// Human-readable parse failure including stderr.
        let message: String

        /// Returns `message` for test failure display.
        var errorDescription: String? {
            message
        }
    }

    /// Asserts the assembled bridge source parses as Python without executing it.
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
    final class QueryCapture: Sendable {
        /// Guard for the captured query.
        private let stored = OSAllocatedUnfairLock<String?>(initialState: nil)

        /// Records the query.
        /// - Parameter value: Normalized query from the tool.
        func set(_ value: String) {
            stored.withLock { $0 = value }
        }

        /// Returns the last recorded query.
        var value: String? {
            stored.withLock { $0 }
        }
    }

    /// Locked box capturing memory audit events across concurrency domains.
    final class AuditCapture: Sendable {
        /// Guarded events.
        private let events = OSAllocatedUnfairLock<[MemoryAuditEvent]>(initialState: [])

        /// Records an event.
        /// - Parameter event: Audit event to keep.
        func record(_ event: MemoryAuditEvent) {
            events.withLock { $0.append(event) }
        }

        /// Returns captured events.
        /// - Returns: Events in capture order.
        func captured() -> [MemoryAuditEvent] {
            events.withLock { $0 }
        }
    }

    /// Stub gateway returning canned results without touching the network.
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
        /// Selectable mailboxes reported by the listing (nil means `["INBOX"]`).
        let listedMailboxes: [String]?
        /// Per-mailbox hits for fan-out (nil means every folder returns `hits`).
        let hitsByMailbox: [String: [EmailSearchHit]]?
        /// Box receiving the mailbox passed to per-mailbox `search`, when set.
        let mailboxCapture: QueryCapture?
        /// Hierarchy separator reported for every mailbox in `mailboxListing` (nil means `"/"`).
        let delimiter: String?
        /// Box receiving the destination mailbox passed to `move`, when set.
        let moveCapture: QueryCapture?

        /// Creates a stub gateway.
        init(
            hits: [EmailSearchHit] = [],
            message: EmailFullMessage? = nil,
            attachment: EmailAttachmentData? = nil,
            failure: String? = nil,
            capture: QueryCapture? = nil,
            listedMailboxes: [String]? = nil,
            hitsByMailbox: [String: [EmailSearchHit]]? = nil,
            mailboxCapture: QueryCapture? = nil,
            delimiter: String? = nil,
            moveCapture: QueryCapture? = nil
        ) {
            self.hits = hits
            self.message = message
            self.attachment = attachment
            self.failure = failure
            self.capture = capture
            self.listedMailboxes = listedMailboxes
            self.hitsByMailbox = hitsByMailbox
            self.mailboxCapture = mailboxCapture
            self.delimiter = delimiter
            self.moveCapture = moveCapture
        }

        /// Stub append (no-op unless failure set).
        func append(credentials _: ResolvedEmailCredentials, mailbox _: String, rawMessage _: Data) async throws {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
        }

        /// Returns canned mailboxes with hierarchy separators for list-envelope assertions.
        /// - Parameter credentials: Ignored resolved credentials.
        /// - Returns: Canned folders in server order with the stub delimiter.
        func mailboxListing(credentials _: ResolvedEmailCredentials) async throws -> EmailMailboxListing {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            let boxes = listedMailboxes ?? ["INBOX"]
            let separator = delimiter ?? "/"
            return EmailMailboxListing(mailboxes: boxes, delimiter: separator)
        }

        /// Canned move honoring failure and capturing routing for assertions.
        /// - Parameters:
        ///   - credentials: Ignored resolved credentials.
        ///   - mailbox: Source folder.
        ///   - messageID: Message being relocated.
        ///   - destination: Target folder.
        ///   - markAsRead: Whether `\Seen` is set on the resulting message.
        /// - Returns: Move result reporting relocation and read flag.
        func move(
            credentials _: ResolvedEmailCredentials,
            mailbox sourceMailbox: String,
            messageID _: String,
            destination: String,
            markAsRead: Bool
        ) async throws -> EmailMoveResult {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            mailboxCapture?.set(sourceMailbox)
            moveCapture?.set(destination)
            // Same-folder moves are no-ops by contract, so report them without pretending to copy.
            if sourceMailbox.lowercased() == destination.lowercased() {
                return EmailMoveResult(
                    mailbox: sourceMailbox,
                    destination: destination,
                    moved: false,
                    markedAsRead: markAsRead
                )
            }
            return EmailMoveResult(
                mailbox: sourceMailbox,
                destination: destination,
                moved: true,
                markedAsRead: markAsRead
            )
        }

        /// Shim for old callers delegating to the richer listing so search/read paths stay covered.
        /// - Parameter credentials: Ignored resolved credentials.
        /// - Returns: Canned folders in server order.
        func listMailboxes(credentials: ResolvedEmailCredentials) async throws -> [String] {
            try await mailboxListing(credentials: credentials).mailboxes
        }

        /// Returns canned per-mailbox hits labeled with the folder.
        func search(credentials _: ResolvedEmailCredentials, mailbox: String, query: String, limit: Int) async throws -> [EmailSearchHit] {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            capture?.set(query)
            mailboxCapture?.set(mailbox)
            if let hitsByMailbox, let canned = hitsByMailbox[mailbox] {
                return Array(canned.prefix(limit)).map {
                    EmailSearchHit(
                        id: $0.id,
                        subject: $0.subject,
                        from: $0.from,
                        date: $0.date,
                        snippet: $0.snippet,
                        mailbox: mailbox,
                        hasAttachments: $0.hasAttachments,
                        attachmentCount: $0.attachmentCount
                    )
                }
            }
            if hitsByMailbox != nil {
                return []
            }
            return Array(hits.prefix(limit)).map {
                EmailSearchHit(
                    id: $0.id,
                    subject: $0.subject,
                    from: $0.from,
                    date: $0.date,
                    snippet: $0.snippet,
                    mailbox: mailbox,
                    hasAttachments: $0.hasAttachments,
                    attachmentCount: $0.attachmentCount
                )
            }
        }

        /// Returns canned per-mailbox hits honoring the attachment filter.
        func search(
            credentials _: ResolvedEmailCredentials,
            mailbox: String,
            query: String,
            limit: Int,
            hasAttachment: Bool?
        ) async throws -> [EmailSearchHit] {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            capture?.set(query)
            mailboxCapture?.set(mailbox)
            let unfiltered: [EmailSearchHit] = if let hitsByMailbox, let canned = hitsByMailbox[mailbox] {
                canned.map {
                    EmailSearchHit(
                        id: $0.id,
                        subject: $0.subject,
                        from: $0.from,
                        date: $0.date,
                        snippet: $0.snippet,
                        mailbox: mailbox,
                        hasAttachments: $0.hasAttachments,
                        attachmentCount: $0.attachmentCount
                    )
                }
            } else if hitsByMailbox != nil {
                []
            } else {
                hits.map {
                    EmailSearchHit(
                        id: $0.id,
                        subject: $0.subject,
                        from: $0.from,
                        date: $0.date,
                        snippet: $0.snippet,
                        mailbox: mailbox,
                        hasAttachments: $0.hasAttachments,
                        attachmentCount: $0.attachmentCount
                    )
                }
            }
            // Apply the filter locally so filtered callers exercise the same contract as the live bridge.
            let filtered = unfiltered.filter { $0.matches(hasAttachment: hasAttachment) }
            return Array(filtered.prefix(limit))
        }

        /// Returns the canned message for one mailbox.
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

        /// Returns a canned batch of messages for one mailbox.
        func batchFetch(
            credentials _: ResolvedEmailCredentials,
            mailbox: String,
            query: String,
            limit _: Int
        ) async throws -> [EmailFullMessage] {
            if let failure {
                throw EmailIMAPError.bridgeFailed(failure)
            }
            capture?.set(query)
            mailboxCapture?.set(mailbox)
            if let message {
                return [message]
            }
            return []
        }

        /// Returns canned attachment bytes for one mailbox.
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
    static func withTestCredential(envVar: String, value: String, _ body: @Sendable () async throws -> Void) async rethrows {
        try await testCredentialGate.run(envVar: envVar, value: value, body)
    }

    /// Sets the stub account password in the environment for credential resolution.
    static func withTestPassword(_ body: @Sendable () async throws -> Void) async rethrows {
        try await withTestCredential(envVar: "EMAIL_PERSONAL_PASSWORD", value: "test-secret", body)
    }

    /// Sets the iCloud account password in the environment for credential resolution.
    static func withICloudTestPassword(_ body: @Sendable () async throws -> Void) async rethrows {
        try await withTestCredential(envVar: "EMAIL_ICLOUD_PASSWORD", value: "test-icloud-secret", body)
    }
}
