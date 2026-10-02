// Rune Weaver Core Tests — Recipient classification, normalization, and handle identity.
//
// Pins the shared shape rules every recipient surface depends on: email and
// phone classification with canonical handle output, near-miss fallbacks to
// normalized names, diacritic and whitespace folding, the query-length bound,
// the handle key used for dedupe and history matching, and Codable round-trips
// of the shared candidate and resolution value types. Classification is pure,
// so the suite needs no store, Contacts, or Messages fixtures.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Message Recipient Classification")
struct MessageRecipientClassificationTests {
    @Test
    func `Email shapes classify as canonical handles`() {
        #expect(MessageRecipientClassification.classify("rebecca@icloud.com") == MessageRecipientInput.handle("rebecca@icloud.com"))
        #expect(MessageRecipientClassification.classify("Rebecca@ICloud.COM") == MessageRecipientInput.handle("Rebecca@ICloud.COM"))
        #expect(MessageRecipientClassification.classify("  rebecca@icloud.com  ") == MessageRecipientInput.handle("rebecca@icloud.com"))
        #expect(MessageRecipientClassification.classify("first.last+tag@sub.example.co") == MessageRecipientInput.handle("first.last+tag@sub.example.co"))
        #expect(MessageRecipientClassification.classify("r_m%x@example.io") == MessageRecipientInput.handle("r_m%x@example.io"))
        // Case folds only for matching; the canonical handle preserves the typed spelling.
        #expect(MessageRecipientClassification.canonicalHandle("Rebecca@ICloud.COM") == "Rebecca@ICloud.COM")
    }

    @Test
    func `Email near-misses fall through to normalized names`() {
        #expect(MessageRecipientClassification.classify("rebecca@icloud") == MessageRecipientInput.name("rebecca icloud"))
        #expect(MessageRecipientClassification.classify("rebecca@icloud.c") == MessageRecipientInput.name("rebecca icloud c"))
        #expect(MessageRecipientClassification.classify("@icloud.com") == MessageRecipientInput.name("icloud com"))
        #expect(MessageRecipientClassification.classify("rebecca@.com") == MessageRecipientInput.name("rebecca com"))
        #expect(MessageRecipientClassification.classify("rebecca@@icloud.com") == MessageRecipientInput.name("rebecca icloud com"))
        #expect(MessageRecipientClassification.classify("rebecca@icloud.com extra") == MessageRecipientInput.name("rebecca icloud com extra"))
        // The email shape is deliberately ASCII-only, so accented addresses stay names.
        #expect(MessageRecipientClassification.classify("josé@icloud.com") == MessageRecipientInput.name("jose icloud com"))
    }

    @Test
    func `Phone shapes classify as canonical digit handles`() {
        #expect(MessageRecipientClassification.classify("+1 (555) 123-4567") == MessageRecipientInput.handle("+15551234567"))
        #expect(MessageRecipientClassification.classify("  +1 (555) 123-4567  ") == MessageRecipientInput.handle("+15551234567"))
        #expect(MessageRecipientClassification.classify("555.123.4567") == MessageRecipientInput.handle("5551234567"))
        #expect(MessageRecipientClassification.classify("555-123-4567") == MessageRecipientInput.handle("5551234567"))
        #expect(MessageRecipientClassification.classify("(555) 123 4567") == MessageRecipientInput.handle("5551234567"))
        #expect(MessageRecipientClassification.classify("+44 20 7946 0958") == MessageRecipientInput.handle("+442079460958"))
        #expect(MessageRecipientClassification.classify("1234567") == MessageRecipientInput.handle("1234567"))
        #expect(MessageRecipientClassification.classify("123-4567") == MessageRecipientInput.handle("1234567"))
        #expect(MessageRecipientClassification.classify("+1234567") == MessageRecipientInput.handle("+1234567"))
        #expect(MessageRecipientClassification.classify("123456789012345") == MessageRecipientInput.handle("123456789012345"))
        // Canonical output drops every separator and keeps only a leading plus.
        #expect(MessageRecipientClassification.canonicalHandle("+1 (555) 123-4567") == "+15551234567")
        #expect(MessageRecipientClassification.canonicalHandle("555.123.4567") == "5551234567")
    }

    @Test
    func `Phone near-misses fall through to normalized names`() {
        // Outside the 7–15 digit bounds.
        #expect(MessageRecipientClassification.classify("123456") == MessageRecipientInput.name("123456"))
        #expect(MessageRecipientClassification.classify("1234567890123456") == MessageRecipientInput.name("1234567890123456"))
        // A plus is legal only as the single leading character.
        #expect(MessageRecipientClassification.classify("555+1234567") == MessageRecipientInput.name("555 1234567"))
        #expect(MessageRecipientClassification.classify("++15551234567") == MessageRecipientInput.name("15551234567"))
        // Trailing letters and other characters disqualify the shape entirely.
        #expect(MessageRecipientClassification.classify("555-123-4567 x89") == MessageRecipientInput.name("555 123 4567 x89"))
        #expect(MessageRecipientClassification.classify("5551234567x") == MessageRecipientInput.name("5551234567x"))
    }

