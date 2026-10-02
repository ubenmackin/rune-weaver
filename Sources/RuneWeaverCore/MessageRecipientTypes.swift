// Rune Weaver Core — Shared recipient value types and the one owner of handle shape rules.
//
// Every recipient surface — contact, history, and alias lookup, ambiguity
// resolution, passthrough display-name matching, and send confirmation — builds
// on these value types and pure helpers, so email/phone shape recognition,
// handle canonicalization, name normalization, and handle-key identity are
// defined exactly once here. The rules are pure and store-free: callers classify
// or normalize without touching Contacts, Messages, or any index, which keeps
// matching deterministic, locale-independent, and independently testable.

import Foundation

/// One classified recipient query: either a canonical handle or a normalized name.
///
/// The associated value is always in its canonical spelling. Handles are the
/// trimmed email text unchanged or phone digits (with a leading `+` preserved
/// when the caller supplied one), and names are already folded by
/// ``MessageRecipientNameNormalizer/normalize(_:)``. Keeping the canonical form
/// on the enum means later matching, dedupe, and send paths never re-derive it.
public enum MessageRecipientInput: Sendable, Equatable, Codable {
    /// Canonical handle: email text, or `+`-prefixed/digit-only phone number.
    case handle(String)
    /// Normalized name: case- and diacritic-folded with punctuation as spaces.
    case name(String)
}

/// Lookup surface that produced one recipient candidate.
///
/// Raw values are stable wire strings for diagnostics and tests; renaming a case
/// must not silently change what a caller reads. The set stays closed because
/// resolution ranks each source explicitly, so a new surface is a deliberate
/// scoring decision rather than a silent extra string.
public enum MessageRecipientSource: String, Sendable, Codable, CaseIterable, Equatable {
    /// Address-book contact.
    case contact
    /// Prior message history.
    case history
    /// A user-defined alias.
    case alias
    /// A handle typed directly by the caller.
    case handle
}

/// One possible recipient assembled from a lookup surface.
///
/// A candidate is a display-only snapshot. `handle` is the canonical handle used
/// for identity, while `contactID` and `service` feed the resolver's identity
/// grouping and deterministic ordering. Every optional field is genuinely
/// optional — history rows may carry no contact link, and a typed handle may
/// carry no display name — so nil never means "unknown, fetch me".
public struct MessageRecipientCandidate: Sendable, Equatable, Codable {
    /// Friendly name to show; nil when the surface offered none.
    public let displayName: String?
    /// Canonical handle (see ``MessageRecipientClassification/canonicalHandle(_:)``).
    public let handle: String
    /// Messaging service label such as `iMessage`; nil when unknown.
    public let service: String?
    /// When this handle last exchanged a message; nil when history is absent.
    public let lastMessageAt: Date?
    /// Lookup surface that produced the candidate.
    public let source: MessageRecipientSource
    /// Address-book identifier used to group duplicate handles; nil when unlinked.
    public let contactID: String?

    /// Creates a recipient candidate.
    /// - Parameters:
    ///   - displayName: Friendly name, or nil when absent.
    ///   - handle: Canonical handle.
    ///   - service: Messaging service label, or nil when unknown.
    ///   - lastMessageAt: Last exchange instant, or nil when history is absent.
    ///   - source: Lookup surface that produced the candidate.
    ///   - contactID: Address-book identifier, or nil when unlinked.
    public init(
        displayName: String? = nil,
        handle: String,
        service: String? = nil,
        lastMessageAt: Date? = nil,
        source: MessageRecipientSource,
        contactID: String? = nil
    ) {
        self.displayName = displayName
        self.handle = handle
        self.service = service
        self.lastMessageAt = lastMessageAt
        self.source = source
        self.contactID = contactID
    }
}

/// Outcome of resolving one recipient query.
///
/// Ambiguity is data, not an error: `candidates` always carries everything the
/// surfaces found, while `selected` is non-nil only when the top-scored group
/// collapses to one identity. `isAmbiguous` is true exactly when distinct
/// top-scored identities remain, so callers ask the owner instead of guessing.
/// An empty candidate list is a normal value too — the caller decides how to
/// report "no match" in its own vocabulary.
public struct MessageRecipientResolution: Sendable, Equatable, Codable {
    /// Query exactly as the caller supplied it.
    public let query: String
    /// Every candidate the lookup surfaces returned, in deterministic order.
    public let candidates: [MessageRecipientCandidate]
    /// The chosen candidate when one identity won outright; nil when ambiguous or empty.
    public let selected: MessageRecipientCandidate?
    /// Whether the top score was shared by distinct identities.
    public let isAmbiguous: Bool

    /// Creates a resolution snapshot.
    /// - Parameters:
    ///   - query: Query exactly as the caller supplied it.
    ///   - candidates: Candidates in deterministic order.
    ///   - selected: Chosen candidate, or nil when ambiguous or empty.
    ///   - isAmbiguous: Whether distinct identities shared the top score.
    public init(
        query: String,
        candidates: [MessageRecipientCandidate],
        selected: MessageRecipientCandidate? = nil,
        isAmbiguous: Bool = false
    ) {
        self.query = query
        self.candidates = candidates
        self.selected = selected
        self.isAmbiguous = isAmbiguous
    }
}

