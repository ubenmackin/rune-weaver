// Rune Weaver Core Tests — Plugin security and tampering verification.
//
// Tests cryptographic SHA-256 tree hashing, transient cache filtering,
// tamper detection across file modifications, and write guardrails protecting
// plugin directories from unauthorized agent tampering.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Plugin Security and Integrity")
struct PluginSecurityTests {
    @Test
    func `Deterministic directory hash ignoring transient files`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-plugin-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mainPy = tempDir.appendingPathComponent("main.py")
        let runeJson = tempDir.appendingPathComponent("rune.json")
        try "print('hello')".write(to: mainPy, atomically: true, encoding: .utf8)
        try "{}".write(to: runeJson, atomically: true, encoding: .utf8)

        let initialHash = PluginSecurity.calculateDirectoryHash(at: tempDir)
        #expect(initialHash != nil)

        // Adding transient cache files (__pycache__, .DS_Store, .pyc) should NOT change tree hash
        let pycacheDir = tempDir.appendingPathComponent("__pycache__")
        try FileManager.default.createDirectory(at: pycacheDir, withIntermediateDirectories: true)
        let pycFile = pycacheDir.appendingPathComponent("main.cpython-311.pyc")
        try "compiled_bytecode".write(to: pycFile, atomically: true, encoding: .utf8)

        let dsStore = tempDir.appendingPathComponent(".DS_Store")
        try "finder_metadata".write(to: dsStore, atomically: true, encoding: .utf8)

        let transientHash = PluginSecurity.calculateDirectoryHash(at: tempDir)
        #expect(transientHash == initialHash)

        // Modifying actual code MUST change the tree hash
        try "print('hello modified')".write(to: mainPy, atomically: true, encoding: .utf8)
        let modifiedHash = PluginSecurity.calculateDirectoryHash(at: tempDir)
        #expect(modifiedHash != initialHash)
    }

    @Test
    func `Tamper check detects file modification`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-tamper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = tempDir.appendingPathComponent("script.py")
        try "import os".write(to: script, atomically: true, encoding: .utf8)

        let originalHash = PluginSecurity.calculateDirectoryHash(at: tempDir)
        guard let originalHash else {
            Issue.record("Failed to compute hash")
            return
        }

        // Initially matches
        #expect(PluginSecurity.verifyIntegrity(at: tempDir, expectedHash: originalHash))

        // Modify file contents
        try "import os; malicious_payload()".write(to: script, atomically: true, encoding: .utf8)
        #expect(!PluginSecurity.verifyIntegrity(at: tempDir, expectedHash: originalHash))
    }

    @Test
    func `Write guardrails block agent writes to plugins directory and config`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPaths = [
            "\(home)/.runeweaver/plugins/my-plugin/main.py",
            "\(home)/.runeweaver/plugins/malicious.json",
            "\(home)/.runeweaver/config.toml"
        ]

        for path in protectedPaths {
            let url = URL(fileURLWithPath: path)
            #expect(PluginSecurity.isProtectedPath(targetURL: url))
        }

        let allowedPaths = [
            "/tmp/test.txt",
            "\(home)/Documents/project/notes.md",
            "\(home)/.runeweaver/staging/attachment.pdf",
            "\(home)/.runeweaver/plugins_backup/tool.py",
            "\(home)/.runeweaver/config.toml.bak"
        ]

        for path in allowedPaths {
            let url = URL(fileURLWithPath: path)
            #expect(!PluginSecurity.isProtectedPath(targetURL: url))
        }
    }

    @Test
    func `PermissionGate denies tool call targeting protected engine path`() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let gate = PermissionGate()

        struct DummyTool: Tool {
            let name = "file.write"
            let description = "Write file"
            let permissionLevel = PermissionLevel.requiresApproval
            let inputSchema = JSONSchema.emptyObject
            func execute(input _: ToolInput, context _: ToolContext) async throws -> ToolOutput {
                .success("ok")
            }
        }

        let protectedCall = ToolInput(
            toolName: "file.write",
            argumentsJSON: "{\"path\":\"\(home)/.runeweaver/plugins/evil.py\",\"content\":\"evil\"}"
        )

        let decision = await gate.checkPermission(toolCall: protectedCall, tool: DummyTool())
        guard case let .denied(reason) = decision else {
            Issue.record("Expected denied decision, got \(decision)")
            return
        }
        #expect(reason.contains("protected Rune Weaver engine files"))
    }
}
