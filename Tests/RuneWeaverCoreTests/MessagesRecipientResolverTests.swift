// Rune Weaver Core Tests — Recipient resolution composition and determinism.

import Foundation
import os
@testable import RuneWeaverCore
import Testing

/// Failure thrown by the history stub to model an unavailable database.
private enum StubHistoryFailure: Error {
    /// The snapshot could not be read.
    case unavailable
}

/// Lock-backed contact search stub recording every call it receives.
final class StubContactSearching: MessagesContactSearching, Sendable {
    /// One captured search request.
    struct SearchCall: Sendable, Equatable {
        /// Raw query passed by the resolver.
        let name: String
        /// Requested limit passed by the resolver.
        let limit: Int
    }

    private struct State: Sendable {
        var records: [MessageContactMatch]
        var names: [String: String]
        var searchCalls: [SearchCall] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates a stub over canned records and handle-to-name pairs. records:
    /// Contact records served by name search.
    init(records: [MessageContactMatch] = [], names: [String: String] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(records: records, names: names))
    }

    /// Search requests seen so far.
    var searchCalls: [SearchCall] {
        state.withLock { $0.searchCalls }
    }

    /// Serves the records that pass the shared matcher, honoring the requested limit.
    func search(name: String, limit: Int) async -> [MessageContactMatch] {
        state.withLock { current in
            current.searchCalls.append(SearchCall(name: name, limit: limit))
            return MessagesContactMatcher.match(name: name, records: current.records, limit: limit)
        }
    }

    /// Serves the canned handle-to-name map.
    func displayNames() -> [String: String] {
        state.withLock { $0.names }
    }
}

/// Lock-backed history stub serving canned rows or a canned failure.
final class StubHistorySourcing: MessagesHistorySourcing, Sendable {
    private struct State: Sendable {
        var stats: [MessageHandleStats]
        var fails: Bool
        var requestedLimits: [Int] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates a history stub. stats: Rows returned by a successful read.
    init(stats: [MessageHandleStats] = [], fails: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(stats: stats, fails: fails))
    }

    /// Limits requested by the resolver so far.
    var requestedLimits: [Int] {
        state.withLock { $0.requestedLimits }
    }

    /// Returns the canned rows, or throws the canned failure.
    func recentDirectHandleStats(limit: Int) async throws -> [MessageHandleStats] {
        try state.withLock { current in
            current.requestedLimits.append(limit)
            if current.fails {
                throw StubHistoryFailure.unavailable
            }
            return current.stats
        }
    }
}

/// Lock-backed alias stub serving candidates per name key and recording writes.
final class StubAliasStore: MessageAliasStoring, Sendable {
    /// One captured alias write.
    struct RecordedAlias: Sendable, Equatable {
        /// Raw name recorded.
        let name: String
        /// Handle recorded.
        let handle: String
        /// Service recorded, when supplied.
        let service: String?
        /// Display name recorded, when supplied.
        let displayName: String?
    }

    private struct State: Sendable {
        var candidatesByNameKey: [String: [MessageRecipientCandidate]]
        var requestedNameKeys: [String] = []
        var requestedLimits: [Int] = []
        var recorded: [RecordedAlias] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates an alias stub.
    /// - Parameter candidatesByNameKey: Canned candidates keyed by normalized name.
    init(candidatesByNameKey: [String: [MessageRecipientCandidate]] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(candidatesByNameKey: candidatesByNameKey))
    }

    /// Normalized name keys requested so far.
    var requestedNameKeys: [String] {
        state.withLock { $0.requestedNameKeys }
    }

    /// Limits requested so far.
    var requestedLimits: [Int] {
        state.withLock { $0.requestedLimits }
    }

    /// Alias writes recorded so far.
    var recorded: [RecordedAlias] {
        state.withLock { $0.recorded }
    }

    /// Serves canned candidates for the requested key, capped to the limit.
    func aliases(nameKey: String, limit: Int) async -> [MessageRecipientCandidate] {
        state.withLock { current in
            current.requestedNameKeys.append(nameKey)
            current.requestedLimits.append(limit)
            let candidates = current.candidatesByNameKey[nameKey] ?? []
            return Array(candidates.prefix(max(limit, 0)))
        }
    }

