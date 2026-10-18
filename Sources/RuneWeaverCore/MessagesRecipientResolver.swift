// Rune Weaver Core — Deterministic recipient resolution across contacts, history, and aliases.

import Foundation

// MARK: - Seams

/// Seam for resolving a raw recipient query into a ranked resolution. Implementations never throw:
/// a surface that is unavailable contributes nothing rather than failing the lookup.
public protocol MessagesRecipientResolving: Sendable {
    /// Resolves a recipient query against every available lookup surface. name: Raw
    /// recipient text: a name, an email address, or a phone number.
    func resolve(name: String, limit: Int) async -> MessageRecipientResolution
}

/// Seam for the durable name-to-handle aliases the send flow writes.
public protocol MessageAliasStoring: Sendable {
    /// Returns stored alias candidates for a normalized name key. nameKey:
    /// Normalized name (see ``MessageRecipientNameNormalizer/normalize(_:)``).
    func aliases(nameKey: String, limit: Int) async -> [MessageRecipientCandidate]

    /// Records one name-to-handle alias after a send. name: Raw name the owner
    /// typed.
    func recordAlias(name: String, handle: String, service: String?, displayName: String?) async
}

#if canImport(SQLite3)
    /// Deterministic recipient resolution over contacts, history, and aliases.
    public struct MessagesRecipientResolver: MessagesRecipientResolving {
        /// Candidate budget used when the caller supplies none.
        public static let defaultLimit = 5
        /// Hard upper bound on returned candidates.
        public static let maximumLimit = 10
        /// History rows read per call; enrichment only needs a bounded recent slice.
        static let historyLookback = 200

        /// Flat score for a stored alias hit: an owner-taught mapping outranks
        /// address-book name quality.
        private static let aliasScore = 110
        /// Recency bump for a handle messaged within the last week.
        private static let recentBonus = 20
        /// Recency bump for a handle messaged within the last month.
        private static let staleBonus = 10
        /// Upper age of the "recent" window.
        private static let recentWindow: TimeInterval = 7 * 24 * 60 * 60
        /// Upper age of the "stale but known" window.
        private static let staleWindow: TimeInterval = 30 * 24 * 60 * 60

        /// Address-book name search surface.
        private let contacts: any MessagesContactSearching
        /// Direct-chat history surface; always present, defaulting to the snapshot reader.
        private let history: any MessagesHistorySourcing
        /// Alias store, or nil when aliases are not wired.
        private let aliasStore: any MessageAliasStoring?

        /// Creates a recipient resolver. chatDatabasePath: Live `chat.db` path used
        /// to build the default history source.
        public init(
            chatDatabasePath: String = MessagesIndexer.defaultChatDatabasePath,
            contacts: any MessagesContactSearching = MessagesContactNameResolver(),
            history: any MessagesHistorySourcing? = nil,
            aliasStore: any MessageAliasStoring? = nil
        ) {
            self.contacts = contacts
            self.history = history ?? MessagesChatHistorySource(chatDatabasePath: chatDatabasePath)
            self.aliasStore = aliasStore
        }

        /// Resolves one recipient query against every available surface.
        public func resolve(name: String, limit: Int = Self.defaultLimit) async -> MessageRecipientResolution {
            let cappedLimit = min(max(limit, 1), Self.maximumLimit)
            guard let classified = MessageRecipientClassification.classify(name) else {
                return MessageRecipientResolution(query: name, candidates: [])
            }

            let stats = await bestHistoryStats()
            switch classified {
            case let .handle(handle):
                return handleResolution(handle: handle, query: name, stats: stats)
            case let .name(nameKey):
                return await nameResolution(
                    query: name,
                    nameKey: nameKey,
                    limit: cappedLimit,
                    stats: stats,
                    now: Date()
                )
            }
        }

        /// Builds the handle passthrough resolution for an exact-address query.
        private func handleResolution(
            handle: String,
            query: String,
            stats: [String: MessageHandleStats]
        ) -> MessageRecipientResolution {
            let key = MessageRecipientNameNormalizer.handleKey(handle)
            var displayName: String?
            if let key {
                displayName = contacts.displayNames()[key]
            }
            var candidate = MessageRecipientCandidate(displayName: displayName, handle: handle, source: .handle)
            if let key, let stat = stats[key] {
                candidate = MessageRecipientCandidate(
                    displayName: displayName,
                    handle: handle,
                    service: stat.service,
                    lastMessageAt: stat.lastMessageAt,
                    source: .handle
                )
            }
            return MessageRecipientResolution(
                query: query,
                candidates: [candidate],
                selected: candidate,
                isAmbiguous: false
            )
        }

        /// Runs the name ranking pipeline: aliases, contacts, history, merge, rank.
        private func nameResolution(
            query: String,
            nameKey: String,
            limit: Int,
            stats: [String: MessageHandleStats],
            now: Date
        ) async -> MessageRecipientResolution {
            var ranked: [RankedCandidate] = []

            if let aliasStore {
                let aliases = await aliasStore.aliases(nameKey: nameKey, limit: limit)
                ranked.append(contentsOf: aliases.map { candidate in
                    RankedCandidate(
                        candidate: MessageRecipientCandidate(
                            displayName: candidate.displayName,
                            handle: candidate.handle,
                            service: candidate.service,
                            lastMessageAt: candidate.lastMessageAt,
                            source: .alias,
                            contactID: candidate.contactID
                        ),
                        score: Self.aliasScore
                    )
                })
            }

            let matches = await contacts.search(name: query, limit: limit)
            for match in matches {
                // Name quality comes from the matcher's shared table, never a
                // re-derived copy: the score that admitted the record there is
                // the score that ranks it after alias and history merging here.
                let score = MessagesContactMatcher.bestScore(for: match, query: nameKey)
                guard score > 0 else { continue }
                for handle in match.handles {
                    ranked.append(RankedCandidate(
                        candidate: MessageRecipientCandidate(
                            displayName: match.displayName,
                            handle: handle,
                            source: .contact,
                            contactID: match.contactID
                        ),
                        score: score
                    ))
                }
            }

            let enriched = ranked.map { item in
                Self.enriched(item, stats: stats, now: now)
            }
            let ordered = Self.dedupe(enriched).sorted(by: Self.isOrderedBefore)
            let topScore = ordered.first?.score
            let top = ordered.prefix { $0.score == topScore }
            var selected: MessageRecipientCandidate?
            var isAmbiguous = false
            if let first = top.first {
                if top.count == 1 || Self.formsOneIdentity(Array(top)) {
                    selected = first.candidate
                } else {
                    isAmbiguous = true
                }
            }
            return MessageRecipientResolution(
                query: query,
                candidates: ordered.prefix(limit).map(\.candidate),
                selected: selected,
                isAmbiguous: isAmbiguous
            )
        }

        /// Reads recent direct-chat stats and folds them to one best row per handle key.
        private func bestHistoryStats() async -> [String: MessageHandleStats] {
            let stats: [MessageHandleStats]
            do {
                stats = try await history.recentDirectHandleStats(limit: Self.historyLookback)
            } catch is CancellationError {
                return [:]
            } catch {
                RuneWeaverLog.tools.debug("Failed to read recent direct handle stats: \(error.localizedDescription)")
                return [:]
            }
            var best: [String: MessageHandleStats] = [:]
            for stat in stats {
                guard let key = MessageRecipientNameNormalizer.handleKey(stat.handle) else { continue }
                if let existing = best[key], !Self.isBetterStat(stat, than: existing) {
                    continue
                }
                best[key] = stat
            }
            return best
        }

        /// One scored candidate plus the handle identity used for merging.
        private struct RankedCandidate {
            /// Candidate snapshot.
            let candidate: MessageRecipientCandidate
            /// Score after the recency bonus.
            let score: Int

            /// Normalized handle identity, or nil when the handle has none.
            var handleKey: String? {
                MessageRecipientNameNormalizer.handleKey(candidate.handle)
            }
        }
    }

    // MARK: - Pure ranking helpers

    extension MessagesRecipientResolver {
        /// Applies the best history row and the recency bonus to one candidate.
        private static func enriched(
            _ item: RankedCandidate,
            stats: [String: MessageHandleStats],
            now: Date
        ) -> RankedCandidate {
            var candidate = item.candidate
            if let key = item.handleKey, let stat = stats[key] {
                candidate = MessageRecipientCandidate(
                    displayName: candidate.displayName,
                    handle: candidate.handle,
                    service: stat.service,
                    lastMessageAt: stat.lastMessageAt,
                    source: candidate.source,
                    contactID: candidate.contactID
                )
            }
            return RankedCandidate(
                candidate: candidate,
                score: item.score + recencyBonus(for: candidate.lastMessageAt, now: now)
            )
        }

        /// Whether `candidate` should replace `current` for the same handle key.
        fileprivate static func isBetterStat(_ candidate: MessageHandleStats, than current: MessageHandleStats) -> Bool {
            switch (candidate.lastMessageAt, current.lastMessageAt) {
            case let (lhs?, rhs?):
                if lhs != rhs {
                    return lhs > rhs
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
            return serviceRank(candidate.service) < serviceRank(current.service)
        }

        /// Merges candidates that denote the same handle.
        private static func dedupe(_ candidates: [RankedCandidate]) -> [RankedCandidate] {
            var best: [String: RankedCandidate] = [:]
            var unkeyed: [RankedCandidate] = []
            for candidate in candidates {
                guard let key = candidate.handleKey else {
                    unkeyed.append(candidate)
                    continue
                }
                guard let existing = best[key] else {
                    best[key] = candidate
                    continue
                }
                let winner = candidate.score > existing.score ? candidate : existing
                best[key] = RankedCandidate(
                    candidate: MessageRecipientCandidate(
                        displayName: richerDisplayName(existing.candidate.displayName, candidate.candidate.displayName),
                        handle: winner.candidate.handle,
                        service: winner.candidate.service,
                        lastMessageAt: winner.candidate.lastMessageAt,
                        source: winner.candidate.source,
                        contactID: winner.candidate.contactID
                    ),
                    score: max(existing.score, candidate.score)
                )
            }
            return Array(best.values) + unkeyed
        }

        /// Picks the more informative of two display names.
        fileprivate static func richerDisplayName(_ lhs: String?, _ rhs: String?) -> String? {
            switch (lhs, rhs) {
            case (nil, nil): return nil
            case let (lhs?, nil): return lhs
            case let (nil, rhs?): return rhs
            case let (lhs?, rhs?):
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count ? lhs : rhs
                }
                return min(lhs, rhs)
            }
        }

        /// Deterministic ranking: score, recency, service, then handle. A nil `lastMessageAt` sorts
        /// after every dated candidate because unknown recency must never outrank known recency.
        private static func isOrderedBefore(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            switch (lhs.candidate.lastMessageAt, rhs.candidate.lastMessageAt) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
            let lhsRank = serviceRank(lhs.candidate.service)
            let rhsRank = serviceRank(rhs.candidate.service)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.candidate.handle < rhs.candidate.handle
        }

        /// Transport preference for equal-recency candidates.
        fileprivate static func serviceRank(_ service: String?) -> Int {
            switch service?.lowercased() {
            case "imessage": 0
            case "sms": 1
            default: 2
            }
        }

        /// Whether every top-scored candidate belongs to one identity.
        private static func formsOneIdentity(_ candidates: [RankedCandidate]) -> Bool {
            guard candidates.count > 1 else { return true }
            var groups: [[RankedCandidate]] = []
            for candidate in candidates {
                if let index = groups.firstIndex(where: { group in
                    group.contains { sharesIdentity($0, candidate) }
                }) {
                    groups[index].append(candidate)
                } else {
                    groups.append([candidate])
                }
            }
            return groups.count == 1
        }

        /// Whether two candidates denote the same identity.
        private static func sharesIdentity(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
            if let lhsID = lhs.candidate.contactID, !lhsID.isEmpty,
               let rhsID = rhs.candidate.contactID, !rhsID.isEmpty,
               lhsID == rhsID
            {
                return true
            }
            if let lhsKey = lhs.handleKey, let rhsKey = rhs.handleKey, lhsKey == rhsKey {
                return true
            }
            return false
        }

        /// Score bump for a recently exchanged handle.
        fileprivate static func recencyBonus(for lastMessageAt: Date?, now: Date) -> Int {
            guard let lastMessageAt else { return 0 }
            let age = now.timeIntervalSince(lastMessageAt)
            if age <= recentWindow {
                return recentBonus
            }
            if age <= staleWindow {
                return staleBonus
            }
            return 0
        }
    }
#endif
