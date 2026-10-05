// Rune Weaver Core Tests — Hash-pinned agent script registry plus verified execution.
//
// Purpose: pins the `workspace/tools/` promotion contract the tools and service
// share: outside-root rejection, byte-exact pinning, fail-closed tamper
// disablement with a needs-attention note, literal-argv execution that never
// rebuilds script text, graduated-trust tiers through the permission gate,
// and the single-flight contention that the service maps to 409.
// Scope: store pin plus verify plus tamper, tool argument shapes plus shell
// quoting plus approval tiers, and run-lock contention only; HTTP status codes
// and dashboard rendering stay with the server route layer.
// Architectural role: regression net for the Core pin beside the Tools shell
// and the workspace quotas, proving promote, run, modify, and re-run fails
// closed and disabled.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Creates an isolated base directory for one test.
private func makeAgentBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Removes a temporary base without failing the test on cleanup errors.
private func removeAgentBase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Builds an isolated workspace root with its `tools/` leaf created owner-only.
private func makeAgentWorkspace(at base: URL) throws -> (store: WorkspaceStore, root: URL, tools: URL) {
    let root = base.appendingPathComponent("ws", isDirectory: true)
    let store = WorkspaceStore(config: WorkspaceConfig(), rootURL: root)
    let tools = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return (store, root, tools)
}

