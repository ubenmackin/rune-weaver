// Rune Weaver Tools Tests — Exhaustive JSON schema validation across every builtin.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
@testable import RuneWeaverTools
import Testing

/// Corrupt plugin proving the resilient filter: its payload never parses, so
/// wire builders must omit it while direct encoding stays loud for callers.
private struct BrokenSchemaTool: Tool, Sendable {
    let name = "broken.tool"
    let description = "Intentionally corrupt schema for resilience coverage."
    let inputSchema = JSONSchema(rawValue: "not-json")
    let permissionLevel = PermissionLevel.readOnly

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("unreachable", callID: input.callID)
    }
}

@Suite("Tool Schemas")
struct ToolSchemaTests {
    /// Single-sources the production registry so prompt and wire agree on the same nineteen tools;
    /// isolated memory keeps the suite hermetic and the injected policy store keeps the mandatory
    /// `api.request` supervisor off the operator's real `policy.toml`.
    private func makeFullBuiltinTools(engine: MemoryEngine, policyStore: PolicyStore) async throws -> [any Tool] {
        let networkTools = try await BuiltinToolPlugins.makeTools(policyStore: policyStore)
        return EmailTools.makeTools(emailConfig: ToolsTestSupport.testEmailConfig())
            + MemoryTools.makeTools(engine: engine)
            + FilesTools.makeTools()
            + MessagesTools.makeTools()
            + networkTools
    }

    private var expectedBuiltinNames: Set<String> {
        Set(
            EmailTools.toolNames
                + MemoryTools.toolNames
                + FilesTools.toolNames
                + MessagesTools.toolNames
                + BuiltinToolPlugins.toolNames
        )
    }

