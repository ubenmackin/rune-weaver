// Rune Weaver Tests — Settings REST API integration and configuration tests.
//
// Purpose: pins the settings config merge and DTO contracts plus the
// security-critical `/settings/policy` HTTP surface: the structured GET shape
// without raw TOML, structured PUT validation (field gates then the two
// formal invariants) before any file write, the shared-store visibility that
// lets a rebuilt egress supervisor observe an accepted write with no restart,
// and the structured candidate verify route.
// Scope: route status codes, DTO shapes, and policy file/store effects;
// invariant math and the supervisor gate internals stay with their own suites.
// Architectural role: guards the one owner surface whose writes steer the
// mandatory egress choke-point, so a route edit cannot persist an unverified
// policy or claim a write that never landed.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing
import Vapor

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
    func `UpdateSettingsRequest files write mode patch applies and reports`() throws {
        var config = RuneWeaverConfig.default
        #expect(config.files.writeMode == .model)

        // A valid mode PUT merges into the stored posture and the response
        // mirrors it; the route maps a successful apply to 200.
        try UpdateSettingsRequest(filesWriteMode: "staged").apply(to: &config)
        #expect(config.files.writeMode == .staged)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.filesWriteMode == "staged")

        // The dashboard wire key stays camelCase like its sibling files fields.
        let decoded = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"filesWriteMode":"live"}"#.utf8)
        )
        #expect(decoded.filesWriteMode == "live")

        // An unknown mode fails closed as ConfigError, which the route maps to
        // 400, and the stored posture survives the rejected save.
        do {
            try UpdateSettingsRequest(filesWriteMode: "bogus").apply(to: &config)
            Issue.record("Expected a validation error for an unknown files write mode")
        } catch let error as ConfigError {
            guard case let .validationError(field, _) = error, field == "files.write_mode" else {
                Issue.record("Expected files.write_mode validation, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ConfigError, got \(type(of: error))")
        }
        #expect(config.files.writeMode == .staged)

        // A files patch carrying other keys never disturbs the stored mode.
        try UpdateSettingsRequest(filesDenyPatterns: [".env*"]).apply(to: &config)
        #expect(config.files.writeMode == .staged)
    }

    @Test
    func `Files write mode survives a save and reload through the settings merge`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings_write_mode_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A forced posture written through the same merge the route uses must
        // reload intact, so a mode save is durable rather than live-only.
        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        try UpdateSettingsRequest(filesWriteMode: "live").apply(to: &config)
        try config.save(to: fileURL)

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.files.writeMode == .live)
        #expect(SettingsResponse(config: reloaded, configPath: fileURL.path).filesWriteMode == "live")
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

    @Test
    func `Allow roots order is display-only for FilesAccessGuard decisions`() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("settings_roots_order_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dirA = base.appendingPathComponent("a", isDirectory: true)
        let dirB = base.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let fileA = dirA.appendingPathComponent("notes.md").path
        let fileB = dirB.appendingPathComponent("notes.md").path
        let outside = base.appendingPathComponent("outside.md").path

        // Two roots in opposite orders must decide identically: inside either
        // root allows while outside denies, so order never changes the result.
        var forward = FilesConfig()
        forward.denyPatterns = []
        forward.allowRoots = [dirA.path, dirB.path]
        var reversed = FilesConfig()
        reversed.denyPatterns = []
        reversed.allowRoots = [dirB.path, dirA.path]
        for path in [fileA, fileB] {
            let fwd = FilesAccessGuard.evaluate(path: path, filesConfig: forward)
            let rev = FilesAccessGuard.evaluate(path: path, filesConfig: reversed)
            #expect(fwd.allowed == true)
            #expect(rev.allowed == true)
            #expect(fwd.allowed == rev.allowed)
        }
        let fwdOutside = FilesAccessGuard.evaluate(path: outside, filesConfig: forward)
        let revOutside = FilesAccessGuard.evaluate(path: outside, filesConfig: reversed)
        #expect(fwdOutside.allowed == false)
        #expect(revOutside.allowed == false)
        #expect(fwdOutside.allowed == revOutside.allowed)

        // Deny-then-containment: a deny match denies first even when inside a
        // root, and the denial is identical in both orders.
        var forwardDeny = forward
        forwardDeny.denyPatterns = ["*.pem"]
        var reversedDeny = reversed
        reversedDeny.denyPatterns = ["*.pem"]
        let deniedA = dirA.appendingPathComponent("secret.pem").path
        let fwdDenied = FilesAccessGuard.evaluate(path: deniedA, filesConfig: forwardDeny)
        let revDenied = FilesAccessGuard.evaluate(path: deniedA, filesConfig: reversedDeny)
        #expect(fwdDenied.allowed == false)
        #expect(revDenied.allowed == false)
        #expect(fwdDenied.allowed == revDenied.allowed)
    }

    @Test
    func `UpdateSettingsRequest fanout patch preserves omitted fields`() throws {
        var config = RuneWeaverConfig.default
        config.fanOut = FanOutConfig(maxWorkers: 4, workerTimeoutSeconds: 300, fullTools: false)

        // A patch carrying one key leaves the rest of the stored swarm policy
        // untouched instead of resetting it, so a workers-only PUT never
        // widens the tool subset or shortens the timeout by surprise.
        try UpdateSettingsRequest(
            fanout: FanOutSettingsUpdate(maxWorkers: 5)
        ).apply(to: &config)
        #expect(config.fanOut.maxWorkers == 5)
        #expect(config.fanOut.workerTimeoutSeconds == 300)
        #expect(config.fanOut.fullTools == false)

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.fanout.maxWorkers == 5)
        #expect(response.fanout.workerTimeoutSeconds == 300)
        #expect(response.fanout.fullTools == false)
    }

    @Test
    func `UpdateSettingsRequest nil fanout patch is a no-op`() throws {
        var config = RuneWeaverConfig.default
        config.fanOut = FanOutConfig(maxWorkers: 6, workerTimeoutSeconds: 120, fullTools: true)

        // A nil patch preserves every stored fan-out value so a dashboard edit
        // elsewhere never resets the swarm policy.
        try UpdateSettingsRequest(engineName: "Kept Fanout").apply(to: &config)
        #expect(config.engine.name == "Kept Fanout")
        #expect(config.fanOut.maxWorkers == 6)
        #expect(config.fanOut.workerTimeoutSeconds == 120)
        #expect(config.fanOut.fullTools == true)
    }

    @Test
    func `FanOutSettingsUpdate decodes snake_case wire keys`() throws {
        // The dashboard PUT sends `{"fanout":{"max_workers":5}}`; the patch
        // must land on the workers knob while the omitted knobs stay nil so
        // the merge preserves them instead of resetting.
        let payload = #"{"fanout":{"max_workers":5}}"#
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(payload.utf8)
        )
        #expect(request.fanout?.maxWorkers == 5)
        #expect(request.fanout?.workerTimeoutSeconds == nil)
        #expect(request.fanout?.fullTools == nil)

        var config = RuneWeaverConfig.default
        config.fanOut = FanOutConfig(maxWorkers: 4, workerTimeoutSeconds: 300, fullTools: false)
        try request.apply(to: &config)
        #expect(config.fanOut.maxWorkers == 5)
        #expect(config.fanOut.workerTimeoutSeconds == 300)
        #expect(config.fanOut.fullTools == false)
    }

    @Test
    func `UpdateSettingsRequest fanout bounds fail validation`() throws {
        // The worker cap stays 1-8 so a wide subtask list cannot oversubscribe
        // the serving model; the merged file must refuse before persisting.
        for invalid in [0, -1, 9, 99] {
            var config = RuneWeaverConfig.default
            do {
                try UpdateSettingsRequest(
                    fanout: FanOutSettingsUpdate(maxWorkers: invalid)
                ).apply(to: &config)
                try config.validate()
                Issue.record("Expected a validation error for fanout max_workers \(invalid)")
            } catch let error as ConfigError {
                guard case let .validationError(field, _) = error, field == "fanout.max_workers" else {
                    Issue.record("Expected fanout.max_workers validation, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ConfigError, got \(type(of: error))")
            }
        }

        // Negative and overlong timeouts fail closed matching the file-load
        // path; zero is accepted as unlimited.
        for invalid in [-1, -5, FanOutConfig.maxWorkerTimeoutSeconds + 1] {
            var config = RuneWeaverConfig.default
            do {
                try UpdateSettingsRequest(
                    fanout: FanOutSettingsUpdate(workerTimeoutSeconds: invalid)
                ).apply(to: &config)
                try config.validate()
                Issue.record("Expected a validation error for fanout worker_timeout_seconds \(invalid)")
            } catch let error as ConfigError {
                guard case let .validationError(field, _) = error, field == "fanout.worker_timeout_seconds" else {
                    Issue.record("Expected fanout.worker_timeout_seconds validation, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ConfigError, got \(type(of: error))")
            }
        }

        // Zero is accepted as unlimited, matching file-load and defaults.
        var zeroConfig = RuneWeaverConfig.default
        try UpdateSettingsRequest(
            fanout: FanOutSettingsUpdate(workerTimeoutSeconds: 0)
        ).apply(to: &zeroConfig)
        try zeroConfig.validate()
        #expect(zeroConfig.fanOut.workerTimeoutSeconds == 0)
    }

    @Test
    func `FanOut engine live reload observes saved patch through accessor`() async throws {
        // A saved workers-only patch must reach the live swarm without a
        // restart: the engine accessor observes the merged snapshot after the
        // settings save pushes it live.
        let engine = FanOutEngine(
            orchestrator: StubFanOutOrchestrator(),
            runLogs: StubFanOutRunLogger(),
            config: FanOutConfig(maxWorkers: 4, workerTimeoutSeconds: 300, fullTools: false)
        )
        var config = RuneWeaverConfig.default
        config.fanOut = FanOutConfig(maxWorkers: 4, workerTimeoutSeconds: 300, fullTools: false)
        try UpdateSettingsRequest(
            fanout: FanOutSettingsUpdate(maxWorkers: 5)
        ).apply(to: &config)
        try config.validate()
        await engine.updateConfig(config.fanOut)
        let live = await engine.currentConfig
        #expect(live.maxWorkers == 5)
        #expect(live.workerTimeoutSeconds == 300)
        #expect(live.fullTools == false)
    }

    @Test
    func `Fanout tool reports settings support while staying approval-gated`() {
        // The dashboard renders Configure from `hasConfig`, while the
        // permission gate still parks every swarm for approval because it
        // spends concurrent model rounds.
        let engine = FanOutEngine(
            orchestrator: StubFanOutOrchestrator(),
            runLogs: StubFanOutRunLogger(),
            config: FanOutConfig()
        )
        let tools = FanOutTools.makeTools(engine: engine)
        #expect(tools.count == 1)
        guard let tool = tools.first else {
            Issue.record("Expected one fanout.run tool")
            return
        }
        #expect(tool.name == "fanout.run")
        #expect(tool.permissionLevel == .requiresApproval)
        let info = buildToolInfo(for: tool, isEnabled: true, recordByPluginID: [:])
        #expect(info.hasConfig == true)
        #expect(info.isEnabled == true)

        // Unrelated tools keep no Configure action so the fan-out addition
        // never widens other rows; files.write is the one files tool exposing
        // its own write review mode, and every other files tool stays clean.
        let filesTools = FilesTools.makeTools(filesConfig: FilesConfig())
        for filesTool in filesTools {
            let listed = buildToolInfo(for: filesTool, isEnabled: true, recordByPluginID: [:])
            #expect(listed.hasConfig == (filesTool.name == "files.write"))
        }
    }

    @Test
    func `Live browser reload rebinds the rebuilt gateway to the live egress supervisor`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = try await OutboundEgressSupervisor.make(policyStore: store)

        // A browser-knob save merges into the stored policy and rebuilds the
        // managed bridge from the merged settings; the rebuilt gateway must
        // keep the live supervisor boot wired into the original.
        var config = RuneWeaverConfig.default
        try UpdateSettingsRequest(browserTimeoutSeconds: 45).apply(to: &config)
        #expect(config.browser.timeoutSeconds == 45)
        let stored = SubprocessPlaywrightGateway(browserConfig: BrowserConfig(), egressSupervisor: nil)
        let rebuilt = try #require(
            gatewayForLiveReload(
                stored: stored,
                busGateway: nil,
                browserConfig: config.browser,
                mediaConfig: config.media,
                llmServerURLs: [],
                origins: [],
                egressSupervisor: supervisor
            ) as? SubprocessPlaywrightGateway
        )
        #expect(rebuilt.timeoutSeconds == 45)
        #expect(rebuilt.egressSupervisor === supervisor)

        // A public literal clears the SSRF-only stack, so only the declarative
        // policy gate can refuse it. A rebuild that lost the supervisor would
        // let this entry validation pass and reach the unlisted host.
        let destination = try #require(URL(string: "https://93.184.216.34/v1/status"))
        do {
            _ = try await rebuilt.navigate(url: destination.absoluteString, includeScreenshot: false, dryRun: true)
            Issue.record("Expected the rebuilt gateway to refuse the unlisted public literal")
        } catch let error as BrowserError {
            guard case let .invalidURL(reason) = error else {
                Issue.record("Expected BrowserError.invalidURL, got \(error)")
                return
            }
            #expect(reason.contains("Egress blocked"))
        } catch {
            Issue.record("Expected an egress refusal, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func `Live network reload keeps api.request on the boot egress supervisor`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let base = ServerContext.fallbackUnconfigured
        // A fresh bus keeps these rebuilt tools off the shared fallback
        // registry, so parallel route tests never observe them.
        let context = makePolicyRouteContext(
            store: store,
            egressSupervisor: bootSupervisor,
            toolBus: ToolBus(permissionGate: base.permissionGate)
        )

        // Every dashboard save carries the browser timeout knobs, so this is
        // the network-tool rebuild each full settings PUT triggers.
        var config = RuneWeaverConfig.default
        let body = UpdateSettingsRequest(browserTimeoutSeconds: 45)
        try body.apply(to: &config)
        try await reloadLiveNetworkTools(body: body, config: config, context: context)

        // The rebuilt browser tools must keep the boot instance the context
        // exposes for triage, the permission gate, and browser hops...
        let navigate = try #require(await context.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool)
        let gateway = try #require(navigate.browserGateway as? SubprocessPlaywrightGateway)
        #expect(gateway.egressSupervisor === bootSupervisor)

        // ...and so must api.request: triage files ephemeral grants on the
        // boot actor, so binding a freshly built supervisor would make an
        // approved allowOnce/allowSession retry check a different actor and
        // fail as unlisted. A dry run takes the same network gate without a
        // dial, making the split observable without a socket.
        await bootSupervisor.allowDomainOnce(domain: "93.184.216.34", sessionID: nil)
        let apiTool = try #require(await context.toolBus.tool(named: "api.request"))
        let output = try await apiTool.execute(
            input: ToolInput(
                toolName: "api.request",
                argumentsJSON: #"{"method":"GET","url":"https://93.184.216.34/v1/status"}"#
            ),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(!output.isError)
    }

    @Test
    func `Configured-service egress derivation feeds boot and settings auto-population`() async throws {
        // One shared derivation must feed both the boot supervisor wiring and
        // the settings save path, or a service source added for one path can
        // silently skip auto-population on the other.
        var config = RuneWeaverConfig.default
        config.browser.searxngURL = "http://searxng.example.net:8888"
        config.media.sonarr = .makeSonarr(url: "http://sonarr.example.net:8989")
        config.media.radarr = .makeRadarr(url: "http://radarr.example.net:7878")
        config.email.accounts = [
            EmailAccount(name: "primary", host: "imap.example.com", username: "owner", smtpHost: "smtp.example.com")
        ]
        let expected = [
            "http://searxng.example.net:8888",
            "http://sonarr.example.net:8989",
            "http://radarr.example.net:7878",
            "imap.example.com",
            "smtp.example.com"
        ]
        #expect(config.serviceEgressCandidates == expected)
        #expect(
            RuneWeaverConfig.serviceEgressCandidates(browser: config.browser, media: config.media, email: config.email) == expected
        )
        #expect(
            ServerContext.configuredServiceEgressCandidates(
                browser: config.browser, media: config.media, email: config.email
            ) == expected
        )

        // The settings path applies that same derivation to the shared store,
        // so every derived service host lands in the persisted allowlist.
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await ensureConfiguredServiceEgressCandidates(config: config, store: store)
        let policy = try await store.snapshot()
        for host in ["searxng.example.net", "sonarr.example.net", "radarr.example.net", "imap.example.com", "smtp.example.com"] {
            #expect(policy.network.allowedDomains.contains(host))
        }
    }
}

