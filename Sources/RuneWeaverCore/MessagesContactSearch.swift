// Rune Weaver Core — Contacts name search: the name-first address-book seam.

import Foundation

#if canImport(Contacts)
    import Contacts
#endif

// MARK: - Search seam

/// Seam for finding address-book contacts by name.
public protocol MessagesContactSearching: MessagesContactResolving {
    /// Finds contacts whose display or alternate name agrees with `name`. name:
    /// User-supplied name query; folded by ``MessageRecipientNameNormalizer``.
    func search(name: String, limit: Int) async -> [MessageContactMatch]
}

// MARK: - Match value

/// One address-book contact snapshot shaped for name matching.
public struct MessageContactMatch: Sendable, Equatable, Codable {
    /// Stable address-book identifier of the contact.
    public let contactID: String
    /// Primary name shown for the contact; never empty.
    public let displayName: String
    /// Additional searchable names (nickname, organization) in display order.
    public let alternateNames: [String]
    /// Trimmed, deduplicated phone and email strings in address-book order.
    public let handles: [String]

    /// Creates a contact match snapshot. contactID: Stable address-book identifier.
    public init(
        contactID: String,
        displayName: String,
        alternateNames: [String] = [],
        handles: [String] = []
    ) {
        self.contactID = contactID
        self.displayName = displayName
        self.alternateNames = alternateNames
        self.handles = handles
    }

    /// Builds one snapshot from raw address-book field values.
    static func assemble(
        contactID: String,
        formattedName: String?,
        nickname: String?,
        organization: String?,
        phoneNumbers: [String],
        emailAddresses: [String]
    ) -> MessageContactMatch? {
        let alternates = [nickname, organization].compactMap { NormalizedText.value($0) }
        guard let displayName = NormalizedText.value(formattedName) else {
            return nil
        }
        var handles: [String] = []
        var seen = Set<String>()
        for raw in phoneNumbers + emailAddresses {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            handles.append(trimmed)
        }
        return MessageContactMatch(
            contactID: contactID,
            displayName: displayName,
            alternateNames: alternates,
            handles: handles
        )
    }
}

// MARK: - Pure matcher

/// Pure scorer that ranks contact snapshots against a name query. Records with no hit are dropped,
/// and the result is capped so a caller can never fan a single name out into an unbounded list.
public enum MessagesContactMatcher: Sendable {
    /// Exact normalized equality between query and candidate name.
    private static let exactScore = 100
    /// The candidate name begins with the normalized query.
    private static let prefixScore = 80
    /// Every query token appears as a whole token in the candidate name.
    private static let tokenScore = 60
    /// Hard upper bound on returned matches regardless of the caller's limit.
    private static let maximumResults = 25

    /// Ranks the records whose names agree with `name`. An empty or punctuation-only query has no
    /// name tokens and therefore matches nothing.
    public static func match(name: String, records: [MessageContactMatch], limit: Int) -> [MessageContactMatch] {
        let query = MessageRecipientNameNormalizer.normalize(name)
        guard !query.isEmpty else { return [] }
        let cap = min(max(limit, 1), maximumResults)
        let scored = records.compactMap { record -> (record: MessageContactMatch, score: Int)? in
            let score = bestScore(for: record, query: query)
            return score > 0 ? (record, score) : nil
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.record.displayName != rhs.record.displayName {
                return lhs.record.displayName < rhs.record.displayName
            }
            return lhs.record.contactID < rhs.record.contactID
        }
        return ranked.prefix(cap).map(\.record)
    }

    /// Highest score across the display name and alternates; 0 means no hit. `query` must already
    /// be normalized by ``MessageRecipientNameNormalizer``.
    static func bestScore(for record: MessageContactMatch, query: String) -> Int {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        var best = 0
        for name in [record.displayName] + record.alternateNames {
            let normalized = MessageRecipientNameNormalizer.normalize(name)
            guard !normalized.isEmpty else { continue }
            if normalized == query {
                return exactScore
            }
            if normalized.hasPrefix(query), best < prefixScore {
                best = prefixScore
                continue
            }
            if best < tokenScore {
                let tokens = Set(normalized.split(separator: " ").map(String.init))
                if queryTokens.isSubset(of: tokens) {
                    best = tokenScore
                }
            }
        }
        return best
    }
}

// MARK: - Address-book search

/// Name search over an already-authorized address book.
extension MessagesContactNameResolver: MessagesContactSearching {
    /// Searches the address book by name without ever prompting for access.
    public func search(name: String, limit: Int) async -> [MessageContactMatch] {
        #if canImport(Contacts)
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
            // The formatter may render nickname and organization, and the scorer reads those same
            // fields as alternates, so every key the fetch may touch must be requested: reading an
            // unfetched property raises an Objective-C exception Swift cannot catch.
            let keys: [any CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactPhoneNumbersKey as NSString,
                CNContactEmailAddressesKey as NSString,
                CNContactNicknameKey as NSString,
                CNContactOrganizationNameKey as NSString
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            let store = CNContactStore()
            var records: [MessageContactMatch] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    guard let record = MessageContactMatch.assemble(
                        contactID: contact.identifier,
                        formattedName: CNContactFormatter.string(from: contact, style: .fullName),
                        nickname: contact.nickname,
                        organization: contact.organizationName,
                        phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
                        emailAddresses: contact.emailAddresses.map { $0.value as String }
                    ) else { return }
                    records.append(record)
                }
            } catch {
                // A partially readable address book is still useful; rank what
                // was gathered instead of discarding the whole search.
                RuneWeaverLog.stores.debug("MessagesContactSearch: partial contact enumeration stopped: \(error.localizedDescription)")
            }
            return MessagesContactMatcher.match(name: name, records: records, limit: limit)
        #else
            return []
        #endif
    }
}
