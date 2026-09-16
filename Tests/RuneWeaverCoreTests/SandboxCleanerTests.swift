// Rune Weaver Core Tests — Tier-3 crash-orphan reclamation.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Sandbox Cleaner")
struct SandboxCleanerTests {
    @Test
    func `Swift defaults stay pinned to the web mirror`() {
        // Manual cross-language pin: Web/src/api.ts hardcodes these fallbacks because it cannot
        // import Swift. Update both sides together when the detonation policy changes.
        #expect(SandboxConfig.defaultArchiveSessionTTLMinutes == 10)
        #expect(SandboxConfig.defaultMaxConcurrentMachines == 3)
        #expect(SandboxConfig.defaultContainerRuntime == "container")
        #expect(SandboxConfig.defaultContainerBaseImage == "alpine:latest")
        #expect(SandboxCleanupScheduler.defaultIntervalSeconds == 3600)
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
            ".runeweaver/memory/vectors/*"
        ])
        #expect(FilesConfig.defaultAllowRoots == ["~"])
    }

    @Test
    func `Cleanup leaves ordinary files untouched`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let candidate = scratch.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: candidate)

        let config = SandboxConfig()
        let summary = SandboxCleaner.cleanup(config: config, now: Date())

        #expect(FileManager.default.fileExists(atPath: candidate.path) == true)
    }

    @Test
    func `Missing runtime is a clean no-op`() {
        #expect(ContainerMachineManager.isRuntimeAvailable(runtime: "runeweaver-missing-runtime-\(UUID().uuidString)") == false)
        let config = SandboxConfig()
        #expect(config.containerRuntime == SandboxConfig.defaultContainerRuntime)
        let summary = SandboxCleaner.cleanup(config: config)

        if ContainerMachineManager.isRuntimeAvailable(runtime: config.containerRuntime) == false {
            #expect(summary.containersDestroyed == 0)
            #expect(summary.staleMachinesStopped == 0)
            #expect(summary.errors.isEmpty == true)
        }
    }

    @Test
    func `Audit event records the Tier-3 scope`() {
        let summary = SandboxCleanupSummary(containersDestroyed: 1, staleMachinesStopped: 1)
        let event = SandboxCleanupAuditEvent(summary: summary)
        #expect(event.scope == SandboxCleanupAuditEvent.tier3Scope)
        #expect(event.containersDestroyed == 1)
        #expect(event.staleMachinesStopped == 1)
    }
}

/// Creates an isolated scratch root for one test.
private func makeScratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-sandbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