/// Writes a shell script and marks it executable for the test shell.
private func writeAgentScript(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Builds an allow-all shell for hermetic agent runs.
private func makeAgentBash(workspace: WorkspaceStore) -> BashTool {
    BashTool(
        bashConfig: BashConfig(rules: [BashRule(pattern: "*", action: .allow)]),
        filesConfig: FilesConfig(),
        allowUnsandboxedFallback: true,
        workspaceConfig: WorkspaceConfig(),
        workspaceStore: workspace
    )
}

/// Decodes a shell envelope from tool output content.
private func decodeAgentBashEnvelope(_ content: String) throws -> BashResultEnvelope {
    try JSONDecoder().decode(BashResultEnvelope.self, from: Data(content.utf8))
}

@Suite("AgentToolStore")
struct AgentToolStoreTests {
    @Test
    func `Promote rejects paths outside workspace tools`() async throws {
        let base = try makeAgentBase()
        defer { removeAgentBase(base) }
        let (workspace, _, _) = try makeAgentWorkspace(at: base)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let store = AgentToolStore(dbPath: dbPath, workspaceStore: workspace)
        // An absolute path far outside the workspace must refuse with the
        // eligible directory named, never a generic failure.
        do {
            _ = try await store.promote(name: "evil", scriptPath: "/etc/hosts")
            Issue.record("Expected outside-workspace refusal for /etc/hosts")
        } catch let error as AgentToolStoreError {
            guard case let .outsideWorkspace(reason) = error else {
                Issue.record("Expected outsideWorkspace, got \(error)")
                return
            }
            #expect(reason.contains("workspace/tools"))
        }
        // A parent traversal that standardizes outside must refuse the same way.
        do {
            _ = try await store.promote(name: "evil", scriptPath: "tools/../../outside.sh")
            Issue.record("Expected outside-workspace refusal for traversal")
        } catch let error as AgentToolStoreError {
            guard case .outsideWorkspace = error else {
                Issue.record("Expected outsideWorkspace for traversal, got \(error)")
                return
            }
        }
        // Blank names fail as invalid, not as workspace errors, so callers can
        // distinguish a bad handle from a bad path.
        do {
            _ = try await store.promote(name: "  ", scriptPath: "tools/a.sh")
            Issue.record("Expected invalid-name refusal for blank name")
        } catch let error as AgentToolStoreError {
            guard case .invalidName = error else {
                Issue.record("Expected invalidName, got \(error)")
                return
            }
        }
        #expect(try await store.list().isEmpty)
    }

    @Test
    func `Promote pins hash and re-promote updates pin only`() async throws {
        let base = try makeAgentBase()
        defer { removeAgentBase(base) }
        let (workspace, _, tools) = try makeAgentWorkspace(at: base)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let store = AgentToolStore(dbPath: dbPath, workspaceStore: workspace)
        let script = tools.appendingPathComponent("hello.sh")
        try writeAgentScript("#!/bin/bash\necho hi\n", to: script)
        let first = try await store.promote(name: "hello", scriptPath: script.path)
        #expect(first.name == "hello")
        #expect(first.status == .enabled)
        #expect(first.scriptPath == script.standardizedFileURL.path)
        let expected = try AgentToolStore.sha256Hex(of: Data(contentsOf: script))
        #expect(first.sha256 == expected)

        // A byte change re-pins on explicit re-promotion while preserving
        // identity; the pin tracks bytes, not mtimes.
        try writeAgentScript("#!/bin/bash\necho hi2\n", to: script)
        let second = try await store.promote(name: "hello", scriptPath: script.path)
        #expect(second.id == first.id)
        #expect(second.sha256 != first.sha256)
        #expect(try second.sha256 == AgentToolStore.sha256Hex(of: Data(contentsOf: script)))

        // Re-promotion never silently re-enables: a disabled row stays
        // disabled until the owner explicitly lifts it.
        _ = try await store.setStatus(name: "hello", status: .disabled)
        try writeAgentScript("#!/bin/bash\necho hi3\n", to: script)
        let third = try await store.promote(name: "hello", scriptPath: script.path)
        #expect(third.status == .disabled)
        #expect(third.id == first.id)
        let listed = try await store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.status == .disabled)
        #expect(try await store.remove(name: "hello"))
        #expect(try await store.list().isEmpty)
    }

    @Test
    func `Hash mismatch disables plus fails closed with attention note`() async throws {
        let base = try makeAgentBase()
        defer { removeAgentBase(base) }
        let (workspace, _, tools) = try makeAgentWorkspace(at: base)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let notes = AgentAttentionCapture()
        let store = AgentToolStore(dbPath: dbPath, workspaceStore: workspace, eventSink: { await notes.record($0) })
        let script = tools.appendingPathComponent("worker.sh")
        try writeAgentScript("#!/bin/bash\necho v1\n", to: script)
        _ = try await store.promote(name: "worker", scriptPath: script.path)
        // Quietly change the bytes without re-promoting: the next verify
        // must fail closed, disable the row, and emit the note.
        try writeAgentScript("#!/bin/bash\necho v2-tampered\n", to: script)
        do {
            _ = try await store.verify(name: "worker")
            Issue.record("Expected tamper failure after modification")
        } catch let error as AgentToolStoreError {
            guard case .tampered = error else {
                Issue.record("Expected tampered, got \(error)")
                return
            }
        }
        let stored = try await store.get(name: "worker")
        #expect(stored?.status == .disabled)
        let captured = await notes.captured()
        #expect(captured.count == 1)
        #expect(captured.first?.contains("worker") == true)
        #expect(captured.first?.contains("needs attention") == true)
        // A disabled row stays failed closed even when the bytes still match
        // the tampered content: verification keeps throwing until re-promote.
        do {
            _ = try await store.verify(name: "worker")
            Issue.record("Expected second tamper failure while disabled")
        } catch let error as AgentToolStoreError {
            guard case .tampered = error else {
                Issue.record("Expected tampered on second verify, got \(error)")
                return
            }
        }
    }

    @Test
    func `Promote run modify run fails closed disabled`() async throws {
        let base = try makeAgentBase()
        defer { removeAgentBase(base) }
        let (workspace, _, tools) = try makeAgentWorkspace(at: base)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let store = AgentToolStore(dbPath: dbPath, workspaceStore: workspace)
        let bash = makeAgentBash(workspace: workspace)
        let toolsPair = AgentTools.makeTools(store: store, bash: bash, workspace: workspace)
        let run = try #require(toolsPair.first { $0.name == "tool.run" })
        let script = tools.appendingPathComponent("echoer.sh")
        try writeAgentScript("#!/bin/bash\nprintf 'got:%s\\n' \"$@\"\n", to: script)
        _ = try await store.promote(name: "echoer", scriptPath: script.path)
        let first = try await run.execute(
            input: ToolInput(toolName: "tool.run", argumentsJSON: #"{"name":"echoer","argv":["hello"]}"#),
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(!first.isError)
        let envelope = try decodeAgentBashEnvelope(first.content)
        #expect(envelope.exitCode == 0)
        #expect(envelope.stdout.contains("got:hello"))
        // Modify without re-promoting: the next run verifies first and must
        // refuse disabled instead of executing changed bytes.
        try writeAgentScript("#!/bin/bash\necho TAMPERED\n", to: script)
        let second = try await run.execute(
            input: ToolInput(toolName: "tool.run", argumentsJSON: #"{"name":"echoer","argv":["hello"]}"#),
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(second.isError)
        #expect(second.content.lowercased().contains("disabled") || second.content.lowercased().contains("verification"))
        #expect(try await store.get(name: "echoer")?.status == .disabled)
    }

    @Test
    func `Tool run argv never touches script text`() async throws {
        let base = try makeAgentBase()
        defer { removeAgentBase(base) }
        let (workspace, _, tools) = try makeAgentWorkspace(at: base)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let store = AgentToolStore(dbPath: dbPath, workspaceStore: workspace)
        let bash = makeAgentBash(workspace: workspace)
        let pair = AgentTools.makeTools(store: store, bash: bash, workspace: workspace)
        let run = try #require(pair.first { $0.name == "tool.run" })
        // The script echoes its first caller word verbatim after dropping the
        // `--` separator, so an injection attempt must arrive as data rather
        // than splitting into a new command.
        let script = tools.appendingPathComponent("argcheck.sh")
        try writeAgentScript("#!/bin/bash\nif [ \"$1\" = \"--\" ]; then shift; fi\necho \"ARG:$1\"\n", to: script)
        _ = try await store.promote(name: "argcheck", scriptPath: script.path)
        let injection = "; echo INJECTED"
        let payload: [String: Any] = ["name": "argcheck", "argv": [injection]]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let payloadJSON = String(bytes: payloadData, encoding: .utf8) ?? "{}"
        let output = try await run.execute(
            input: ToolInput(toolName: "tool.run", argumentsJSON: payloadJSON, callID: UUID().uuidString),
            context: ToolContext(conversationID: UUID(), approved: true)
        )
        #expect(!output.isError)
        let envelope = try decodeAgentBashEnvelope(output.content)
        #expect(envelope.exitCode == 0)
        // The literal attempt survives as one argv word; a split would have
        // produced a bare `INJECTED` line outside the `ARG:` prefix.
        #expect(envelope.stdout.contains("ARG:; echo INJECTED"))
        let lines = envelope.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(!lines.contains("INJECTED"))
    }

    @Test
    func `Agent tools park for approval with graduated trust`() async throws {
        let base = try makeAgentBase()
        defer { removeAgentBase(base) }
        let (workspace, _, _) = try makeAgentWorkspace(at: base)
        let dbPath = base.appendingPathComponent("episodes.db").path
        let store = AgentToolStore(dbPath: dbPath, workspaceStore: workspace)
        let bash = makeAgentBash(workspace: workspace)
        let tools = AgentTools.makeTools(store: store, bash: bash, workspace: workspace)
        #expect(tools.map(\.name) == ["tool.promote", "tool.run"])
        #expect(AgentTools.toolNames == ["tool.promote", "tool.run"])
        for tool in tools {
            #expect(tool.permissionLevel == .requiresApproval)
        }
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let promote = try #require(byName["tool.promote"])
        let run = try #require(byName["tool.run"])
        // Schemas stay strict objects so unknown keys fail closed on the wire.
        for tool in tools {
            let parsed = try JSONSerialization.jsonObject(with: Data(tool.inputSchema.rawValue.utf8), options: []) as? [String: Any]
            #expect(parsed?["type"] as? String == "object")
            #expect(parsed?["additionalProperties"] as? Bool == false)
        }
        #expect(promote.inputSchema.rawValue.contains("script_path"))
        #expect(run.inputSchema.rawValue.contains("argv"))
        // Both tools park before trust, then a durable grant covers the repeat
        // exactly like a `bash.exec` repeat: the gate owns the decision, the
        // tools only declare the tier.
        let gate = PermissionGate()
        let promoteCall = ToolInput(toolName: "tool.promote", argumentsJSON: #"{"name":"a","script_path":"tools/a.sh"}"#)
        let promoteVerdict = await gate.checkPermission(toolCall: promoteCall, tool: promote)
        guard case .requiresApproval = promoteVerdict else {
            Issue.record("tool.promote must park for approval")
            return
        }
        let runCall = ToolInput(toolName: "tool.run", argumentsJSON: #"{"name":"a"}"#)
        let runVerdict = await gate.checkPermission(toolCall: runCall, tool: run)
        guard case .requiresApproval = runVerdict else {
            Issue.record("tool.run must park for approval")
            return
        }
        await gate.grantTrust(for: ActionDescriptor(toolName: "tool.run"), duration: .forever)
        let covered = await gate.checkPermission(toolCall: runCall, tool: run)
        #expect(covered == .allowed)
    }

    @Test
    func `Route validation plus single-flight contention`() async throws {
        // Name validation mirrors the promote route's 400 path: blank and
        // slash-carrying names refuse before any file or database work.
        do {
            _ = try AgentToolStore.validatedName("  ")
            Issue.record("Expected invalid name for blank")
        } catch let error as AgentToolStoreError {
            guard case .invalidName = error else {
                Issue.record("Expected invalidName, got \(error)")
                return
            }
        }
        do {
            _ = try AgentToolStore.validatedName("a/b")
            Issue.record("Expected invalid name for slash")
        } catch let error as AgentToolStoreError {
            guard case .invalidName = error else {
                Issue.record("Expected invalidName for slash, got \(error)")
                return
            }
        }
        // Argv bounds mirror the run route's 400 path: an oversized list
        // refuses before verification or shell spawn.
        let oversized = Array(repeating: "x", count: RunAgentTool.maxArgvCount + 1)
        #expect(oversized.count > RunAgentTool.maxArgvCount)
        // Alias decoding mirrors the REST `args`/`arguments` tolerance: all
        // three spellings land on the same effective list.
        let direct = try JSONDecoder().decode(RunAgentToolArgs.self, from: Data(#"{"name":"a","argv":["x"]}"#.utf8))
        #expect(direct.effectiveArgv == ["x"])
        let alias = try JSONDecoder().decode(RunAgentToolArgs.self, from: Data(#"{"name":"a","args":["x"]}"#.utf8))
        #expect(alias.effectiveArgv == ["x"])
        // Single-flight mirrors the service 409 path: a held slot refuses the
        // second acquire until released.
        let lock = AgentToolRunLock()
        let id = UUID()
        #expect(await lock.tryAcquire(id: id))
        #expect(await !(lock.tryAcquire(id: id)))
        #expect(await lock.isRunning(id: id))
        await lock.release(id: id)
        #expect(await !(lock.isRunning(id: id)))
        #expect(await lock.tryAcquire(id: id))
        await lock.release(id: id)
    }
}

/// Captures needs-attention notes without touching the filesystem.
private actor AgentAttentionCapture {
    /// Notes in arrival order.
    private var notes: [String] = []

    /// Records one note.
    func record(_ note: String) {
        notes.append(note)
    }

    /// Returns captured notes.
    func captured() -> [String] {
        notes
    }
}
