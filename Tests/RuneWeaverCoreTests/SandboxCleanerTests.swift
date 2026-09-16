// Rune Weaver Core Tests — Tier-3 crash-orphan reclamation.
//
// Verifies the Tier-1/Tier-2 Seatbelt plus Tier-3 microVM model with no host
// sandbox folder: cleanup reclaims only crash-orphaned detonation machines,
// leaves ordinary files untouched, and reports zero file counts. Scoped to
// the prune contract, not service wiring.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Sandbox Cleaner")
struct SandboxCleanerTests {
    @Test
    func `Swift defaults stay pinned to the web mirror`() {
        // Manual cross-language pin: Web/src/api.ts hardcodes these fallbacks
        // because it cannot import Swift. Update both sides together when the
        // detonation policy changes. The sweep cadence lives on the scheduler
        // so crash-orphan pressure stays bounded without another tuning knob.
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
    func `Cleanup leaves ordinary files untouched with zero file counts`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let candidate = scratch.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: candidate)

        // The detonation runtime is hardcoded to the Apple Container CLI, so
        // the prune runs against the shared default; the point under test is
        // that file state is never swept even when Tier-3 reclamation runs.
        let config = SandboxConfig()
        let summary = SandboxCleaner.cleanup(config: config, now: Date())

        #expect(summary.filesRemoved == 0)
        #expect(summary.bytesFreed == 0)
        #expect(FileManager.default.fileExists(atPath: candidate.path) == true)
    }

    @Test
    func `Missing runtime is a clean no-op`() {
        // The runtime stays pinned to the Apple Container CLI with no
        // per-config override, so a missing CLI must fail closed: probe an
        // unknown binary to prove the detector reports absent, then verify
        // the real prune never claims file reclamation. Container counts are
        // only pinned when the CLI is absent, since a present CLI may report
        // genuine Tier-3 crash orphans.
        #expect(ContainerMachineManager.isRuntimeAvailable(runtime: "runeweaver-missing-runtime-\(UUID().uuidString)") == false)
        let config = SandboxConfig()
        #expect(config.containerRuntime == SandboxConfig.defaultContainerRuntime)
        let summary = SandboxCleaner.cleanup(config: config)

        #expect(summary.filesRemoved == 0)
        #expect(summary.bytesFreed == 0)
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
        #expect(event.stagingPath == SandboxCleanupAuditEvent.tier3Scope)
        #expect(event.filesRemoved == 0)
        #expect(event.bytesFreed == 0)
        #expect(event.containersDestroyed == 1)
        #expect(event.staleMachinesStopped == 1)
    }
}

/// Creates an isolated scratch root for one test.
///
/// Each test owns its directory so parallel suites never share prune state;
/// callers remove it with `defer` to keep the temporary volume clean.
/// - Returns: Fresh scratch root URL.
private func makeScratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-sandbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