    @Test
    func `Name shapes keep digits and fold punctuation and diacritics`() {
        #expect(MessageRecipientClassification.classify("Rebecca Mackin") == MessageRecipientInput.name("rebecca mackin"))
        #expect(MessageRecipientClassification.classify("Rebecca 2") == MessageRecipientInput.name("rebecca 2"))
        #expect(MessageRecipientClassification.classify("  José  García  ") == MessageRecipientInput.name("jose garcia"))
        #expect(MessageRecipientClassification.classify("Jean-Luc O'Brien") == MessageRecipientInput.name("jean luc o brien"))
        #expect(MessageRecipientClassification.classify("Müller #1") == MessageRecipientInput.name("muller 1"))
        // Digits are part of a name's identity, never stripped as punctuation.
        #expect(MessageRecipientClassification.classify("Rebecca 2") != MessageRecipientInput.name("rebecca"))
    }

    @Test
    func `Name normalization collapses whitespace runs and trims`() {
        #expect(MessageRecipientNameNormalizer.normalize("José  García") == "jose garcia")
        #expect(MessageRecipientNameNormalizer.normalize("  A   B  ") == "a b")
        #expect(MessageRecipientNameNormalizer.normalize("\tJosé\nGarcía ") == "jose garcia")
        #expect(MessageRecipientNameNormalizer.normalize("Jean-Luc O'Brien") == "jean luc o brien")
        #expect(MessageRecipientNameNormalizer.normalize("...") == "")
        #expect(MessageRecipientNameNormalizer.normalize("   ") == "")
    }

    @Test
    func `Empty and whitespace-only input classify nil`() {
        #expect(MessageRecipientClassification.classify("") == nil)
        #expect(MessageRecipientClassification.classify("   ") == nil)
        #expect(MessageRecipientClassification.classify("\n\t ") == nil)
        #expect(MessageRecipientClassification.canonicalHandle("") == nil)
        #expect(MessageRecipientClassification.canonicalHandle("   ") == nil)
    }

    @Test
    func `The query bound accepts 500 trimmed characters and rejects longer`() {
        let atBound = String(repeating: "a", count: 500)
        let overBound = String(repeating: "a", count: 501)
        #expect(MessageRecipientClassification.classify(atBound) == MessageRecipientInput.name(atBound))
        #expect(MessageRecipientClassification.classify(overBound) == nil)
        // Trimming runs first, so surrounding whitespace never pushes a valid query over.
        #expect(MessageRecipientClassification.classify("  " + atBound + "  ") == MessageRecipientInput.name(atBound))
        #expect(MessageRecipientClassification.canonicalHandle(overBound) == nil)
        #expect(MessageRecipientClassification.canonicalHandle(String(repeating: "1", count: 501)) == nil)
    }

    @Test
    func `Canonical handle mirrors classified handles and rejects names`() {
        #expect(MessageRecipientClassification.canonicalHandle("rebecca@icloud.com") == "rebecca@icloud.com")
        #expect(MessageRecipientClassification.canonicalHandle("  rebecca@icloud.com  ") == "rebecca@icloud.com")
        #expect(MessageRecipientClassification.canonicalHandle("Rebecca Mackin") == nil)
        #expect(MessageRecipientClassification.canonicalHandle("123456") == nil)
        // The classified handle already carries the canonical spelling.
        #expect(MessageRecipientClassification.classify("555-123-4567") == MessageRecipientInput.handle("5551234567"))
    }

    @Test
    func `Handle keys collapse phone spellings and email case`() {
        let punctuationPhone = MessageRecipientNameNormalizer.handleKey("+1 (555) 123-4567")
        let digitsPhone = MessageRecipientNameNormalizer.handleKey("+15551234567")
        // Both spellings carry the NANP country code, so they fold to the
        // national form shared with Contacts instead of the raw E.164 digits.
        #expect(punctuationPhone == "5551234567")
        #expect(punctuationPhone == digitsPhone)
        #expect(MessageRecipientNameNormalizer.handleKey("1.555.123.4567") == digitsPhone)
        let foldedEmail = MessageRecipientNameNormalizer.handleKey("Rebecca@ICloud.com")
        #expect(foldedEmail == "rebeccaicloudcom")
        #expect(foldedEmail == MessageRecipientNameNormalizer.handleKey("rebecca@icloud.com"))
    }