    @Test
    func `All registered plugin tools expose valid JSON Schemas`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let bus = ToolBus()
        for tool in try await makeFullBuiltinTools(engine: engine, policyStore: policyStore) {
            await bus.register(tool: tool)
        }
        let tools = await bus.availableTools()
        let expected = expectedBuiltinNames
        let names = Set(tools.map(\.name))
        #expect(expected.isSubset(of: names), "Missing tools: \(expected.subtracting(names))")
        #expect(tools.count >= expected.count)
        for tool in tools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            #expect(parsed["type"] as? String == "object", "Tool \(tool.name) must declare type object")
            #expect(parsed["additionalProperties"] as? Bool == false, "Tool \(tool.name) must opt into strict mode")
            #expect((parsed["properties"] as? [String: Any]) != nil, "Tool \(tool.name) must declare properties")
        }
    }

    @Test
    func `Every builtin schema parses as a strict object`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let tools = try await makeFullBuiltinTools(engine: engine, policyStore: policyStore)
        #expect(Set(tools.map(\.name)) == expectedBuiltinNames)
        for tool in tools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            #expect(parsed["type"] as? String == "object", "Tool \(tool.name) must declare type object")
            #expect(parsed["additionalProperties"] as? Bool == false, "Tool \(tool.name) must be strict")
            let properties = try #require(parsed["properties"] as? [String: Any], "Missing properties for \(tool.name)")
            #expect(!properties.isEmpty, "Tool \(tool.name) must describe at least one property")
        }
    }

    @Test
    func `Builtin schemas advertise canonical property groups`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let tools = try await makeFullBuiltinTools(engine: engine, policyStore: policyStore)
        for tool in tools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            let properties = try #require(parsed["properties"] as? [String: Any], "Missing properties for \(tool.name)")
            let raw = tool.inputSchema.rawValue
            switch tool.name {
            case "web.search":
                for key in ["query", "limit"] {
                    #expect(properties[key] != nil, "web.search missing property \(key)")
                }
                #expect(properties["q"] == nil)
                #expect(raw.contains(#""required":["query"]"#), "web.search must require query")
            case "web.fetch":
                #expect(properties["url"] != nil, "web.fetch missing property url")
                #expect(properties["uri"] == nil)
                #expect(raw.contains(#""required":["url"]"#))
            case "browser.navigate":
                for key in ["url", "includeScreenshot", "headed"] {
                    #expect(properties[key] != nil, "browser.navigate missing property \(key)")
                }
                #expect(properties["page"] == nil)
                #expect(raw.contains(#""required":["url"]"#))
            case "browser.act":
                for key in ["action", "ref", "url", "text"] {
                    #expect(properties[key] != nil, "browser.act missing property \(key)")
                }
                #expect(properties["type"] == nil)
                #expect(raw.contains(#""required":["action","ref","url"]"#))
            case "api.request":
                for key in ["method", "url", "headers", "body"] {
                    #expect(properties[key] != nil, "api.request missing property \(key)")
                }
                #expect(properties["verb"] == nil)
                #expect(raw.contains(#""required":["method","url"]"#))
            case "files.read":
                for key in ["path", "offset", "limit", "encoding"] {
                    #expect(properties[key] != nil, "files.read missing property \(key)")
                }
                #expect(raw.contains(#""required":["path"]"#))
            case "files.grep":
                for key in ["pattern", "path", "include", "maxResults", "recursive"] {
                    #expect(properties[key] != nil, "files.grep missing property \(key)")
                }
                #expect(raw.contains(#""required":["pattern","path"]"#))
            case "files.glob":
                for key in ["pattern", "baseDir", "maxResults", "recursive"] {
                    #expect(properties[key] != nil, "files.glob missing property \(key)")
                }
                #expect(raw.contains(#""required":["pattern"]"#))
            case "files.list":
                for key in ["path", "showHidden", "limit"] {
                    #expect(properties[key] != nil, "files.list missing property \(key)")
                }
            case "files.write":
                for key in ["path", "content", "mode"] {
                    #expect(properties[key] != nil, "files.write missing property \(key)")
                }
                #expect(raw.contains(#""required":["path","content"]"#))
            case "memories.store":
                for key in ["text", "category"] {
                    #expect(properties[key] != nil, "\(tool.name) missing property \(key)")
                }
                #expect(raw.contains(#""required":["text"]"#))
            case "memories.recall":
                for key in ["query", "limit", "since", "until"] {
                    #expect(properties[key] != nil, "\(tool.name) missing property \(key)")
                }
                #expect(raw.contains(#""required":["query"]"#))
            case "memories.remove":
                for key in ["id"] {
                    #expect(properties[key] != nil, "\(tool.name) missing property \(key)")
                }
                #expect(raw.contains(#""required":["id"]"#))
            case "email.search":
                for key in ["account", "query", "limit", "mailbox"] {
                    #expect(properties[key] != nil, "email.search missing property \(key)")
                }
                #expect(properties["folder"] == nil)
                // Omitting account searches every configured account, so only query is required.
                #expect(raw.contains(#""required":["query"]"#))
                #expect(!raw.contains(#""required":["account""#), "email.search must keep account optional")
            case "email.read":
                for key in ["account", "id", "mailbox"] {
                    #expect(properties[key] != nil, "email.read missing property \(key)")
                }
                #expect(properties["messageId"] == nil)
                #expect(raw.contains(#""required":["account","id","mailbox"]"#))
            case "email.attachment":
                for key in ["account", "id", "index", "mailbox", "preview", "subpath", "saveToPath"] {
                    #expect(properties[key] != nil, "email.attachment missing property \(key)")
                }
                #expect(properties["messageId"] == nil)
                #expect(properties["attachmentIndex"] == nil)
                #expect(raw.contains(#""required":["account","id","index","mailbox"]"#))
            case "email.send":
                for key in ["account", "to", "cc", "bcc", "subject", "bodyText", "bodyHtml", "attachmentPaths", "replyToId", "mailbox"] {
                    #expect(properties[key] != nil, "email.send missing property \(key)")
                }
                #expect(properties["body"] == nil)
                #expect(properties["folder"] == nil)
                #expect(raw.contains(#""required":["account","to","subject"]"#))
            case "email.listMailboxes":
                #expect(properties["account"] != nil, "email.listMailboxes must describe account")
                #expect(raw.contains(#""required":["account"]"#))
            case "email.move":
                for key in ["account", "id", "destination", "markAsRead"] {
                    #expect(properties[key] != nil, "email.move missing property \(key)")
                }
                #expect(properties["messageId"] == nil)
                #expect(raw.contains(#""required": ["account", "id", "destination"]"#) || raw.contains(#""required":["account","id","destination"]"#))
            case "messages.search":
                for key in ["query", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.search missing property \(key)")
                }
            case "messages.read":
                for key in ["chatId", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.read missing property \(key)")
                }
                #expect(properties["chat_id"] == nil)
            case "messages.send":
                for key in ["recipient", "text"] {
                    #expect(properties[key] != nil, "messages.send missing property \(key)")
                }
                #expect(properties["to"] == nil)
                #expect(raw.contains(#""required":["recipient","text"]"#))
            case "messages.resolveRecipient":
                for key in ["name", "limit"] {
                    #expect(properties[key] != nil, "messages.resolveRecipient missing property \(key)")
                }
                #expect(properties["query"] == nil)
                #expect(raw.contains(#""required":["name"]"#))
            default:
                Issue.record("Unexpected builtin tool \(tool.name)")
            }
        }
    }

    @Test
    func `Chat and Responses bodies succeed with the full tool set`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let tools = try await makeFullBuiltinTools(engine: engine, policyStore: policyStore)
        let definitions = tools.map { ToolDefinition($0) }
        let wireMessages = [Message(role: .user, content: "Full registry wire check")]
        let chatBody = try openAIChatRequestBody(model: "test-model", messages: wireMessages, tools: definitions, stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatTools = try #require(chatJSON["tools"] as? [[String: Any]])
        #expect(chatTools.count == definitions.count)
        #expect(chatJSON["tool_choice"] as? String == "auto")
        for entry in chatTools {
            #expect(entry["type"] as? String == "function")
            let function = try #require(entry["function"] as? [String: Any])
            #expect((function["name"] as? String) != nil)
            let parameters = try #require(function["parameters"] as? [String: Any])
            #expect(parameters["type"] as? String == "object")
            #expect(parameters["additionalProperties"] as? Bool == false)
        }
        let responsesBody = try openAIResponsesRequestBody(model: "test-model", messages: wireMessages, tools: definitions, stream: true)
        let responsesJSON = try #require(try JSONSerialization.jsonObject(with: responsesBody) as? [String: Any])
        let responsesTools = try #require(responsesJSON["tools"] as? [[String: Any]])
        #expect(responsesTools.count == definitions.count)
        for entry in responsesTools {
            #expect(entry["type"] as? String == "function")
            #expect((entry["name"] as? String) != nil)
            let parameters = try #require(entry["parameters"] as? [String: Any])
            #expect(parameters["type"] as? String == "object")
            #expect(parameters["additionalProperties"] as? Bool == false)
        }
        let wireNames = Set(chatTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(expectedBuiltinNames.isSubset(of: wireNames))
        let responsesNames = Set(responsesTools.compactMap { $0["name"] as? String })
        #expect(expectedBuiltinNames.isSubset(of: responsesNames))
    }

    @Test
    func `Broken schemas degrade to fewer tools while direct encoding throws`() async throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let validTools = try await makeFullBuiltinTools(engine: engine, policyStore: policyStore)
        let validDefinitions = validTools.map { ToolDefinition($0) }
        let brokenDefinition = ToolDefinition(
            name: "broken.tool",
            description: "Intentionally corrupt schema.",
            parameters: JSONSchema(rawValue: "not-json")
        )
        // Direct callers stay loud so a single corrupt plugin is visible in isolation.
        do {
            _ = try encodeToolParameters(brokenDefinition)
            Issue.record("encodeToolParameters should throw for unparseable schemas")
        } catch {
            #expect(error is LLMProviderError)
        }
        // Bulk builders skip and report instead of failing the turn.
        let mixed = validDefinitions + [brokenDefinition]
        let filtered = validatedDefinitions(mixed)
        #expect(filtered.valid.count == validDefinitions.count)
        #expect(filtered.skipped == ["broken.tool"])
        let wireMessages = [Message(role: .user, content: "Resilience wire check")]
        let chatBody = try openAIChatRequestBody(model: "test-model", messages: wireMessages, tools: mixed, stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatTools = try #require(chatJSON["tools"] as? [[String: Any]])
        #expect(chatTools.count == validDefinitions.count)
        let chatNames = Set(chatTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(!chatNames.contains("broken.tool"))
        let responsesBody = try openAIResponsesRequestBody(model: "test-model", messages: wireMessages, tools: mixed, stream: true)
        let responsesJSON = try #require(try JSONSerialization.jsonObject(with: responsesBody) as? [String: Any])
        let responsesTools = try #require(responsesJSON["tools"] as? [[String: Any]])
        #expect(responsesTools.count == validDefinitions.count)
        let responsesNames = Set(responsesTools.compactMap { $0["name"] as? String })
        #expect(!responsesNames.contains("broken.tool"))
        // The prompt filter agrees with the wire so warnings name the same skip.
        let mixedPlugins: [any Tool] = validTools + [BrokenSchemaTool()]
        let promptFiltered = VisionSchemaFilter.validatedTools(mixedPlugins)
        #expect(promptFiltered.valid.count == validTools.count)
        #expect(promptFiltered.skipped == ["broken.tool"])
        let warnings = OrchestratorToolLoop.degradedToolWarnings(for: mixedPlugins)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("broken.tool"))
    }

    @Test
    func `Email attachment schema defines canonical properties`() async throws {
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
        for key in ["account", "id", "index", "mailbox", "preview", "subpath", "saveToPath"] {
            #expect(properties[key] != nil, "Missing property \(key)")
        }
        #expect(properties["messageId"] == nil)
        #expect(properties["attachmentIndex"] == nil)
        #expect(parsed["additionalProperties"] as? Bool == false)
    }

    @Test
    func `Messages schemas partition cleanly and encode strictly`() throws {
        // The shared partition is the single gate deciding which schemas reach
        // the prompt and the wire, so an unparseable messages schema must show
        // up here as a skip instead of failing the whole turn downstream.
        let tools = MessagesTools.makeTools()
        #expect(Set(tools.map(\.name)) == Set(MessagesTools.toolNames))
        let partitioned = VisionSchemaFilter.partitionValidSchemas(
            entries: tools,
            name: { $0.name },
            rawSchema: { $0.inputSchema.rawValue },
            logSkips: false
        )
        #expect(partitioned.skipped.isEmpty, "Unexpected messages skips: \(partitioned.skipped)")
        #expect(partitioned.valid.count == MessagesTools.toolNames.count)
        // Strict backends reject non-object roots, so each messages schema must
        // decode to a strict object; per-tool property checks pin canonical keys.
        for tool in tools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            #expect(parsed["type"] as? String == "object", "Tool \(tool.name) must declare type object")
            #expect(parsed["additionalProperties"] as? Bool == false, "Tool \(tool.name) must opt into strict mode")
            let properties = try #require(parsed["properties"] as? [String: Any], "Missing properties for \(tool.name)")
            switch tool.name {
            case "messages.search":
                for key in ["query", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.search missing property \(key)")
                }
            case "messages.read":
                for key in ["chatId", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.read missing property \(key)")
                }
                #expect(properties["chat_id"] == nil)
            case "messages.send":
                for key in ["recipient", "text"] {
                    #expect(properties[key] != nil, "messages.send missing property \(key)")
                }
                #expect(properties["to"] == nil)
                #expect(tool.inputSchema.rawValue.contains(#""required":["recipient","text"]"#))
            case "messages.resolveRecipient":
                for key in ["name", "limit"] {
                    #expect(properties[key] != nil, "messages.resolveRecipient missing property \(key)")
                }
                #expect(properties["query"] == nil)
                #expect(tool.inputSchema.rawValue.contains(#""required":["name"]"#))
            default:
                Issue.record("Unexpected messages tool \(tool.name)")
            }
        }
    }
}
