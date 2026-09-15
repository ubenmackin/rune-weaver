// Rune Weaver LLM Tests — Chat SSE usage-only tail parsing tests.
import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("Chat SSE Usage")
struct ChatSSEUsageTests {
    @Test
    func `Usage-only final chunk with empty choices is captured`() throws {
        let decoder = JSONDecoder()
        var lastModel = "fallback-model"
        var lastUsage: TokenUsage?
        var lastFinishReason: String?
        var accumulator = OpenAIToolCallAccumulator()

        let payloads = [
            #"{"model":"llama-model","choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#,
            #"{"model":"llama-model","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"{"model":"llama-model","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}"#
        ]
        var texts: [String?] = []
        for payload in payloads {
            let data = try #require(payload.data(using: .utf8))
            let chunk = try decoder.decode(OpenAIStreamChunkDTO.self, from: data)
            let text = OpenAISSEPump.ingestChatChunk(
                chunk,
                lastModel: &lastModel,
                lastUsage: &lastUsage,
                lastFinishReason: &lastFinishReason,
                toolAccumulator: &accumulator
            )
            texts.append(text)
        }
        #expect(texts[0] == "Hello")
        #expect(texts[1] == nil)
        #expect(texts[2] == nil)
        #expect(lastModel == "llama-model")
        #expect(lastFinishReason == "stop")
        #expect(lastUsage == TokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30))
    }

    @Test
    func `Text chunk without usage leaves usage nil`() throws {
        let decoder = JSONDecoder()
        var lastModel = "fallback-model"
        var lastUsage: TokenUsage?
        var lastFinishReason: String?
        var accumulator = OpenAIToolCallAccumulator()

        let payload = #"{"model":"llama-model","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#
        let data = try #require(payload.data(using: .utf8))
        let chunk = try decoder.decode(OpenAIStreamChunkDTO.self, from: data)
        let text = OpenAISSEPump.ingestChatChunk(
            chunk,
            lastModel: &lastModel,
            lastUsage: &lastUsage,
            lastFinishReason: &lastFinishReason,
            toolAccumulator: &accumulator
        )
        #expect(text == "Hi")
        #expect(lastUsage == nil)
        #expect(lastModel == "llama-model")
    }
}