// MARK: - Security Policy Routes

/// Minimal orchestrator stub so fan-out live-reload tests can own an engine
/// without the full LLM stack; turns never run in these tests.
private struct StubFanOutOrchestrator: OrchestratorFanOutSeam, Sendable {
    func process(_: UserInput) async throws {}
}

/// Minimal run-log stub so fan-out live-reload tests can own an engine
/// without the durable store; rows are discarded because these tests pin
/// config propagation, never the audit trail.
private struct StubFanOutRunLogger: FanOutRunLogging, Sendable {
    @discardableResult
    func appendFanOutRow(kind _: String, status _: String, message _: String, sessionID _: UUID) async -> UUID {
        UUID()
    }

    func updateFanOutRow(id _: UUID, status _: String) async {}
}

/// Builds an isolated policy store over a throwaway directory and loads it.
///
/// The route tests must exercise the real file read/write boundary, so the
/// store points at a temp `policy.toml` instead of the operator's file. The
/// load mirrors boot: a missing file seeds the factory-safe default and still
/// counts as accepted, so the routes always start from a verified posture.
/// - Parameter contents: Optional file contents written before the load.
/// - Returns: The loaded store, the policy file URL, and the temp directory.
private func makePolicyRouteStore(contents: String? = nil) async throws -> (store: PolicyStore, fileURL: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rw-policy-routes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("policy.toml")
    if let contents {
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    let store = PolicyStore(fileURL: fileURL)
    await store.load()
    return (store, fileURL, directory)
}

/// Builds the lean route context for the policy surface.
///
/// Borrows the fallback context's collaborators — the policy routes read only
/// the shared store, so no turn machinery is involved — and injects the
/// isolated store under test as the one instance the app serves. Live-reload
/// regressions may additionally inject the boot supervisor the save path must
/// preserve and a fresh bus so their tool registrations stay off the shared
/// fallback registry.
/// - Parameters:
///   - store: The one policy store this app's routes must serve.
///   - egressSupervisor: Boot supervisor the context exposes for triage and gate decisions.
///   - toolBus: Fresh registry for tests that rebuild tools; defaults to the fallback bus.
/// - Returns: A context wired for the `/settings/policy` routes.
private func makePolicyRouteContext(
    store: PolicyStore,
    egressSupervisor: OutboundEgressSupervisor? = nil,
    toolBus: ToolBus? = nil
) -> ServerContext {
    let base = ServerContext.fallbackUnconfigured
    return ServerContext(
        config: .default,
        conversations: base.conversations,
        toolBus: toolBus ?? base.toolBus,
        orchestrator: base.orchestrator,
        memoryEngine: base.memoryEngine,
        permissionGate: base.permissionGate,
        approvals: base.approvals,
        steeringQueue: base.steeringQueue,
        policyStore: store,
        egressSupervisor: egressSupervisor
    )
}

/// Runs one test body against an application serving the policy routes.
/// - Parameters:
///   - store: The shared store the routes must serve.
///   - body: Test body receiving the configured app.
/// - Returns: Whatever `body` returns.
private func withPolicyRouteApp<T>(
    store: PolicyStore,
    _ body: (Application) async throws -> T
) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        app.runeWeaver = makePolicyRouteContext(store: store)
        registerRuneWeaverRoutes(app)
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Sends one in-process request through the registered policy surface.
/// - Parameters:
///   - app: Configured application.
///   - method: HTTP verb.
///   - path: Request path.
///   - body: Content JSON body for PUT and POST probes; nil sends no body.
/// - Returns: The route response, without binding a socket.
private func policyRequest(
    app: Application,
    method: HTTPMethod,
    path: String,
    body: (some Content)?
) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    if let body {
        try request.content.encode(body)
    }
    return try await app.responder.respond(to: request).get()
}

