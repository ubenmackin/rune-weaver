// Rune Weaver Tools Tests — Shared lock-backed doubles for recipient resolution.

import Foundation
import os
@testable import RuneWeaverCore

/// Lock-backed resolver stub: seedable resolutions keyed by query, records calls.
final class StubMessagesRecipientResolver: MessagesRecipientResolving, Sendable {
    /// One captured resolve request.
    struct ResolveCall: Sendable, Equatable {
        /// Raw name passed to the resolver.
        let name: String
        /// Requested candidate limit.
        let limit: Int
    }

    private struct State: Sendable {
        var resolutionsByName: [String: MessageRecipientResolution]
        var resolveCalls: [ResolveCall] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates a resolver stub.
    /// - Parameter resolutionsByName: Canned resolutions keyed by the exact query.
    init(resolutionsByName: [String: MessageRecipientResolution] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(resolutionsByName: resolutionsByName))
    }

    /// Canned resolutions keyed by the exact query string.
    var resolutionsByName: [String: MessageRecipientResolution] {
        get { state.withLock { $0.resolutionsByName } }
        set { state.withLock { $0.resolutionsByName = newValue } }
    }

    /// Resolve requests seen so far, in call order.
    var resolveCalls: [ResolveCall] {
        state.withLock { $0.resolveCalls }
    }

    /// Names requested so far, in call order.
    var queries: [String] {
        state.withLock { $0.resolveCalls.map(\.name) }
    }

    /// Serves the seeded resolution for the query, or an empty resolution when
    /// the query was never seeded — mirroring the production contract that a
    /// zero-candidate result is a value, never an error.
    func resolve(name: String, limit: Int) async -> MessageRecipientResolution {
        state.withLock { current in
            current.resolveCalls.append(ResolveCall(name: name, limit: limit))
            return current.resolutionsByName[name] ?? MessageRecipientResolution(query: name, candidates: [])
        }
    }
}

/// Lock-backed alias store stub: seedable aliases per name key, records writes.
final class StubMessageAliasStore: MessageAliasStoring, Sendable {
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

    /// Canned candidates keyed by normalized name.
    var candidatesByNameKey: [String: [MessageRecipientCandidate]] {
        get { state.withLock { $0.candidatesByNameKey } }
        set { state.withLock { $0.candidatesByNameKey = newValue } }
    }

    /// Normalized name keys requested so far, in call order.
    var requestedNameKeys: [String] {
        state.withLock { $0.requestedNameKeys }
    }

    /// Limits requested so far, in call order.
    var requestedLimits: [Int] {
        state.withLock { $0.requestedLimits }
    }

    /// Alias writes recorded so far, in call order.
    var recorded: [RecordedAlias] {
        state.withLock { $0.recorded }
    }

    /// Serves canned candidates for the requested key, capped to the limit.
    func aliases(nameKey: String, limit: Int) async -> [MessageRecipientCandidate] {
        state.withLock { current in
            current.requestedNameKeys.append(nameKey)
            current.requestedLimits.append(limit)
            return Array((current.candidatesByNameKey[nameKey] ?? []).prefix(max(limit, 0)))
        }
    }

    /// Records one alias write without touching durable storage.
    func recordAlias(name: String, handle: String, service: String?, displayName: String?) async {
        state.withLock { current in
            current.recorded.append(RecordedAlias(name: name, handle: handle, service: service, displayName: displayName))
        }
    }
}
