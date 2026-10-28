// Rune Weaver Tests — Settings REST API integration and configuration tests.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
@testable import RuneWeaverTools
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
        #expect(response.containers == config.containers)
        #expect(response.containers.memoryMB == config.containers.memoryMB)
        #expect(response.containers.maxConcurrent == config.containers.maxConcurrent)
        #expect(response.containers.ttlMinutes == config.containers.ttlMinutes)
        #expect(response.memoryEmbeddingModel == config.memory.embeddingModel)
        #expect(response.memoryEmbeddingBackend == config.memory.embeddingBackend)
    }

    @Test
    func `UpdateSettingsRequest modifies config and preserves unmodified fields`() throws {
        var config = RuneWeaverConfig.default
        let update = UpdateSettingsRequest(
            engineName: "Custom Engine",
            logLevel: "debug",
            containers: ContainersSettingsUpdate(
                memoryMB: 1024,
                maxConcurrent: 8,
                ttlMinutes: 30
            )
        )

        try update.apply(to: &config)
        #expect(config.engine.name == "Custom Engine")
        #expect(config.engine.logLevel == "debug")
        #expect(config.containers.memoryMB == 1024)
        #expect(config.containers.maxConcurrent == 8)
        #expect(config.containers.ttlMinutes == 30)
        // Preserved defaults
        #expect(config.llm.defaultProvider == RuneWeaverConfig.default.llm.defaultProvider)
    }

    @Test
    func `Containers delta round-trips via JSON while preserving other sections`() throws {
        var config = RuneWeaverConfig.default
        config.bash.timeoutSeconds = 120
        config.files.denyPatterns = ["custom*"]

        // The dashboard wire shape for a containers edit: camelCase inside
        // the nested object, mirroring the accepted `PUT /settings` body.
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"containers":{"memoryMb":1024,"maxConcurrent":8,"ttlMinutes":30}}"#.utf8)
        )
        #expect(request.containers?.memoryMB == 1024)
        #expect(request.containers?.maxConcurrent == 8)
        #expect(request.containers?.ttlMinutes == 30)

        try request.apply(to: &config)
        try config.validate()
        #expect(config.containers.memoryMB == 1024)
        #expect(config.containers.maxConcurrent == 8)
        #expect(config.containers.ttlMinutes == 30)
        // Untouched sections survive the merge.
        #expect(config.bash.timeoutSeconds == 120)
        #expect(config.files.denyPatterns == ["custom*"])

        // GET mirrors the persisted bounds so the dashboard renders live values.
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.containers.memoryMB == 1024)
        #expect(response.containers.maxConcurrent == 8)
        #expect(response.containers.ttlMinutes == 30)

        // The nested snapshot encodes as one object with camelCase keys so
        // GET and PUT share a single lockstep shape.
        let encoded = try JSONEncoder().encode(response)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains(#""containers""#))
        #expect(text.contains("memoryMb"))
        #expect(!text.contains("memory_mb"))
        let decoded = try JSONDecoder().decode(SettingsResponse.self, from: encoded)
        #expect(decoded.containers == config.containers)
    }

    @Test
    func `ContainersSettingsUpdate decodes and encodes camelCase`() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let camel = try decoder.decode(
            ContainersSettingsUpdate.self,
            from: Data(#"{"memoryMb":1024,"maxConcurrent":8,"ttlMinutes":30}"#.utf8)
        )
        #expect(camel.memoryMB == 1024)
        #expect(camel.maxConcurrent == 8)
        #expect(camel.ttlMinutes == 30)

        let encoded = try encoder.encode(ContainersSettingsUpdate(memoryMB: 1024, maxConcurrent: 8, ttlMinutes: 30))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("memoryMb"))
        #expect(text.contains("maxConcurrent"))
        #expect(text.contains("ttlMinutes"))
        #expect(!text.contains("memory_mb"))
        #expect(!text.contains("max_concurrent"))
        #expect(!text.contains("ttl_minutes"))
    }

    @Test
    func `Containers patch preserves omitted fields and nil patch is a no-op`() throws {
        var config = RuneWeaverConfig.default
        config.containers = ContainersConfig(memoryMB: 1024, maxConcurrent: 8, ttlMinutes: 30)

        try UpdateSettingsRequest(
            containers: ContainersSettingsUpdate(memoryMB: 2048)
        ).apply(to: &config)
        #expect(config.containers.memoryMB == 2048)
        #expect(config.containers.maxConcurrent == 8)
        #expect(config.containers.ttlMinutes == 30)

        let before = config.containers
        try UpdateSettingsRequest(engineName: "Kept Containers").apply(to: &config)
        #expect(config.containers == before)
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
        // Single cross-language contract: the server owns `maxSecretStatusKeys` and the dashboard
        // mirrors `SECRET_STATUS_CHUNK_SIZE` in `Web/src/components/SettingsManager.tsx`.
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
    func `BashSettingsUpdate decodes and encodes camelCase`() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // CamelCase mirrors the wire contract.
        let camelPayload = "{\"defaultAction\":\"deny\",\"timeoutSeconds\":120,\"allowNetwork\":true}"
        let camel = try decoder.decode(
            BashSettingsUpdate.self,
            from: Data(camelPayload.utf8)
        )
        #expect(camel.defaultAction == "deny")
        #expect(camel.timeoutSeconds == 120)
        #expect(camel.allowNetwork == true)

        // Encode emits camelCase.
        let encoded = try encoder.encode(
            BashSettingsUpdate(defaultAction: "deny", timeoutSeconds: 120, allowNetwork: true)
        )
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("defaultAction"))
        #expect(text.contains("timeoutSeconds"))
        #expect(text.contains("allowNetwork"))
        #expect(!text.contains("default_action"))
        #expect(!text.contains("timeout_seconds"))
        #expect(!text.contains("allow_network"))
    }

    @Test
    func `Bash cpuSeconds delta preserves other bash keys`() throws {
        var config = RuneWeaverConfig.default
        config.bash.enabled = false
        config.bash.defaultAction = .deny
        config.bash.rules = [
            BashRule(pattern: "git *", action: .allow),
            BashRule(pattern: "*", action: .ask)
        ]
        config.bash.timeoutSeconds = 120
        config.bash.cpuSeconds = 120
        config.bash.memoryMB = 1024
        config.bash.allowNetwork = true

        // The dashboard wire shape for a single-knob edit: camelCase inside
        // the bash object, mirroring the accepted `PUT /settings` body.
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"bash":{"cpuSeconds":60}}"#.utf8)
        )
        #expect(request.bash?.cpuSeconds == 60)
        #expect(request.bash?.memoryMb == nil)

        try request.apply(to: &config)
        try config.validate()
        #expect(config.bash.cpuSeconds == 60)
        #expect(config.bash.enabled == false)
        #expect(config.bash.defaultAction == .deny)
        #expect(config.bash.rules.count == 2)
        #expect(config.bash.timeoutSeconds == 120)
        #expect(config.bash.memoryMB == 1024)
        #expect(config.bash.allowNetwork == true)

        // GET mirrors the persisted bound so the dashboard shows the live value.
        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.bash.cpuSeconds == 60)
        #expect(response.bash.memoryMB == 1024)
    }

    @Test
    func `BashSettingsUpdate snapshot init carries resource bounds`() {
        var bash = BashConfig()
        bash.cpuSeconds = 60
        bash.memoryMB = 512

        // A caller holding a complete policy reuses the merge path without
        // hand-mapping the new bounds.
        let patch = BashSettingsUpdate(bash: bash)
        #expect(patch.cpuSeconds == 60)
        #expect(patch.memoryMb == 512)
        #expect(patch.timeoutSeconds == bash.timeoutSeconds)
        #expect(patch.allowNetwork == bash.allowNetwork)
    }

    @Test
    func `UpdateSettingsRequest rejects out-of-range bash cpu_seconds`() throws {
        // A zero budget would kill every command instantly and an unbounded one
        // holds a run past any plausible shell turn, so both fail closed with
        // the dotted field the route maps to 400.
        for invalid in [0, -5, 3601] {
            var config = RuneWeaverConfig.default
            let preserved = config.bash
            do {
                try UpdateSettingsRequest(
                    bash: BashSettingsUpdate(cpuSeconds: invalid)
                ).apply(to: &config)
                Issue.record("Expected a validation error for bash cpu_seconds \(invalid)")
            } catch let error as ConfigError {
                guard case let .validationError(field, _) = error, field == "bash.cpu_seconds" else {
                    Issue.record("Expected bash.cpu_seconds validation, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ConfigError, got \(type(of: error))")
            }
            #expect(config.bash == preserved)
        }

        // Documented edges still save, matching the TOML load path.
        var edges = RuneWeaverConfig.default
        try UpdateSettingsRequest(
            bash: BashSettingsUpdate(cpuSeconds: 1)
        ).apply(to: &edges)
        try UpdateSettingsRequest(
            bash: BashSettingsUpdate(cpuSeconds: 3600)
        ).apply(to: &edges)
        try edges.validate()
        #expect(edges.bash.cpuSeconds == 3600)
    }

    @Test
    func `UpdateSettingsRequest rejects out-of-range bash memory_mb`() throws {
        // A trivially small budget fails every spawn and a host-scale one
        // invites OOM swaps, so both fail closed with the dotted field the
        // route maps to 400.
        for invalid in [0, 63, 8193] {
            var config = RuneWeaverConfig.default
            let preserved = config.bash
            do {
                try UpdateSettingsRequest(
                    bash: BashSettingsUpdate(memoryMb: invalid)
                ).apply(to: &config)
                Issue.record("Expected a validation error for bash memory_mb \(invalid)")
            } catch let error as ConfigError {
                guard case let .validationError(field, _) = error, field == "bash.memory_mb" else {
                    Issue.record("Expected bash.memory_mb validation, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ConfigError, got \(type(of: error))")
            }
            #expect(config.bash == preserved)
        }

        // Documented edges still save, matching the TOML load path.
        var edges = RuneWeaverConfig.default
        try UpdateSettingsRequest(
            bash: BashSettingsUpdate(memoryMb: 64)
        ).apply(to: &edges)
        try UpdateSettingsRequest(
            bash: BashSettingsUpdate(memoryMb: 8192)
        ).apply(to: &edges)
        try edges.validate()
        #expect(edges.bash.memoryMB == 8192)
    }

    @Test
    func `Bash resource bounds decodes and encodes camelCase`() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let camel = try decoder.decode(
            BashSettingsUpdate.self,
            from: Data(#"{"cpuSeconds":60,"memoryMb":512}"#.utf8)
        )
        #expect(camel.cpuSeconds == 60)
        #expect(camel.memoryMb == 512)

        let encoded = try encoder.encode(BashSettingsUpdate(cpuSeconds: 60, memoryMb: 512))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("cpuSeconds"))
        #expect(text.contains("memoryMb"))
        #expect(!text.contains("cpu_seconds"))
        #expect(!text.contains("memory_mb"))
    }

    @Test
    func `Workspace delta round-trips while preserving other sections`() throws {
        var config = RuneWeaverConfig.default
        config.workspace = WorkspaceConfig(quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 7)
        config.bash.timeoutSeconds = 120
        config.files.denyPatterns = ["custom*"]

        // The dashboard wire shape for a single-knob edit.
        let request = try JSONDecoder().decode(
            UpdateSettingsRequest.self,
            from: Data(#"{"workspace":{"quotaMB":100}}"#.utf8)
        )
        #expect(request.workspace?.quotaMB == 100)
        #expect(request.workspace?.quotaFiles == nil)
        #expect(request.workspace?.tmpTTLDays == nil)

        try request.apply(to: &config)
        try config.validate()
        #expect(config.workspace.quotaMB == 100)
        #expect(config.workspace.quotaFiles == 10000)
        #expect(config.workspace.tmpTTLDays == 7)
        // Untouched sections survive the merge.
        #expect(config.bash.timeoutSeconds == 120)
        #expect(config.files.denyPatterns == ["custom*"])

        let response = SettingsResponse(config: config, configPath: "/test/config.toml")
        #expect(response.workspace.quotaMB == 100)
        #expect(response.workspace.quotaFiles == 10000)
        #expect(response.workspace.tmpTTLDays == 7)
        #expect(response.bash.timeoutSeconds == 120)
    }

    @Test
    func `Workspace quotas survive a save and reload through the settings merge`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings_workspace_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Quotas written through the same merge the route uses must reload
        // intact, so a quota save is durable rather than live-only.
        let fileURL = tempDir.appendingPathComponent("config.toml")
        var config = RuneWeaverConfig.default
        try UpdateSettingsRequest(
            workspace: WorkspaceUpdate(quotaMB: 100, tmpTTLDays: 3)
        ).apply(to: &config)
        try config.save(to: fileURL)

        let reloaded = try RuneWeaverConfig.load(from: fileURL)
        #expect(reloaded.workspace.quotaMB == 100)
        #expect(reloaded.workspace.quotaFiles == WorkspaceConfig.defaultQuotaFiles)
        #expect(reloaded.workspace.tmpTTLDays == 3)
        #expect(SettingsResponse(config: reloaded, configPath: fileURL.path).workspace.quotaMB == 100)
    }

    @Test
    func `UpdateSettingsRequest rejects out-of-range workspace quotas`() {
        // Each bound mirrors the loader contract: below the floor the scratch
        // cannot fit a working checkout, above the ceiling it rivals the index
        // scale, and a bad TTL either never prunes or reads as storage.
        let cases: [(WorkspaceUpdate, String)] = [
            (WorkspaceUpdate(quotaMB: 9), "workspace.quota_mb"),
            (WorkspaceUpdate(quotaMB: 10241), "workspace.quota_mb"),
            (WorkspaceUpdate(quotaFiles: 99), "workspace.quota_files"),
            (WorkspaceUpdate(quotaFiles: 100_001), "workspace.quota_files"),
            (WorkspaceUpdate(tmpTTLDays: -1), "workspace.tmp_ttl_days"),
            (WorkspaceUpdate(tmpTTLDays: 91), "workspace.tmp_ttl_days")
        ]
        for (patch, field) in cases {
            var config = RuneWeaverConfig.default
            let preserved = config.workspace
            do {
                try UpdateSettingsRequest(workspace: patch).apply(to: &config)
                Issue.record("Expected a validation error for \(field)")
            } catch let error as ConfigError {
                guard case let .validationError(actual, _) = error, actual == field else {
                    Issue.record("Expected \(field) validation, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ConfigError, got \(type(of: error))")
            }
            #expect(config.workspace == preserved)
        }
    }

    @Test
    func `WorkspaceUpdate decodes and encodes camelCase`() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // CamelCase mirrors the dashboard contract.
        let camel = try decoder.decode(
            WorkspaceUpdate.self,
            from: Data(#"{"quotaMB":100,"quotaFiles":200,"tmpTTLDays":3}"#.utf8)
        )
        #expect(camel.quotaMB == 100)
        #expect(camel.quotaFiles == 200)
        #expect(camel.tmpTTLDays == 3)

        // Encode emits camelCase.
        let encoded = try encoder.encode(WorkspaceUpdate(quotaMB: 100, quotaFiles: 200, tmpTTLDays: 3))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("quotaMB"))
        #expect(text.contains("quotaFiles"))
        #expect(text.contains("tmpTTLDays"))
        #expect(!text.contains("quota_mb"))
        #expect(!text.contains("quota_files"))
        #expect(!text.contains("tmp_ttl_days"))
    }

    @Test
    func `UpdateSettingsRequest without bash or workspace keys leaves both sections equivalent`() throws {
        var config = RuneWeaverConfig.default
        config.bash.cpuSeconds = 60
        config.bash.memoryMB = 512
        config.workspace.quotaMB = 100
        let beforeBash = config.bash
        let beforeWorkspace = config.workspace

        // A full-form PUT carrying unrelated keys must not disturb either section: the merge is a
        // no-op for absent patches.
        try UpdateSettingsRequest(engineName: "Kept Sections").apply(to: &config)
        #expect(config.bash == beforeBash)
        #expect(config.workspace == beforeWorkspace)
    }

    @Test
    func `Workspace quota decrease bites the next exec without restart`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("settings_workspace_live_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Fill past the decreased file quota: the floor is 100 files, so 101
        // tiny markers exceed it while staying instant to create.
        for index in 0 ..< 101 {
            try "x".write(
                to: root.appendingPathComponent("marker-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        // Baseline quotas still allow the tree.
        let baseline = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
        try await baseline.checkQuota()

        // A settings save lowering only the file quota validates and merges
        // like the route, then threads through a rebuilt shell exactly like
        // the live reload: a fresh store from the merged config.
        var config = RuneWeaverConfig.default
        try UpdateSettingsRequest(workspace: WorkspaceUpdate(quotaFiles: 100)).apply(to: &config)
        try config.validate()
        #expect(config.workspace.quotaFiles == 100)
        #expect(config.workspace.quotaMB == WorkspaceConfig.defaultQuotaMB)

        let live = WorkspaceStore(config: config.workspace, rootURL: root)
        do {
            try await live.checkQuota()
            Issue.record("Expected the decreased quota to refuse the over-quota tree")
        } catch WorkspaceError.quotaExceeded {
            #expect(true)
        } catch {
            Issue.record("Expected quotaExceeded, got \(error)")
        }
        var bash = BashConfig(
            defaultAction: .allow,
            rules: [BashRule(pattern: "*", action: .allow)]
        )
        bash.cpuSeconds = 60
        bash.memoryMB = 512
        let tool = BashTool(
            bashConfig: bash,
            filesConfig: FilesConfig(),
            workspaceConfig: config.workspace,
            workspaceStore: live
        )
        #expect(tool.bashConfig.cpuSeconds == 60)
        #expect(tool.bashConfig.memoryMB == 512)
        let output = try await tool.execute(
            input: ToolInput(toolName: "bash.exec", argumentsJSON: #"{"command":"echo hi"}"#),
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(output.isError)
        #expect(output.content.contains("Workspace quota exceeded"))
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
    func `FanOutSettingsUpdate decodes camelCase wire keys`() throws {
        // The dashboard PUT sends `{"fanout":{"maxWorkers":5}}`; the patch
        // must land on the workers knob while the omitted knobs stay nil so
        // the merge preserves them instead of resetting.
        let payload = #"{"fanout":{"maxWorkers":5}}"#
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
        // never widens other rows; the bash and files policies moved to the
        // Access surface, so no files row exposes its own Configure action.
        let filesTools = FilesTools.makeTools(filesConfig: FilesConfig())
        for filesTool in filesTools {
            let listed = buildToolInfo(for: filesTool, isEnabled: true, recordByPluginID: [:])
            #expect(listed.hasConfig == false)
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
        let context = makeRouteContext(
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

        // ...and so must api.request: triage files ephemeral grants on the boot actor, so binding a
        // freshly built supervisor would make an approved allowOnce/allowSession retry check a
        // different actor and fail as unlisted.
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
    func `Policy exemption reaches the rebuilt gateway origins`() async throws {
        // A stored local exemption must ride the merged origins into the
        // rebuilt browser gateway and the web.fetch initial guard, so boot
        // and settings-save paths agree on the effective set.
        let toml = """
        version = 1
        [network]
        mode = "allowlist_only"
        allowed_domains = ["127.0.0.1"]
        blocked_domains = ["169.254.169.254"]
        local_exemptions = ["192.168.1.10"]
        """
        let (store, _, directory) = try await makePolicyRouteStore(contents: toml)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storedExemptions = try await store.snapshot().network.localExemptions
        #expect(storedExemptions == ["192.168.1.10"])
        let bootSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let base = ServerContext.fallbackUnconfigured
        let context = makeRouteContext(
            store: store,
            egressSupervisor: bootSupervisor,
            toolBus: ToolBus(permissionGate: base.permissionGate)
        )
        var config = RuneWeaverConfig.default
        let body = UpdateSettingsRequest(browserTimeoutSeconds: 45)
        try body.apply(to: &config)
        try await reloadLiveNetworkTools(body: body, config: config, context: context)
        let navigate = try #require(await context.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool)
        let gateway = try #require(navigate.browserGateway as? SubprocessPlaywrightGateway)
        // The merged set carries the policy exemption alongside the
        // config-derived searxng origin.
        #expect(gateway.allowlistedOrigins.contains("192.168.1.10"))
        #expect(gateway.egressSupervisor === bootSupervisor)
        // The web.fetch initial guard honors the same merged set: the
        // private literal clears only when the extra origins name it.
        let guarded = await WebFetchSSRFGuard.denyReasonAsync(
            for: "http://192.168.1.10/status",
            browserConfig: config.browser,
            mediaConfig: config.media,
            extraAllowlistedOrigins: gateway.allowlistedOrigins
        )
        #expect(guarded == nil)
        let unguarded = await WebFetchSSRFGuard.denyReasonAsync(
            for: "http://192.168.1.10/status",
            browserConfig: config.browser,
            mediaConfig: config.media
        )
        #expect(unguarded != nil)
        // The policy-save refresh rebuilds through the same merged origins
        // without a settings body, so a committed exemption lands live.
        let refreshContext = makeRouteContext(
            store: store,
            egressSupervisor: bootSupervisor,
            toolBus: ToolBus(permissionGate: base.permissionGate)
        )
        await refreshNetworkToolsAfterPolicySave(context: refreshContext)
        let refreshedNavigate = try #require(await refreshContext.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool)
        let refreshedGateway = try #require(refreshedNavigate.browserGateway as? SubprocessPlaywrightGateway)
        #expect(refreshedGateway.allowlistedOrigins.contains("192.168.1.10"))
        #expect(refreshedGateway.egressSupervisor === bootSupervisor)
    }

    @Test
    func `Non-network settings update triggers no live network reload`() async throws {
        // A PUT carrying only non-network fields must not rebuild network tools and must not write
        // exemptions: no gateway may appear on a fresh bus, the store keeps no exemption, and a
        // later rebuild for a network knob carries only expected entries.
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let base = ServerContext.fallbackUnconfigured

        let idleContext = makeRouteContext(
            store: store,
            egressSupervisor: bootSupervisor,
            toolBus: ToolBus(permissionGate: base.permissionGate)
        )
        var idleConfig = RuneWeaverConfig.default
        let idleBody = UpdateSettingsRequest(engineName: "NewName")
        try idleBody.apply(to: &idleConfig)
        try await reloadLiveNetworkTools(body: idleBody, config: idleConfig, context: idleContext)
        #expect(await idleContext.toolBus.tool(named: "browser.navigate") == nil)
        #expect(await idleContext.toolBus.tool(named: "web.fetch") == nil)
        #expect(await idleContext.toolBus.tool(named: "api.request") == nil)
        #expect(try await store.snapshot().network.localExemptions.isEmpty)

        // Control: the timeout knob still rebuilds through the same path.
        let liveContext = makeRouteContext(
            store: store,
            egressSupervisor: bootSupervisor,
            toolBus: ToolBus(permissionGate: base.permissionGate)
        )
        var liveConfig = RuneWeaverConfig.default
        let liveBody = UpdateSettingsRequest(browserTimeoutSeconds: 45)
        try liveBody.apply(to: &liveConfig)
        try await reloadLiveNetworkTools(body: liveBody, config: liveConfig, context: liveContext)
        let navigate = try #require(await liveContext.toolBus.tool(named: "browser.navigate") as? BrowserNavigateTool)
        let gateway = try #require(navigate.browserGateway as? SubprocessPlaywrightGateway)
        #expect(gateway.egressSupervisor === bootSupervisor)
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

    @Test
    func `LLM provider switch applies live with health reflecting new provider`() async throws {
        // An `[llm]` save carrying a provider/default change must reach the live
        // orchestrator without a restart, so the next health probe reports the
        // new model while the response claims no restart.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rw-llm-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("episodes.db").path
        let conversations = ConversationManager()
        let gate = PermissionGate()
        let approvals = ApprovalQueue(permissionGate: gate)
        let bus = ToolBus(permissionGate: gate)
        let steering = SteeringQueue()
        let initial = LLMLiveReloadStub(modelName: "live-reload-before", providerName: "before")
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: bus,
            llm: initial,
            steeringQueue: steering
        )
        let memory = MemoryEngine(
            episodesDBPath: dbPath,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        let context = ServerContext(
            conversations: conversations,
            toolBus: bus,
            orchestrator: orchestrator,
            memoryEngine: memory,
            permissionGate: gate,
            approvals: approvals,
            steeringQueue: steering,
            servingLLM: initial
        )
        #expect(await orchestrator.modelInfo.name == "live-reload-before")

        // Two OpenAI-compatible entries keep distinct router names so the
        // default switch selects deterministically.
        var config = RuneWeaverConfig.default
        config.llm.providers = [
            "before": ProviderConfig(enabled: true, model: "live-reload-before"),
            "after": ProviderConfig(enabled: true, model: "live-reload-after")
        ]
        config.llm.defaultProvider = "before"
        config.llm.fallbackProvider = nil

        let body = UpdateSettingsRequest(defaultProvider: "after")
        #expect(body.carriesServerPatch == false)
        var merged = config
        try body.apply(to: &merged)
        try merged.validate()
        #expect(merged.llm.defaultProvider == "after")

        // Drives the same prepare/apply path the settings save uses.
        let swap = try await prepareLiveLLMSwap(config: merged, context: context)
        await applyLiveLLMSwap(swap, context: context)
        let live = await orchestrator.modelInfo
        #expect(live.name == "live-reload-after")
        #expect(live.provider == "after")
        #expect(context.servingLLM?.modelInfo.name == "live-reload-after")

        // An LLM-only patch never joins the restart set.
        let bootHeld = body.goals != nil || body.proactive != nil || body.ideas != nil || body.persona != nil
        #expect(bootHeld == false)
        #expect(SettingsResponse(config: merged, configPath: "/test/config.toml", requiresRestart: false).requiresRestart == false)

        let app = try await Application.make(.testing)
        do {
            app.runeWeaver = context
            registerRuneWeaverRoutes(app)
            let request = Request(
                application: app,
                method: .GET,
                url: URI(string: "/health"),
                on: app.eventLoopGroup.next()
            )
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let health = try response.content.decode(HealthResponse.self)
            #expect(health.model == "live-reload-after")
            #expect(health.provider == "after")
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

// MARK: - Shared Settings Route Helpers

/// Builds the lean route context for the settings policy and secrets surfaces.
private func makeRouteContext(
    store: PolicyStore? = nil,
    egressSupervisor: OutboundEgressSupervisor? = nil,
    toolBus: ToolBus? = nil,
    secrets: SecretsManager? = nil
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
        secrets: secrets,
        policyStore: store ?? base.policyStore,
        egressSupervisor: egressSupervisor
    )
}

/// Runs one test body against an application serving the settings routes. store:
/// The policy store the routes must serve; defaults to the fallback store.
private func withRouteApp<T>(
    store: PolicyStore? = nil,
    secrets: SecretsManager? = nil,
    _ body: (Application) async throws -> T
) async throws -> T {
    let app = try await Application.make(.testing)
    do {
        app.runeWeaver = makeRouteContext(store: store, secrets: secrets)
        registerRuneWeaverRoutes(app)
        let value = try await body(app)
        try await app.asyncShutdown()
        return value
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Sends one in-process request through the registered settings routes. app:
/// Configured application.
private func settingsRequest(
    app: Application,
    method: HTTPMethod,
    path: String,
    body: some Content?
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

/// Sends one in-process bodyless request through the registered settings routes.
/// app: Configured application.
private func settingsRequest(
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

// MARK: - Settings Secrets Routes

@Suite("Settings Secrets Routes")
struct SettingsSecretsRouteTests {
    @Test
    func `POST /settings/secrets stores the secret and answers 204`() async throws {
        // The dashboard accepts only a bodyless 204 as success, so the bare 200 this route used to
        // answer surfaced as `Invalid JSON response` even after the Keychain write landed.
        let secrets = SecretsManager(inMemory: true)
        let key = "RW_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")

        try await withRouteApp(secrets: secrets) { app in
            let response = try await settingsRequest(
                app: app,
                method: .POST,
                path: "/settings/secrets",
                body: StoreSecretRequest(key: key, secret: "s3cret-value")
            )
            #expect(response.status == .noContent)
            #expect((response.body.string ?? "").isEmpty)
            #expect(response.headers.first(name: "Cache-Control") == "no-store, private")
            #expect(try await secrets.retrieve(key: key) == "s3cret-value")
        }
    }

    @Test
    func `DELETE /settings/secrets/:key removes the secret and answers 204`() async throws {
        // A pre-seeded value proves the route removed bytes rather than only answering a status;
        // the unique key keeps a same-named environment variable from faking a retrieval.
        let secrets = SecretsManager(inMemory: true)
        let key = "RW_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        try await secrets.store(key: key, secret: "to-delete")

        try await withRouteApp(secrets: secrets) { app in
            let response = try await settingsRequest(
                app: app,
                method: .DELETE,
                path: "/settings/secrets/\(key)"
            )
            #expect(response.status == .noContent)
            #expect((response.body.string ?? "").isEmpty)
            #expect(response.headers.first(name: "Cache-Control") == "no-store, private")
            #expect(try await (secrets.retrieve(key: key) ?? "").isEmpty)
        }
    }

    @Test
    func `GET /settings/secrets returns empty list with no-store header when nothing stored`() async throws {
        // An empty store lists no names while keeping the names-only shape and
        // the non-cacheable header every secrets response carries.
        let secrets = SecretsManager(inMemory: true)

        try await withRouteApp(secrets: secrets) { app in
            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/secrets")
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "Cache-Control") == "no-store, private")
            let payload = try response.content.decode(SecretListResponse.self)
            #expect(payload.keys == [])
        }
    }

    @Test
    func `GET /settings/secrets lists stored keys sorted without values on the wire`() async throws {
        // Stored keys surface sorted by name while secret bytes never reach the
        // body; the shared prefix keeps the environment from faking a hit.
        let secrets = SecretsManager(inMemory: true)
        let base = "RW_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let keyB = base + "_B"
        let keyA = base + "_A"
        try await secrets.store(key: keyB, secret: "second-secret")
        try await secrets.store(key: keyA, secret: "first-secret")

        try await withRouteApp(secrets: secrets) { app in
            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/secrets")
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "Cache-Control") == "no-store, private")
            let payload = try response.content.decode(SecretListResponse.self)
            #expect(payload.keys == [keyA, keyB])
            let body = response.body.string ?? ""
            #expect(!body.contains("first-secret"))
            #expect(!body.contains("second-secret"))
        }
    }

    @Test
    func `GET /settings/secrets omits deleted keys`() async throws {
        // A deleted name vanishes from the next listing while the surviving
        // name stays listed; values stay off the wire on the follow-up read.
        let secrets = SecretsManager(inMemory: true)
        let base = "RW_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let kept = base + "_KEPT"
        let removed = base + "_GONE"
        try await secrets.store(key: kept, secret: "kept-secret")
        try await secrets.store(key: removed, secret: "gone-secret")
        try await secrets.delete(key: removed)

        try await withRouteApp(secrets: secrets) { app in
            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/secrets")
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "Cache-Control") == "no-store, private")
            let payload = try response.content.decode(SecretListResponse.self)
            #expect(payload.keys == [kept])
            #expect(!payload.keys.contains(removed))
            let body = response.body.string ?? ""
            #expect(!body.contains("kept-secret"))
            #expect(!body.contains("gone-secret"))
        }
    }
}

// MARK: - Security Policy Routes

/// Stub provider pinning one model identity so the live-reload test proves a switch without the network.
private struct LLMLiveReloadStub: LLMProvider, Sendable {
    /// Fixed model identity served before the switch.
    let modelInfo: ModelInfo

    /// Pins the stub to one model identity.
    init(modelName: String, providerName: String) {
        self.modelInfo = ModelInfo(name: modelName, provider: providerName, contextLength: 8192)
    }

    /// Never runs a turn in these tests.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        AsyncStream { $0.finish() }
    }

    /// Unused embeddings stub.
    func embeddings(text _: [String]) async throws -> [[Float]] {
        []
    }
}

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

/// Builds an isolated policy store over a throwaway directory and loads it. The route tests must
/// exercise the real file read/write boundary, so the store points at a temp `policy.toml` instead
/// of the operator's file.
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

/// Retired raw-TOML body shape, kept so the migration signal stays pinned:
/// the server must reject it with a 400 naming the field instead of
/// persisting unvalidated text.
private struct RetiredRawTOMLPolicyBody: Content {
    /// Legacy raw document the structured contract no longer accepts.
    let raw_toml: String
}

/// Snake-case credential body for the fallback PUT probe.
private struct SnakeCredentialBody: Content {
    let allowed_hosts: [String]
    let allowed_methods: [String]
    let allowed_path_prefixes: [String]
}

/// Snake-case network body for the fallback PUT probe.
private struct SnakeNetworkBody: Content {
    let mode: String
    let allowed_domains: [String]
    let blocked_domains: [String]
}

/// Snake-case policy body for the fallback PUT probe.
private struct SnakePolicyBody: Content {
    let version: Int
    let network: SnakeNetworkBody
    let credentials: [String: SnakeCredentialBody]
}

/// Snake-case update body for the fallback PUT probe.
private struct SnakeUpdatePolicyBody: Content {
    let policy: SnakePolicyBody
}

/// Builds one structured policy DTO for PUT and verify probes. mode: Wire mode
/// string.
private func structuredPolicyDTO(
    mode: String = "allowlist_only",
    allowed: [String] = ["93.184.216.34"],
    blocked: [String] = ["169.254.169.254"],
    credentials: [String: CredentialBindingDTO] = [:],
    version: Int = 1,
    localExemptions: [String] = []
) -> SecurityPolicyDTO {
    SecurityPolicyDTO(
        version: version,
        network: NetworkEgressPolicyDTO(
            mode: mode,
            allowedDomains: allowed,
            blockedDomains: blocked,
            localExemptions: localExemptions
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

        try await withRouteApp(store: store) { app in
            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/policy")
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

        try await withRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // An old editor sending unvalidated text must learn the new
            // contract: the 400 names the retired field, and neither the
            // file nor the live snapshot moves.
            for legacy in [
                RetiredRawTOMLPolicyBody(raw_toml: "version = 1\n[network]\nmode = \"unrestricted\"\n")
            ] {
                let response = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
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
                let response = try await settingsRequest(
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

            // Retired mode name is refused as invalid.
            let legacyResponse = try await settingsRequest(
                app: app,
                method: .PUT,
                path: "/settings/policy",
                body: UpdatePolicyRequest(policy: structuredPolicyDTO(mode: "deny_by_default"))
            )
            #expect(legacyResponse.status == .badRequest)
        }
    }

    @Test
    func `PUT refuses an invariant violation and leaves the file and live store untouched`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
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
            let response = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
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
            let response = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
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
            let putResponse = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(putResponse.status == .ok)

            let getResponse = try await settingsRequest(app: app, method: .GET, path: "/settings/policy")
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

        try await withRouteApp(store: store) { app in
            let candidate = UpdatePolicyRequest(policy: structuredPolicyDTO())
            let putResponse = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            let candidate = VerifyPolicyRequest(
                policy: structuredPolicyDTO(mode: "unrestricted", allowed: [], blocked: ["169.254.169.254"])
            )
            let response = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)

            // A structural refusal names the gate and field so the editor can
            // repair the exact entry; the verdict stays invalid either way.
            let structural = try await settingsRequest(
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
            let violating = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let rejected = try await settingsRequest(
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
        // A present-but-rejected file keeps the safe fallback in `current`, so verifying the
        // fallback would report zero violations while the CLI exits nonzero for the same file.
        let violating = "[credentials.LEAK]\nallowed_hosts = [\"*\"]\n"
        let (store, fileURL, directory) = try await makePolicyRouteStore(contents: violating)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await store.loadedFromDisk == false)

        try await withRouteApp(store: store) { app in
            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/policy")
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

        try await withRouteApp(store: store) { app in
            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/policy")
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

        try await withRouteApp(store: store) { app in
            let candidate = UpdatePolicyRequest(policy: structuredPolicyDTO())
            let response = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
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
                let response = try await settingsRequest(
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

        try await withRouteApp(store: store) { app in
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
            let response = try await settingsRequest(
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

    @Test
    func `PUT accepts snake_case wire and GET returns camelCase`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // Raw snake wire from an older draft must persist without wiping
            // the candidate, covering network lists plus binding lists.
            let rawSnake = #"{"policy":{"version":1,"network":{"mode":"allowlist_only","allowed_domains":["api.example.com"],"blocked_domains":["blocked.example.com"]},"credentials":{"API_KEY":{"allowed_hosts":["api.example.com"],"allowed_methods":["GET"],"allowed_path_prefixes":["/v1"]}}}}"#
            let decoded = try JSONDecoder().decode(UpdatePolicyRequest.self, from: Data(rawSnake.utf8))
            #expect(decoded.policy.network.allowedDomains == ["api.example.com"])
            #expect(decoded.policy.network.blockedDomains == ["blocked.example.com"])
            #expect(decoded.policy.credentials["API_KEY"]?.allowedHosts == ["api.example.com"])

            // Mixed spellings prefer camel so a partial migration never
            // silently swaps in the legacy value.
            let rawMixed = #"{"policy":{"version":1,"network":{"mode":"allowlist_only","allowedDomains":["camel.example.com"],"allowed_domains":["snake.example.com"],"blocked_domains":[]},"credentials":{"API_KEY":{"allowedHosts":["camel.example.com"],"allowed_hosts":["snake.example.com"],"allowed_methods":[],"allowed_path_prefixes":[]}}}}"#
            let mixed = try JSONDecoder().decode(UpdatePolicyRequest.self, from: Data(rawMixed.utf8))
            #expect(mixed.policy.network.allowedDomains == ["camel.example.com"])
            #expect(mixed.policy.credentials["API_KEY"]?.allowedHosts == ["camel.example.com"])

            // Missing keys default to empty so validation still gates shape.
            let rawEmpty = #"{"policy":{"version":1,"network":{"mode":"allowlist_only"},"credentials":{}}}"#
            let empty = try JSONDecoder().decode(UpdatePolicyRequest.self, from: Data(rawEmpty.utf8))
            #expect(empty.policy.network.allowedDomains == [])
            #expect(empty.policy.network.blockedDomains == [])

            // The route accepts the same snake shape on the wire.
            let snake = SnakeUpdatePolicyBody(
                policy: SnakePolicyBody(
                    version: 1,
                    network: SnakeNetworkBody(
                        mode: "allowlist_only",
                        allowed_domains: ["api.example.com"],
                        blocked_domains: ["blocked.example.com"]
                    ),
                    credentials: [
                        "API_KEY": SnakeCredentialBody(
                            allowed_hosts: ["api.example.com"],
                            allowed_methods: ["GET"],
                            allowed_path_prefixes: ["/v1"]
                        )
                    ]
                )
            )
            // Hostnames classify via DNS, so stub to a public IP
            // to keep the probe hermetic without live resolution.
            let dnsProof: @Sendable (String) -> [String] = { _ in ["93.184.216.34"] }
            let response = try await ApiSSRFGuard.$taskTestDNSResolver.withValue(dnsProof) {
                try await settingsRequest(
                    app: app, method: .PUT, path: "/settings/policy", body: snake
                )
            }
            #expect(response.status == .ok)
            let stored = try await store.snapshot()
            #expect(stored.network.allowedDomains == ["api.example.com"])
            #expect(stored.network.blockedDomains == ["blocked.example.com"])
            #expect(stored.credentials["API_KEY"]?.allowedHosts == ["api.example.com"])

            // GET encodes camelCase only for the dashboard contract.
            let getResponse = try await settingsRequest(app: app, method: .GET, path: "/settings/policy")
            #expect(getResponse.status == .ok)
            let payload = try getResponse.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains == ["api.example.com"])
            #expect(payload.policy.credentials["API_KEY"]?.allowedHosts == ["api.example.com"])
            let bodyText = getResponse.body.string ?? ""
            #expect(bodyText.contains("allowedDomains"))
            #expect(bodyText.contains("allowedHosts"))
            #expect(!bodyText.contains("allowed_domains"))
            #expect(!bodyText.contains("allowed_hosts"))
        }
    }
}

// MARK: - Policy Local Access Classification (PUT)

/// Pins the PUT classification flow: server-derived `localExemptions` with an
/// atomic failure and a report. Only `PUT /settings/policy` (and the future
/// re-check apply) may write the field; every other path leaves it untouched.
@Suite("Settings Policy Local Access")
struct SettingsPolicyLocalAccessTests {
    @Test
    func `PUT grants local access for a newly added internal host and reports it`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // The private literal needs no resolver hop, so the grant proves
            // hermetically without DNS.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10"])
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains.sorted() == ["127.0.0.1", "192.168.1.10"])
            #expect(payload.policy.network.localExemptions == ["192.168.1.10"])
            let report = try #require(payload.localAccess)
            #expect(report.granted == ["192.168.1.10"])
            #expect(report.removed == [])
            #expect(report.neverDialable == [])

            // The stored snapshot and the file agree on the grant, sorted on
            // write per the shared contract.
            let live = try await store.snapshot()
            #expect(live.network.localExemptions == ["192.168.1.10"])
            let saved = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(saved.contains("192.168.1.10"))
            #expect(saved.contains("local_exemptions"))
        }
    }

    @Test
    func `PUT grants nothing for a newly added public destination`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // A public literal settles as `.publicDestination` with no grant.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "93.184.216.34"])
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains.sorted() == ["127.0.0.1", "93.184.216.34"])
            #expect(payload.policy.network.localExemptions == [])
            let report = try #require(payload.localAccess)
            #expect(report.granted == [])
            #expect(report.removed == [])
            #expect(report.neverDialable == [])
            let live = try await store.snapshot()
            #expect(live.network.localExemptions.isEmpty)
        }
    }

    @Test
    func `PUT aborts atomically when an added host cannot resolve`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // `.invalid` never resolves, so classification fails closed to
            // `.unresolved` without a network side effect.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "nonexistent-host-abc123.invalid"])
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .badRequest)
            let reason = response.body.string ?? ""
            #expect(reason.contains("nonexistent-host-abc123.invalid"))
            #expect(reason.contains("Nothing was saved"))
            #expect(reason.contains("Gate: classification"))
            #expect(reason.contains("field: network.allowed_domains"))

            // File plus memory stay unchanged: the abort leaves both agreeing
            // instead of diverging.
            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
            let stored = try await store.snapshot()
            #expect(!stored.network.allowedDomains.contains("nonexistent-host-abc123.invalid"))
            #expect(stored.network.localExemptions.isEmpty)
        }
    }

    @Test
    func `PUT ignores client-supplied localExemptions`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // The pane draft is display-only: even a crafted grant plus a
            // crafted public entry cannot alter the stored set.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(
                    allowed: ["127.0.0.1", "192.168.1.10"],
                    localExemptions: ["evil.example.com", "93.184.216.34"]
                )
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.localExemptions == ["192.168.1.10"])
            #expect(!payload.policy.network.localExemptions.contains("evil.example.com"))
            let report = try #require(payload.localAccess)
            #expect(report.granted == ["192.168.1.10"])
            let live = try await store.snapshot()
            #expect(live.network.localExemptions == ["192.168.1.10"])
        }
    }

    @Test
    func `PUT drops the grant when the entry is deleted`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // Seed one grant through the PUT so the drop path has something to
            // remove.
            let seeded = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10"])
            )
            let seedResponse = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: seeded
            )
            #expect(seedResponse.status == .ok)
            let seededLive = try await store.snapshot()
            #expect(seededLive.network.localExemptions == ["192.168.1.10"])

            // Removing the host drops its grant via the canonical intersect.
            let pruned = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1"])
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: pruned
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains == ["127.0.0.1"])
            #expect(payload.policy.network.localExemptions == [])
            let report = try #require(payload.localAccess)
            #expect(report.granted == [])
            #expect(report.removed == ["192.168.1.10"])
            #expect(report.neverDialable == [])
            let live = try await store.snapshot()
            #expect(live.network.localExemptions.isEmpty)
        }
    }

    @Test
    func `PUT never grants wildcard entries`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // The leading edge authorizes at runtime but is never classified,
            // so it persists name-only with no grant.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "*.example.com"])
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains.sorted() == ["*.example.com", "127.0.0.1"])
            #expect(payload.policy.network.localExemptions == [])
            let report = try #require(payload.localAccess)
            #expect(report.granted == [])
            #expect(report.neverDialable == [])
            let live = try await store.snapshot()
            #expect(live.network.localExemptions.isEmpty)
        }
    }

    @Test
    func `PUT persists never-dialable entries name-only and reports them`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // The metadata hostname refuses before DNS, so the report proves
            // hermetically.
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "metadata.google.internal"])
            )
            let response = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.allowedDomains.sorted() == ["127.0.0.1", "metadata.google.internal"])
            #expect(payload.policy.network.localExemptions == [])
            let report = try #require(payload.localAccess)
            #expect(report.granted == [])
            #expect(report.removed == [])
            #expect(report.neverDialable == ["metadata.google.internal"])
            let live = try await store.snapshot()
            #expect(live.network.allowedDomains.contains("metadata.google.internal"))
            #expect(live.network.localExemptions.isEmpty)
            let saved = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(saved.contains("metadata.google.internal"))
        }
    }

    @Test
    func `GET exposes localExemptions and sends no report`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            let granted = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10"])
            )
            let putResponse = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: granted
            )
            #expect(putResponse.status == .ok)

            let response = try await settingsRequest(app: app, method: .GET, path: "/settings/policy")
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.localExemptions == ["192.168.1.10"])
            #expect(payload.localAccess == nil)
            // The wire emits camelCase and never the snake spelling.
            let bodyText = response.body.string ?? ""
            #expect(bodyText.contains("localExemptions"))
            #expect(!bodyText.contains("local_exemptions"))
        }
    }

    @Test
    func `PUT refreshes network tools after commit`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let base = ServerContext.fallbackUnconfigured
        let freshBus = ToolBus(permissionGate: base.permissionGate)
        let context = makeRouteContext(store: store, egressSupervisor: bootSupervisor, toolBus: freshBus)

        let app = try await Application.make(.testing)
        do {
            app.runeWeaver = context
            registerRuneWeaverRoutes(app)
            let candidate = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10"])
            )
            let request = Request(
                application: app,
                method: .PUT,
                url: URI(string: "/settings/policy"),
                on: app.eventLoopGroup.next()
            )
            try request.content.encode(candidate)
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(payload.policy.network.localExemptions == ["192.168.1.10"])

            // The committed exemption lands live: the rebuilt browser gateway
            // carries it while keeping the boot supervisor for grants.
            let navigate = try #require(await freshBus.tool(named: "browser.navigate") as? BrowserNavigateTool)
            let gateway = try #require(navigate.browserGateway as? SubprocessPlaywrightGateway)
            #expect(gateway.allowlistedOrigins.contains("192.168.1.10"))
            #expect(gateway.egressSupervisor === bootSupervisor)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func `NetworkEgressPolicyDTO emits and decodes camelCase`() throws {
        // The canonical wire shape is camelCase sorted; snake is not emitted.
        let dto = NetworkEgressPolicyDTO(
            mode: "allowlist_only",
            allowedDomains: ["127.0.0.1"],
            blockedDomains: ["169.254.169.254"],
            localExemptions: ["192.168.1.10"]
        )
        let encoded = try JSONEncoder().encode(dto)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("localExemptions"))
        #expect(!text.contains("local_exemptions"))

        let camelPayload = #"{"mode":"allowlist_only","allowedDomains":["127.0.0.1"],"blockedDomains":["169.254.169.254"],"localExemptions":["192.168.1.10"]}"#
        let camel = try JSONDecoder().decode(NetworkEgressPolicyDTO.self, from: Data(camelPayload.utf8))
        #expect(camel.localExemptions == ["192.168.1.10"])
    }

    @Test
    func `validateStructuredPolicyInput ignores client localExemptions`() throws {
        // The server-owned field never flows from the wire into the candidate:
        // even a crafted grant verifies to an empty set.
        let dto = structuredPolicyDTO(
            allowed: ["127.0.0.1"],
            localExemptions: ["192.168.1.10"]
        )
        let candidate = try validateStructuredPolicyInput(dto)
        #expect(candidate.network.localExemptions.isEmpty)
        #expect(candidate.network.allowedDomains == ["127.0.0.1"])
    }
}

