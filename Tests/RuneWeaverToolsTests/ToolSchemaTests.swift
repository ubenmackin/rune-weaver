// Rune Weaver Tools Tests — Exhaustive JSON schema validation across every builtin.

// Every builtin must survive strict backends, so this suite pins the full
// registry (email plus messages plus memory plus files plus web and browser) to strict
// objects and proves one corrupt schema degrades instead of failing turns.

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
    /// Single-sources the production registry so prompt and wire agree on the
    /// same nineteen tools; isolated memory keeps the suite hermetic.
    private func makeFullBuiltinTools(engine: MemoryEngine) -> [any Tool] {
        EmailTools.makeTools(emailConfig: ToolsTestSupport.testEmailConfig())
            + MemoryTools.makeTools(engine: engine)
            + FilesTools.makeTools()
            + MessagesTools.makeTools()
            + BuiltinToolPlugins.makeTools()
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
        let bus = ToolBus()
        for tool in makeFullBuiltinTools(engine: engine) {
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
    func `Every builtin schema parses as a strict object`() throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let tools = makeFullBuiltinTools(engine: engine)
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
    func `Builtin schemas advertise required alias groups`() throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let tools = makeFullBuiltinTools(engine: engine)
        for tool in tools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            let properties = try #require(parsed["properties"] as? [String: Any], "Missing properties for \(tool.name)")
            let raw = tool.inputSchema.rawValue
            switch tool.name {
            case "web.search":
                for key in ["query", "q", "limit", "count"] {
                    #expect(properties[key] != nil, "web.search missing property \(key)")
                }
                #expect(raw.contains(#""required":["query"]"#), "web.search must require query")
                #expect(raw.contains(#""required":["q"]"#), "web.search must accept q alias")
            case "web.fetch":
                for key in ["url", "uri", "link"] {
                    #expect(properties[key] != nil, "web.fetch missing property \(key)")
                }
                #expect(raw.contains(#""required":["url"]"#))
                #expect(raw.contains(#""required":["uri"]"#))
                #expect(raw.contains(#""required":["link"]"#))
            case "browser.navigate":
                for key in ["url", "page", "pageUrl", "page_url", "includeScreenshot", "screenshot", "include_screenshot"] {
                    #expect(properties[key] != nil, "browser.navigate missing property \(key)")
                }
                #expect(raw.contains(#""required":["url"]"#))
                #expect(raw.contains(#""required":["page"]"#))
                #expect(raw.contains(#""required":["pageUrl"]"#))
                #expect(raw.contains(#""required":["page_url"]"#))
            case "browser.act":
                for key in ["action", "type", "kind", "ref", "target", "selector", "element", "elementRef", "text", "value", "input", "key", "url", "page", "pageUrl", "page_url"] {
                    #expect(properties[key] != nil, "browser.act missing property \(key)")
                }
                #expect(raw.contains("allOf"), "browser.act must group action, ref, and url requirements")
                #expect(raw.contains(#""required":["action"]"#))
                #expect(raw.contains(#""required":["ref"]"#))
                #expect(raw.contains(#""required":["url"]"#))
            case "api.request":
                for key in ["method", "verb", "url", "uri", "link", "headers", "header", "body", "payload", "data"] {
                    #expect(properties[key] != nil, "api.request missing property \(key)")
                }
                #expect(raw.contains("allOf"), "api.request must group method and url requirements")
                #expect(raw.contains(#""required":["method"]"#))
                #expect(raw.contains(#""required":["url"]"#))
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
            case "remember_fact", "memories.store":
                for key in ["text", "category"] {
                    #expect(properties[key] != nil, "\(tool.name) missing property \(key)")
                }
                #expect(raw.contains(#""required":["text"]"#))
            case "recall_memories", "memories.recall":
                for key in ["query", "limit"] {
                    #expect(properties[key] != nil, "\(tool.name) missing property \(key)")
                }
                #expect(raw.contains(#""required":["query"]"#))
            case "email.search":
                for key in ["account", "query", "limit", "mailbox", "folder"] {
                    #expect(properties[key] != nil, "email.search missing property \(key)")
                }
                #expect(raw.contains(#""required":["account","query"]"#))
            case "email.read":
                for key in ["account", "id", "messageId", "message_id", "uid", "mailbox", "folder"] {
                    #expect(properties[key] != nil, "email.read missing property \(key)")
                }
                #expect(raw.contains(#""required":["account"]"#))
                #expect(raw.contains(#""required":["id"]"#))
                #expect(raw.contains(#""required":["messageId"]"#))
            case "email.attachment":
                for key in ["account", "id", "messageId", "message_id", "uid", "index", "attachmentIndex", "attachment_index", "mailbox", "preview", "subpath", "saveToPath"] {
                    #expect(properties[key] != nil, "email.attachment missing property \(key)")
                }
                #expect(raw.contains(#""required":["account"]"#))
                #expect(raw.contains(#""required":["id"]"#))
                #expect(raw.contains(#""required":["index"]"#))
            case "email.send":
                for key in ["account", "to", "cc", "bcc", "subject", "bodyText", "body", "bodyHtml", "attachmentPaths", "replyToId", "mailbox"] {
                    #expect(properties[key] != nil, "email.send missing property \(key)")
                }
                #expect(raw.contains(#""required":["account","to","subject"]"#))
            case "email.listMailboxes":
                #expect(properties["account"] != nil, "email.listMailboxes must describe account")
                #expect(raw.contains(#""required":["account"]"#))
            case "email.move":
                for key in ["account", "id", "messageId", "destination", "toMailbox", "markAsRead", "mark_as_read"] {
                    #expect(properties[key] != nil, "email.move missing property \(key)")
                }
                #expect(raw.contains(#""required":["account"]"#))
                #expect(raw.contains(#""required":["id"]"#))
                #expect(raw.contains(#""required":["destination"]"#))
            case "messages.search":
                for key in ["query", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.search missing property \(key)")
                }
            case "messages.read":
                for key in ["chatId", "chat_id", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.read missing property \(key)")
                }
            case "messages.send":
                for key in ["recipient", "to", "text", "message"] {
                    #expect(properties[key] != nil, "messages.send missing property \(key)")
                }
                #expect(raw.contains(#""required":["recipient","text"]"#))
            default:
                Issue.record("Unexpected builtin tool \(tool.name)")
            }
        }
    }

    @Test
    func `Chat and Responses bodies succeed with the full tool set`() throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let tools = makeFullBuiltinTools(engine: engine)
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
    func `Broken schemas degrade to fewer tools while direct encoding throws`() throws {
        let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let validTools = makeFullBuiltinTools(engine: engine)
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
        // decode to a strict object; per-tool property checks pin the alias
        // groups callers rely on, with send keeping both canonical keys required
        // so recipient and text aliases cannot drift out of the contract.
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
                for key in ["chatId", "chat_id", "recipient", "limit"] {
                    #expect(properties[key] != nil, "messages.read missing property \(key)")
                }
            case "messages.send":
                for key in ["recipient", "to", "text", "message"] {
                    #expect(properties[key] != nil, "messages.send missing property \(key)")
                }
                #expect(tool.inputSchema.rawValue.contains(#""required":["recipient","text"]"#))
            default:
                Issue.record("Unexpected messages tool \(tool.name)")
            }
        }
    }
}
