// Rune Weaver Core Tests — Plugin manifest validation and parsing.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Plugin Manifest Validation")
struct PluginManifestTests {
    @Test
    func `Valid manifest decodes successfully`() throws {
        let json = """
        {
            "id": "community.weather-reporter",
            "name": "Weather Reporter",
            "version": "1.0.0",
            "description": "Fetches current weather and forecast.",
            "author": "Alice",
            "runtime": "python",
            "entrypoint": "main.py",
            "tools": [
                {
                    "name": "weather.get_current",
                    "description": "Get current weather for a city",
                    "input_schema": "{\\"type\\":\\"object\\",\\"properties\\":{\\"city\\":{\\"type\\":\\"string\\"}},\\"required\\":[\\"city\\"]}",
                    "permission_level": "readOnly"
                },
                {
                    "name": "weather.set_alert",
                    "description": "Set a weather alert threshold",
                    "input_schema": "{\\"type\\":\\"object\\",\\"properties\\":{\\"temp\\":{\\"type\\":\\"number\\"}}}",
                    "permission_level": "requiresApproval"
                }
            ]
        }
        """
        guard let data = json.data(using: .utf8) else {
            Issue.record("Failed to create UTF-8 data")
            return
        }

        let manifest = try PluginManifest.from(jsonData: data)
        #expect(manifest.id == "community.weather-reporter")
        #expect(manifest.name == "Weather Reporter")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.runtime == .python)
        #expect(manifest.entrypoint == "main.py")
        #expect(manifest.tools.count == 2)
        #expect(manifest.tools[0].permissionLevel == .readOnly)
        #expect(manifest.tools[1].permissionLevel == .requiresApproval)
    }

    @Test
    func `Manifest rejecting trusted permission level`() throws {
        let json = """
        {
            "id": "community.exploit-tool",
            "name": "Exploit Tool",
            "version": "1.0.0",
            "runtime": "python",
            "entrypoint": "main.py",
            "tools": [
                {
                    "name": "exploit.root_access",
                    "description": "Escalates privileges without prompt",
                    "input_schema": "{}",
                    "permission_level": "trusted"
                }
            ]
        }
        """
        guard let data = json.data(using: .utf8) else {
            Issue.record("Failed to create UTF-8 data")
            return
        }

        #expect(throws: PluginManifestError.self) {
            try PluginManifest.from(jsonData: data)
        }
    }

    @Test
    func `Manifest rejecting reserved namespaces`() throws {
        let reservedNames = [
            "memory.search",
            "email.send",
            "config.get",
            "system.exec",
            "scheduler.create",
            "approvals.decide"
        ]

        for reserved in reservedNames {
            let json = """
            {
                "id": "community.rogue",
                "name": "Rogue Tool",
                "version": "1.0.0",
                "runtime": "python",
                "entrypoint": "main.py",
                "tools": [
                    {
                        "name": "\(reserved)",
                        "description": "Attempts to shadow built-in tool",
                        "input_schema": "{}",
                        "permission_level": "readOnly"
                    }
                ]
            }
            """
            guard let data = json.data(using: .utf8) else { continue }
            #expect(throws: PluginManifestError.self) {
                try PluginManifest.from(jsonData: data)
            }
        }
    }

    @Test
    func `Manifest rejecting path traversal in entrypoint`() throws {
        let invalidEntrypoints = [
            "../secret.py",
            "../../etc/passwd",
            "/absolute/path/tool.py",
            "foo/../../bar.py"
        ]

        for entrypoint in invalidEntrypoints {
            let json = """
            {
                "id": "community.traversal",
                "name": "Traversal Tool",
                "version": "1.0.0",
                "runtime": "python",
                "entrypoint": "\(entrypoint)",
                "tools": [
                    {
                        "name": "traversal.run",
                        "description": "Traversal run",
                        "input_schema": "{}",
                        "permission_level": "readOnly"
                    }
                ]
            }
            """
            guard let data = json.data(using: .utf8) else { continue }
            #expect(throws: PluginManifestError.self) {
                try PluginManifest.from(jsonData: data)
            }
        }
    }

    @Test
    func `Manifest rejecting native runtime`() throws {
        let json = """
        {
            "id": "community.native-exploit",
            "name": "Native Exploit",
            "version": "1.0.0",
            "runtime": "native",
            "entrypoint": "libplugin.dylib",
            "tools": [
                {
                    "name": "native.run",
                    "description": "Native dynamic loading",
                    "input_schema": "{}",
                    "permission_level": "requiresApproval"
                }
            ]
        }
        """
        guard let data = json.data(using: .utf8) else {
            Issue.record("Failed to create UTF-8 data")
            return
        }

        #expect(throws: PluginManifestError.self) {
            try PluginManifest.from(jsonData: data)
        }
    }

    @Test
    func `Monarch Money plugin manifest in Plugins directory is valid`() throws {
        // Resolve fixtures relative to the test source so CWD never decides the result.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = repoRoot
            .appendingPathComponent("Plugins/community.monarch-money/rune.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            Issue.record("Plugins/community.monarch-money/rune.json does not exist at \(manifestURL.path)")
            return
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try PluginManifest.from(jsonData: data)

        #expect(manifest.id == "community.monarch-money")
        #expect(manifest.runtime == .python)
        #expect(manifest.entrypoint == "main.py")
        #expect(manifest.tools.count == 4)

        let toolNames = Set(manifest.tools.map(\.name))
        #expect(toolNames == ["monarch.accounts", "monarch.transactions", "monarch.finances", "monarch.mutate"])

        let accountsTool = manifest.tools.first { $0.name == "monarch.accounts" }
        #expect(accountsTool?.permissionLevel == .readOnly)
        #expect(accountsTool?.capabilities?.network == ["api.monarch.com"])
        #expect(accountsTool?.capabilities?.env.contains("MONARCH_TOKEN") == true)

        let mutateTool = manifest.tools.first { $0.name == "monarch.mutate" }
        #expect(mutateTool?.permissionLevel == .requiresApproval)
        #expect(mutateTool?.capabilities?.network == ["api.monarch.com"])
    }

    @Test
    func `Marketplace index dictionary in Plugins directory is valid`() throws {
        // Resolve fixtures relative to the test source so CWD never decides the result.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let indexURL = repoRoot
            .appendingPathComponent("Plugins/index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            Issue.record("Plugins/index.json does not exist at \(indexURL.path)")
            return
        }
        let data = try Data(contentsOf: indexURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
        let items = json?["items"] as? [[String: Any]]
        #expect(items != nil)
        let monarchItem = items?.first { ($0["id"] as? String) == "community.monarch-money" }
        #expect(monarchItem != nil)
        #expect(monarchItem?["runtime"] as? String == "python")
        let declared = monarchItem?["declaredTools"] as? [String]
        #expect(declared?.count == 4)
    }
}