/// Sends one in-process GET through the registered policy surface.
/// - Parameters:
///   - app: Configured application.
///   - path: Request path.
/// - Returns: The route response, without binding a socket.
private func policyRequest(
    app: Application,
    method: HTTPMethod,
    path: String
) async throws -> Response {
    let request = Request(
        application: app,
        method: method,
        url: URI(string: path),
        on: app.eventLoopGroup.next()
    )
    return try await app.responder.respond(to: request).get()
}

/// Retired raw-TOML body shape, kept so the migration signal stays pinned:
/// the server must reject it with a 400 naming the field instead of
/// persisting unvalidated text.
private struct RetiredRawTOMLPolicyBody: Content {
    /// Legacy raw document the structured contract no longer accepts.
    let raw_toml: String
}

/// Builds one structured policy DTO for PUT and verify probes.
/// - Parameters:
///   - mode: Wire mode string.
///   - allowed: Allowlist entries.
///   - blocked: Blocklist entries.
///   - credentials: Per-key bindings.
///   - version: Schema version carried verbatim.
/// - Returns: DTO mirroring the REST wire shape.
private func structuredPolicyDTO(
    mode: String = "allowlist_only",
    allowed: [String] = ["93.184.216.34"],
    blocked: [String] = ["169.254.169.254"],
    credentials: [String: CredentialBindingDTO] = [:],
    version: Int = 1
) -> SecurityPolicyDTO {
    SecurityPolicyDTO(
        version: version,
        network: NetworkEgressPolicyDTO(
            mode: mode,
            allowedDomains: allowed,
            blockedDomains: blocked
        ),
        credentials: credentials
    )
}

