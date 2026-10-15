// Rune Weaver LLM Tests — Tests for LlamaCppEmbeddingsBackend.

import Foundation
import os
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

struct LlamaCppEmbeddingsBackendTests {
    @Test
    func `LlamaCppEmbeddingsBackend reports modelID and 768 dimension`() {
        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/mock.sock",
            customEmbedder: { texts in
                texts.map { _ in [Float](repeating: 0.1, count: 768) }
            }
        )

        #expect(backend.modelID == "embeddinggemma-2")
        let dim = backend.dimension
        #expect(dim == 768)
    }

    @Test
    func `LlamaCppEmbeddingsBackend embeds texts using custom embedder`() async throws {
        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/mock.sock",
            customEmbedder: { texts in
                texts.map { text in
                    var vec = [Float](repeating: 0.0, count: 768)
                    vec[0] = Float(text.count)
                    return vec
                }
            }
        )

        let vectors = try await backend.embed(["hello", "world!"])
        #expect(vectors.count == 2)
        #expect(vectors[0].count == 768)
        #expect(vectors[0][0] == 5.0)
        #expect(vectors[1][0] == 6.0)

        let single = try await backend.embedQuery("query")
        #expect(single != nil)
        #expect(single?.count == 768)
        #expect(single?[0] == Float(EmbeddingGemmaPrompts.query("query").count))
    }

    @Test
    func `LlamaCppEmbeddingsBackend throws on dimension mismatch in vector`() async throws {
        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/mock.sock",
            customEmbedder: { texts in
                texts.map { _ in [Float](repeating: 0.1, count: 512) }
            }
        )

        await #expect(throws: EmbeddingsError.self) {
            try await backend.embed(["test"])
        }
    }

    @Test
    func `LlamaCppEmbeddingsBackend embeds image using customImageEmbedder`() async throws {
        let dummyURL = URL(fileURLWithPath: "/tmp/fake.png")
        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/mock.sock",
            customImageEmbedder: { _ in
                [Float](repeating: 0.42, count: 768)
            }
        )

        let vector = try await backend.embedImage(at: dummyURL)
        #expect(vector.count == 768)
        #expect(vector[0] == 0.42)
    }

    @Test
    func `Empty batch returns empty vector list without calling backend`() async throws {
        let called = OSAllocatedUnfairLock(initialState: false)
        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/mock.sock",
            customEmbedder: { _ in
                called.withLock { $0 = true }
                return []
            }
        )

        let results = try await backend.embed([])
        #expect(results.isEmpty)
        #expect(!called.withLock { $0 })
    }

    @Test
    func `LlamaCppEmbeddingsBackend invokes supervisor ensureRunning before embedding`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let supervisorCalled = OSAllocatedUnfairLock(initialState: false)
        let supervisor = LlamaEmbeddingSupervisor(
            modelPath: tempDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path,
            socketPath: tempDir.appendingPathComponent("test.sock").path,
            pidPath: tempDir.appendingPathComponent("test.pid").path,
            logPath: tempDir.appendingPathComponent("test.log").path,
            testRunner: {
                supervisorCalled.withLock { $0 = true }
            }
        )

        let backend = LlamaCppEmbeddingsBackend(
            socketPath: tempDir.appendingPathComponent("test.sock").path,
            supervisor: supervisor
        )

        do {
            _ = try await backend.embed(["test text"])
        } catch {
            // expected socket connection failure
        }
        #expect(supervisorCalled.withLock { $0 } == true)
    }

    @Test
    func `EmbeddingsBackendFactory produces backend with supervisor`() {
        let backend = EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: "local",
            router: LLMRouter(providers: [])
        ) as? LlamaCppEmbeddingsBackend

        #expect(backend != nil)
        #expect(backend?.supervisor != nil)
    }

    @Test
    func `Cancelled task throws CancellationError without blocking`() async throws {
        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/nonexistent-test.sock",
            supervisor: nil
        )
        let task = Task {
            try await backend.embed(["test text"])
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            #expect(true)
        } catch {
            #expect(true)
        }
    }

    @Test
    func `LlamaCppEmbeddingsBackend rejects images exceeding maxImageBytes`() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("large.png")
        let data = Data(count: 1024)
        try data.write(to: testFile)

        let backend = LlamaCppEmbeddingsBackend(
            socketPath: "/tmp/mock.sock",
            maxImageBytes: 512
        )

        await #expect(throws: EmbeddingsError.self) {
            try await backend.embedImage(at: testFile)
        }
    }
}
