import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
@testable import RuneWeaverTools
import Testing

@Suite("Tool Schemas")
struct ToolSchemaTests {
    @Test
    func `All registered plugin tools expose valid JSON Schemas`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: ToolsTestSupport.testEmailConfig()) {
            await bus.register(tool: tool)
        }
        for tool in MemoryTools.makeTools(engine: engine) {
            await bus.register(tool: tool)
        }
        let tools = await bus.availableTools()
        let expected: Set = ["email.search", "email.read", "email.attachment", "remember_fact", "recall_memories"]
        let names = Set(tools.map(\.name))
        #expect(expected.isSubset(of: names), "Missing tools: \(expected.subtracting(names))")
        #expect(tools.count >= expected.count)
        for tool in tools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            #expect(parsed["type"] as? String == "object")
        }
    }

    @Test
    func `Email attachment schema keeps identifier and index aliases`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let bus = ToolBus()
        for tool in EmailTools.makeTools(emailConfig: ToolsTestSupport.testEmailConfig()) {
            await bus.register(tool: tool)
        }
        for tool in MemoryTools.makeTools(engine: engine) {
            await bus.register(tool: tool)
        }
        guard let attachment = await bus.tool(named: "email.attachment") else {
            Issue.record("Missing email.attachment tool")
            return
        }
        let parsed = try encodeToolParameters(ToolDefinition(attachment))
        let properties = try #require(parsed["properties"] as? [String: Any])
        for key in ["account", "id", "messageId", "message_id", "uid", "index", "attachmentIndex", "attachment_index"] {
            #expect(properties[key] != nil, "Missing property \(key)")
        }
        #expect(parsed["additionalProperties"] as? Bool == false)
    }
}
