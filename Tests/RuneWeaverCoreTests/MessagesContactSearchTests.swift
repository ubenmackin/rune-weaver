// Rune Weaver Core Tests — Contacts name ranking and match-record shaping.
//
// Pins the pure half of address-book name search: exact/prefix/whole-token
// scoring across display and alternate names, diacritic and case folding,
// deterministic tie-breaking, the 1...25 limit clamp, and the snapshot shaping
// rules (formatter-name requirement, handle trimming, order-preserving dedupe).
// Every test drives `MessagesContactMatcher` or `MessageContactMatch.assemble`,
// so no test touches `CNContactStore` or prompts for Contacts access.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Messages Contact Search")
struct MessagesContactSearchTests {
    /// Builds one contact snapshot for ranking tests.
    /// - Parameters:
    ///   - id: Stable contact identifier.
    ///   - name: Primary display name.
    ///   - alternates: Additional searchable names.
    ///   - handles: Phone and email strings.
    /// - Returns: Snapshot ready for the pure matcher.
    private func record(
        id: String,
        name: String,
        alternates: [String] = [],
        handles: [String] = []
    ) -> MessageContactMatch {
        MessageContactMatch(contactID: id, displayName: name, alternateNames: alternates, handles: handles)
    }

    @Test
    func `Exact full-name match outranks a prefix match and unrelated records drop`() {
        let records = [
            record(id: "c-prefix", name: "Rebecca Mackin Smith"),
            record(id: "c-exact", name: "Rebecca Mackin"),
            record(id: "c-unrelated", name: "John Doe")
        ]
        let matches = MessagesContactMatcher.match(name: "Rebecca Mackin", records: records, limit: 10)
        #expect(matches.map(\.contactID) == ["c-exact", "c-prefix"])
    }

    @Test
    func `A query token match requires whole tokens, not substrings`() {
        let records = [
            record(id: "c-token", name: "Mackin, Rebecca"),
            record(id: "c-substring", name: "Rebeccamackin")
        ]
        let matches = MessagesContactMatcher.match(name: "Rebecca Mackin", records: records, limit: 10)
        #expect(matches.map(\.contactID) == ["c-token"])
    }

    @Test
    func `Nickname alternates match and an exact alternate outranks a prefix`() {
        let records = [
            record(id: "c-prefix", name: "Bexley Sterling"),
            record(id: "c-nickname", name: "Rebecca Mackin", alternates: ["Bex"], handles: ["rebecca@example.com"])
        ]
        let matches = MessagesContactMatcher.match(name: "Bex", records: records, limit: 10)
        #expect(matches.map(\.contactID) == ["c-nickname", "c-prefix"])
    }

    @Test
    func `Organization alternates are searchable too`() {
        let records = [record(id: "c-org", name: "Rebecca Mackin", alternates: ["Mackin Design"])]
        let matches = MessagesContactMatcher.match(name: "Mackin Design", records: records, limit: 10)
        #expect(matches.map(\.contactID) == ["c-org"])
    }

    @Test
    func `The shared scorer table returns exact, prefix, whole-token, and no-hit values`() {
        let query = MessageRecipientNameNormalizer.normalize("Rebecca Mackin")
        #expect(MessagesContactMatcher.bestScore(for: record(id: "c-exact", name: "Rebecca Mackin"), query: query) == 100)
        #expect(MessagesContactMatcher.bestScore(for: record(id: "c-prefix", name: "Rebecca Mackin Smith"), query: query) == 80)
        #expect(MessagesContactMatcher.bestScore(for: record(id: "c-token", name: "Mackin, Rebecca"), query: query) == 60)
        #expect(MessagesContactMatcher.bestScore(for: record(id: "c-miss", name: "John Doe"), query: query) == 0)

        // Best-of across names: the display name misses while the alternate is exact.
        let alternate = record(id: "c-alt", name: "Unrelated", alternates: ["Rebecca Mackin"])
        #expect(MessagesContactMatcher.bestScore(for: alternate, query: query) == 100)
    }

    @Test
    func `Diacritics and case fold on both sides of the match`() {
        let accented = [record(id: "c-accent", name: "José  García")]
        #expect(MessagesContactMatcher.match(name: "jose garcia", records: accented, limit: 5).map(\.contactID) == ["c-accent"])

        let plain = [record(id: "c-plain", name: "Jose Garcia")]
        #expect(MessagesContactMatcher.match(name: "José García", records: plain, limit: 5).map(\.contactID) == ["c-plain"])
    }

    @Test
    func `Empty handle lists do not affect name ranking`() {
        let records = [
            record(id: "c-empty", name: "Rebecca Mackin", handles: []),
            record(id: "c-with", name: "Rebecca Mackin Smith", handles: ["rebecca@example.com"])
        ]
        let matches = MessagesContactMatcher.match(name: "Rebecca Mackin", records: records, limit: 10)
        #expect(matches.map(\.contactID) == ["c-empty", "c-with"])
    }

