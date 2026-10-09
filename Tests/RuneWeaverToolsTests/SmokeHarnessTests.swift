// Rune Weaver Tools Tests — End-to-end smoke coverage over the scripted harness.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
@testable import RuneWeaverTools
import Testing

/// One scripted model turn: text fragments plus billed usage.
private struct SmokeTurn: Sendable {
    /// Text fragments emitted as separate deltas in order.
    let textDeltas: [String]
    /// Billed tokens reported on the terminal chunk, if any.
    let totalTokens: Int?

    /// Creates a scripted turn.
    init(textDeltas: [String], totalTokens: Int? = nil) {
        self.textDeltas = textDeltas
        self.totalTokens = totalTokens
    }
}

/// Scripted provider replaying canned turns in call order.
private final class SmokeScriptedProvider: LLMProvider, Sendable {
    /// Stable smoke model metadata.
    let modelInfo = ModelInfo(name: "smoke-model", provider: "smoke", contextLength: 8192)
    /// Script state guarded by lock.
    private struct ScriptState: Sendable {
        var turns: [SmokeTurn]
        var index: Int
    }

    private let state: OSAllocatedUnfairLock<ScriptState>

    /// Creates a scripted provider.
    /// - Parameter turns: Canned turns in call order.
    init(turns: [SmokeTurn]) {
        self.state = OSAllocatedUnfairLock(initialState: ScriptState(turns: turns, index: 0))
    }

    /// Replays the next canned turn as chunked deltas plus terminal usage.
    func chat(messages _: [Message], tools _: [any Tool]) -> AsyncStream<LLMResponse> {
        let turn: SmokeTurn? = state.withLock { s in
            guard s.index < s.turns.count else {
                Issue.record("SmokeScriptedProvider exhausted \(s.turns.count) scripted turn(s)")
                return nil
            }
            let next = s.turns[s.index]
            s.index += 1
            return next
        }
        guard let turn else {
            return AsyncStream { continuation in
                continuation.yield(LLMResponse(delta: "", isFinished: true))
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            for part in turn.textDeltas {
                continuation.yield(LLMResponse(delta: part))
            }
            continuation.yield(LLMResponse(delta: "", isFinished: true, totalTokens: turn.totalTokens))
            continuation.finish()
        }
    }

    /// Unused embeddings stub returning one vector per input.
    func embeddings(text: [String]) async throws -> [[Float]] {
        Array(repeating: [Float](), count: text.count)
    }
}

/// Lock-guarded cursor replaying tool batches in resolver-call order.
private final class SmokeBatchCursor: Sendable {
    private struct CursorState: Sendable {
        var batches: [[ToolInput]]
        var index: Int
    }

    /// Guards batch state below.
    private let state: OSAllocatedUnfairLock<CursorState>

    /// Creates a batch cursor.
    /// - Parameter batches: Canned batches in resolver-call order.
    init(batches: [[ToolInput]]) {
        self.state = OSAllocatedUnfairLock(initialState: CursorState(batches: batches, index: 0))
    }

