// Rune Weaver Core Tests — Plugin discovery and disabled-by-default lifecycle.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Plugin Discovery and Lifecycle")
struct PluginDiscoveryTests {
    @Test
    func `Newly discovered plugin enters disabled state and is hidden from available tools`() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-discovery-\(UUID().uuidString)")
        let pluginsDir = tempBase.appendingPathComponent("plugins")
        let dbPath = tempBase.appendingPathComponent("episodes.db").path

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Create sample plugin
        let pluginDir = pluginsDir.appendingPathComponent("custom.calc")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifestContent = """
        {
            "id": "custom.calc",
            "name": "Calculator",
            "version": "1.0.0",
            "runtime": "python",
            "entrypoint": "calc.py",
            "tools": [
                {
                    "name": "calc.add",
                    "description": "Adds two numbers",
                    "input_schema": "{}",
                    "permission_level": "readOnly"
                }
            ]
        }
        """
        try manifestContent.write(to: pluginDir.appendingPathComponent("rune.json"), atomically: true, encoding: .utf8)
        try "print('calc')".write(to: pluginDir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)

        let store = ToolRegistryStore(dbPath: dbPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsDir, store: store)
        let bus = ToolBus()

        // 1. Initial scan
        let discovered = await discovery.discoverAndSync(toolBus: bus)
        #expect(discovered.count == 1)
        #expect(discovered[0].manifest.id == "custom.calc")
        #expect(discovered[0].record.status == .discovered)
        #expect(!discovered[0].record.isEnabled)

        // Tool MUST NOT be in available tools!
        let available = await bus.availableTools()
        #expect(!available.contains(where: { $0.name == "calc.add" }))

        // 2. Human explicitly enables the plugin
        let enabledRecord = try await discovery.enablePlugin(id: "custom.calc", toolBus: bus)
        #expect(enabledRecord.status == .enabled)
        #expect(enabledRecord.isEnabled)
        #expect(enabledRecord.integrityHash != nil)

        // Tool MUST now be in available tools!
        let availableAfterEnable = await bus.availableTools()
        #expect(availableAfterEnable.contains(where: { $0.name == "calc.add" }))

        // 3. User disables the plugin
        let disabledRecord = try await discovery.disablePlugin(id: "custom.calc", toolBus: bus)
        #expect(disabledRecord.status == .disabled)
        #expect(!disabledRecord.isEnabled)

