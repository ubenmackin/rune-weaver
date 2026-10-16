// Rune Weaver LLM Tests — LLM router dispatch and priority tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("LLM Router")
struct LLMRouterTests {
    @Test
    func `Empty router streams nothing`() async {
        let router = LLMRouter()
        var count = 0
        for await _ in await router.chat(messages: [], tools: []) {
            count += 1
        }
        #expect(count == 0)
    }

    @Test
    func `Generic entry with responses style maps to responses provider`() {
        let entry = ProviderConfig(
            enabled: true,
            serverURL: "https://example.com/v1",
            apiKeyEnv: "EXAMPLE_API_KEY",
            apiStyle: .responses
        )
        guard let provider = LLMProviderFactory.makeProvider(entryName: "custom", config: entry) else {
            Issue.record("Expected a provider for an enabled generic entry")
            return
        }
        guard let compat = provider as? OpenAICompatibleProvider else {
            Issue.record("Expected an OpenAICompatibleProvider, got \(type(of: provider))")
            return
        }
        #expect(compat.apiStyle == .responses)
        #expect(compat.providerID == "custom")
    }

    @Test
    func `Responses SSE fixture maps deltas tool calls and usage`() throws {
        let payloads = [
            #"{"type":"response.output_text.delta","delta":"Hello "}"#,
            #"{"type":"response.output_text.delta","delta":"world"}"#,
            #"{"type":"response.output_item.added","item":{"type":"function_call","name":"email.search","arguments":"{\"query\":\"hello\"}","call_id":"call_123"}}"#,
            #"{"type":"response.mystery.event","foo":"bar"}"#,
            #"{"type":"response.completed","response":{"model":"gpt-4o-mini","usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30}}}"#
        ]
        var text = ""
        var model = "fallback-model"
        var usage: TokenUsage?
        var accumulator = OpenAIResponsesToolCallAccumulator()
        let decoder = JSONDecoder()
        for payload in payloads {
            let data = try #require(payload.data(using: .utf8))
            let event = try decoder.decode(OpenAIResponsesStreamEventDTO.self, from: data)
            let nextIndex = accumulator.count
            accumulator.ingest(event, nextIndex: nextIndex)
            switch OpenAISSEPump.effect(for: event, nextIndex: nextIndex) {
            case let .textDelta(delta):
                text += delta
            case let .completed(reportedModel, reportedUsage):
                if let reportedModel {
                    model = reportedModel
                }
                if let reportedUsage {
                    usage = reportedUsage
                }
            case let .error(message):
                Issue.record("Unexpected error event in fixture: \(message)")
            case .toolCall:
                continue
            case .ignored:
                continue
            }
        }
        let toolCalls = accumulator.finishedCalls()
        #expect(text == "Hello world")
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.name == "email.search")
        #expect(toolCalls.first?.argumentsJSON == #"{"query":"hello"}"#)
        #expect(toolCalls.first?.id == "call_123")
        #expect(model == "gpt-4o-mini")
        #expect(usage == TokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30))
    }

    @Test
    func `Responses SSE accumulates split function arguments`() throws {
        let addedPayload =
            #"{"type":"response.output_item.added","item":{"type":"function_call","name":"email.search","arguments":"","call_id":"call_123","id":"fc_123"}}"#
        let completedPayload =
            #"{"type":"response.completed","response":{"model":"gpt-4o-mini","usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30}}}"#
        let deltaPayloads: [[String: Any]] = [
            ["type": "response.function_call_arguments.delta", "item_id": "fc_123", "delta": "{\"query\":"],
            ["type": "response.function_call_arguments.delta", "item_id": "fc_123", "delta": "\"hello\"}"]
        ]
        var text = ""
        var accumulator = OpenAIResponsesToolCallAccumulator()
        let decoder = JSONDecoder()
        let addedData = try #require(addedPayload.data(using: .utf8))
        let addedEvent = try decoder.decode(OpenAIResponsesStreamEventDTO.self, from: addedData)
        accumulator.ingest(addedEvent, nextIndex: accumulator.count)
        for deltaPayload in deltaPayloads {
            let data = try JSONSerialization.data(withJSONObject: deltaPayload)
            let event = try decoder.decode(OpenAIResponsesStreamEventDTO.self, from: data)
            let nextIndex = accumulator.count
            accumulator.ingest(event, nextIndex: nextIndex)
            switch OpenAISSEPump.effect(for: event, nextIndex: nextIndex) {
            case let .textDelta(delta):
                text += delta
            case .completed:
                continue
            case let .error(message):
                Issue.record("Unexpected error event in fixture: \(message)")
            case .toolCall:
                continue
            case .ignored:
                continue
            }
        }
        let completedData = try #require(completedPayload.data(using: .utf8))
        let completedEvent = try decoder.decode(OpenAIResponsesStreamEventDTO.self, from: completedData)
        switch OpenAISSEPump.effect(for: completedEvent, nextIndex: accumulator.count) {
        case let .completed(reportedModel, reportedUsage):
            #expect(reportedModel == "gpt-4o-mini")
            #expect(reportedUsage == TokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30))
        default:
            Issue.record("Expected a completed effect")
        }
        let toolCalls = accumulator.finishedCalls()
        #expect(text == "")
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.name == "email.search")
        #expect(toolCalls.first?.argumentsJSON == #"{"query":"hello"}"#)
        #expect(toolCalls.first?.id == "call_123")
    }

    @Test
    func `Session header present only when sessionID set`() {
        let body = Data("{}".utf8)
        let withoutSession = OpenAICompatibleHTTPClient(
            baseURL: "https://example.com/v1",
            model: "gpt-4o-mini"
        )
        let anonymous = withoutSession.makeRequest(path: "/responses", body: body)
        #expect(anonymous?.value(forHTTPHeaderField: "User-Agent") == RuneWeaverVersion.userAgent)
        #expect(anonymous?.value(forHTTPHeaderField: "x-opencode-session") == nil)

        let emptySession = OpenAICompatibleHTTPClient(
            baseURL: "https://example.com/v1",
            model: "gpt-4o-mini",
            sessionID: ""
        )
        let emptyRequest = emptySession.makeRequest(path: "/responses", body: body)
        #expect(emptyRequest?.value(forHTTPHeaderField: "User-Agent") == RuneWeaverVersion.userAgent)
        #expect(emptyRequest?.value(forHTTPHeaderField: "x-opencode-session") == nil)

        let withSession = OpenAICompatibleHTTPClient(
            baseURL: "https://example.com/v1",
            model: "gpt-4o-mini",
            sessionID: "sess-123"
        )
        let identified = withSession.makeRequest(path: "/responses", body: body)
        #expect(identified?.value(forHTTPHeaderField: "User-Agent") == RuneWeaverVersion.userAgent)
        #expect(identified?.value(forHTTPHeaderField: "x-opencode-session") == "sess-123")
    }
}