// MARK: - Policy Recheck Local Exemptions (Preview + Apply)

/// Pins the re-check preview diff and atomic apply: server-side
/// re-classification of every exact entry with stored wildcard preservation.
@Suite("Settings Policy Recheck Local")
struct SettingsPolicyRecheckLocalTests {
    @Test
    func `ServerPaths defines recheck-local paths`() {
        #expect(ServerPaths.recheckLocal == "recheck-local")
        #expect(ServerPaths.recheckLocalApply == "recheck-local/apply")
    }

    @Test
    func `Preview diffs proposed grants without touching disk or memory`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // Seed two grants through the PUT so the preview has added,
            // removed, and unchanged to report.
            let seeded = UpdatePolicyRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10", "192.168.1.11"])
            )
            let seedResponse = try await settingsRequest(
                app: app, method: .PUT, path: "/settings/policy", body: seeded
            )
            #expect(seedResponse.status == .ok)
            let seededLive = try await store.snapshot()
            #expect(Set(seededLive.network.localExemptions) == ["192.168.1.10", "192.168.1.11"])

            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // Re-check classifies every exact entry, so the loopback joins the
            // proposed set even though the PUT never granted it.
            let previewBody = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10", "192.168.1.12"])
            )
            let response = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local", body: previewBody
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(RecheckLocalExemptionsResponse.self)
            #expect(payload.added == ["127.0.0.1", "192.168.1.12"])
            #expect(payload.removed == ["192.168.1.11"])
            #expect(payload.unchanged == ["192.168.1.10"])
            #expect(payload.unresolved == [])

            // Preview never writes: file plus memory stay agreeing.
            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
            let stored = try await store.snapshot()
            #expect(Set(stored.network.localExemptions) == ["192.168.1.10", "192.168.1.11"])
        }
    }

    @Test
    func `Preview preserves wildcard grants without classifying them`() async throws {
        let toml = """
        version = 1
        [network]
        mode = "allowlist_only"
        allowed_domains = ["127.0.0.1", "*.example.com"]
        blocked_domains = ["169.254.169.254"]
        local_exemptions = ["*.example.com"]
        """
        let (store, _, directory) = try await makePolicyRouteStore(contents: toml)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storedExemptions = try await store.snapshot().network.localExemptions
        #expect(storedExemptions == ["*.example.com"])

        try await withRouteApp(store: store) { app in
            let beforePolicy = await store.current
            let previewBody = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "*.example.com", "192.168.1.10"])
            )
            let response = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local", body: previewBody
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(RecheckLocalExemptionsResponse.self)
            // The wildcard keeps its stored grant without classification while
            // both local literals propose fresh grants.
            #expect(payload.unchanged == ["*.example.com"])
            #expect(payload.added == ["127.0.0.1", "192.168.1.10"])
            #expect(payload.removed == [])
            #expect(payload.unresolved == [])

            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
        }
    }

    @Test
    func `Unresolved preview reports while apply aborts with the store unchanged`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            let before = try String(contentsOf: fileURL, encoding: .utf8)
            let beforePolicy = await store.current

            // `.invalid` never resolves, so preview reports it instead of
            // erroring while still proposing the provable loopback grant.
            let previewBody = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "nonexistent-host-abc123.invalid"])
            )
            let preview = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local", body: previewBody
            )
            #expect(preview.status == .ok)
            let diff = try preview.content.decode(RecheckLocalExemptionsResponse.self)
            #expect(diff.unresolved == ["nonexistent-host-abc123.invalid"])
            #expect(diff.added == ["127.0.0.1"])
            #expect(diff.removed == [])
            #expect(diff.unchanged == [])
            let midFile = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(midFile == before)

            // Apply aborts the whole write atomically with every unresolved
            // entry named and file plus memory unchanged.
            let applyBody = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "nonexistent-host-abc123.invalid"])
            )
            let apply = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local/apply", body: applyBody
            )
            #expect(apply.status == .badRequest)
            let reason = apply.body.string ?? ""
            #expect(reason.contains("nonexistent-host-abc123.invalid"))
            #expect(reason.contains("Nothing was saved"))
            #expect(reason.contains("Gate: classification"))

            let after = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(after == before)
            let livePolicy = await store.current
            #expect(livePolicy == beforePolicy)
            let stored = try await store.snapshot()
            #expect(!stored.network.allowedDomains.contains("nonexistent-host-abc123.invalid"))
            #expect(stored.network.localExemptions.isEmpty)
        }
    }

    @Test
    func `Apply adds and removes grants per the preview and refreshes live tools`() async throws {
        let (store, fileURL, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootSupervisor = try await OutboundEgressSupervisor.make(policyStore: store)
        let base = ServerContext.fallbackUnconfigured
        let freshBus = ToolBus(permissionGate: base.permissionGate)
        let context = makeRouteContext(store: store, egressSupervisor: bootSupervisor, toolBus: freshBus)

        // Seed one grant so the apply has a removal to report alongside its
        // additions.
        let seededPolicy = SecurityPolicy(
            version: 1,
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["127.0.0.1", "192.168.1.10", "192.168.1.11"],
                blockedDomains: ["169.254.169.254"],
                localExemptions: ["192.168.1.10", "192.168.1.11"]
            ),
            credentials: [:]
        )
        try await store.replace(seededPolicy)

        let app = try await Application.make(.testing)
        do {
            app.runeWeaver = context
            registerRuneWeaverRoutes(app)
            // Re-check re-classifies every exact entry, so the loopback joins
            // the final set while the dropped `.11` leaves it.
            let candidate = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "192.168.1.10", "192.168.1.12"])
            )
            let request = Request(
                application: app,
                method: .POST,
                url: URI(string: "/settings/policy/recheck-local/apply"),
                on: app.eventLoopGroup.next()
            )
            try request.content.encode(candidate)
            let response = try await app.responder.respond(to: request).get()
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(Set(payload.policy.network.localExemptions) == ["127.0.0.1", "192.168.1.10", "192.168.1.12"])
            let report = try #require(payload.localAccess)
            #expect(report.granted == ["127.0.0.1", "192.168.1.12"])
            #expect(report.removed == ["192.168.1.11"])
            let live = try await store.snapshot()
            #expect(Set(live.network.localExemptions) == ["127.0.0.1", "192.168.1.10", "192.168.1.12"])
            let saved = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(saved.contains("192.168.1.12"))

            // The committed exemptions land live: the rebuilt browser gateway
            // carries them while keeping the boot supervisor for grants.
            let navigate = try #require(await freshBus.tool(named: "browser.navigate") as? BrowserNavigateTool)
            let gateway = try #require(navigate.browserGateway as? SubprocessPlaywrightGateway)
            #expect(gateway.allowlistedOrigins.contains("192.168.1.12"))
            #expect(gateway.allowlistedOrigins.contains("192.168.1.10"))
            #expect(gateway.egressSupervisor === bootSupervisor)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test
    func `Apply keeps wildcard grants while adding fresh local grants`() async throws {
        let toml = """
        version = 1
        [network]
        mode = "allowlist_only"
        allowed_domains = ["127.0.0.1", "*.example.com"]
        blocked_domains = ["169.254.169.254"]
        local_exemptions = ["*.example.com"]
        """
        let (store, _, directory) = try await makePolicyRouteStore(contents: toml)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            let candidate = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(allowed: ["127.0.0.1", "*.example.com", "192.168.1.10"])
            )
            let response = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local/apply", body: candidate
            )
            #expect(response.status == .ok)
            let payload = try response.content.decode(PolicyResponse.self)
            #expect(Set(payload.policy.network.localExemptions) == ["*.example.com", "127.0.0.1", "192.168.1.10"])
            let report = try #require(payload.localAccess)
            #expect(report.granted == ["127.0.0.1", "192.168.1.10"])
            #expect(report.removed == [])
            let live = try await store.snapshot()
            #expect(live.network.localExemptions.contains("*.example.com"))
        }
    }

    @Test
    func `Recheck ignores client-supplied localExemptions`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            // The pane draft is display-only: a crafted grant cannot alter the
            // preview diff or the applied set.
            let previewBody = RecheckLocalExemptionsRequest(
                policy: structuredPolicyDTO(
                    allowed: ["127.0.0.1", "192.168.1.10"],
                    localExemptions: ["evil.example.com"]
                )
            )
            let preview = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local", body: previewBody
            )
            #expect(preview.status == .ok)
            let diff = try preview.content.decode(RecheckLocalExemptionsResponse.self)
            #expect(!diff.added.contains("evil.example.com"))
            #expect(!diff.unchanged.contains("evil.example.com"))

            let apply = try await settingsRequest(
                app: app, method: .POST, path: "/settings/policy/recheck-local/apply", body: previewBody
            )
            #expect(apply.status == .ok)
            let payload = try apply.content.decode(PolicyResponse.self)
            #expect(!payload.policy.network.localExemptions.contains("evil.example.com"))
        }
    }

    @Test
    func `Domain validation parity with AccessNetworkSection client validator`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withRouteApp(store: store) { app in
            let valid = [
                "api.example.com",
                "*.example.com",
                "127.0.0.1",
                "::1",
                "2001:db8::1",
                "sub.domain.co.uk"
            ]
            for host in valid {
                let candidate = VerifyPolicyRequest(policy: structuredPolicyDTO(allowed: [host]))
                let response = try await settingsRequest(
                    app: app, method: .POST, path: "/settings/policy/verify", body: candidate
                )
                #expect(response.status == .ok, "Expected valid host '\(host)' to verify with 200 OK")
                let payload = try response.content.decode(VerifyPolicyResponse.self)
                #expect(payload.valid == true, "Expected valid host '\(host)' to have valid == true")
                #expect(payload.violations.isEmpty)
            }

            let rejected = [
                "*",
                "*.",
                "*example.com",
                "api.*",
                "api.*.com",
                "http://api.example.com",
                "api.example.com:8080",
                "api.example.com/path",
                "foo@bar",
                "foo#bar",
                "foo bar",
                "foo,bar"
            ]
            for host in rejected {
                let candidate = VerifyPolicyRequest(policy: structuredPolicyDTO(allowed: [host]))
                let verifyResponse = try await settingsRequest(
                    app: app, method: .POST, path: "/settings/policy/verify", body: candidate
                )
                let payload = try verifyResponse.content.decode(VerifyPolicyResponse.self)
                #expect(payload.valid == false, "Expected rejected host '\(host)' to fail verification")
                #expect(!payload.violations.isEmpty)

                let putCandidate = UpdatePolicyRequest(policy: structuredPolicyDTO(allowed: [host]))
                let putResponse = try await settingsRequest(
                    app: app, method: .PUT, path: "/settings/policy", body: putCandidate
                )
                #expect(putResponse.status == .badRequest, "Expected rejected host '\(host)' to return 400 badRequest on PUT")
            }
        }
    }

    @Test
    func `PolicyStore optimistic concurrency CAS rejection`() async throws {
        let (store, _, directory) = try await makePolicyRouteStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialSnapshot = await store.readSnapshot()
        let initialGen = initialSnapshot.generation

        var policy = initialSnapshot.policy
        policy.network.allowedDomains.insert("example.com")
        let updated = try await store.replace(policy, expectedGeneration: initialGen)
        let nextGen = await store.currentGeneration()
        #expect(nextGen == initialGen + 1)

        do {
            try await store.replace(updated, expectedGeneration: initialGen)
            Issue.record("Expected stale expectedGeneration \(initialGen) to be rejected by CAS check")
        } catch let PolicyInvariantError.invariantViolations(violations) {
            #expect(violations.joined().contains("Concurrent modification"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