    /// Returns the next canned batch, recording an issue when exhausted.
    func next() -> [ToolInput] {
        state.withLock { s in
            guard s.index < s.batches.count else {
                Issue.record("SmokeBatchCursor consumed all \(s.batches.count) batch(es)")
                return []
            }
            let batch = s.batches[s.index]
            s.index += 1
            return batch
        }
    }
}

/// Builds the production-wired stack for one smoke test.
private func makeSmokeStack(gateway: any EmailIMAPGateway) async throws -> (
    base: URL,
    engine: MemoryEngine,
    conversations: ConversationManager,
    bus: ToolBus,
    systemPrompt: String,
    audit: ToolsTestSupport.AuditCapture
) {
    let (engine, base) = try ToolsTestSupport.makeIsolatedMemoryEngine()
    let episodesPath = base.appendingPathComponent("episodes.db").path
    let conversations = ConversationManager(episodesDBPath: episodesPath)
    let audit = ToolsTestSupport.AuditCapture()
    let sandbox = ContainersConfig()
    let bus = ToolBus(permissionGate: PermissionGate())
    for tool in EmailTools.makeTools(emailConfig: ToolsTestSupport.testEmailConfig(), gateway: gateway, containersConfig: sandbox) {
        await bus.register(tool: tool)
    }
    await MemoryTools.register(on: bus, engine: engine, audit: { audit.record($0) })
    let systemPrompt = await SystemPromptComposer.compose(toolBus: bus)
    return (base, engine, conversations, bus, systemPrompt, audit)
}

/// Serialized plus `testCredentialEnvLock`: `ToolsTestSupport.withTestPassword` installs the stub
/// credential via process-global `setenv` (POSIX-unsafe under concurrency).
@Suite("Smoke Harness", .serialized)
struct SmokeHarnessTests {
    @Test
    func `Plain turn completes with trailer usage`() async throws {
        try await ToolsTestSupport.withTestPassword {
            let hits = try ToolsTestSupport.sharedSearchHits()
            let (base, engine, conversations, bus, systemPrompt, _) = try await makeSmokeStack(
                gateway: ToolsTestSupport.StubEmailGateway(hits: hits)
            )
            defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
            #expect(systemPrompt.contains("Rune Weaver"))
            #expect(systemPrompt.contains("email.search"))
            #expect(systemPrompt.contains("memories.recall"))
            let provider = SmokeScriptedProvider(turns: [
                SmokeTurn(textDeltas: ["Hello, ", "I am ready to help."], totalTokens: 42)
            ])
            let cursor = SmokeBatchCursor(batches: [[]])
            let resolver: OrchestratorToolResolver = { _, _ in cursor.next() }
            let orchestrator = Orchestrator(
                conversations: conversations,
                toolBus: bus,
                llm: provider,
                systemPrompt: systemPrompt,
                toolResolver: resolver,
                memoryEngine: engine
            )
            let sessionID = UUID()
            let response = try await orchestrator.process(input: UserInput(text: "Hello", sessionID: sessionID))
            #expect(response.text == "Hello, I am ready to help.")
            #expect(response.toolActions.isEmpty)
            #expect(response.totalTokens == 42)
            let trailer = SessionTokenDisplay.label(
                model: provider.modelInfo.name,
                used: response.totalTokens ?? 0,
                window: provider.modelInfo.contextLength
            )
            #expect(trailer == "(smoke-model · 42/8192, 1%)")
            let history = await conversations.history(for: sessionID)
            #expect(history.contains { $0.role == .user && $0.content == "Hello" })
            #expect(history.contains { $0.role == .assistant && $0.content == "Hello, I am ready to help." })
            let working = await conversations.workingHistory(for: sessionID, systemPrompt: systemPrompt)
            #expect(working.first?.role == .system)
            #expect(working.first?.content == systemPrompt)
            let episodes = try await engine.episodes(for: sessionID)
            #expect(episodes.count == 2)
            #expect(episodes.contains { $0.role == .user && $0.content == "Hello" })
            #expect(episodes.contains { $0.role == .assistant && $0.content == "Hello, I am ready to help." })
        }
    }

