// Rune Weaver Core Tests — VectorStore duplicate-id and corrupt-file load behavior.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Unique-per-test store directories plus facts.json fixture writing.
private enum VectorStoreTestSupport {
    /// Creates a fresh temporary store directory for one test.
    static func makeStoreDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-vectorstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Removes a temporary store directory.
    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    /// Writes a raw facts.json fixture into a store directory.
    static func writeFacts(_ json: String, to directory: URL) throws {
        try json.write(to: directory.appendingPathComponent("facts.json"), atomically: true, encoding: .utf8)
    }
}

/// Fixture id shared by both entries of the duplicate tests.
private let duplicateFixtureID = "11111111-1111-1111-1111-111111111111"

@Suite("VectorStore loading", .testLogCaptureBootstrap)
struct VectorStoreTests {
    @Test
    func `Duplicate ids keep the last occurrence and log one warning`() async throws {
        let base = try VectorStoreTestSupport.makeStoreDirectory()
        defer { VectorStoreTestSupport.cleanup(base) }
        let fixture = """
        [
          {"id":"\(duplicateFixtureID)","content":"first","embedding":[1,0],"metadata":{},"createdAt":100,"updatedAt":100},
          {"id":"\(duplicateFixtureID)","content":"second","embedding":[1,0],"metadata":{},"createdAt":200,"updatedAt":200}
        ]
        """
        try VectorStoreTestSupport.writeFacts(fixture, to: base)
        let store = VectorStore(directoryPath: base.path)
        #expect(await store.count() == 1)
        let id = try #require(UUID(uuidString: duplicateFixtureID))
        let retained = try #require(await store.fact(id: id))
        #expect(retained.content == "second")
        #expect(retained.embedding == [1, 0])
        #expect(retained.createdAt.timeIntervalSince1970 == 200)
        #expect(!TestLogCapture.records(containing: "duplicate fact id(s)").isEmpty)
    }

    @Test
    func `Reload deduplicates a duplicated facts.json the same way`() async throws {
        let base = try VectorStoreTestSupport.makeStoreDirectory()
        defer { VectorStoreTestSupport.cleanup(base) }
        let store = VectorStore(directoryPath: base.path)
        let fixture = """
        [
          {"id":"\(duplicateFixtureID)","content":"first","embedding":[1,0],"metadata":{},"createdAt":100,"updatedAt":100},
          {"id":"\(duplicateFixtureID)","content":"second","embedding":[1,0],"metadata":{},"createdAt":200,"updatedAt":200}
        ]
        """
        try VectorStoreTestSupport.writeFacts(fixture, to: base)
        await store.reload()
        #expect(await store.count() == 1)
        let id = try #require(UUID(uuidString: duplicateFixtureID))
        let retained = try #require(await store.fact(id: id))
        #expect(retained.content == "second")
        #expect(retained.createdAt.timeIntervalSince1970 == 200)
        #expect(!TestLogCapture.records(containing: "duplicate fact id(s)").isEmpty)
    }

    @Test
    func `Mixed-width duplicates derive dimension from the deduplicated set`() async throws {
        let base = try VectorStoreTestSupport.makeStoreDirectory()
        defer { VectorStoreTestSupport.cleanup(base) }
        let fixture = """
        [
          {"id":"\(duplicateFixtureID)","content":"narrow","embedding":[1,0],"metadata":{},"createdAt":100,"updatedAt":100},
          {"id":"\(duplicateFixtureID)","content":"wide","embedding":[1,0,0],"metadata":{},"createdAt":200,"updatedAt":200}
        ]
        """
        try VectorStoreTestSupport.writeFacts(fixture, to: base)
        let store = VectorStore(directoryPath: base.path)
        #expect(await store.dimension == 3)
        let id = try #require(UUID(uuidString: duplicateFixtureID))
        let retained = try #require(await store.fact(id: id))
        #expect(retained.embedding == [1, 0, 0])
        await store.reload()
        #expect(await store.dimension == 3)
    }

    @Test
    func `Corrupt facts.json degrades to an empty store with a warning`() async throws {
        let base = try VectorStoreTestSupport.makeStoreDirectory()
        defer { VectorStoreTestSupport.cleanup(base) }
        try VectorStoreTestSupport.writeFacts("definitely not json", to: base)
        let store = VectorStore(directoryPath: base.path)
        #expect(await store.count() == 0)
        #expect(await store.dimension == nil)
        #expect(!TestLogCapture.records(containing: "failed to decode facts").isEmpty)
    }

    @Test
    func `Absent facts.json loads empty`() async throws {
        let base = try VectorStoreTestSupport.makeStoreDirectory()
        defer { VectorStoreTestSupport.cleanup(base) }
        let store = VectorStore(directoryPath: base.path)
        #expect(await store.count() == 0)
        #expect(await store.allFacts().isEmpty)
    }
}