/// Pure normalization shared by classification, matching, and handle identity.
///
/// Both helpers are deterministic and locale-independent, so the same query
/// classifies, matches, and dedupes identically on every surface. Neither
/// throws: input with nothing usable yields an empty string (names) or nil
/// (handles), letting callers keep their own empty-input errors.
public enum MessageRecipientNameNormalizer: Sendable {
    /// Folds a raw name into its comparable form.
    ///
    /// Diacritics and case fold first, then every scalar that is not a letter or
    /// digit becomes a space, runs collapse, and the result trims. Digits survive
    /// so "Rebecca 2" stays distinct from "Rebecca", and punctuation never splits
    /// identity: "Jean-Luc O'Brien" and "Jean Luc O Brien" agree.
    /// - Parameter raw: Raw display name.
    /// - Returns: Comparable name; empty when nothing alphanumeric remains.
    public static func normalize(_ raw: String) -> String {
        let folded = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let replaced = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(replaced)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Canonical handle identity for dedupe, history matching, and send confirmation.
    ///
    /// Lowercasing plus alphanumeric-only filtering maps every spelling of the
    /// same phone number (`+1 (555) 123-4567`, `+15551234567`) and every case
    /// variant of the same email onto one key. The country code stays part of
    /// the key because dropping it could merge distinct numbers; deciding when
    /// two keys are the same person stays with the caller. Punctuation-only
    /// input has no identity at all, so the result is nil rather than an empty key.
    /// - Parameter raw: Raw phone number, email address, or handle.
    /// - Returns: Lowercased alphanumeric key, or nil when nothing remains.
    public static func handleKey(_ raw: String) -> String? {
        let scalars = raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !scalars.isEmpty else { return nil }
        return String(scalars.map { Character($0) })
    }
}

/// The single owner of recipient shape rules: email, phone, or name.
///
/// Every caller that needs to know whether a typed value is a handle, and what
/// its canonical spelling is, routes through here, so the email pattern, the
/// phone punctuation set, the digit bounds, and the query-length bound cannot
/// drift between the tool, the server, and the resolver. Empty input keeps
/// classifying nil so callers surface their existing empty-input errors.
public enum MessageRecipientClassification: Sendable {
    /// Longest trimmed query accepted for classification; longer input is not a recipient.
    private static let maxQueryLength = 500

    /// Email shape: one or more local-part characters, `@`, a dotted domain, and
    /// a 2+ letter TLD. Anchored and case-insensitive; the `%`/`+`/`_`/`-`/`.`
    /// local set mirrors what mail providers actually accept.
    private static let emailShapeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[A-Z0-9._%+\\-]+@[A-Z0-9.\\-]+\\.[A-Z]{2,}$",
        options: [.caseInsensitive]
    )

    /// Classifies a raw query into a canonical handle or a normalized name.
    ///
    /// Empty or whitespace-only input, and trimmed values longer than 500
    /// characters, are not recipients at all, so they classify nil and the
    /// caller keeps its own empty-input error. Email is tested before phone
    /// because the two shapes are disjoint; everything else becomes a normalized
    /// name, which is also the fallback for near-miss phone and email spellings.
    /// - Parameter raw: Raw query from the caller.
    /// - Returns: Canonical input, or nil when there is nothing to classify.
    public static func classify(_ raw: String) -> MessageRecipientInput? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxQueryLength else { return nil }
        if isEmailShape(trimmed) {
            return .handle(trimmed)
        }
        if isPhoneShape(trimmed) {
            return .handle(canonicalPhone(trimmed))
        }
        return .name(MessageRecipientNameNormalizer.normalize(raw))
    }

    /// Canonical handle for a raw query, or nil when the query is not a handle.
    ///
    /// Reads the canonical spelling straight off ``classify(_:)`` so there is one
    /// owner of shape rules and no second email/phone branch to keep in sync.
    /// Names, empty input, and over-long input all return nil.
    /// - Parameter raw: Raw query from the caller.
    /// - Returns: Email text unchanged or phone digits (leading `+` kept), or nil.
    public static func canonicalHandle(_ raw: String) -> String? {
        guard case let .handle(canonical) = classify(raw) else { return nil }
        return canonical
    }

    /// Whether a trimmed value matches the email shape.
    ///
    /// The match must span the entire value: `firstMatch` alone would accept a
    /// valid email embedded in trailing junk, which would then canonicalize to
    /// text that still carries that junk.
    private static func isEmailShape(_ value: String) -> Bool {
        guard let regex = emailShapeRegex else { return false }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else { return false }
        return match.range == range
    }

    /// Whether a trimmed value matches the phone shape.
    ///
    /// One optional leading `+`, then only ASCII space, `-`, `(`, `)`, and `.`
    /// may separate 7–15 ASCII digits. A `+` anywhere else, a non-ASCII digit,
    /// or any other character disqualifies the value, so near-miss spellings
    /// fall through to name classification instead of being dialed.
    private static func isPhoneShape(_ value: String) -> Bool {
        var digitCount = 0
        for (index, scalar) in value.unicodeScalars.enumerated() {
            if index == 0, scalar == "+" {
                continue
            }
            if scalar == " " || scalar == "-" || scalar == "(" || scalar == ")" || scalar == "." {
                continue
            }
            guard ("0" ... "9").contains(scalar) else { return false }
            digitCount += 1
        }
        return (7 ... 15).contains(digitCount)
    }

    /// Canonical phone spelling: leading `+` preserved, every separator dropped.
    ///
    /// Only called for values that already passed ``isPhoneShape(_:)``, so the
    /// filtered scalars are all ASCII digits and the count is within bounds.
    private static func canonicalPhone(_ value: String) -> String {
        let digits = String(value.unicodeScalars.filter { ("0" ... "9").contains($0) }.map { Character($0) })
        return value.hasPrefix("+") ? "+" + digits : digits
    }
}