    @Test
    func `Search then answer tool loop`() async throws {
        try await ToolsTestSupport.withTestPassword {
            let hits = try ToolsTestSupport.sharedSearchHits()
            let capture = ToolsTestSupport.QueryCapture()
            let gateway = ToolsTestSupport.StubEmailGateway(hits: hits, capture: capture)
            let (base, engine, conversations, bus, systemPrompt, _) = try await makeSmokeStack(gateway: gateway)
            defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
            let searchCall = ToolInput(
                toolName: "email.search",
                argumentsJSON: #"{"account":"personal","query":"quarterly","limit":10}"#,
                callID: "call_smoke_search_01"
            )
            let provider = SmokeScriptedProvider(turns: [
                SmokeTurn(textDeltas: ["I will search your mail."], totalTokens: 100),
                SmokeTurn(textDeltas: ["You have a quarterly report from your boss."], totalTokens: 50)
            ])
            let cursor = SmokeBatchCursor(batches: [[searchCall], []])
            let resolver: OrchestratorToolResolver = { _, _ in cursor.next() }
            let orchestrator = Orchestrator(
                conversations: conversations,
                toolBus: bus,
                llm: provider,
                systemPrompt: systemPrompt,
                toolResolver: resolver,
                memoryEngine: engine
            )
            let sessionID = UUID()
            let response = try await orchestrator.process(input: UserInput(text: "Find my quarterly email", sessionID: sessionID))
            #expect(response.text == "You have a quarterly report from your boss.")
            #expect(response.toolActions.count == 1)
            #expect(response.toolActions.first?.toolName == "email.search")
            #expect(response.toolActions.first?.callID == "call_smoke_search_01")
            #expect(response.toolActions.first?.result?.isError == false)
            #expect(response.toolActions.first?.result?.content.contains("Quarterly report") == true)
            #expect(response.totalTokens == 150)
            #expect(capture.value == "quarterly")
            let trailer = SessionTokenDisplay.label(
                model: provider.modelInfo.name,
                used: response.totalTokens ?? 0,
                window: provider.modelInfo.contextLength
            )
            #expect(trailer == "(smoke-model · 150/8192, 2%)")
            let history = await conversations.history(for: sessionID)
            #expect(history.contains { $0.role == .assistant && $0.content.contains("Calling email.search") })
            #expect(history.contains { $0.role == .assistant && $0.content.contains("call_smoke_search_01") })
            #expect(history.contains { $0.role == .tool && $0.toolCallID == "call_smoke_search_01" })
            let episodes = try await engine.episodes(for: sessionID)
            #expect(episodes.contains { $0.role == .user && $0.content == "Find my quarterly email" })
            #expect(episodes.contains { $0.role == .assistant && $0.content == "You have a quarterly report from your boss." })
            #expect(episodes.contains {
                $0.role == .tool && $0.content.contains("email.search") && $0.content.contains("Quarterly report")
            })
            let joined = episodes.map(\.content).joined(separator: "\n")
            #expect(!joined.contains("Calling "))
            #expect(!joined.contains("call_smoke_search_01"))
            #expect(!joined.contains(#""query":"quarterly""#))
            for episode in episodes {
                #expect(episode.metadata["tool_call_id"] == nil)
            }
        }
    }

    @Test
    func `Remember then recall across two sessions`() async throws {
        try await ToolsTestSupport.withTestPassword {
            let hits = try ToolsTestSupport.sharedSearchHits()
            let (base, engine, conversations, bus, systemPrompt, audit) = try await makeSmokeStack(
                gateway: ToolsTestSupport.StubEmailGateway(hits: hits)
            )
            defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
            let rememberCall = ToolInput(
                toolName: "memories.store",
                argumentsJSON: #"{"text":"My dog Biscuit loves brass compasses","category":"preference"}"#,
                callID: "call_smoke_remember_01"
            )
            let saveProvider = SmokeScriptedProvider(turns: [
                SmokeTurn(textDeltas: ["I will save that."], totalTokens: 10),
                SmokeTurn(textDeltas: ["Saved your preference."], totalTokens: 12)
            ])
            let saveCursor = SmokeBatchCursor(batches: [[rememberCall], []])
            let saveResolver: OrchestratorToolResolver = { _, _ in saveCursor.next() }
            let saveOrchestrator = Orchestrator(
                conversations: conversations,
                toolBus: bus,
                llm: saveProvider,
                systemPrompt: systemPrompt,
                toolResolver: saveResolver,
                memoryEngine: engine
            )
            let firstSession = UUID()
            let saved = try await saveOrchestrator.process(input: UserInput(
                text: "Please save that my dog Biscuit loves brass compasses",
                sessionID: firstSession
            ))
            #expect(saved.text == "Saved your preference.")
            #expect(saved.toolActions.count == 1)
            #expect(saved.toolActions.first?.toolName == "memories.store")
            #expect(saved.toolActions.first?.result?.isError == false)
            #expect(saved.totalTokens == 22)
            let profile = await engine.getUserProfile()
            #expect(profile.facts.contains { $0.content.contains("Biscuit") && $0.content.contains("brass compasses") })
            #expect(audit.captured().count == 1)
            #expect(audit.captured().first?.text.contains("Biscuit") == true)
            let recallCall = ToolInput(
                toolName: "memories.recall",
                argumentsJSON: #"{"query":"Biscuit dog","limit":5}"#,
                callID: "call_smoke_recall_01"
            )
            let recallProvider = SmokeScriptedProvider(turns: [
                SmokeTurn(textDeltas: ["I will recall what I know."], totalTokens: 11),
                SmokeTurn(textDeltas: ["Biscuit loves brass compasses, per your saved preference."], totalTokens: 13)
            ])
            let recallCursor = SmokeBatchCursor(batches: [[recallCall], []])
            let recallResolver: OrchestratorToolResolver = { _, _ in recallCursor.next() }
            let recallOrchestrator = Orchestrator(
                conversations: conversations,
                toolBus: bus,
                llm: recallProvider,
                systemPrompt: systemPrompt,
                toolResolver: recallResolver,
                memoryEngine: engine
            )
            let secondSession = UUID()
            #expect(secondSession != firstSession)
            let recalled = try await recallOrchestrator.process(input: UserInput(
                text: "What do you remember about Biscuit?",
                sessionID: secondSession
            ))
            #expect(recalled.text.contains("Biscuit"))
            #expect(recalled.toolActions.count == 1)
            #expect(recalled.toolActions.first?.toolName == "memories.recall")
            #expect(recalled.toolActions.first?.result?.isError == false)
            #expect(recalled.toolActions.first?.result?.content.contains("Biscuit") == true)
            #expect(recalled.toolActions.first?.result?.content.contains("brass compasses") == true)
            #expect(recalled.totalTokens == 24)
            let direct = try await engine.recall(query: "Biscuit", limit: 5)
            #expect(direct.contains { $0.content.contains("brass compasses") })
            let firstEpisodes = try await engine.episodes(for: firstSession)
            let secondEpisodes = try await engine.episodes(for: secondSession)
            #expect(!firstEpisodes.isEmpty)
            #expect(!secondEpisodes.isEmpty)
            #expect(secondEpisodes.contains { $0.content.contains("brass compasses") })
        }
    }

    @Test
    func `Every registered tool schema parses`() async throws {
        let hits = try ToolsTestSupport.sharedSearchHits()
        let (base, _, _, bus, systemPrompt, _) = try await makeSmokeStack(
            gateway: ToolsTestSupport.StubEmailGateway(hits: hits)
        )
        defer { ToolsTestSupport.cleanupIsolatedEngineBase(base) }
        let busTools = await bus.availableTools()
        let smokeExpected: Set = ["email.search", "email.read", "email.attachment", "memories.store", "memories.recall"]
        let busNames = Set(busTools.map(\.name))
        #expect(smokeExpected.isSubset(of: busNames), "Missing tools: \(smokeExpected.subtracting(busNames))")
        // Exhaustive registry mirrors the dedicated schema suite so smoke stays
        // honest when a new builtin lands: email plus memory plus files plus web.
        // The injected store keeps the mandatory egress supervisor hermetic.
        let policyStore = await ToolsTestSupport.makeTestPolicyStore()
        let networkTools = try await BuiltinToolPlugins.makeTools(policyStore: policyStore)
        let fullTools: [any Tool] = busTools + FilesTools.makeTools() + networkTools
        let expected: Set<String> = Set(EmailTools.toolNames + MemoryTools.toolNames + FilesTools.toolNames + BuiltinToolPlugins.toolNames)
        let names = Set(fullTools.map(\.name))
        #expect(expected.isSubset(of: names), "Missing tools: \(expected.subtracting(names))")
        #expect(fullTools.count >= expected.count)
        for tool in fullTools {
            let parsed = try encodeToolParameters(ToolDefinition(tool))
            #expect(parsed["type"] as? String == "object", "Tool \(tool.name) must declare type object")
            #expect(parsed["additionalProperties"] as? Bool == false, "Tool \(tool.name) must be strict")
            #expect((parsed["properties"] as? [String: Any]) != nil, "Tool \(tool.name) must declare properties")
        }
        let definitions = fullTools.map { ToolDefinition($0) }
        for definition in definitions {
            let parsed = try encodeToolParameters(definition)
            #expect(parsed["type"] as? String == "object")
            #expect(parsed["additionalProperties"] as? Bool == false)
        }
        let wireMessages = [Message(role: .user, content: "Smoke wire check")]
        let chatBody = try openAIChatRequestBody(model: "smoke-model", messages: wireMessages, tools: definitions, stream: true)
        let chatJSON = try #require(try JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let chatTools = try #require(chatJSON["tools"] as? [[String: Any]])
        #expect(chatTools.count == definitions.count)
        #expect(chatJSON["tool_choice"] as? String == "auto")
        let chatWireNames = Set(chatTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(expected.isSubset(of: chatWireNames), "Missing tools on chat wire: \(expected.subtracting(chatWireNames))")
        for entry in chatTools {
            #expect(entry["type"] as? String == "function")
            let function = try #require(entry["function"] as? [String: Any])
            let parameters = try #require(function["parameters"] as? [String: Any])
            #expect(parameters["type"] as? String == "object")
            #expect(parameters["additionalProperties"] as? Bool == false)
        }
        let responsesBody = try openAIResponsesRequestBody(model: "smoke-model", messages: wireMessages, tools: definitions, stream: true)
        let responsesJSON = try #require(try JSONSerialization.jsonObject(with: responsesBody) as? [String: Any])
        let responsesTools = try #require(responsesJSON["tools"] as? [[String: Any]])
        #expect(responsesTools.count == definitions.count)
        let responsesWireNames = Set(responsesTools.compactMap { $0["name"] as? String })
        #expect(expected.isSubset(of: responsesWireNames), "Missing tools on responses wire: \(expected.subtracting(responsesWireNames))")
        for entry in responsesTools {
            #expect(entry["type"] as? String == "function")
            let parameters = try #require(entry["parameters"] as? [String: Any])
            #expect(parameters["type"] as? String == "object")
            #expect(parameters["additionalProperties"] as? Bool == false)
        }
        // One corrupt schema must not fail the turn: the filter skips it while
        // direct encoding stays loud, keeping valid tools on both wires.
        let broken = ToolDefinition(name: "broken.tool", description: "Corrupt", parameters: JSONSchema(rawValue: "not-json"))
        do {
            _ = try encodeToolParameters(broken)
            Issue.record("encodeToolParameters should throw for corrupt schemas")
        } catch {
            #expect(error is LLMProviderError)
        }
        let mixed = definitions + [broken]
        let filtered = validatedDefinitions(mixed)
        #expect(filtered.valid.count == definitions.count)
        #expect(filtered.skipped == ["broken.tool"])
        let degradedChat = try openAIChatRequestBody(model: "smoke-model", messages: wireMessages, tools: mixed, stream: true)
        let degradedChatJSON = try #require(try JSONSerialization.jsonObject(with: degradedChat) as? [String: Any])
        let degradedChatTools = try #require(degradedChatJSON["tools"] as? [[String: Any]])
        #expect(degradedChatTools.count == definitions.count)
        let degradedResponses = try openAIResponsesRequestBody(model: "smoke-model", messages: wireMessages, tools: mixed, stream: true)
        let degradedResponsesJSON = try #require(try JSONSerialization.jsonObject(with: degradedResponses) as? [String: Any])
        let degradedResponsesTools = try #require(degradedResponsesJSON["tools"] as? [[String: Any]])
        #expect(degradedResponsesTools.count == definitions.count)
        let attachment = try #require(await bus.tool(named: "email.attachment"))
        let parsed = try encodeToolParameters(ToolDefinition(attachment))
        let properties = try #require(parsed["properties"] as? [String: Any])
        for key in ["account", "id", "index", "mailbox", "preview", "subpath", "saveToPath"] {
            #expect(properties[key] != nil, "Missing property \(key)")
        }
        #expect(parsed["additionalProperties"] as? Bool == false)
        let prompt = systemPrompt
        #expect(prompt.contains("Rune Weaver"))
        #expect(prompt.contains("memories.store"))
        #expect(prompt.contains("memories.recall"))
        #expect(!prompt.contains("Available tools:"))
        // Full prompt composition verifies lean prompt consistency.
        let fullBus = ToolBus()
        for tool in fullTools {
            await fullBus.register(tool: tool)
        }
        let fullPrompt = await SystemPromptComposer.compose(toolBus: fullBus)
        #expect(fullPrompt.contains("Rune Weaver"))
        #expect(fullPrompt.contains("memories.store"))
        #expect(fullPrompt.contains("memories.recall"))
        #expect(!fullPrompt.contains("Available tools:"))
    }

    @Test
    func `Wildcard and empty search map to ALL newest-first`() async throws {
        try await ToolsTestSupport.withTestPassword {
            let hits = try ToolsTestSupport.sharedSearchHits()
            let capture = ToolsTestSupport.QueryCapture()
            let tool = EmailSearchTool(
                emailConfig: ToolsTestSupport.testEmailConfig(),
                gateway: ToolsTestSupport.StubEmailGateway(hits: hits, capture: capture)
            )
            let empty = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"  "}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(empty.isError == false)
            #expect(capture.value == "")
            #expect(empty.content.contains("Quarterly report"))
            let wildcard = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":1}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(wildcard.isError == false)
            #expect(capture.value == "")
            let single = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(wildcard.content.utf8))
            #expect(single.query == "")
            #expect(single.count == 1)
            #expect(single.messages.count == 1)
            #expect(single.messages[0].id == "42")
            #expect(single.messages[0].subject == "Quarterly report")
            let full = try await tool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"*","limit":2}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(full.isError == false)
            let both = try JSONDecoder().decode(EmailSearchEnvelope.self, from: Data(full.content.utf8))
            #expect(both.count == 2)
            #expect(both.messages.map(\.id) == ["42", "41"])
        }
    }

    @Test
    func `Production bridge source parses and stub gateway covers every op`() async throws {
        let source = EmailIMAPBridgeScript.source
        #expect(source.contains("op == \"list\""))
        #expect(source.contains("op == \"search\""))
        #expect(source.contains("op == \"fetch\""))
        #expect(source.contains("op == \"attachment\""))
        #expect(source.contains("attachmentIndex"))
        #expect(source.contains("messageID"))
        #expect(source.contains("is_selectable"))
        #expect(source.contains("(BODY.PEEK[])"))
        try ToolsTestSupport.assertBridgeSourceParses(source)
        let credentials = ResolvedEmailCredentials(
            accountName: "personal",
            host: "mail.yourdomain.com",
            port: 993,
            username: "you@yourdomain.com",
            password: "test-secret"
        )
        func bridgeDocument(_ request: EmailIMAPBridgeRequest) throws -> [String: Any] {
            let data = try JSONEncoder().encode(request)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let document = object as? [String: Any] else {
                Issue.record("Bridge request did not encode as an object")
                return [:]
            }
            return document
        }
        let listDocument = try bridgeDocument(.list(credentials: credentials))
        #expect(listDocument["op"] as? String == "list")
        #expect(listDocument["host"] as? String == "mail.yourdomain.com")
        let searchDocument = try bridgeDocument(.search(credentials: credentials, query: "quarterly", limit: 10, mailbox: "INBOX"))
        #expect(searchDocument["op"] as? String == "search")
        #expect(searchDocument["query"] as? String == "quarterly")
        #expect(searchDocument["limit"] as? Int == 10)
        #expect(searchDocument["mailbox"] as? String == "INBOX")
        let fetchDocument = try bridgeDocument(.fetch(credentials: credentials, messageID: "42", mailbox: "INBOX"))
        #expect(fetchDocument["op"] as? String == "fetch")
        #expect(fetchDocument["messageID"] as? String == "42")
        #expect(fetchDocument["mailbox"] as? String == "INBOX")
        let attachmentDocument = try bridgeDocument(.attachment(credentials: credentials, messageID: "42", attachmentIndex: 0, mailbox: "INBOX"))
        #expect(attachmentDocument["op"] as? String == "attachment")
        #expect(attachmentDocument["messageID"] as? String == "42")
        #expect(attachmentDocument["attachmentIndex"] as? Int == 0)
        #expect(attachmentDocument["mailbox"] as? String == "INBOX")
        try await ToolsTestSupport.withTestPassword {
            let hits = try ToolsTestSupport.sharedSearchHits()
            let bytes = Data("hello world".utf8)
            let message = EmailFullMessage(
                id: "42",
                subject: "Quarterly report",
                from: "boss@example.com",
                to: "you@yourdomain.com",
                date: "Mon, 01 Sep 2025 09:00:00 +0000",
                body: "Please review the quarterly numbers attached.",
                attachments: [EmailAttachmentInfo(filename: "report.pdf", contentType: "application/pdf", sizeBytes: bytes.count)]
            )
            let downloadable = EmailAttachmentData(
                filename: "report.pdf",
                contentType: "application/pdf",
                sizeBytes: bytes.count,
                data: bytes
            )
            let gateway = ToolsTestSupport.StubEmailGateway(
                hits: hits,
                message: message,
                attachment: downloadable,
                listedMailboxes: ["INBOX"]
            )
            let stubCredentials = ResolvedEmailCredentials(
                accountName: "personal",
                host: "mail.yourdomain.com",
                port: 993,
                username: "you@yourdomain.com",
                password: "test-secret"
            )
            let mailboxes = try await gateway.listMailboxes(credentials: stubCredentials)
            #expect(mailboxes == ["INBOX"])
            let searched = try await gateway.search(credentials: stubCredentials, mailbox: "INBOX", query: "quarterly", limit: 10)
            #expect(searched.count == 2)
            #expect(searched[0].id == "42")
            #expect(searched[0].mailbox == "INBOX")
            let fetched = try await gateway.fetch(credentials: stubCredentials, mailbox: "INBOX", messageID: "42")
            #expect(fetched.id == "42")
            #expect(fetched.attachments.count == 1)
            #expect(fetched.attachments[0].filename == "report.pdf")
            let downloaded = try await gateway.attachment(credentials: stubCredentials, mailbox: "INBOX", messageID: "42", attachmentIndex: 0)
            #expect(downloaded.filename == "report.pdf")
            #expect(downloaded.data == bytes)
            let config = ToolsTestSupport.testEmailConfig()
            let searchTool = EmailSearchTool(emailConfig: config, gateway: gateway)
            let searchOutput = try await searchTool.execute(
                input: ToolInput(toolName: "email.search", argumentsJSON: #"{"account":"personal","query":"quarterly","limit":10}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(searchOutput.isError == false)
            #expect(searchOutput.content.contains("Quarterly report"))
            let readTool = EmailReadTool(emailConfig: config, gateway: gateway)
            let readOutput = try await readTool.execute(
                input: ToolInput(toolName: "email.read", argumentsJSON: #"{"account":"personal","id":"42","mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(readOutput.isError == false)
            #expect(readOutput.content.contains("quarterly numbers"))
            let attachmentTool = EmailAttachmentTool(
                emailConfig: config,
                gateway: gateway,
                containersConfig: ContainersConfig()
            )
            let stagedOutput = try await attachmentTool.execute(
                input: ToolInput(toolName: "email.attachment", argumentsJSON: #"{"account":"personal","id":"42","index":0,"mailbox":"INBOX"}"#),
                context: ToolContext(conversationID: UUID())
            )
            #expect(stagedOutput.isError == false)
            struct StagedAttachment: Decodable { let path: String?; let skipped: Bool }
            let staged = try JSONDecoder().decode(StagedAttachment.self, from: Data(stagedOutput.content.utf8))
            #expect(staged.skipped == false)
            let path = try #require(staged.path)
            #expect(path.contains("runeweaver-attachments"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
            #expect(!stagedOutput.content.contains("test-secret"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }
}