        let availableAfterDisable = await bus.availableTools()
        #expect(!availableAfterDisable.contains(where: { $0.name == "calc.add" }))
    }

    @Test
    func `Permission overrides apply without allowing trusted level`() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-override-\(UUID().uuidString)")
        let pluginsDir = tempBase.appendingPathComponent("plugins")
        let dbPath = tempBase.appendingPathComponent("episodes.db").path

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let pluginDir = pluginsDir.appendingPathComponent("custom.runner")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifestContent = """
        {
            "id": "custom.runner",
            "name": "Script Runner",
            "version": "1.0.0",
            "runtime": "python",
            "entrypoint": "run.py",
            "tools": [
                {
                    "name": "runner.execute",
                    "description": "Executes script",
                    "input_schema": "{}",
                    "permission_level": "readOnly"
                }
            ]
        }
        """
        try manifestContent.write(to: pluginDir.appendingPathComponent("rune.json"), atomically: true, encoding: .utf8)
        try "print('run')".write(to: pluginDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)

        let store = ToolRegistryStore(dbPath: dbPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsDir, store: store)
        let bus = ToolBus()

        await discovery.discoverAndSync(toolBus: bus)
        _ = try await discovery.enablePlugin(id: "custom.runner", toolBus: bus)

        // Verify initial permission level is readOnly
        var tool = await bus.availableTools().first(where: { $0.name == "runner.execute" })
        #expect(tool?.permissionLevel == .readOnly)

        // Override permission to requiresApproval
        let overriddenRecord = try await discovery.setPermissionOverride(
            id: "custom.runner",
            toolName: "runner.execute",
            overrideLevel: .requiresApproval,
            toolBus: bus
        )
        #expect(overriddenRecord.permissionOverrides["runner.execute"] == "requiresApproval")

        // Live tool bus reflects new permission level
        tool = await bus.availableTools().first(where: { $0.name == "runner.execute" })
        #expect(tool?.permissionLevel == .requiresApproval)

        // Attempting to override to .trusted MUST throw an error
        await #expect(throws: PluginManifestError.self) {
            try await discovery.setPermissionOverride(
                id: "custom.runner",
                toolName: "runner.execute",
                overrideLevel: .trusted,
                toolBus: bus
            )
        }
    }

    @Test
    func `Disabled plugin remains in allTools for GET tools but excluded from availableTools`() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-alltools-\(UUID().uuidString)")
        let pluginsDir = tempBase.appendingPathComponent("plugins")
        let dbPath = tempBase.appendingPathComponent("episodes.db").path

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let pluginDir = pluginsDir.appendingPathComponent("custom.search")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifestContent = """
        {
            "id": "custom.search",
            "name": "Searcher",
            "version": "1.0.0",
            "runtime": "python",
            "entrypoint": "search.py",
            "tools": [
                {
                    "name": "search.query",
                    "description": "Performs query",
                    "input_schema": "{}",
                    "permission_level": "readOnly"
                }
            ]
        }
        """
        try manifestContent.write(to: pluginDir.appendingPathComponent("rune.json"), atomically: true, encoding: .utf8)
        try "print('search')".write(to: pluginDir.appendingPathComponent("search.py"), atomically: true, encoding: .utf8)

        let store = ToolRegistryStore(dbPath: dbPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsDir, store: store)
        let bus = ToolBus()

        // Sync without enabling
        await discovery.discoverAndSync(toolBus: bus)

        // Tool MUST be present in allTools() so GET /tools can report disabled status
        let allTools = await bus.allTools()
        #expect(allTools.contains(where: { $0.name == "search.query" }))

        // Tool MUST NOT be present in availableTools() so LLM / agent prompt excludes it
        let available = await bus.availableTools()
        #expect(!available.contains(where: { $0.name == "search.query" }))
    }

    @Test
    func `Tampered plugin transitions to tampered state and fails closed`() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-tamper-lifecycle-\(UUID().uuidString)")
        let pluginsDir = tempBase.appendingPathComponent("plugins")
        let dbPath = tempBase.appendingPathComponent("episodes.db").path

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let pluginDir = pluginsDir.appendingPathComponent("custom.tamper")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifestContent = """
        {
            "id": "custom.tamper",
            "name": "Tamper Test",
            "version": "1.0.0",
            "runtime": "python",
            "entrypoint": "tamper.py",
            "tools": [
                {
                    "name": "tamper.run",
                    "description": "Runs task",
                    "input_schema": "{}",
                    "permission_level": "readOnly"
                }
            ]
        }
        """
        let scriptFile = pluginDir.appendingPathComponent("tamper.py")
        try manifestContent.write(to: pluginDir.appendingPathComponent("rune.json"), atomically: true, encoding: .utf8)
        try "print('original')".write(to: scriptFile, atomically: true, encoding: .utf8)

        let store = ToolRegistryStore(dbPath: dbPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsDir, store: store)
        let bus = ToolBus()

        // 1. Discover and enable
        await discovery.discoverAndSync(toolBus: bus)
        let enabled = try await discovery.enablePlugin(id: "custom.tamper", toolBus: bus)
        #expect(enabled.status == .enabled)
        #expect(await bus.availableTools().contains(where: { $0.name == "tamper.run" }))

        // 2. Modify script behind the engine's back
        try "print('malicious backdoor')".write(to: scriptFile, atomically: true, encoding: .utf8)

        // 3. Rescan
        let resynced = await discovery.discoverAndSync(toolBus: bus)
        #expect(resynced[0].record.status == .tampered)

        // Tool MUST be disabled from live execution
        let available = await bus.availableTools()
        #expect(!available.contains(where: { $0.name == "tamper.run" }))
    }

    @Test
    func `SubprocessToolBridge contentTrustLevel is untrustedExternal`() throws {
        let decl = PluginToolDeclaration(
            name: "test.tool",
            description: "Test tool",
            inputSchema: "{}",
            permissionLevel: .readOnly
        )
        let bridge = try SubprocessToolBridge(
            pluginID: "test.plugin",
            declaration: decl,
            pluginDirectory: URL(fileURLWithPath: "/tmp"),
            entrypoint: "main.py",
            runtime: .python
        )
        #expect(bridge.contentTrustLevel == .untrustedExternal)
    }

    @Test
    func `SubprocessToolBridge sweeps secrets from output`() throws {
        let decl = PluginToolDeclaration(
            name: "test.tool",
            description: "Test tool",
            inputSchema: "{}",
            permissionLevel: .readOnly
        )
        let bridge = try SubprocessToolBridge(
            pluginID: "test.plugin",
            declaration: decl,
            pluginDirectory: URL(fileURLWithPath: "/tmp"),
            entrypoint: "main.py",
            runtime: .python
        )

        let secret = "super_secret_token_12345"
        let jsonResponse = """
        {"jsonrpc":"2.0","id":"call-1","result":"Received authorization: \(secret)"}
        """
        let output = bridge.parseSubprocessResponse(
            stdoutData: Data(jsonResponse.utf8),
            stderrData: Data(),
            terminationStatus: 0,
            maxOutputBytes: 1024,
            callID: "call-1",
            resolvedSecrets: [secret]
        )
        #expect(!output.isError)
        #expect(output.content.contains("[redacted]"))
        #expect(!output.content.contains(secret))
    }

    @Test
    func `PluginSecurity ignores .mm directory during directory hashing`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mm-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "test-content".write(to: tempDir.appendingPathComponent("rune.json"), atomically: true, encoding: .utf8)
        let hashBefore = PluginSecurity.calculateDirectoryHash(at: tempDir)
        #expect(hashBefore != nil)

        // Create .mm session directory
        let mmDir = tempDir.appendingPathComponent(".mm")
        try FileManager.default.createDirectory(at: mmDir, withIntermediateDirectories: true)
        try "session-pickle-data".write(to: mmDir.appendingPathComponent("mm_session.pickle"), atomically: true, encoding: .utf8)

        let hashAfter = PluginSecurity.calculateDirectoryHash(at: tempDir)
        #expect(hashAfter == hashBefore)
    }

    @Test
    func `PluginDiscoveryService discovers dropped-in monarch-money plugin`() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dropin-monarch-\(UUID().uuidString)")
        let pluginsDir = tempBase.appendingPathComponent("plugins")
        let dbPath = tempBase.appendingPathComponent("episodes.db").path
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Copy Plugins/community.monarch-money from repo into pluginsDir
        // Resolve fixtures relative to the test source so CWD never decides the result.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoMonarchDir = repoRoot
            .appendingPathComponent("Plugins/community.monarch-money")
        guard FileManager.default.fileExists(atPath: repoMonarchDir.path) else {
            Issue.record("Plugins/community.monarch-money not found")
            return
        }
        let targetMonarchDir = pluginsDir.appendingPathComponent("community.monarch-money")
        try FileManager.default.copyItem(at: repoMonarchDir, to: targetMonarchDir)

        let store = ToolRegistryStore(dbPath: dbPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsDir, store: store)
        let bus = ToolBus()

        let discovered = await discovery.discoverAndSync(toolBus: bus)
        #expect(discovered.count == 1)
        #expect(discovered[0].manifest.id == "community.monarch-money")
        #expect(discovered[0].record.status == .discovered)
        #expect(!discovered[0].record.isEnabled)
        #expect(discovered[0].manifest.tools.count == 4)

        // Before enable, tools are hidden
        let availableBefore = await bus.availableTools()
        #expect(!availableBefore.contains(where: { $0.name.hasPrefix("monarch.") }))
    }
}
