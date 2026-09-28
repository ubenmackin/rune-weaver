// Rune Weaver Tests — Settings REST API integration and configuration tests.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
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
        #expect(response.sandboxContainerBaseImage == config.sandbox.containerBaseImage)
        #expect(response.sandboxArchiveSessionTTLMinutes == config.sandbox.archiveSessionTTLMinutes)
        #expect(response.sandboxMaxConcurrentMachines == config.sandbox.maxConcurrentMachines)
        #expect(response.memoryEmbeddingModel == config.memory.embeddingModel)
        #expect(response.memoryEmbeddingBackend == config.memory.embeddingBackend)
    }

    @Test
    func `UpdateSettingsRequest modifies config and preserves unmodified fields`() throws {
        var config = RuneWeaverConfig.default
        let update = UpdateSettingsRequest(
            engineName: "Custom Engine",
            logLevel: "debug",
            sandboxContainerBaseImage: "debian:bookworm-slim",
            sandboxArchiveSessionTTLMinutes: 20,
            sandboxMaxConcurrentMachines: 5
        )

        try update.apply(to: &config)
        #expect(config.engine.name == "Custom Engine")
        #expect(config.engine.logLevel == "debug")
        #expect(config.sandbox.containerBaseImage == "debian:bookworm-slim")
        #expect(config.sandbox.archiveSessionTTLMinutes == 20)
        #expect(config.sandbox.maxConcurrentMachines == 5)
        // Preserved defaults
        #expect(config.llm.defaultProvider == RuneWeaverConfig.default.llm.defaultProvider)
    }

    @Test
    func `SettingsResponse and UpdateSettingsRequest map emailAccounts`() throws {
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
        try update.apply(to: &config)
        #expect(config.email.accounts == newAccounts)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.emailAccounts == newAccounts)
    }

    @Test
    func `UpdateSettingsRequest clears fallback when empty and keeps providers when omitted`() throws {
        var config = RuneWeaverConfig.default
        config.llm.fallbackProvider = "openrouter"
        let preserved = config.llm.providers

        // An empty fallback clears to nil so the dashboard `(None)` choice
        // round-trips, while an omitted provider map keeps stored entries.
        try UpdateSettingsRequest(fallbackProvider: "").apply(to: &config)
        #expect(config.llm.fallbackProvider == nil)
        #expect(config.llm.providers == preserved)

        // A present map replaces wholesale instead of merging per entry.
        let replacement = ["solo": ProviderConfig(enabled: true, model: "m")]
        try UpdateSettingsRequest(providers: replacement).apply(to: &config)
        #expect(config.llm.providers == replacement)
    }

    @Test
    func `SettingsResponse and UpdateSettingsRequest map memoryEmbeddingBackend`() throws {
        var config = RuneWeaverConfig.default

        // Response mirrors the stored backend so the dashboard select stays in sync.
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.memoryEmbeddingBackend == config.memory.embeddingBackend)

        // A present value updates the stored backend.
        try UpdateSettingsRequest(memoryEmbeddingBackend: "provider").apply(to: &config)
        #expect(config.memory.embeddingBackend == "provider")

        // An omitted value preserves the stored backend.
        try UpdateSettingsRequest(engineName: "Kept Backend").apply(to: &config)
        #expect(config.engine.name == "Kept Backend")
        #expect(config.memory.embeddingBackend == "provider")
    }

    @Test
    func `UpdateSettingsRequest rejects unknown memoryEmbeddingBackend`() {
        var config = RuneWeaverConfig.default
        let preserved = config.memory.embeddingBackend

        // Unknown backends fail closed so invalid strings never persist
        // and silently degrade recall to keyword-only later.
        do {
            try UpdateSettingsRequest(memoryEmbeddingBackend: "carrier-pigeon").apply(to: &config)
            Issue.record("Expected a validation error for an unknown embedding backend")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "memory.embedding_backend" else {
                Issue.record("Expected memory.embedding_backend validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }
        #expect(config.memory.embeddingBackend == preserved)
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
        let alpha = try #require(alphaRange)
        let zeta = try #require(zetaRange)
        #expect(alpha.lowerBound < zeta.lowerBound)

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

    @Test
    func `SettingsResponse and UpdateSettingsRequest map media configuration`() throws {
        var config = RuneWeaverConfig.default
        let update = UpdateSettingsRequest(
            media: MediaConfig(
                sonarr: SonarrConfig(
                    enabled: true,
                    url: "http://192.168.1.50:8989",
                    apiKeyEnv: "SONARR_KEY_TEST",
                    defaultQualityProfile: "HD-1080p",
                    defaultRootFolder: "/tv"
                ),
                radarr: RadarrConfig(
                    enabled: false,
                    url: "http://192.168.1.50:7878",
                    apiKeyEnv: "RADARR_KEY_TEST"
                )
            )
        )

        try update.apply(to: &config)
        #expect(config.media.sonarr.url == "http://192.168.1.50:8989")
        #expect(config.media.sonarr.apiKeyEnv == "SONARR_KEY_TEST")
        #expect(config.media.radarr.enabled == false)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.media.sonarr.url == "http://192.168.1.50:8989")
        #expect(response.media.radarr.enabled == false)
    }

    @Test
    func `SettingsResponse and UpdateSettingsRequest map desktop configuration`() throws {
        var config = RuneWeaverConfig.default
        let update = UpdateSettingsRequest(
            desktop: DesktopSettingsUpdate(
                maxImageDimension: 1600,
                jpegQuality: 0.8,
                blockedApps: ["Terminal", "Finder"]
            )
        )

        try update.apply(to: &config)
        #expect(config.desktop.maxImageDimension == 1600)
        #expect(config.desktop.jpegQuality == 0.8)
        #expect(config.desktop.blockedApps == ["Terminal", "Finder"])

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.desktop.maxImageDimension == 1600)
        #expect(response.desktop.blockedApps == ["Terminal", "Finder"])
    }

    @Test
    func `UpdateSettingsRequest desktop patch preserves omitted fields`() throws {
        var config = RuneWeaverConfig.default
        config.desktop.maxImageDimension = 1280
        config.desktop.jpegQuality = 0.75
        config.desktop.blockedApps = ["Terminal"]

        // A patch carrying one key leaves the rest of the stored section
        // untouched instead of resetting it.
        try UpdateSettingsRequest(
            desktop: DesktopSettingsUpdate(maxImageDimension: 1600)
        ).apply(to: &config)
        #expect(config.desktop.maxImageDimension == 1600)
        #expect(config.desktop.jpegQuality == 0.75)
        #expect(config.desktop.blockedApps == ["Terminal"])

        // A nil patch is a full no-op.
        try UpdateSettingsRequest(engineName: "Kept Desktop").apply(to: &config)
        #expect(config.desktop.maxImageDimension == 1600)
        #expect(config.desktop.jpegQuality == 0.75)
    }

    @Test
    func `Desktop tools report settings support through buildToolInfo`() {
        let tools = DesktopTools.makeTools(desktopConfig: DesktopConfig())
        #expect(tools.count == 2)
        for tool in tools {
            let info = buildToolInfo(for: tool, isEnabled: false, recordByPluginID: [:])
            #expect(info.hasConfig == true)
            #expect(info.isEnabled == false)
        }
    }

    @Test
    func `Desktop settings reload keeps both tools registered with live state`() async {
        // Boot ships both tools disabled (the stock install), so a settings
        // reload never has to re-introduce an absent tool to keep the surface
        // inspectable. The tool-state toggle stays the sole authority.
        let bus = ToolBus()
        let initial = DesktopConfig()
        for tool in DesktopTools.makeTools(desktopConfig: initial) {
            await bus.register(tool: tool, isEnabled: false)
        }
        #expect(await bus.tool(named: "desktop.screenshot") != nil)
        #expect(await bus.tool(named: "desktop.action") != nil)

        // Enabling through the tool-state toggle sticks with no config gate
        // overriding it, and the tools stay registered and visible.
        await bus.enableTool(named: "desktop.screenshot")
        #expect(await bus.tool(named: "desktop.screenshot") != nil)
        #expect(await bus.isToolEnabled(named: "desktop.screenshot") == true)

        // A capture-knob change re-registers with preserved state (still
        // enabled), keeping live state across the reload.
        var updated = DesktopConfig()
        updated.maxImageDimension = 1600
        for tool in DesktopTools.makeTools(desktopConfig: updated) {
            let isEnabled = await bus.isToolEnabled(named: tool.name)
            await bus.register(tool: tool, isEnabled: isEnabled)
        }
        #expect(await bus.tool(named: "desktop.action") != nil)
        #expect(await bus.isToolEnabled(named: "desktop.screenshot") == true)
        #expect(await bus.isToolEnabled(named: "desktop.action") == false)

        await bus.enableTool(named: "desktop.action")
        #expect(await bus.isToolEnabled(named: "desktop.action") == true)
    }

    @Test
    func `Updating media config re-registers media tools with new settings`() async throws {
        let bus = ToolBus()
        let initialTools = MediaTools.makeTools(mediaConfig: MediaConfig())
        for tool in initialTools {
            await bus.register(tool: tool)
        }

        // Initial state: Sonarr URL is unconfigured
        let initialToolOpt = await bus.tool(named: "media.arr")
        let initialTool = try #require(initialToolOpt)
        let unconfiguredOutput = try await initialTool.execute(
            input: ToolInput(toolName: "media.arr", argumentsJSON: "{\"action\":\"status\",\"service\":\"sonarr\"}", callID: "call-1"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(unconfiguredOutput.isError)
        #expect(unconfiguredOutput.content.contains("Sonarr URL is not configured"))

        // Update media config and re-register
        var updatedMedia = MediaConfig()
        updatedMedia.sonarr.url = "http://127.0.0.1:8989"
        updatedMedia.sonarr.apiKeyEnv = "MOCK_SONARR_KEY"
        for tool in MediaTools.makeTools(mediaConfig: updatedMedia) {
            let isEnabled = await bus.isToolEnabled(named: tool.name)
            await bus.register(tool: tool, isEnabled: isEnabled)
        }

        // New state: Sonarr URL is present and new apiKeyEnv is picked up
        let reloadedToolOpt = await bus.tool(named: "media.arr")
        let reloadedTool = try #require(reloadedToolOpt)
        let configuredOutput = try await reloadedTool.execute(
            input: ToolInput(toolName: "media.arr", argumentsJSON: "{\"action\":\"status\",\"service\":\"sonarr\"}", callID: "call-2"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(configuredOutput.isError)
        #expect(configuredOutput.content.contains("Missing API key for Sonarr"))
        #expect(configuredOutput.content.contains("MOCK_SONARR_KEY"))
    }

    @Test
    func `ServerPaths defines secrets and status paths`() {
        #expect(ServerPaths.secrets == "secrets")
        #expect(ServerPaths.status == "status")
    }

    @Test
    func `StoreSecretRequest and SecretStatusRequest JSON roundtrips`() throws {
        let storeReq = StoreSecretRequest(key: "EMAIL_WORK_PASSWORD", secret: "testpass123")
        let encodedStore = try JSONEncoder().encode(storeReq)
        let decodedStore = try JSONDecoder().decode(StoreSecretRequest.self, from: encodedStore)
        #expect(decodedStore.key == "EMAIL_WORK_PASSWORD")
        #expect(decodedStore.secret == "testpass123")

        let statusReq = SecretStatusRequest(keys: ["EMAIL_WORK_PASSWORD", "OPENAI_API_KEY"])
        let encodedStatus = try JSONEncoder().encode(statusReq)
        let decodedStatus = try JSONDecoder().decode(SecretStatusRequest.self, from: encodedStatus)
        #expect(decodedStatus.keys == ["EMAIL_WORK_PASSWORD", "OPENAI_API_KEY"])

        let statusResp = SecretStatusResponse(status: ["EMAIL_WORK_PASSWORD": true, "OPENAI_API_KEY": false])
        let encodedResp = try JSONEncoder().encode(statusResp)
        let decodedResp = try JSONDecoder().decode(SecretStatusResponse.self, from: encodedResp)
        #expect(decodedResp.status["EMAIL_WORK_PASSWORD"] == true)
        #expect(decodedResp.status["OPENAI_API_KEY"] == false)
    }

    @Test
    func `Secret status cap stays pinned to the dashboard chunk contract`() {
        // Single cross-language contract: the server owns `maxSecretStatusKeys`
        // and the dashboard mirrors `SECRET_STATUS_CHUNK_SIZE` in
        // `Web/src/components/SettingsManager.tsx`. Both pin 500 so badge-probe
        // chunks never trip the status gate; update both together.
        #expect(maxSecretStatusKeys == 500)
    }

    @Test
    func `SettingsResponse and UpdateSettingsRequest map bash configuration`() throws {
        var config = RuneWeaverConfig.default
        let rules = [
            BashRule(pattern: "git *", action: .allow),
            BashRule(pattern: "*", action: .ask)
        ]
        let update = UpdateSettingsRequest(
            bash: BashSettingsUpdate(
                enabled: false,
                defaultAction: "deny",
                rules: rules,
                timeoutSeconds: 120,
                allowNetwork: true
            )
        )

        try update.apply(to: &config)
        #expect(config.bash.enabled == false)
        #expect(config.bash.defaultAction == .deny)
        #expect(config.bash.rules == rules)
        #expect(config.bash.timeoutSeconds == 120)
        #expect(config.bash.allowNetwork == true)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.bash == config.bash)
        #expect(response.bash.rules == rules)
    }

    @Test
    func `UpdateSettingsRequest rejects unknown bash default action`() {
        var config = RuneWeaverConfig.default
        let preserved = config.bash

        // Unknown actions fail closed so invalid strings never persist
        // and silently widen the shell policy later.
        do {
            try UpdateSettingsRequest(
                bash: BashSettingsUpdate(defaultAction: "bogus")
            ).apply(to: &config)
            Issue.record("Expected a validation error for an unknown bash default action")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "bash.default_action" else {
                Issue.record("Expected bash.default_action validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }
        #expect(config.bash == preserved)
    }

    @Test
    func `UpdateSettingsRequest rejects bash timeout outside bounds`() {
        // Timeout stays 1-3600 so a zero hang or an unbounded run never
        // persists through the settings route.
        for invalid in [0, -5, 3601] {
            var config = RuneWeaverConfig.default
            let preserved = config.bash.timeoutSeconds
            do {
                try UpdateSettingsRequest(
                    bash: BashSettingsUpdate(timeoutSeconds: invalid)
                ).apply(to: &config)
                Issue.record("Expected a validation error for bash timeout \(invalid)")
            } catch let error as ConfigError {
                guard case let .validationError(field, _) = error, field == "bash.timeout_seconds" else {
                    Issue.record("Expected bash.timeout_seconds validation, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ConfigError, got \(type(of: error))")
            }
            #expect(config.bash.timeoutSeconds == preserved)
        }
    }

    @Test
    func `UpdateSettingsRequest files patch persists and preserves omitted fields`() throws {
        var config = RuneWeaverConfig.default
        config.files.denyPatterns = [".env*"]
        config.files.allowRoots = ["~"]
        config.files.requireApprovalOnDeny = true

        // A patch carrying two keys leaves the third stored value untouched
        // instead of resetting it.
        try UpdateSettingsRequest(
            filesDenyPatterns: [".env*", "*.pem"],
            filesRequireApprovalOnDeny: false
        ).apply(to: &config)
        #expect(config.files.denyPatterns == [".env*", "*.pem"])
        #expect(config.files.allowRoots == ["~"])
        #expect(config.files.requireApprovalOnDeny == false)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.filesDenyPatterns == [".env*", "*.pem"])
        #expect(response.filesAllowRoots == ["~"])
        #expect(response.filesRequireApprovalOnDeny == false)
    }

    @Test
    func `UpdateSettingsRequest nil bash and files patches are no-ops`() throws {
        var config = RuneWeaverConfig.default
        config.bash.enabled = false
        config.bash.defaultAction = .deny
        config.bash.timeoutSeconds = 120
        config.files.denyPatterns = ["custom*"]
        config.files.allowRoots = ["~/custom"]

        // A nil patch preserves every stored bash and files value so a
        // dashboard edit elsewhere never resets the shell or guard policy.
        try UpdateSettingsRequest(engineName: "Kept Bash Files").apply(to: &config)
        #expect(config.engine.name == "Kept Bash Files")
        #expect(config.bash.enabled == false)
        #expect(config.bash.defaultAction == .deny)
        #expect(config.bash.timeoutSeconds == 120)
        #expect(config.files.denyPatterns == ["custom*"])
        #expect(config.files.allowRoots == ["~/custom"])
    }

    @Test
    func `Bash and files reload preserves enabled state`() async {
        // Boot ships bash disabled in this probe, so a policy reload never
        // has to re-introduce an absent tool. The tool-state toggle stays
        // the sole authority for enablement.
        let bus = ToolBus()
        let initialBash = BashTool(bashConfig: BashConfig(), filesConfig: FilesConfig())
        await bus.register(tool: initialBash, isEnabled: false)
        #expect(await bus.tool(named: "bash.exec") != nil)
        #expect(await bus.isToolEnabled(named: "bash.exec") == false)

        // Enabling through the tool-state toggle sticks with no config gate
        // overriding it.
        await bus.enableTool(named: "bash.exec")
        #expect(await bus.isToolEnabled(named: "bash.exec") == true)

        // A policy change re-registers with preserved state (still enabled),
        // keeping live state across the reload.
        var updatedBash = BashConfig()
        updatedBash.timeoutSeconds = 120
        let reloadedBash = BashTool(bashConfig: updatedBash, filesConfig: FilesConfig())
        let bashEnabled = await bus.isToolEnabled(named: reloadedBash.name)
        await bus.register(tool: reloadedBash, isEnabled: bashEnabled)
        #expect(await bus.tool(named: "bash.exec") != nil)
        #expect(await bus.isToolEnabled(named: "bash.exec") == true)

        // Files tools follow the same pattern: re-registration keeps the
        // live toggle while the fresh guard policy rides the new instance.
        for tool in FilesTools.makeTools(filesConfig: FilesConfig()) {
            await bus.register(tool: tool, isEnabled: false)
        }
        #expect(await bus.tool(named: "files.read") != nil)
        await bus.enableTool(named: "files.read")
        #expect(await bus.isToolEnabled(named: "files.read") == true)

        var updatedFiles = FilesConfig()
        updatedFiles.denyPatterns = [".env*"]
        for tool in FilesTools.makeTools(filesConfig: updatedFiles) {
            let isEnabled = await bus.isToolEnabled(named: tool.name)
            await bus.register(tool: tool, isEnabled: isEnabled)
        }
        #expect(await bus.tool(named: "files.read") != nil)
        #expect(await bus.isToolEnabled(named: "files.read") == true)
        #expect(await bus.isToolEnabled(named: "files.grep") == false)
    }

    @Test
    func `UpdateSettingsRequest rejects empty bash rules`() {
        var config = RuneWeaverConfig.default
        let preserved = config.bash

        // An empty rule list would diverge on save/load (zero tables reload
        // as the default star rule), so it fails closed instead of persisting.
        do {
            try UpdateSettingsRequest(
                bash: BashSettingsUpdate(rules: [])
            ).apply(to: &config)
            Issue.record("Expected a validation error for empty bash rules")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "bash.rules" else {
                Issue.record("Expected bash.rules validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }
        #expect(config.bash == preserved)
    }

    @Test
    func `UpdateSettingsRequest rejects blank bash rule pattern`() {
        var config = RuneWeaverConfig.default
        let preserved = config.bash

        // A whitespace-only pattern never matches (the matcher trims to ""),
        // so it fails closed matching the file-load path.
        do {
            try UpdateSettingsRequest(
                bash: BashSettingsUpdate(rules: [BashRule(pattern: "   ", action: .allow)])
            ).apply(to: &config)
            Issue.record("Expected a validation error for a blank bash rule pattern")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "bash.rules[0].pattern" else {
                Issue.record("Expected bash.rules[0].pattern validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }
        #expect(config.bash == preserved)
    }

    @Test
    func `RuneWeaverConfig validation rejects empty and blank bash rules`() {
        // Core validation single-sources the PUT checks so file-load and the
        // settings route agree with the same field and message.
        var emptyConfig = RuneWeaverConfig.default
        emptyConfig.bash.rules = []
        do {
            try emptyConfig.validate()
            Issue.record("Expected a validation error for empty bash rules")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "bash.rules" else {
                Issue.record("Expected bash.rules validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }

        var blankConfig = RuneWeaverConfig.default
        blankConfig.bash.rules = [BashRule(pattern: "   ", action: .ask)]
        do {
            try blankConfig.validate()
            Issue.record("Expected a validation error for a blank bash rule pattern")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "bash.rules[0].pattern" else {
                Issue.record("Expected bash.rules[0].pattern validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }
    }

    @Test
    func `Bash TOML round-trips default star rule`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings_bash_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The default star rule must survive save/load without widening or
        // narrowing, pinning the single-rule evaluation order.
        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        config.bash.rules = [BashRule(pattern: "*", action: .ask)]
        try config.save(to: fileURL)

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.bash.rules == [BashRule(pattern: "*", action: .ask)])
    }

    @Test
    func `BashSettingsUpdate decodes camelCase aliases and encodes snake_case`() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // Snake_case stays canonical.
        let snakePayload = "{\"default_action\":\"deny\",\"timeout_seconds\":120,\"allow_network\":true}"
        let snake = try decoder.decode(
            BashSettingsUpdate.self,
            from: Data(snakePayload.utf8)
        )
        #expect(snake.defaultAction == "deny")
        #expect(snake.timeoutSeconds == 120)
        #expect(snake.allowNetwork == true)

        // CamelCase aliases mirror the dashboard contract.
        let camelPayload = "{\"defaultAction\":\"deny\",\"timeoutSeconds\":120,\"allowNetwork\":true}"
        let camel = try decoder.decode(
            BashSettingsUpdate.self,
            from: Data(camelPayload.utf8)
        )
        #expect(camel.defaultAction == "deny")
        #expect(camel.timeoutSeconds == 120)
        #expect(camel.allowNetwork == true)

        // Snake wins when both spellings arrive so the contracts cannot fork.
        let bothPayload = "{\"default_action\":\"deny\",\"defaultAction\":\"allow\","
            + "\"timeout_seconds\":120,\"timeoutSeconds\":5,"
            + "\"allow_network\":true,\"allowNetwork\":false}"
        let both = try decoder.decode(
            BashSettingsUpdate.self,
            from: Data(bothPayload.utf8)
        )
        #expect(both.defaultAction == "deny")
        #expect(both.timeoutSeconds == 120)
        #expect(both.allowNetwork == true)

        // Encode preserves snake_case so saved payloads keep the file shape.
        let encoded = try encoder.encode(
            BashSettingsUpdate(defaultAction: "deny", timeoutSeconds: 120, allowNetwork: true)
        )
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("default_action"))
        #expect(text.contains("timeout_seconds"))
        #expect(text.contains("allow_network"))
        #expect(!text.contains("defaultAction"))
        #expect(!text.contains("timeoutSeconds"))
        #expect(!text.contains("allowNetwork"))
    }
}