    /// Records one alias write without touching storage.
    func recordAlias(name: String, handle: String, service: String?, displayName: String?) async {
        state.withLock { current in
            current.recorded.append(RecordedAlias(name: name, handle: handle, service: service, displayName: displayName))
        }
    }
}

@Suite("Messages Recipient Resolver")
struct MessagesRecipientResolverTests {
    /// One day in seconds, used to place history instants relative to now.
    private static let day: TimeInterval = 24 * 60 * 60

    /// Builds one contact record.
    private func contact(id: String, name: String, handles: [String], alternates: [String] = []) -> MessageContactMatch {
        MessageContactMatch(contactID: id, displayName: name, alternateNames: alternates, handles: handles)
    }

    /// Builds one history row.
    private func stat(handle: String, service: String? = nil, at lastMessageAt: Date?, count: Int = 1) -> MessageHandleStats {
        MessageHandleStats(handle: handle, service: service, lastMessageAt: lastMessageAt, messageCount: count)
    }

    /// Builds a resolver over stubs, never touching live sources.
    private func resolver(
        contacts: StubContactSearching,
        history: StubHistorySourcing = StubHistorySourcing(),
        aliases: StubAliasStore? = nil
    ) -> MessagesRecipientResolver {
        MessagesRecipientResolver(contacts: contacts, history: history, aliasStore: aliases)
    }

