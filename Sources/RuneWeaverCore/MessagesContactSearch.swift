// Rune Weaver Core — Contacts name search: the name-first address-book seam.
//
// Resolving "send this to Rebecca" needs the reverse of the indexer's
// handle-to-name map: a ranked lookup of contacts whose display or alternate
// name agrees with a typed query. This file owns that surface end to end — the
// `MessagesContactSearching` seam layered on `MessagesContactResolving`, the
// `MessageContactMatch` snapshot a caller can hold without touching Contacts
// types, and the pure `MessagesContactMatcher` that scores and orders records.
// The scorer is deterministic and store-free so ranking is unit-testable
// without an address book; the resolver extension only reads an address book
// that is already authorized and never prompts, preserving the engine's
// no-surprise-permission posture.

import Foundation

#if canImport(Contacts)
    import Contacts
#endif

// MARK: - Search seam

/// Seam for finding address-book contacts by name.
///
/// Extends the indexer's handle-to-name resolution with the direction a send
/// flow needs: callers ask for contacts matching a name and receive ranked
/// snapshots. Implementations return an empty array when Contacts access is
/// unavailable instead of prompting, so lookup degrades to other surfaces
/// without a permission surprise.
public protocol MessagesContactSearching: MessagesContactResolving {
    /// Finds contacts whose display or alternate name agrees with `name`.
    /// - Parameters:
    ///   - name: User-supplied name query; folded by ``MessageRecipientNameNormalizer``.
    ///   - limit: Maximum matches requested; clamped to `1...25` so a caller can
    ///     never widen the result budget past the address-book search cap.
    /// - Returns: Ranked matches, or an empty array when access is unavailable or nothing matches.
    func search(name: String, limit: Int) async -> [MessageContactMatch]
}

// MARK: - Match value

/// One address-book contact snapshot shaped for name matching.
///
/// A match is a value snapshot rather than a live `CNContact`: ranking callers
/// and their tests never need Contacts framework types, and the resolver can
/// hand records across a Sendable boundary. `displayName` is always non-empty;
/// `alternateNames` carries nickname and organization copy that should score
/// like a name, and `handles` preserves address-book order after trimming and
/// dedupe so a later send path can use the first candidate directly.
public struct MessageContactMatch: Sendable, Equatable, Codable {
    /// Stable address-book identifier of the contact.
    public let contactID: String
    /// Primary name shown for the contact; never empty.
    public let displayName: String
    /// Additional searchable names (nickname, organization) in display order.
    public let alternateNames: [String]
    /// Trimmed, deduplicated phone and email strings in address-book order.
    public let handles: [String]

    /// Creates a contact match snapshot.
    /// - Parameters:
    ///   - contactID: Stable address-book identifier.
    ///   - displayName: Primary, non-empty display name.
    ///   - alternateNames: Additional searchable names.
    ///   - handles: Trimmed, deduplicated handles.
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
    ///
    /// The resolver passes values straight off `CNContact`; keeping the shaping
    /// rules (formatter-name requirement, whitespace trimming, order-preserving
    /// handle dedupe) here means they can be exercised without a `CNContactStore`.
    /// `displayName` must be a non-empty formatted full name: a contact whose
    /// formatter output is blank carries no primary identity for a name search,
    /// so it is skipped rather than emitted with an empty name that would break
    /// the ``displayName`` guarantee.
    /// - Parameters:
    ///   - contactID: Stable address-book identifier.
    ///   - formattedName: Formatter output for the full name, if any.
    ///   - nickname: Contact nickname, if any.
    ///   - organization: Contact organization name, if any.
    ///   - phoneNumbers: Raw phone-number strings in address-book order.
    ///   - emailAddresses: Raw email strings in address-book order.
    /// - Returns: Snapshot, or nil when the contact has no non-empty formatted name.
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

/// Pure scorer that ranks contact snapshots against a name query.
///
/// Ranking is a pure function of the records, so the send flow and its tests
/// agree on ordering without a store. Scores are best-of across the display
/// name and every alternate: exact normalized equality (100), the normalized
/// query as a leading prefix (80), or every query token present as a whole
/// token (60). Records with no hit are dropped, and the result is capped so a
/// caller can never fan a single name out into an unbounded list. The table
/// itself lives once, in ``bestScore(for:query:)``, which the recipient
/// resolver also calls when it expands matched records, so the score that
/// admits a record here is the score that ranks it there.
public enum MessagesContactMatcher: Sendable {
    /// Exact normalized equality between query and candidate name.
    private static let exactScore = 100
    /// The candidate name begins with the normalized query.
    private static let prefixScore = 80
    /// Every query token appears as a whole token in the candidate name.
    private static let tokenScore = 60
    /// Hard upper bound on returned matches regardless of the caller's limit.
    private static let maximumResults = 25

    /// Ranks the records whose names agree with `name`.
    ///
    /// An empty or punctuation-only query has no name tokens and therefore
    /// matches nothing. Ties break deterministically by display name and then
    /// contact ID so the same query always presents the same order, and `limit`
    /// is clamped to `1...maximumResults`: a zero or negative request means
    /// "one match", not "unbounded".
    /// - Parameters:
    ///   - name: User-supplied name query.
    ///   - records: Contact snapshots to score.
    ///   - limit: Requested maximum matches.
    /// - Returns: Matching records, best first, at most 25.
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

    /// Highest score across the display name and alternates; 0 means no hit.
    ///
    /// The single name-quality table — exact 100, prefix 80, whole-token 60 —
    /// shared by ``match(name:records:limit:)`` and the recipient resolver's
    /// contact expansion, so the score that admits a record in the matcher is
    /// the score that ranks it after merging in the resolver. `query` must
    /// already be normalized by ``MessageRecipientNameNormalizer``.
    /// - Parameters:
    ///   - record: Snapshot whose display and alternate names are scored.
    ///   - query: Normalized query shared by every record in one ranking pass.
    /// - Returns: Exact 100, prefix 80, whole-token 60, or 0 when nothing hits.
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
    ///
    /// Only the read path is used (`authorizationStatus` plus `enumerateContacts`),
    /// so a send flow can call this speculatively: an undecided, denied, or
    /// restricted address book yields no matches instead of a system prompt.
    /// A mid-enumeration failure keeps the contacts gathered so far, matching
    /// the resolver's degrade-to-partial posture.
    /// - Parameters:
    ///   - name: User-supplied name query.
    ///   - limit: Requested maximum matches, clamped by ``MessagesContactMatcher``.
    /// - Returns: Ranked matches, empty when access is unavailable or nothing matches.
    public func search(name: String, limit: Int) async -> [MessageContactMatch] {
        #if canImport(Contacts)
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
            // The formatter may render nickname and organization, and the scorer
            // reads those same fields as alternates, so every key the fetch may
            // touch must be requested: reading an unfetched property raises an
            // Objective-C exception Swift cannot catch.
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
