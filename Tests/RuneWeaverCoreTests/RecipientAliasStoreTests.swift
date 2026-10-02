// Rune Weaver Core Tests — Durable recipient-alias store behavior.
//
// Purpose: pin the learned-alias contract the Messages send flow writes and
// recipient resolution reads: a recorded name-to-handle pair round-trips with
// the alias source, repeated confirmations increment the use count without
// erasing a stored service or display name (COALESCE), names are keyed by the
// shared normalizer, blank input is a true no-op, unreadable paths degrade to
// an empty array instead of throwing, and concurrent records and reads stay
// safe over the shared serial SQLite lane.
//
// Scope: the store against isolated temporary databases only. Tests never
// touch the real `~/.runeweaver/memory` store, and the resolver integration
// with the concrete store lives in the resolver suite.
//
// Architectural role: guards the production `MessageAliasStoring`
// implementation so alias persistence and the non-throwing degradation
// contract cannot drift silently.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Creates an isolated temporary database path and its parent directory.
/// - Returns: The `episodes.db` URL plus the base directory to remove on teardown.
private func makeAliasWorkspace() throws -> (dbURL: URL, base: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-alias-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("episodes.db"), base)
}

@Suite("Recipient Alias Store")
struct RecipientAliasStoreTests {
    @Test
    func `A recorded alias round-trips through a fresh store with the alias source`() async throws {
        let (dbURL, base) = try makeAliasWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let store = RecipientAliasStore(dbPath: dbURL.path)
        await store.recordAlias(
            name: "Rebecca Mackin",
            handle: "+15551234567",
            service: "iMessage",
            displayName: "Rebecca"
        )

        // A fresh actor over the same file proves the row reached disk and the
        // additive migration runs against a database it did not create.
        let reopened = RecipientAliasStore(dbPath: dbURL.path)
        let candidates = await reopened.aliases(nameKey: "rebecca mackin", limit: 5)

        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.handle == "+15551234567")
        #expect(candidate.service == "iMessage")
        #expect(candidate.displayName == "Rebecca")
        #expect(candidate.source == .alias)
        #expect(candidate.lastMessageAt == nil)
        #expect(candidate.contactID == nil)
    }

    @Test
    func `Repeated records increment the use count and COALESCE preserves stored details`() async throws {
        let (dbURL, base) = try makeAliasWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecipientAliasStore(dbPath: dbURL.path)

        await store.recordAlias(
            name: "Rebecca Mackin",
            handle: "+15551234567",
            service: "iMessage",
            displayName: "Rebecca"
        )
        // The second confirmation of the same pair carries nil details; the
        // count must still advance and the stored service/name must survive.
        await store.recordAlias(name: "Rebecca Mackin", handle: "+15551234567", service: nil, displayName: nil)
        // A later first-seen handle has a newer timestamp but a lower use count,
        // so ordering by count ahead of recency is what keeps the learned pair
        // first instead of the most recent typing.
        await store.recordAlias(name: "Rebecca Mackin", handle: "other@example.com", service: nil, displayName: nil)

        let ranked = await store.aliases(nameKey: "rebecca mackin", limit: 5)
        #expect(ranked.map(\.handle) == ["+15551234567", "other@example.com"])
        #expect(ranked.first?.service == "iMessage")
        #expect(ranked.first?.displayName == "Rebecca")

        // A later non-nil confirmation may refine both fields.
        await store.recordAlias(name: "Rebecca Mackin", handle: "+15551234567", service: "SMS", displayName: "Bex")
        let refined = await store.aliases(nameKey: "rebecca mackin", limit: 5)
        #expect(refined.first?.service == "SMS")
        #expect(refined.first?.displayName == "Bex")
    }

    @Test
    func `Names are keyed by the shared normalizer and handles trim`() async throws {
        let (dbURL, base) = try makeAliasWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecipientAliasStore(dbPath: dbURL.path)

        await store.recordAlias(
            name: "José  García",
            handle: "  jose@example.com  ",
            service: nil,
            displayName: nil
        )

        let normalizedKey = MessageRecipientNameNormalizer.normalize("  JOSÉ   GARCIA ")
        #expect(normalizedKey == "jose garcia")
        let candidates = await store.aliases(nameKey: normalizedKey, limit: 5)
        #expect(candidates.map(\.handle) == ["jose@example.com"])
    }

    @Test
    func `Blank names or handles are no-ops`() async throws {
        let (dbURL, base) = try makeAliasWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecipientAliasStore(dbPath: dbURL.path)

        await store.recordAlias(name: "   ", handle: "+15551234567", service: nil, displayName: nil)
        await store.recordAlias(name: "Rebecca", handle: "   ", service: nil, displayName: nil)
        await store.recordAlias(name: "", handle: "", service: nil, displayName: nil)

        // Blank input never reaches disk: no file exists yet and no key matches.
        #expect(FileManager.default.fileExists(atPath: dbURL.path) == false)
        let candidates = await store.aliases(nameKey: "rebecca", limit: 5)
        #expect(candidates.isEmpty)
    }

    @Test
    func `An unwritable path reads empty and swallows writes`() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-alias-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A regular file where the store needs a directory makes every open
        // fail before SQLite is reached, modelling an unwritable path.
        let blocker = base.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let store = RecipientAliasStore(dbPath: blocker.appendingPathComponent("episodes.db").path)
        await store.recordAlias(name: "Rebecca Mackin", handle: "+15551234567", service: nil, displayName: nil)
        let candidates = await store.aliases(nameKey: "rebecca mackin", limit: 5)
        #expect(candidates.isEmpty)
    }

    @Test
    func `Concurrent records and reads stay safe`() async throws {
        let (dbURL, base) = try makeAliasWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecipientAliasStore(dbPath: dbURL.path)

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    await store.recordAlias(
                        name: "Rebecca Mackin",
                        handle: "+155500000\(index)",
                        service: "iMessage",
                        displayName: "Rebecca"
                    )
                }
                group.addTask {
                    _ = await store.aliases(nameKey: "rebecca mackin", limit: 5)
                }
            }
        }

        let candidates = await store.aliases(nameKey: "rebecca mackin", limit: 10)
        #expect(candidates.count == 10)
        #expect(candidates.allSatisfy { $0.source == .alias })
        #expect(candidates.allSatisfy { $0.service == "iMessage" })
    }

    @Test
    func `Concurrent records of one pair produce a single row`() async throws {
        let (dbURL, base) = try makeAliasWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecipientAliasStore(dbPath: dbURL.path)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    await store.recordAlias(
                        name: "Rebecca Mackin",
                        handle: "+15551234567",
                        service: "iMessage",
                        displayName: "Rebecca"
                    )
                }
            }
        }

        // The composite primary key plus the atomic upsert keeps the pair to one
        // row even when every confirmation races the others.
        let candidates = await store.aliases(nameKey: "rebecca mackin", limit: 5)
        #expect(candidates.count == 1)
        #expect(candidates.first?.service == "iMessage")
    }
}
