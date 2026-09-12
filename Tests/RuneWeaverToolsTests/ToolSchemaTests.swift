import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Mirrors `RuneWeaverLLM.encodeToolParameters` for schema validation.
///
/// The provider layer decodes each tool's `inputSchema.rawValue` with
/// `JSONSerialization` and requires a JSON object, throwing
/// "has an invalid JSON Schema; expected a JSON object" otherwise.
/// This local helper applies the same check without taking a new
/// module dependency so the registry test exercises the same path.
/// - Parameter tool: Registered plugin tool to validate.
/// - Returns: Decoded schema object.
/// - Throws: When the schema is not a JSON object.
private func encodeToolParameters(_ tool: any Tool) throws -> [String: Any] {
    guard let data = tool.inputSchema.rawValue.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let object = parsed as? [String: Any]
    else {
        throw NSError(
            domain: "ToolSchemaTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tool '\(tool.name)' has an invalid JSON Schema; expected a JSON object"
            ]
        )
    }
    return object
}

/// Test email config with one self-hosted account for schema tests.
private func schemaTestEmailConfig() -> EmailConfig {
    EmailConfig(accounts: [
        EmailAccount(
            name: "personal",
            type: "imap",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com"
        )
    ])
}

/// Builds an isolated memory engine on a fresh temporary directory.
private func makeSchemaTestEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

@Suite("Tool Schemas")
struct ToolSchemaTests {
    @Test
    func `All registered plugin tools expose valid JSON Schemas`() async throws {
        let (engine, base) = makeSchemaTestEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: schemaTestEmailConfig()) {
            await bus.register(tool: tool)
        }
        for tool in MemoryTools.makeTools(engine: engine) {
            await bus.register(tool: tool)
        }
        let tools = await bus.availableTools()
        #expect(tools.count == 5)
        #expect(Set(tools.map(\.name)) == Set(["email.search", "email.read", "email.attachment", "remember_fact", "recall_memories"]))
        for tool in tools {
            let parsed = try encodeToolParameters(tool)
            #expect(parsed["type"] as? String == "object")
        }
    }

    @Test
    func `Email attachment schema keeps identifier and index aliases`() async throws {
        let (engine, base) = makeSchemaTestEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: schemaTestEmailConfig()) {
            await bus.register(tool: tool)
        }
        for tool in MemoryTools.makeTools(engine: engine) {
            await bus.register(tool: tool)
        }
        guard let attachment = await bus.tool(named: "email.attachment") else {
            Issue.record("Missing email.attachment tool")
            return
        }
        let parsed = try encodeToolParameters(attachment)
        let properties = try #require(parsed["properties"] as? [String: Any])
        for key in ["account", "id", "messageId", "message_id", "uid", "index", "attachmentIndex", "attachment_index"] {
            #expect(properties[key] != nil, "Missing property \(key)")
        }
        #expect(parsed["additionalProperties"] as? Bool == false)
    }
}
