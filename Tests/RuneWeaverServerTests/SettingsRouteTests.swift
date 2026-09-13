// Rune Weaver Tests — Settings REST API integration and configuration tests.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing

@Suite("Settings Configuration and DTOs")
struct SettingsRouteTests {
    @Test
    func `ServerPaths defines settings path`() {
        #expect(ServerPaths.settings == "settings")
    }

    @Test
    func `SettingsResponse maps RuneWeaverConfig fields`() {
        let config = RuneWeaverConfig.default
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")

        #expect(response.defaultProvider == config.llm.defaultProvider)
        #expect(response.engineName == config.engine.name)
        #expect(response.logLevel == config.engine.logLevel)
        #expect(response.configPath == "/test/config.toml")
        #expect(response.sandboxStagingPath == config.sandbox.stagingPath)
    }

    @Test
    func `UpdateSettingsRequest modifies config and preserves unmodified fields`() {
        var config = RuneWeaverConfig.default
        let update = UpdateSettingsRequest(
            engineName: "Custom Engine",
            logLevel: "debug",
            sandboxAutoApproveAfter: 42
        )

        update.apply(to: &config)
        #expect(config.engine.name == "Custom Engine")
        #expect(config.engine.logLevel == "debug")
        #expect(config.sandbox.autoApproveAfter == 42)
        // Preserved defaults
        #expect(config.llm.defaultProvider == RuneWeaverConfig.default.llm.defaultProvider)
    }

    @Test
    func `SettingsResponse and UpdateSettingsRequest map emailAccounts`() {
        var config = RuneWeaverConfig.default
        let newAccounts = [
            EmailAccount(
                name: "testmail",
                type: "imap",
                host: "imap.test.org",
                port: 993,
                username: "tester"
            )
        ]
        let update = UpdateSettingsRequest(emailAccounts: newAccounts)
        update.apply(to: &config)
        #expect(config.email.accounts == newAccounts)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.emailAccounts == newAccounts)
    }

    @Test
    func `UpdateSettingsRequest clears fallback when empty and keeps providers when omitted`() {
        var config = RuneWeaverConfig.default
        config.llm.fallbackProvider = "openrouter"
        let preserved = config.llm.providers

        // An empty fallback clears to nil so the dashboard `(None)` choice
        // round-trips, while an omitted provider map keeps stored entries.
        UpdateSettingsRequest(fallbackProvider: "").apply(to: &config)
        #expect(config.llm.fallbackProvider == nil)
        #expect(config.llm.providers == preserved)

        // A present map replaces wholesale instead of merging per entry.
        let replacement = ["solo": ProviderConfig(enabled: true, model: "m")]
        UpdateSettingsRequest(providers: replacement).apply(to: &config)
        #expect(config.llm.providers == replacement)
    }

    @Test
    func `RuneWeaverConfig save preserves home integrations`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings_home_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Home entries must survive save/load so a settings PUT never
        // silently drops automation integrations back to defaults.
        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        config.home = HomeConfig(
            homekit: [HomeKitConfig(enabled: false)],
            homeAssistant: [
                HomeAssistantConfig(enabled: true, url: "http://example.local:8123", tokenEnv: "EXAMPLE_TOKEN")
            ]
        )
        try config.save(to: fileURL)

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.home == config.home)
    }

    @Test
    func `renderTOML escapes, sorts providers, and round-trips`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings_quote_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Tricky characters must escape so the file still parses, and
        // provider order must stay deterministic for stable diffs.
        var config = RuneWeaverConfig.default
        config.engine.name = "a\\b\"c\nd\te"
        config.llm.providers = [
            "zeta": ProviderConfig(enabled: true),
            "alpha": ProviderConfig(enabled: false)
        ]
        config.llm.defaultProvider = "alpha"
        config.llm.fallbackProvider = nil

        let toml = config.renderTOML()
        #expect(toml.contains("\\n"))
        #expect(toml.contains("\\t"))
        let alphaRange = toml.range(of: "[llm.providers.alpha]")
        let zetaRange = toml.range(of: "[llm.providers.zeta]")
        #expect(alphaRange != nil && zetaRange != nil && alphaRange!.lowerBound < zetaRange!.lowerBound)

        let fileURL = tempDir.appendingPathComponent("config.toml")
        try config.save(to: fileURL)
        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.engine.name == config.engine.name)
        #expect(reloaded.llm.providers == config.llm.providers)
    }

    @Test
    func `RuneWeaverConfig save and reload roundtrips with backup`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        config.engine.name = "Initial Name"
        try config.save(to: fileURL)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // Second save creates .bak backup
        config.engine.name = "Updated Name"
        try config.save(to: fileURL)

        let backupURL = fileURL.appendingPathExtension("bak")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.engine.name == "Updated Name")
    }
}
