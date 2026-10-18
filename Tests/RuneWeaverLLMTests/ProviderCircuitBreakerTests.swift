// Rune Weaver LLM Tests — Provider circuit breaker and routing failover tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("Provider Circuit Breaker Tests")
struct ProviderCircuitBreakerTests {
    private struct MockProvider: LLMProvider, Sendable {
        let modelInfo: ModelInfo
        let outcome: @Sendable () -> LLMResponse

        func isAvailable() async -> Bool {
            true
        }

        func chat(messages _: [Message], tools _: [any Tool], sessionID _: String?) -> AsyncStream<LLMResponse> {
            AsyncStream { continuation in
                continuation.yield(outcome())
                continuation.finish()
            }
        }

        func chat(messages: [Message], tools: [any Tool]) -> AsyncStream<LLMResponse> {
            chat(messages: messages, tools: tools, sessionID: nil)
        }

        func embeddings(text _: [String]) async throws -> [[Float]] {
            []
        }
    }

    @Test
    func `HTTP 429 rate limit trips cooldown immediately for 60 seconds`() async throws {
        let breaker = ProviderCircuitBreaker(rateLimitCooldown: 60)
        let provider = MockProvider(
            modelInfo: ModelInfo(name: "cloud-v1", provider: "openrouter", contextLength: 4096),
            outcome: { LLMResponse(delta: "", isFinished: true) }
        )

        #expect(await breaker.isAvailable(provider: provider) == true)

        let now = Date()
        await breaker.recordFailure(provider: provider, error: "HTTP 429: Too Many Requests - rate limit exceeded", at: now)

        #expect(await breaker.isAvailable(provider: provider, at: now) == false)
        let remaining = await breaker.cooldownRemaining(provider: provider, at: now)
        #expect(remaining != nil)
        #expect(try #require(remaining) <= 60 && #require(remaining) > 50)

        // After 61 seconds, breaker allows calls again
        let later = now.addingTimeInterval(61)
        #expect(await breaker.isAvailable(provider: provider, at: later) == true)
    }

    @Test
    func `two consecutive 503 errors trip 180 second outage cooldown`() async throws {
        let breaker = ProviderCircuitBreaker(outageCooldown: 180, failureThreshold: 2)
        let provider = MockProvider(
            modelInfo: ModelInfo(name: "deepseek", provider: "azure", contextLength: 8192),
            outcome: { LLMResponse(delta: "", isFinished: true) }
        )

        let now = Date()
        // First failure: does not trip
        await breaker.recordFailure(provider: provider, error: "503 Service Unavailable", at: now)
        #expect(await breaker.isAvailable(provider: provider, at: now) == true)

        // Second failure: trips outage cooldown
        await breaker.recordFailure(provider: provider, error: "503 Service Unavailable", at: now)
        #expect(await breaker.isAvailable(provider: provider, at: now) == false)
        let remaining = await breaker.cooldownRemaining(provider: provider, at: now)
        #expect(remaining != nil)
        #expect(try #require(remaining) <= 180 && #require(remaining) > 170)

        // Success resets failures
        await breaker.recordSuccess(provider: provider)
        #expect(await breaker.isAvailable(provider: provider, at: now) == true)
    }

    @Test
    func `router skips cooling provider and routes to healthy fallback`() async {
        let breaker = ProviderCircuitBreaker(outageCooldown: 180, failureThreshold: 1)
        let primary = MockProvider(
            modelInfo: ModelInfo(name: "primary-model", provider: "cloud", contextLength: 4096),
            outcome: { LLMResponse(delta: "from primary", isFinished: true) }
        )
        let fallback = MockProvider(
            modelInfo: ModelInfo(name: "fallback-model", provider: "local", contextLength: 4096),
            outcome: { LLMResponse(delta: "from fallback", isFinished: true) }
        )

        // Trip primary provider into cooldown
        await breaker.recordFailure(provider: primary, error: "HTTP 503 Outage")
        #expect(await breaker.isAvailable(provider: primary) == false)
        #expect(await breaker.isAvailable(provider: fallback) == true)

        let router = LLMRouter(providers: [primary, fallback], circuitBreaker: breaker)
        var received = ""
        for await chunk in await router.chat(messages: [], tools: []) {
            received += chunk.delta
        }

        #expect(received == "from fallback")
    }
}
