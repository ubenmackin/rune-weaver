// Rune Weaver Core Tests — Sandbox staging retention and cleanup.
//
// Verifies the bounded staging lifecycle: expired files are reclaimed after
// the retention window, total size pressure evicts oldest-first, symlinks
// that would escape the staging prefix are refused, and empty staging is a
// clean no-op. Scoped to the sweeper's filesystem contract, not service wiring.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Sandbox Cleaner")
struct SandboxCleanerTests {
    @Test
    func `Swift defaults stay pinned to the web mirror`() {
        // Manual cross-language pin: Web/src/api.ts hardcodes these fallbacks
        // because it cannot import Swift. Update both sides together when the
        // staging policy changes.
        #expect(SandboxConfig.defaultRetentionDays == 14)
        #expect(SandboxConfig.defaultMaxTotalBytes == 500 * 1024 * 1024)
        #expect(SandboxConfig.defaultCleanupIntervalSeconds == 3600)
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
    func `Expired files are removed while fresh files are kept`() throws {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let pending = staging.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)

        let now = Date()
        let oldURL = pending.appendingPathComponent("old.txt")
        let freshURL = pending.appendingPathComponent("fresh.txt")
        let oldBytes = Data(repeating: 0x41, count: 64)
        let freshBytes = Data(repeating: 0x42, count: 64)
        try oldBytes.write(to: oldURL)
        try freshBytes.write(to: freshURL)
        // Age the stale file past the window while keeping the fresh file
        // current, so the test pins the retention boundary deterministically.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-15 * 86400)],
            ofItemAtPath: oldURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshURL.path
        )

        var config = SandboxConfig(stagingPath: staging.path)
        config.retentionDays = 14
        config.maxTotalBytes = 10 * 1024 * 1024
        let summary = SandboxCleaner.cleanup(config: config, now: now)

        #expect(summary.filesRemoved == 1)
        #expect(summary.bytesFreed == oldBytes.count)
        #expect(FileManager.default.fileExists(atPath: oldURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: freshURL.path) == true)
    }

    @Test
    func `Size cap evicts oldest files first`() throws {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let pending = staging.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)

        let now = Date()
        // Three equal payloads with staggered ages; the cap forces exactly
        // one eviction so the test proves oldest-first ordering, not just count.
        let oldest = pending.appendingPathComponent("oldest.txt")
        let middle = pending.appendingPathComponent("middle.txt")
        let newest = pending.appendingPathComponent("newest.txt")
        try Data(repeating: 0x41, count: 100).write(to: oldest)
        try Data(repeating: 0x42, count: 100).write(to: middle)
        try Data(repeating: 0x43, count: 100).write(to: newest)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)],
            ofItemAtPath: oldest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-200)],
            ofItemAtPath: middle.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100)],
            ofItemAtPath: newest.path
        )

        var config = SandboxConfig(stagingPath: staging.path)
        // Generous retention disables expiry so only cap pressure drives removal.
        config.retentionDays = 365
        config.maxTotalBytes = 200
        let summary = SandboxCleaner.cleanup(config: config, now: now)

        #expect(summary.filesRemoved == 1)
        #expect(summary.bytesFreed == 100)
        #expect(FileManager.default.fileExists(atPath: oldest.path) == false)
        #expect(FileManager.default.fileExists(atPath: middle.path) == true)
        #expect(FileManager.default.fileExists(atPath: newest.path) == true)
    }

    @Test
    func `Symlink escaping staging is refused`() throws {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let pending = staging.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside)

        // A link inside staging pointing outside must never cause the target
        // to be unlinked, even when the pass would otherwise reclaim old files.
        let link = pending.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)

        var config = SandboxConfig(stagingPath: staging.path)
        config.retentionDays = 1
        config.maxTotalBytes = 10 * 1024 * 1024
        let summary = SandboxCleaner.cleanup(
            config: config,
            now: Date().addingTimeInterval(10 * 86400)
        )

        #expect(FileManager.default.fileExists(atPath: outside.path) == true)
        #expect(summary.filesRemoved == 0)
        #expect(summary.errors.isEmpty == false)
    }

    @Test
    func `Empty staging is a no-op`() throws {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        for subdir in ["pending", "approved", "attachments"] {
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent(subdir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let config = SandboxConfig(stagingPath: staging.path)
        let summary = SandboxCleaner.cleanup(config: config)

        #expect(summary.filesRemoved == 0)
        #expect(summary.bytesFreed == 0)
        #expect(summary.errors.isEmpty == true)
    }
}

/// Creates an isolated staging root for one test.
///
/// Each test owns its directory so parallel suites never share sweep state;
/// callers remove it with `defer` to keep the temporary volume clean.
/// - Returns: Fresh staging root URL.
private func makeStaging() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-sandbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
