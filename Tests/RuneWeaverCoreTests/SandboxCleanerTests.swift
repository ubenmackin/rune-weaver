// Rune Weaver Core Tests — Sandbox container reclamation.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Sandbox Cleaner")
struct SandboxCleanerTests {
    @Test
    func `Files defaults stay pinned to the web mirror`() {
        // Manual cross-language pin: Web/src/api.ts hardcodes these fallbacks because it cannot
        // import Swift. Update both sides together when the file policy changes.
        #expect(FilesConfig.defaultDenyPatterns == [
            ".env*",
            ".netrc",
            "secrets.json",
            "config.toml",
            "*.pem",
            "*.key",
            "*keychain*",
            ".ssh/*",
            ".aws/*",
            ".runeweaver/memory/*",
            ".runeweaver/memory/vectors/*",
            ".runeweaver/browser_profiles/*",
            ".runeweaver/policy.toml",
            ".runeweaver/auth_token",
            ".runeweaver/searxng/*",
            ".git-credentials",
            ".gitcookies",
            ".rclone.conf",
            ".npmrc",
            ".pypirc",
            ".Xauthority",
            ".emulator_console_auth_token",
            ".gnupg/*",
            ".kube/*",
            ".docker/*",
            ".config/gcloud/*",
            ".chia_keys/*",
            "*_history",
            ".zsh_sessions/*"
        ])
        #expect(FilesConfig.defaultAllowRoots == ["~"])
        #expect(SandboxCleanupScheduler.defaultIntervalSeconds == 3600)
    }

    @Test
    func `Cleanup leaves ordinary files untouched`() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let candidate = scratch.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: candidate)

        let summary = await SandboxCleaner.cleanup(
            config: ContainersConfig(),
            approvals: ApprovalQueue(),
            registry: StrictTurnRegistry(runtime: HermeticContainerRuntime()),
            workspaceTmp: scratch,
            now: Date()
        )

        #expect(FileManager.default.fileExists(atPath: candidate.path) == true)
        #expect(summary.containersDestroyed == 0)
        #expect(summary.scratchRemoved == 0)
    }

    @Test
    func `Audit event records the crash-orphan scope`() {
        let summary = SandboxCleanupSummary(containersDestroyed: 1, scratchRemoved: 1)
        let event = SandboxCleanupAuditEvent(summary: summary)
        #expect(event.scope == SandboxCleanupAuditEvent.tier3Scope)
        #expect(event.containersDestroyed == 1)
        #expect(event.scratchRemoved == 1)
    }
}

/// Creates an isolated scratch root for one test.
private func makeScratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-sandbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