    @Test
    func `Exact contact match outranks a prefix match`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-prefix", name: "Rebecca Mackin Smith", handles: ["prefix@example.com"]),
            contact(id: "c-exact", name: "Rebecca Mackin", handles: ["exact@example.com"])
        ])
        let resolution = await resolver(contacts: contacts).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["exact@example.com", "prefix@example.com"])
        #expect(resolution.selected?.handle == "exact@example.com")
        #expect(resolution.isAmbiguous == false)
    }

    @Test
    func `Contact score table ranks exact then prefix then whole-token`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-token", name: "Mackin, Rebecca", handles: ["token@example.com"]),
            contact(id: "c-prefix", name: "Rebecca Mackin Smith", handles: ["prefix@example.com"]),
            contact(id: "c-exact", name: "Rebecca Mackin", handles: ["exact@example.com"])
        ])
        let resolution = await resolver(contacts: contacts).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["exact@example.com", "prefix@example.com", "token@example.com"])
    }

    @Test
    func `Resolver expansion ranks records with the shared matcher score`() async {
        let query = "Rebecca Mackin"
        let records = [
            contact(id: "c-token", name: "Mackin, Rebecca", handles: ["token@example.com"]),
            contact(id: "c-prefix", name: "Rebecca Mackin Smith", handles: ["prefix@example.com"]),
            contact(id: "c-exact", name: "Rebecca Mackin", handles: ["exact@example.com"]),
            contact(id: "c-miss", name: "John Doe", handles: ["miss@example.com"])
        ]
        // One handle per record and no history means the resolver's order is
        // exactly the order of the matcher's shared score table, so scoring the
        // records through that table must reproduce the resolver's candidates.
        let normalized = MessageRecipientNameNormalizer.normalize(query)
        let sharedOrder = records
            .map { (id: $0.contactID, score: MessagesContactMatcher.bestScore(for: $0, query: normalized)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.id)
        #expect(sharedOrder == ["c-exact", "c-prefix", "c-token"])

        let resolution = await resolver(contacts: StubContactSearching(records: records)).resolve(name: query, limit: 10)
        #expect(resolution.candidates.compactMap(\.contactID) == sharedOrder)
    }

    @Test
    func `A recently messaged second handle of one contact is selected`() async {
        let recent = Date().addingTimeInterval(-3 * Self.day)
        let old = Date().addingTimeInterval(-40 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["+15551234567", "rebecca@example.com"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "+15551234567", service: "iMessage", at: old),
            stat(handle: "rebecca@example.com", service: "iMessage", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["rebecca@example.com", "+15551234567"])
        #expect(resolution.selected?.handle == "rebecca@example.com")
        #expect(resolution.isAmbiguous == false)
    }

    @Test
    func `Service rank breaks an equal-recency tie before handle order`() async {
        let recent = Date().addingTimeInterval(-2 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["a-sms@example.com", "z-imessage@example.com"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "a-sms@example.com", service: "SMS", at: recent),
            stat(handle: "z-imessage@example.com", service: "iMessage", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["z-imessage@example.com", "a-sms@example.com"])
        #expect(resolution.selected?.handle == "z-imessage@example.com")
    }

    @Test
    func `Distinct contacts with equal top scores are ambiguous`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["one@example.com"]),
            contact(id: "c-2", name: "Rebecca Mackin", handles: ["two@example.com"])
        ])
        let resolution = await resolver(contacts: contacts).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.count == 2)
        #expect(resolution.isAmbiguous == true)
        #expect(resolution.selected == nil)
    }

    @Test
    func `Two handles of one contact stay one identity and order by handle`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["b@example.com", "a@example.com"])
        ])
        let resolution = await resolver(contacts: contacts).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["a@example.com", "b@example.com"])
        #expect(resolution.selected?.handle == "a@example.com")
        #expect(resolution.isAmbiguous == false)
    }

    @Test
    func `One contact identity among several still leaves distinct contacts ambiguous`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["one@example.com", "two@example.com"]),
            contact(id: "c-2", name: "Rebecca Mackin", handles: ["three@example.com"])
        ])
        let resolution = await resolver(contacts: contacts).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.count == 3)
        #expect(resolution.isAmbiguous == true)
        #expect(resolution.selected == nil)
    }

    @Test
    func `An alias hit outranks an exact contact match and uses the normalized key`() async {
        let aliases = StubAliasStore(candidatesByNameKey: [
            "rebecca mackin": [
                MessageRecipientCandidate(displayName: "Bex", handle: "bex@example.com", source: .contact)
            ]
        ])
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["rebecca@example.com"])
        ])
        let resolution = await resolver(contacts: contacts, aliases: aliases).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["bex@example.com", "rebecca@example.com"])
        #expect(resolution.selected?.handle == "bex@example.com")
        #expect(resolution.selected?.source == .alias)
        #expect(aliases.requestedNameKeys == ["rebecca mackin"])
        #expect(aliases.requestedLimits == [5])
    }

    @Test
    func `Recency bonuses apply to alias hits as well`() async {
        let recent = Date().addingTimeInterval(-1 * Self.day)
        let aliases = StubAliasStore(candidatesByNameKey: [
            "rebecca mackin": [
                MessageRecipientCandidate(displayName: "Bex", handle: "bex@example.com", source: .alias)
            ]
        ])
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["rebecca@example.com"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "bex@example.com", service: "iMessage", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history, aliases: aliases)
            .resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.selected?.handle == "bex@example.com")
        #expect(resolution.selected?.service == "iMessage")
        #expect(resolution.selected?.lastMessageAt == recent)
    }

    @Test
    func `Empty names yield an empty resolution with the raw query`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["rebecca@example.com"])
        ])
        let subject = resolver(contacts: contacts)

        let blank = await subject.resolve(name: "   ", limit: 5)
        #expect(blank.query == "   ")
        #expect(blank.candidates.isEmpty)
        #expect(blank.selected == nil)
        #expect(blank.isAmbiguous == false)

        let empty = await subject.resolve(name: "", limit: 5)
        #expect(empty.query == "")
        #expect(empty.candidates.isEmpty)
        #expect(empty.selected == nil)
    }

    @Test
    func `A handle input returns a single passthrough candidate`() async {
        // The stub key is the folded national form, since the typed E.164
        // handle now canonicalizes to the same key Contacts stores.
        let contacts = StubContactSearching(names: ["5551234567": "Alice"])
        let resolution = await resolver(contacts: contacts).resolve(name: "+1 (555) 123-4567", limit: 5)
        #expect(resolution.candidates.count == 1)
        #expect(resolution.selected == resolution.candidates.first)
        #expect(resolution.selected?.source == .handle)
        #expect(resolution.selected?.handle == "+15551234567")
        #expect(resolution.selected?.displayName == "Alice")
        #expect(resolution.isAmbiguous == false)
        // The passthrough path never searches the address book by name.
        #expect(contacts.searchCalls.isEmpty)
    }

    @Test
    func `A handle input is enriched by history`() async throws {
        let recent = Date().addingTimeInterval(-2 * Self.day)
        let history = StubHistorySourcing(stats: [
            stat(handle: "555.123.4567", service: "iMessage", at: recent)
        ])
        let resolution = await resolver(contacts: StubContactSearching(), history: history)
            .resolve(name: "555.123.4567", limit: 5)
        let candidate = try #require(resolution.candidates.first)
        #expect(candidate.handle == "5551234567")
        #expect(candidate.service == "iMessage")
        #expect(candidate.lastMessageAt == recent)
        #expect(history.requestedLimits == [200])
    }

    @Test
    func `History failure degrades to contact-only candidates`() async {
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["rebecca@example.com"])
        ])
        let resolution = await resolver(contacts: contacts, history: StubHistorySourcing(fails: true))
            .resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.count == 1)
        #expect(resolution.candidates.first?.handle == "rebecca@example.com")
        #expect(resolution.candidates.first?.service == nil)
        #expect(resolution.candidates.first?.lastMessageAt == nil)
        #expect(resolution.selected?.handle == "rebecca@example.com")
    }

    @Test
    func `History stats enrich contact candidates with service and recency`() async throws {
        let recent = Date().addingTimeInterval(-3 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["rebecca@example.com"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "rebecca@example.com", service: "iMessage", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        let candidate = try #require(resolution.candidates.first)
        #expect(candidate.service == "iMessage")
        #expect(candidate.lastMessageAt == recent)
        #expect(candidate.contactID == "c-1")
    }

    @Test
    func `Best history row per handle key wins by recency`() async throws {
        let recent = Date().addingTimeInterval(-1 * Self.day)
        let old = Date().addingTimeInterval(-40 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["+15551234567"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "+15551234567", service: "iMessage", at: old),
            stat(handle: "15551234567", service: "SMS", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        let candidate = try #require(resolution.candidates.first)
        #expect(candidate.service == "SMS")
        #expect(candidate.lastMessageAt == recent)
    }

    @Test
    func `Best history row per handle key falls back to service rank`() async throws {
        let recent = Date().addingTimeInterval(-2 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["+15551234567"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "+15551234567", service: "SMS", at: recent),
            stat(handle: "15551234567", service: "iMessage", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        let candidate = try #require(resolution.candidates.first)
        #expect(candidate.service == "iMessage")
    }

    @Test
    func `Cross-format phone history enriches the national contact handle`() async throws {
        // Contacts keeps the national spelling while chat history stores E.164;
        // the shared key fold must still join them, or the phone side loses its
        // recency bonus and a stale email wrongly wins.
        let recent = Date().addingTimeInterval(-2 * Self.day)
        let stale = Date().addingTimeInterval(-10 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["(916) 390-7495", "rebecca@example.com"])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "+19163907495", service: "iMessage", at: recent),
            stat(handle: "rebecca@example.com", service: "SMS", at: stale)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == ["(916) 390-7495", "rebecca@example.com"])
        let selected = try #require(resolution.selected)
        #expect(selected.handle == "(916) 390-7495")
        #expect(selected.service == "iMessage")
        #expect(selected.lastMessageAt == recent)
        #expect(resolution.isAmbiguous == false)
    }

    @Test
    func `Recency bonuses order recent over stale over undated handles`() async {
        let recent = Date().addingTimeInterval(-3 * Self.day)
        let stale = Date().addingTimeInterval(-10 * Self.day)
        let old = Date().addingTimeInterval(-40 * Self.day)
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: [
                "undated@example.com",
                "old@example.com",
                "stale@example.com",
                "recent@example.com"
            ])
        ])
        let history = StubHistorySourcing(stats: [
            stat(handle: "old@example.com", at: old),
            stat(handle: "stale@example.com", at: stale),
            stat(handle: "recent@example.com", at: recent)
        ])
        let resolution = await resolver(contacts: contacts, history: history).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.map(\.handle) == [
            "recent@example.com",
            "stale@example.com",
            "old@example.com",
            "undated@example.com"
        ])
        #expect(resolution.selected?.handle == "recent@example.com")
    }

    @Test
    func `Dedupe collapses one handle across alias and contact keeping the richest name`() async throws {
        let aliases = StubAliasStore(candidatesByNameKey: [
            "rebecca mackin": [
                MessageRecipientCandidate(displayName: "Bex", handle: "+1 (555) 123-4567", source: .contact)
            ]
        ])
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["+15551234567"]),
            contact(id: "c-2", name: "Rebecca Mackin", handles: ["two@example.com"])
        ])
        let resolution = await resolver(contacts: contacts, aliases: aliases).resolve(name: "Rebecca Mackin", limit: 5)
        #expect(resolution.candidates.count == 2)
        let merged = try #require(resolution.candidates.first)
        #expect(merged.source == .alias)
        #expect(merged.displayName == "Rebecca Mackin")
        #expect(MessageRecipientNameNormalizer.handleKey(merged.handle) == "5551234567")
        #expect(resolution.selected?.source == .alias)
        #expect(resolution.isAmbiguous == false)
    }

    @Test
    func `Limit clamps to one minimum and ten maximum`() async {
        let records = (0 ..< 20).map { index in
            contact(id: "c-\(index)", name: "Rebecca Mackin", handles: ["handle\(index)@example.com"])
        }
        let contacts = StubContactSearching(records: records)
        let subject = resolver(contacts: contacts)

        let wide = await subject.resolve(name: "Rebecca Mackin", limit: 100)
        #expect(wide.candidates.count == 10)
        let zero = await subject.resolve(name: "Rebecca Mackin", limit: 0)
        #expect(zero.candidates.count == 1)
        let negative = await subject.resolve(name: "Rebecca Mackin", limit: -5)
        #expect(negative.candidates.count == 1)
        let three = await subject.resolve(name: "Rebecca Mackin", limit: 3)
        #expect(three.candidates.count == 3)
        #expect(contacts.searchCalls.map(\.limit) == [10, 1, 1, 3])
    }

    @Test
    func `The default candidate budget is five`() async {
        let records = (0 ..< 20).map { index in
            contact(id: "c-\(index)", name: "Rebecca Mackin", handles: ["handle\(index)@example.com"])
        }
        let resolution = await resolver(contacts: StubContactSearching(records: records))
            .resolve(name: "Rebecca Mackin")
        #expect(resolution.candidates.count == 5)
    }

    @Test
    func `Diacritic names fold on both sides of the match`() async {
        let accented = StubContactSearching(records: [
            contact(id: "c-accent", name: "José  García", handles: ["accent@example.com"])
        ])
        let first = await resolver(contacts: accented).resolve(name: "jose garcia", limit: 5)
        #expect(first.selected?.handle == "accent@example.com")

        let aliases = StubAliasStore()
        let plain = StubContactSearching(records: [
            contact(id: "c-plain", name: "Jose Garcia", handles: ["plain@example.com"])
        ])
        let second = await resolver(contacts: plain, aliases: aliases).resolve(name: "José García", limit: 5)
        #expect(second.selected?.handle == "plain@example.com")
        #expect(aliases.requestedNameKeys == ["jose garcia"])
    }

    @Test
    func `No matching surfaces yield an empty resolution value`() async {
        let resolution = await resolver(contacts: StubContactSearching()).resolve(name: "Nobody Here", limit: 5)
        #expect(resolution.query == "Nobody Here")
        #expect(resolution.candidates.isEmpty)
        #expect(resolution.selected == nil)
        #expect(resolution.isAmbiguous == false)
    }

    @Test
    func `The resolver adopts the resolving seam`() async {
        let seam: any MessagesRecipientResolving = resolver(contacts: StubContactSearching())
        let resolution = await seam.resolve(name: "", limit: 5)
        #expect(resolution.candidates.isEmpty)
    }

    @Test
    func `The concrete alias store outranks an exact contact match`() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-resolver-aliases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecipientAliasStore(dbPath: base.appendingPathComponent("episodes.db").path)
        await store.recordAlias(
            name: "Rebecca Mackin",
            handle: "bex@example.com",
            service: "iMessage",
            displayName: "Bex"
        )
        let contacts = StubContactSearching(records: [
            contact(id: "c-1", name: "Rebecca Mackin", handles: ["rebecca@example.com"])
        ])

        // End-to-end across the real store: the learned mapping (110) must win
        // over the address-book exact match (100) that the stub already proves
        // scores highest among contact reads.
        let resolution = await MessagesRecipientResolver(
            contacts: contacts,
            history: StubHistorySourcing(),
            aliasStore: store
        ).resolve(name: "Rebecca Mackin", limit: 5)

        #expect(resolution.candidates.map(\.handle) == ["bex@example.com", "rebecca@example.com"])
        #expect(resolution.selected?.handle == "bex@example.com")
        #expect(resolution.selected?.source == .alias)
        #expect(resolution.isAmbiguous == false)
    }
}
