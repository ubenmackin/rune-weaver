// Rune Weaver Tools Tests — Shared file access guard credential deny coverage.
//
// Exercises the `[files]` deny boundary that both the file tools and the
// background files indexer enforce: newly added credential and shell-history
// patterns refuse representative paths through the shared guard, an ordinary
// Markdown document still passes, a denied credential refuses a `files.read`
// without leaking bytes, and an index walk over the same policy skips the
// credential without handing its bytes to the extractor.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Isolated filesystem helpers for the guard suites.
private enum GuardTestSupport {
    /// Creates a fresh temp base with an isolated fake home.
    /// - Returns: Base directory plus the fake home boundary.
    static func makeBaseAndHome() throws -> (base: URL, home: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = base.resolvingSymlinksInPath().standardizedFileURL
        let home = canonical.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (canonical, home)
    }

    /// Removes a temp base best-effort.
    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    /// Writes UTF-8 text, creating parents.
    static func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// Extractor that records every file name it is asked to extract.
///
/// The indexer consults the access guard before opening a candidate, so a
/// denied credential must never reach this seam; the recorded names prove the
/// skip happened before any read rather than after a failed parse.
private final class GuardRecordingExtractor: DocumentTextExtracting, Sendable {
    /// Guarded file names in extraction order.
    private let seen = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// File names handed to the extractor so far.
    var seenNames: [String] {
        seen.withLock { $0 }
    }

    /// Records the file name and extracts a single trivial chunk.
    func extract(data: Data, fileName: String, contentType _: String?) -> DocumentExtraction {
        seen.withLock { $0.append(fileName) }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.isEmpty else {
            return DocumentExtraction(
                status: .metadataOnly,
                format: .plainText,
                chunks: [],
                reason: "empty",
                byteCount: data.count,
                truncated: false
            )
        }
        return DocumentExtraction(
            status: .extracted,
            format: .plainText,
            chunks: [DocumentChunk(index: 0, text: text, estimatedTokens: 1)],
            reason: nil,
            byteCount: data.count,
            truncated: false
        )
    }
}

@Suite("Files Access Guard Credentials")
struct FilesAccessGuardTests {
    @Test
    func `Credential and history patterns deny sensitive paths but allow ordinary documents`() throws {
        let (base, home) = try GuardTestSupport.makeBaseAndHome()
        defer { GuardTestSupport.cleanup(base) }
        // One representative path per newly denied pattern; directory shapes
        // use a nested file so the trailing-`/*` handling is exercised, and
        // the history shape covers the wildcard that spans shell variants.
        let sensitive = [
            ".git-credentials",
            ".gitcookies",
            ".rclone.conf",
            ".npmrc",
            ".pypirc",
            ".Xauthority",
            ".emulator_console_auth_token",
            ".gnupg/secring.gpg",
            ".kube/config",
            ".docker/config.json",
            ".config/gcloud/credentials.db",
            ".chia_keys/mnemonic.txt",
            ".zsh_history",
            ".bash_history",
            ".zsh_sessions/session-file"
        ]
        for relative in sensitive {
            let candidate = home.appendingPathComponent(relative).path
            let decision = FilesAccessGuard.evaluate(path: candidate, homeDirectoryURL: home)
            #expect(decision.allowed == false, "Expected deny for \(relative)")
            #expect(decision.requiresApproval == true, "Expected approval hint for \(relative)")
            #expect((decision.reason ?? "").isEmpty == false, "Expected reason for \(relative)")
        }
        // An ordinary document under the same home boundary still passes, so
        // the widened deny list does not swallow everyday reads.
        let benign = home.appendingPathComponent("notes.md").path
        let allowed = FilesAccessGuard.evaluate(path: benign, homeDirectoryURL: home)
        #expect(allowed.allowed == true)
        #expect(allowed.requiresApproval == false)
    }

    @Test
    func `Denied credential refuses a files read without leaking bytes`() async throws {
        let (base, home) = try GuardTestSupport.makeBaseAndHome()
        defer { GuardTestSupport.cleanup(base) }
        let credential = home.appendingPathComponent(".git-credentials")
        try GuardTestSupport.write("https://owner:super-secret-token@example.com", at: credential)
        let tool = FilesReadTool(homeDirectoryURL: home)
        let denied = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"\#(credential.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(denied.isError == true)
        #expect(!denied.content.contains("super-secret-token"))
        #expect(denied.content.contains("approvalRequired"))

        // The same tool still reads an ordinary document, proving the refusal
        // comes from the deny list rather than a broken read path.
        let document = home.appendingPathComponent("notes.md")
        try GuardTestSupport.write("# Notes\nhello", at: document)
        let allowed = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"\#(document.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(allowed.isError == false)
        #expect(allowed.content.contains("hello"))
    }