    @Test
    func `Handle keys fold the NANP country code across spellings`() {
        // E.164 history rows and national-form Contacts rows must meet on one
        // key, or enrichment silently misses the national side.
        let expected = "9163907495"
        #expect(MessageRecipientNameNormalizer.handleKey("+1 (916) 390-7495") == expected)
        #expect(MessageRecipientNameNormalizer.handleKey("(916) 390-7495") == expected)
        #expect(MessageRecipientNameNormalizer.handleKey("+19163907495") == expected)
        #expect(MessageRecipientNameNormalizer.handleKey("19163907495") == expected)
        // The national spelling already matches, so folding is idempotent.
        #expect(MessageRecipientNameNormalizer.handleKey("9163907495") == expected)
        #expect(MessageRecipientNameNormalizer.handleKey("916-390-7495") == expected)
    }

    @Test
    func `Handle keys leave non-NANP and email shapes unchanged`() {
        // Ten digits never carried a country code to fold.
        #expect(MessageRecipientNameNormalizer.handleKey("9163907495") == "9163907495")
        // Eleven digits without the NANP leading `1` stay distinct numbers.
        #expect(MessageRecipientNameNormalizer.handleKey("29163907495") == "29163907495")
        #expect(MessageRecipientNameNormalizer.handleKey("+2 (916) 390-7495") == "29163907495")
        // Longer digit strings are not NANP national numbers either.
        #expect(MessageRecipientNameNormalizer.handleKey("191639074951") == "191639074951")
        #expect(MessageRecipientNameNormalizer.handleKey("123456789012345") == "123456789012345")
        // Emails fold case only, even when they carry digits.
        #expect(MessageRecipientNameNormalizer.handleKey("Rebecca@ICloud.com") == "rebeccaicloudcom")
        #expect(MessageRecipientNameNormalizer.handleKey("rebecca19163907495@example.com") == "rebecca19163907495examplecom")
        // Letters anywhere disqualify the fold, so mixed handles keep today's key.
        #expect(MessageRecipientNameNormalizer.handleKey("1a9163907495") == "1a9163907495")
    }

    @Test
    func `Punctuation-only handle keys have no identity`() {
        #expect(MessageRecipientNameNormalizer.handleKey("+-().") == nil)
        #expect(MessageRecipientNameNormalizer.handleKey("") == nil)
        #expect(MessageRecipientNameNormalizer.handleKey("   ") == nil)
    }

    @Test
    func `Candidate and resolution round-trip through Codable`() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = MessageRecipientCandidate(
            displayName: "Rebecca Mackin",
            handle: "rebecca@icloud.com",
            service: "iMessage",
            lastMessageAt: instant,
            source: .contact,
            contactID: "contact-1"
        )
        let candidateData = try JSONEncoder().encode(candidate)
        let decodedCandidate = try JSONDecoder().decode(MessageRecipientCandidate.self, from: candidateData)
        #expect(decodedCandidate == candidate)
        #expect(decodedCandidate.displayName == "Rebecca Mackin")
        #expect(decodedCandidate.lastMessageAt == instant)
        #expect(decodedCandidate.source == .contact)
        #expect(decodedCandidate.contactID == "contact-1")

        // Absent optionals survive the round trip as nil instead of dropping the row.
        let sparse = MessageRecipientCandidate(handle: "+15551234567", source: .history)
        let sparseData = try JSONEncoder().encode(sparse)
        let decodedSparse = try JSONDecoder().decode(MessageRecipientCandidate.self, from: sparseData)
        #expect(decodedSparse == sparse)
        #expect(decodedSparse.displayName == nil)
        #expect(decodedSparse.service == nil)
        #expect(decodedSparse.lastMessageAt == nil)
        #expect(decodedSparse.contactID == nil)

        let resolution = MessageRecipientResolution(
            query: "rebecca",
            candidates: [candidate, sparse],
            selected: candidate,
            isAmbiguous: false
        )
        let resolutionData = try JSONEncoder().encode(resolution)
        let decodedResolution = try JSONDecoder().decode(MessageRecipientResolution.self, from: resolutionData)
        #expect(decodedResolution == resolution)

        let input = MessageRecipientInput.handle("+15551234567")
        let inputData = try JSONEncoder().encode(input)
        #expect(try JSONDecoder().decode(MessageRecipientInput.self, from: inputData) == input)
    }

    @Test
    func `Resolution defaults read empty and unambiguous`() {
        let resolution = MessageRecipientResolution(query: "rebecca", candidates: [])
        #expect(resolution.selected == nil)
        #expect(resolution.isAmbiguous == false)
        #expect(resolution.candidates.isEmpty)
    }

    @Test
    func `Source raw values stay stable wire strings`() {
        #expect(MessageRecipientSource.allCases == [.contact, .history, .alias, .handle])
        #expect(MessageRecipientSource.contact.rawValue == "contact")
        #expect(MessageRecipientSource.history.rawValue == "history")
        #expect(MessageRecipientSource.alias.rawValue == "alias")
        #expect(MessageRecipientSource.handle.rawValue == "handle")
    }
}