    @Test
    func `Matches carry the record handles through unchanged and in order`() {
        let handles = ["+15551234567", "rebecca@example.com"]
        let records = [record(id: "c-1", name: "Rebecca Mackin", handles: handles)]
        let matches = MessagesContactMatcher.match(name: "Rebecca Mackin", records: records, limit: 10)
        #expect(matches.first?.handles == handles)
    }

    @Test
    func `Assembly trims and deduplicates handles while preserving address-book order`() {
        let match = MessageContactMatch.assemble(
            contactID: "c-1",
            formattedName: " Rebecca Mackin ",
            nickname: "Bex",
            organization: "Mackin Design",
            phoneNumbers: [" +1 (555) 123-4567 ", "+1 (555) 123-4567", "   ", "\t+1 (555) 987-6543 "],
            emailAddresses: ["rebecca@example.com", "rebecca@example.com", " ", "bex@example.com"]
        )
        #expect(match?.displayName == "Rebecca Mackin")
        #expect(match?.alternateNames == ["Bex", "Mackin Design"])
        #expect(match?.handles == ["+1 (555) 123-4567", "+1 (555) 987-6543", "rebecca@example.com", "bex@example.com"])
    }

    @Test
    func `Assembly drops contacts with no usable name`() {
        let match = MessageContactMatch.assemble(
            contactID: "c-nameless",
            formattedName: "  ",
            nickname: "\n",
            organization: nil,
            phoneNumbers: ["+15551234567"],
            emailAddresses: []
        )
        #expect(match == nil)
    }

    @Test
    func `Assembly requires a non-empty formatted name and never emits an empty display name`() {
        let match = MessageContactMatch.assemble(
            contactID: "c-nickname-only",
            formattedName: nil,
            nickname: "Bex",
            organization: "Mackin Design",
            phoneNumbers: ["+15551234567"],
            emailAddresses: []
        )
        #expect(match == nil)
    }

    @Test
    func `Equal scores order by display name then contact ID`() {
        let tiedNames = [
            record(id: "c-z", name: "Rebecca Mackin"),
            record(id: "c-a", name: "Rebecca Mackin"),
            record(id: "c-m", name: "Rebecca Mackin")
        ]
        #expect(MessagesContactMatcher.match(name: "Rebecca Mackin", records: tiedNames, limit: 10).map(\.contactID) == ["c-a", "c-m", "c-z"])

        let tiedScores = [
            record(id: "c-z", name: "Zoe Quinn", alternates: ["Bex"]),
            record(id: "c-a", name: "Alice Poe", alternates: ["Bex"])
        ]
        #expect(MessagesContactMatcher.match(name: "Bex", records: tiedScores, limit: 10).map(\.contactID) == ["c-a", "c-z"])
    }

    @Test
    func `Limits clamp to one minimum and twenty-five maximum`() {
        let many = (0 ..< 30).map { index in
            record(id: String(format: "c-%02d", index), name: "Rebecca Mackin")
        }
        #expect(MessagesContactMatcher.match(name: "Rebecca Mackin", records: many, limit: 0).count == 1)
        #expect(MessagesContactMatcher.match(name: "Rebecca Mackin", records: many, limit: -4).count == 1)
        #expect(MessagesContactMatcher.match(name: "Rebecca Mackin", records: many, limit: 3).count == 3)
        #expect(MessagesContactMatcher.match(name: "Rebecca Mackin", records: many, limit: 30).count == 25)
        #expect(MessagesContactMatcher.match(name: "Rebecca Mackin", records: many, limit: 10000).count == 25)
    }

    @Test
    func `An empty or punctuation-only query matches nothing`() {
        let records = [record(id: "c-1", name: "Rebecca Mackin")]
        #expect(MessagesContactMatcher.match(name: "", records: records, limit: 10).isEmpty)
        #expect(MessagesContactMatcher.match(name: "   ", records: records, limit: 10).isEmpty)
        #expect(MessagesContactMatcher.match(name: "...", records: records, limit: 10).isEmpty)
    }

    @Test
    func `Matches round-trip through Codable`() throws {
        let match = MessageContactMatch(
            contactID: "c-1",
            displayName: "Rebecca Mackin",
            alternateNames: ["Bex"],
            handles: ["+15551234567"]
        )
        let data = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(MessageContactMatch.self, from: data)
        #expect(decoded == match)
    }

    @Test
    func `The address-book resolver adopts the searching seam`() {
        let searcher: any MessagesContactSearching = MessagesContactNameResolver()
        #expect((searcher as? MessagesContactNameResolver) != nil)
    }
}