    @Test
    func `Index walk skips a denied credential without reading it`() async throws {
        let (base, home) = try GuardTestSupport.makeBaseAndHome()
        defer { GuardTestSupport.cleanup(base) }
        let credential = home.appendingPathComponent(".gnupg/secring.gpg")
        try GuardTestSupport.write("credential bytes that must never index", at: credential)
        let document = home.appendingPathComponent("notes.md")
        try GuardTestSupport.write("# Notes\npublic body", at: document)

        // The document store lives outside the walked home so its own
        // database file can never become an index candidate.
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-guard-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let canonicalStore = storeDirectory.resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: canonicalStore) }
        let store = DocIndexStore(dbPath: canonicalStore.appendingPathComponent("docindex.db").path)

        // The walk enforces the same default `[files]` policy as the file
        // tools through the shared adapter, so a guard refusal here is the
        // same refusal `files.read` reports above.
        let guardAdapter = FilesIndexPolicyGuard(filesConfig: FilesConfig())
        let denied = guardAdapter.evaluate(path: credential.path, homeDirectoryURL: home)
        #expect(denied.allowed == false)

        let extractor = GuardRecordingExtractor()
        let indexer = FilesIndexer(
            store: store,
            extractor: extractor,
            accessGuard: guardAdapter,
            config: IndexConfig(enabled: true, files: true, roots: [home.path]),
            homeDirectoryURL: home
        )
        let report = await indexer.run()

        #expect(report.filesIndexed == 1)
        #expect(report.filesSkipped >= 1)
        #expect(!extractor.seenNames.contains("secring.gpg"))
        #expect(extractor.seenNames.contains("notes.md"))
        let storedDocument = try await store.document(source: .files, externalID: document.path)
        #expect(storedDocument != nil)
        let storedCredential = try await store.document(source: .files, externalID: credential.path)
        #expect(storedCredential == nil)
    }

    @Test
    func `Index adapter ignores allow roots while live guard enforces them`() throws {
        let (base, home) = try GuardTestSupport.makeBaseAndHome()
        defer { GuardTestSupport.cleanup(base) }
        // Narrow the live `[files]` roots to one subdirectory so an ordinary
        // sibling stays outside containment; the index walk is driven by index
        // roots instead, so the adapter must ignore this boundary.
        let allowedRoot = home.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        let restrictive = FilesConfig(allowRoots: [allowedRoot.path])
        let adapter = FilesIndexPolicyGuard(filesConfig: restrictive)

        // A benign candidate outside allow roots stays indexable but refuses
        // live access, pinning the deny-only versus containment split.
        let outside = home.appendingPathComponent("notes.md").path
        let liveOutside = FilesAccessGuard.evaluate(
            path: outside,
            homeDirectoryURL: home,
            filesConfig: restrictive
        )
        #expect(liveOutside.allowed == false)
        let indexOutside = adapter.evaluate(path: outside, homeDirectoryURL: home)
        #expect(indexOutside.allowed == true)
        #expect(indexOutside.requiresApproval == false)

        // A deny match stays skipped on both seams, proving the adapter still
        // honors deny patterns even while it ignores allow roots.
        let deniedInside = allowedRoot.appendingPathComponent(".git-credentials").path
        let liveDenied = FilesAccessGuard.evaluate(
            path: deniedInside,
            homeDirectoryURL: home,
            filesConfig: restrictive
        )
        #expect(liveDenied.allowed == false)
        let indexDenied = adapter.evaluate(path: deniedInside, homeDirectoryURL: home)
        #expect(indexDenied.allowed == false)

        // The same deny shape outside allow roots also stays skipped on both
        // seams, so a sensitive name cannot slip through by leaving the roots.
        let deniedOutside = home.appendingPathComponent(".git-credentials").path
        let liveDeniedOutside = FilesAccessGuard.evaluate(
            path: deniedOutside,
            homeDirectoryURL: home,
            filesConfig: restrictive
        )
        #expect(liveDeniedOutside.allowed == false)
        let indexDeniedOutside = adapter.evaluate(path: deniedOutside, homeDirectoryURL: home)
        #expect(indexDeniedOutside.allowed == false)
    }
}
