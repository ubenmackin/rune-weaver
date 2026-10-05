// Rune Weaver Core — Episodic-excluded paged facts reader for the memory engine.
//
// Purpose: serves windowed semantic plus profile fact browsing without touching
// episodic turns, so the dashboard Facts tab can page, search, and count without
// pulling an unbounded list or disturbing recall ranking.
// Scope: read-only merging of the vector store snapshot with the in-memory profile
// facts, newest first, with token-overlap filtering and offset slicing; no writes,
// no episodic reads beyond the live episode tally, and no cache beyond the
// on-demand store opens the engine already performs.
// Architectural role: engine-owned paged facts reader behind MemoryEngine — REST
// and dashboard delegate here instead of reading VectorStore or profile state
// directly, keeping listing scope, normalization, and clamping single-sourced.

import Foundation

/// One window of durable facts plus the tallies that scope it.
///
/// Bundles the sliced window with its pre-slice total and the live store
/// tallies so the dashboard settles tab labels and the "More" cursor from a
/// single read without a second fetch. A nominal type keeps the four related
/// values together where a tuple would trip the large-tuple lint.
public struct FactsPage: Sendable, Equatable {
    /// Windowed facts for this page, newest first.
    public let page: [UserFact]
    /// Total matching facts before slicing, driving the "More" cursor.
    public let total: Int
    /// Stored semantic fact count.
    public let semanticCount: Int
    /// Stored episode count.
    public let episodeCount: Int

    /// Creates a paged facts window.
    public init(page: [UserFact], total: Int, semanticCount: Int, episodeCount: Int) {
        self.page = page
        self.total = total
        self.semanticCount = semanticCount
        self.episodeCount = episodeCount
    }
}

extension MemoryEngine {
    /// Default window size for facts paging when the caller omits a limit.
    ///
    /// Matches the dashboard recent window so an empty query paints a bounded
    /// preview without a second round trip.
    public static let defaultFactsPageLimit = 20

    /// Maximum window size for facts paging, bounding one read to a preview.
    public static let maxFactsPageLimit = 100

    /// Maximum paging cursor, bounding how far a client can walk into history.
    public static let maxFactsPageOffset = 100_000

    /// Reads one window of durable facts, newest first, excluding episodic turns.
    ///
    /// Merging prefers the live profile row when an identifier exists in both
    /// stores: the profile carries confidence and source authority while the
    /// vector row carries the creation stamp, and the two share identifiers
    /// because every engine write mirrors into both. Vector-only rows (for
    /// example after a profile-only removal) convert with a neutral confidence
    /// so they stay visible instead of vanishing from the browser. Episodic
    /// turns never enter the merge; only the live episode tally rides along so
    /// tab labels settle without a second fetch.
    ///
    /// Normalization trims and lowercases before matching so leading spaces or
    /// casing never hide a row, while token overlap runs over content plus
    /// source so a source-scoped query (for example a dashboard origin) still
    /// narrows. A substring fallback keeps partial-word queries recallable when
    /// token boundaries split them. Bounds clamp rather than throw so a stale
    /// dashboard cursor degrades to the nearest valid window instead of failing
    /// the pane.
    /// - Parameters:
    ///   - query: Substring filter; blank reads the recent window.
    ///   - limit: Window size before clamping to `1...maxFactsPageLimit`.
    ///   - offset: Cursor before clamping to `0...maxFactsPageOffset`.
    /// - Returns: Window plus pre-slice total plus live store tallies.
    public func searchFactsPage(
        query: String = "",
        limit: Int = 20,
        offset: Int = 0
    ) async -> FactsPage {
        let clampedLimit = min(max(limit, 1), Self.maxFactsPageLimit)
        let clampedOffset = min(max(offset, 0), Self.maxFactsPageOffset)
        // Trim plus lowercase once so empty detection, tokenization, and the
        // substring fallback share one normalized form instead of drifting.
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let semanticFacts = await allSemanticFacts()
        let semanticCount = await semanticStoreCount()
        let episodes = await episodeCount()

        // Profile wins on identifier collisions because it owns confidence and
        // source; vector-only rows convert so profile-only removals stay
        // visible through the surviving store copy.
        var mergedByID: [UUID: UserFact] = [:]
        mergedByID.reserveCapacity(profile.facts.count + semanticFacts.count)
        for fact in profile.facts {
            mergedByID[fact.id] = fact
        }
        for stored in semanticFacts {
            guard mergedByID[stored.id] == nil else { continue }
            let rawSource = stored.metadata["source"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSource = (rawSource?.isEmpty == false) ? rawSource ?? "user" : "user"
            mergedByID[stored.id] = UserFact(
                id: stored.id,
                content: stored.content,
                confidence: 1.0,
                source: resolvedSource,
                lastConfirmed: stored.updatedAt
            )
        }

        // Newest first with a stable tie-break so repeated reads order
        // identically instead of leaving equal timestamps to sort chance.
        let mergedNewestFirst = mergedByID.values.sorted {
            if $0.lastConfirmed != $1.lastConfirmed {
                return $0.lastConfirmed > $1.lastConfirmed
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        let filtered: [UserFact]
        if normalized.isEmpty {
            filtered = mergedNewestFirst
        } else {
            let queryTokens = Tokenization.tokenize(normalized)
            filtered = mergedNewestFirst.filter { fact in
                let haystackTokens = Tokenization.tokenize("\(fact.content) \(fact.source)")
                if !queryTokens.isEmpty, !queryTokens.isDisjoint(with: haystackTokens) {
                    return true
                }
                // Substring path keeps partial words recallable when token
                // boundaries would otherwise miss; token overlap already
                // handled the exact-token case above.
                let lowerContent = fact.content.lowercased()
                let lowerSource = fact.source.lowercased()
                return lowerContent.contains(normalized) || lowerSource.contains(normalized)
            }
        }

        let total = filtered.count
        // An offset past the end reads as an empty window rather than an
        // error so "More" simply stops appending at the tail.
        let page = Array(filtered.dropFirst(min(clampedOffset, total)).prefix(clampedLimit))
        return FactsPage(page: page, total: total, semanticCount: semanticCount, episodeCount: episodes)
    }
}