@Suite("Settings Policy Routes")
struct SettingsPolicyRouteTests {
    @Test
    func `GET serves the parsed policy and live invariant status without raw TOML`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let response = try await policyRequest(app: app, method: .GET, path: "/settings/policy")
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)

            // A first-run install serves the seeded deny-by-default posture:
            // inspectable, invariant-clean, and honest that it never came from
            // an operator-authored file.
            #expect(payload.policy.network.mode == EgressMode.allowlistOnly.rawValue)
            #expect(payload.policy.network.allowedDomains == ["127.0.0.1"])
            #expect(payload.policy.network.blockedDomains == ["169.254.169.254"])
            #expect(payload.loadedFromDisk == false)
            #expect(payload.violations.isEmpty)
            #expect(payload.path == fileURL.path)
            // The wire carries the structured shape only: the server owns
            // serialization, so no raw document can disagree with the DTO.
            let bodyText = response.body.string ?? ""
            #expect(!bodyText.contains("raw_toml"))
            #expect(!bodyText.contains("rawToml"))
        }
    }

    @Test
    func `PUT rejects the retired raw_toml shape without writing the file`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // An old editor sending unvalidated text must learn the new
            // contract: the 400 names the retired field, and neither the
            // file nor the live snapshot moves.
            for legacy in [
                RetiredRawTOMLPolicyBody(raw_toml: "version = 1\n[network]\nmode = \"unrestricted\"\n")
            ] {
                let response = try await policyRequest(
                    app: app, method: .PUT, path: "/settings/policy", body: legacy
                )
                #expect(response.status == .badRequest)
                #expect((response.body.string ?? "").contains("raw_toml"))
            }

            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
        }
    }

    @Test
    func `PUT refuses blank domains, unknown modes, and bad bindings without persisting`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // Each malformed shape must fail the same way: Abort 400 with a
            // reason naming the gate and the field, while the file and the
            // live snapshot stay agreeing instead of diverging.
            let badMode = UpdatePolicyRequest(policy: structuredPolicyDTO(mode: "yolo"))
            let blankDomain = UpdatePolicyRequest(policy: structuredPolicyDTO(allowed: ["api.example.com", "   "]))
            let tomlBreaking = UpdatePolicyRequest(policy: structuredPolicyDTO(allowed: ["evil.example\"\n[credentials.X]"]))
            let emptyHosts = UpdatePolicyRequest(
                policy: structuredPolicyDTO(credentials: [
                    "ORPHANED": CredentialBindingDTO(allowedHosts: [], allowedMethods: [], allowedPathPrefixes: [])
                ])
            )
            let badMethod = UpdatePolicyRequest(
                policy: structuredPolicyDTO(credentials: [
                    "API_KEY": CredentialBindingDTO(allowedHosts: ["api.example.com"], allowedMethods: ["FETCH"], allowedPathPrefixes: [])
                ])
            )
            let unrootedPrefix = UpdatePolicyRequest(
                policy: structuredPolicyDTO(credentials: [
                    "API_KEY": CredentialBindingDTO(allowedHosts: ["api.example.com"], allowedMethods: [], allowedPathPrefixes: ["v1/no-slash"])
                ])
            )
            let badKey = UpdatePolicyRequest(
                policy: structuredPolicyDTO(credentials: [
                    "NO SPACES": CredentialBindingDTO(allowedHosts: ["api.example.com"], allowedMethods: [], allowedPathPrefixes: [])
                ])
            )
            // Only an exact host or a single leading `*.` edge authorizes at
            // runtime, so every other star shape plus whitespace, comma, and
            // glob syntax refuses at the network gate like the editor.
            let wildcardShapes = ["*foo", "foo*", "***", "*.*", "foo bar", "a,b", "a?b", "foo.*"].map {
                UpdatePolicyRequest(policy: structuredPolicyDTO(allowed: [$0]))
            }
            let blockedWildcard = UpdatePolicyRequest(
                policy: structuredPolicyDTO(blocked: ["*foo"])
            )
            for candidate in [badMode, blankDomain, tomlBreaking, emptyHosts, badMethod, unrootedPrefix, badKey] + wildcardShapes + [blockedWildcard] {
                let response = try await policyRequest(
                    app: app, method: .PUT, path: "/settings/policy", body: candidate
                )
                #expect(response.status == .badRequest)
                let reason = response.body.string ?? ""
                #expect(reason.contains("Gate:"))
                #expect(reason.contains("field:"))
            }

            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
            let loadedFromDisk = await store.loadedFromDisk
            #expect(loadedFromDisk == false)

            // The retired mode name keeps its fail-closed intent by mapping
            // to the surviving posture instead of refusing the save.
            let legacyResponse = try await policyRequest(
                app: app,
                method: .PUT,
                path: "/settings/policy",
                body: UpdatePolicyRequest(policy: structuredPolicyDTO(mode: "deny_by_default"))
            )
            #expect(legacyResponse.status == .ok)
            let legacyPayload = try legacyResponse.content.decode(PolicyResponse.self)
            #expect(legacyPayload.policy.network.mode == EgressMode.allowlistOnly.rawValue)
        }
    }

    @Test
    func `PUT refuses an invariant violation and leaves the file and live store untouched`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // A bare star would authorize every host, so the binding gate
            // refuses the candidate before the file write and names the exact
            // credential field under repair.
            let violating = UpdatePolicyRequest(
                policy: structuredPolicyDTO(credentials: [
                    "LEAKED": CredentialBindingDTO(allowedHosts: ["*"], allowedMethods: [], allowedPathPrefixes: [])
                ])
            )
            let response = try await policyRequest(
                app: app,
                method: .PUT,
                path: "/settings/policy",
                body: violating
            )
            #expect(response.status == .badRequest)
            let reason = response.body.string ?? ""
            #expect(reason.contains("Gate: binding"))
            #expect(reason.contains("credentials.LEAKED.allowed_hosts"))

            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
        }
    }

    @Test
    func `PUT accepts a valid structured policy and a rebuilt supervisor observes it without a restart`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            // A public literal settles in the policy and SSRF gates without a
            // resolver hop, so the rebuilt supervisor probes hermetically.
            let destination = try #require(URL(string: "https://93.184.216.34/v1/status"))
            let baselineSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let baseline = await baselineSupervisor.validate(url: destination, method: "GET", headers: [:])
            switch baseline {
            case .allowed:
                Issue.record("Expected the seeded allowlist to refuse the public literal before the PUT")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("not in the allowed domains"))
            }

            let candidate = UpdatePolicyRequest(policy: structuredPolicyDTO())
            let response = try await policyRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.mode == EgressMode.allowlistOnly.rawValue)
            #expect(payload.policy.network.allowedDomains == ["93.184.216.34"])
            #expect(payload.loadedFromDisk == true)
            #expect(payload.violations.isEmpty)
            let bodyText = response.body.string ?? ""
            #expect(!bodyText.contains("raw_toml"))
            let saved = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(saved.contains("93.184.216.34"))

            // The route re-loads the SAME store instance in place, so a
            // supervisor rebuilt over the shared store — the live tool-rebuild
            // path — observes the accepted write with no restart and no watcher.
            let livePolicy = await store.current
            #expect(livePolicy.network.allowedDomains == ["93.184.216.34"])
            // The persisted bytes come from the store-owned round-trip proof:
            // reparsing the file must yield the same accepted policy, so a
            // quoting edge can never persist differently than it verified.
            let reparsedFile = try PolicyStore.parse(saved)
            #expect(reparsedFile == livePolicy)
            let acceptedFromDisk = await store.loadedFromDisk
            #expect(acceptedFromDisk == true)
            let rebuiltSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let verdict = await rebuiltSupervisor.validate(url: destination, method: "GET", headers: [:])
            switch verdict {
            case .allowed:
                break
            case let .denied(reason), let .unlistedDomain(_, reason):
                Issue.record("Expected the rebuilt supervisor to allow the policy-listed literal, got: \(reason)")
            }
        }
    }

    @Test
    func `Save-then-GET reflects the structured write`() async throws {
        // The pane re-reads after saving, so a PUT followed by a GET must
        // agree on mode, domains, and bindings with no restart between them.
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(
                    credentials: [
                        "GITHUB_PAT": CredentialBindingDTO(
                            allowedHosts: ["api.github.com"],
                            allowedMethods: ["GET"],
                            allowedPathPrefixes: ["/repos"]
                        )
                    ]
                )
            )
            let putResponse = try await policyRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(putResponse.status == .ok)

            let getResponse = try await policyRequest(app: app, method: .GET, path: "/settings/policy")
            #expect(getResponse.status == .ok)
            let payload = try getResponse.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains == ["93.184.216.34"])
            #expect(payload.policy.credentials["GITHUB_PAT"]?.allowedHosts == ["api.github.com"])
            #expect(payload.policy.credentials["GITHUB_PAT"]?.allowedMethods == ["GET"])
            #expect(payload.policy.credentials["GITHUB_PAT"]?.allowedPathPrefixes == ["/repos"])
            #expect(payload.violations.isEmpty)
        }
    }

    @Test
    func `Unrelated allow leaves other hosts denied`() async throws {
        // Policy writes are additive grants, never ambient permission: an
        // accepted allow for one literal must not open a sibling host, so a
        // denied destination stays denied after an unrelated PUT.
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let candidate = UpdatePolicyRequest(policy: structuredPolicyDTO())
            let putResponse = try await policyRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(putResponse.status == .ok)

            let other = try #require(URL(string: "https://denied.example.com/v1/status"))
            let rebuiltSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
            let verdict = await rebuiltSupervisor.validate(url: other, method: "GET", headers: [:])
            switch verdict {
            case .allowed:
                Issue.record("Expected an unlisted host to stay denied after an unrelated allow")
            case let .denied(reason), let .unlistedDomain(_, reason):
                #expect(reason.contains("not in the allowed domains"))
            }
        }
    }

    @Test
    func `POST verify accepts a valid candidate without persisting it`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            let candidate = VerifyPolicyRequest(
                policy: structuredPolicyDTO(mode: "unrestricted", allowed: [], blocked: ["169.254.169.254"])
            )
            let response = try await policyRequest(
                app: app, method: .POST, path: "/settings/policy/verify", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(VerifyPolicyResponse.self)
            #expect(payload.valid == true)
            #expect(payload.violations.isEmpty)

            // Verification is a pure candidate check: neither the store nor the
            // file moves until an explicit PUT is accepted.
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
        }
    }

    @Test
    func `POST verify reports structural and invariant violations without persisting`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)

            // A structural refusal names the gate and field so the editor can
            // repair the exact entry; the verdict stays invalid either way.
            let structural = try await policyRequest(
                app: app,
                method: .POST,
                path: "/settings/policy/verify",
                body: VerifyPolicyRequest(
                    policy: structuredPolicyDTO(
                        credentials: [
                            "API_KEY": CredentialBindingDTO(
                                allowedHosts: ["api.example.com"],
                                allowedMethods: ["FETCH"],
                                allowedPathPrefixes: []
                            )
                        ]
                    )
                )
            )
            #expect(structural.status == .ok)
            let structuralPayload = try structural.content.decode(VerifyPolicyResponse.self)
            #expect(structuralPayload.valid == false)
            #expect(structuralPayload.violations.contains { $0.contains("Gate:") && $0.contains("field:") })

            // A confinement failure reports the violated formal invariant, so
            // a loopback binding the shape gate accepts still surfaces the
            // credential-confinement wording instead of a field gate.
            let violating = try await policyRequest(
                app: app,
                method: .POST,
                path: "/settings/policy/verify",
                body: VerifyPolicyRequest(
                    policy: structuredPolicyDTO(
                        credentials: [
                            "LEAKED": CredentialBindingDTO(allowedHosts: ["127.0.0.1"], allowedMethods: [], allowedPathPrefixes: [])
                        ]
                    )
                )
            )
            #expect(violating.status == .ok)
            let violatingPayload = try violating.content.decode(VerifyPolicyResponse.self)
            #expect(violatingPayload.valid == false)
            #expect(violatingPayload.violations.contains { $0.contains("Invariant 1") })

            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
        }
    }

    @Test
    func `POST verify rejects the retired raw_toml shape`() async throws {
        // Editors share one migration signal: the retired document shape is a
        // 400 on verify exactly like on PUT, so no caller keeps sending text.
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let rejected = try await policyRequest(
                app: app,
                method: .POST,
                path: "/settings/policy/verify",
                body: RetiredRawTOMLPolicyBody(raw_toml: "version = 1\n")
            )
            #expect(rejected.status == .badRequest)
            #expect((rejected.body.string ?? "").contains("raw_toml"))
            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
        }
    }

    @Test
    func `GET surfaces rejection diagnostics instead of a false healthy banner`() async throws {
        // A present-but-rejected file keeps the safe fallback in `current`,
        // so verifying the fallback would report zero violations while the
        // CLI exits nonzero for the same file. The route must surface the
        // store diagnostics so the dashboard banner stays red.
        let violating = "[credentials.LEAK]\nallowed_hosts = [\"*\"]\n"
        let (store, fileURL, directory) = try await makePolicyRouteStore(contents: violating)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await store.loadedFromDisk == false)

        try await withPolicyRouteApp(store: store) { app in
            let response = try await policyRequest(app: app, method: .GET, path: "/settings/policy")
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.loadedFromDisk == false)
            #expect(!payload.violations.isEmpty)
            let joined = payload.violations.joined(separator: " ")
            #expect(joined.contains("invariant") || joined.contains("Invariant") || joined.contains("Policy"))
            // The served posture is the displayable fallback, never the
            // rejected file content laundered as healthy.
            #expect(payload.policy.network.mode == EgressMode.allowlistOnly.rawValue)
        }
    }

    @Test
    func `GET surfaces parse-error diagnostics instead of a false healthy banner`() async throws {
        // An unreadable spelling must trip the same honesty path as an
        // invariant violation: the fallback verifies clean, so only the
        // load diagnostics keep the banner honest.
        let (store, fileURL, directory) = try await makePolicyRouteStore(contents: "[network\nmode = \"unrestricted\"")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await store.loadedFromDisk == false)

        try await withPolicyRouteApp(store: store) { app in
            let response = try await policyRequest(app: app, method: .GET, path: "/settings/policy")
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.loadedFromDisk == false)
            #expect(!payload.violations.isEmpty)
            #expect(payload.violations.joined(separator: " ").contains("Parse") || payload.violations.joined(separator: " ").contains("parse"))
        }
    }

    @Test
    func `PUT reports the store authoritative loadedFromDisk`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let candidate = UpdatePolicyRequest(policy: structuredPolicyDTO())
            let response = try await policyRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            // The response mirrors the shared store instead of assuming the
            // reload, so the dashboard and the supervisor never diverge.
            let authoritative = await store.loadedFromDisk
            #expect(payload.loadedFromDisk == authoritative)
            #expect(authoritative == true)
            #expect(payload.violations.isEmpty)
            let saved = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(saved.contains("93.184.216.34"))
        }
    }

    @Test
    func `PUT refuses separator, userinfo, fragment, and port domain shapes at the network gate`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // These shapes can never equal a canonicalized URL host, so the
            // boundary refuses them while colon-bearing IPv6 literals stay
            // storable; neither the file nor the live snapshot may move.
            let forbidden = [
                "api.example.com/path",
                "api.example.com\\path",
                "user@example.com",
                "api.example.com#frag",
                "api.example.com:443",
                "*.example.com:443"
            ]
            for entry in forbidden {
                let candidate = UpdatePolicyRequest(policy: structuredPolicyDTO(allowed: [entry]))
                let response = try await policyRequest(
                    app: app, method: .PUT, path: "/settings/policy", body: candidate
                )
                #expect(response.status == .badRequest)
                let reason = response.body.string ?? ""
                #expect(reason.contains("Gate:"))
                #expect(reason.contains("field:"))
            }

            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
        }
    }

    @Test
    func `PUT accepts colon-bearing IPv6 domains and bracketed IPv6 binding hosts`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPolicyRouteApp(store: store) { app in
            // Unbracketed IPv6 keeps its colons on the network allowlist, and a
            // server-accepted bracketed credential host round-trips, so the
            // REST boundary and the dashboard helper agree on IPv6 shapes.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(
                    allowed: ["2001:db8::1"],
                    blocked: ["fe80::1"],
                    credentials: [
                        "IPV6_KEY": CredentialBindingDTO(
                            allowedHosts: ["[2001:db8::1]"],
                            allowedMethods: ["GET"],
                            allowedPathPrefixes: []
                        )
                    ]
                )
            )
            let response = try await policyRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains == ["2001:db8::1"])
            #expect(payload.policy.network.blockedDomains == ["fe80::1"])
            #expect(payload.policy.credentials["IPV6_KEY"]?.allowedHosts == ["[2001:db8::1]"])
            #expect(payload.violations.isEmpty)
        }
    }
}
