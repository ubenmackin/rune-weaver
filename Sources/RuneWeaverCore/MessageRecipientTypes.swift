// Rune Weaver Core — Shared recipient value types and the one owner of handle shape rules.

import Foundation

/// One classified recipient query: either a canonical handle or a normalized name. Keeping the
/// canonical form on the enum means later matching, dedupe, and send paths never re-derive it.
public enum MessageRecipientInput: Sendable, Equatable, Codable {
    /// Canonical handle: email text, or `+`-prefixed/digit-only phone number.
    case handle(String)
    /// Normalized name: case- and diacritic-folded with punctuation as spaces.
    case name(String)
}

/// Lookup surface that produced one recipient candidate. Raw values are stable wire strings for
/// diagnostics and tests; renaming a case must not silently change what a caller reads.
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

/// One possible recipient assembled from a lookup surface. A candidate is a display-only snapshot.
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

    /// Creates a recipient candidate. displayName: Friendly name, or nil when
    /// absent.
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

/// Outcome of resolving one recipient query. Ambiguity is data, not an error: `candidates` always
/// carries everything the surfaces found, while `selected` is non-nil only when the top-scored group
/// collapses to one identity.
public struct MessageRecipientResolution: Sendable, Equatable, Codable {
    /// Query exactly as the caller supplied it.
    public let query: String
    /// Every candidate the lookup surfaces returned, in deterministic order.
    public let candidates: [MessageRecipientCandidate]
    /// The chosen candidate when one identity won outright; nil when ambiguous or empty.
    public let selected: MessageRecipientCandidate?
    /// Whether the top score was shared by distinct identities.
    public let isAmbiguous: Bool

    /// Creates a resolution snapshot. query: Query exactly as the caller supplied
    /// it.
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
public enum MessageRecipientNameNormalizer: Sendable {
    /// Folds a raw name into its comparable form. Digits survive so "Rebecca 2" stays distinct from
    /// "Rebecca", and punctuation never splits identity: "Jean-Luc O'Brien" and "Jean Luc O Brien"
    /// agree.
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
    public static func handleKey(_ raw: String) -> String? {
        let scalars = raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !scalars.isEmpty else { return nil }
        let key = String(scalars.map { Character($0) })
        // Chat history arrives in E.164 while Contacts often keeps the national
        // spelling; folding the single leading NANP `1` lets those two rows join
        // for enrichment and display-name lookup instead of silently missing.
        if key.count == 11, key.hasPrefix("1"), key.unicodeScalars.allSatisfy({ ("0" ... "9").contains($0) }) {
            return String(key.suffix(10))
        }
        return key
    }
}

/// The single owner of recipient shape rules: email, phone, or name.
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
    public static func canonicalHandle(_ raw: String) -> String? {
        guard case let .handle(canonical) = classify(raw) else { return nil }
        return canonical
    }

    /// Whether a trimmed value matches the email shape.
    private static func isEmailShape(_ value: String) -> Bool {
        guard let regex = emailShapeRegex else { return false }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else { return false }
        return match.range == range
    }

    /// Whether a trimmed value matches the phone shape. One optional leading `+`, then only ASCII
    /// space, `-`, `(`, `)`, and `.` may separate 7–15 ASCII digits.
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

    /// Canonical phone spelling: leading `+` preserved, every separator dropped. Only called for
    /// values that already passed ``isPhoneShape(_:)``, so the filtered scalars are all ASCII digits
    /// and the count is within bounds.
    private static func canonicalPhone(_ value: String) -> String {
        let digits = String(value.unicodeScalars.filter { ("0" ... "9").contains($0) }.map { Character($0) })
        return value.hasPrefix("+") ? "+" + digits : digits
    }
}
