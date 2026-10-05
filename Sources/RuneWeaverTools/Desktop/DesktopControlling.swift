// Rune Weaver Tools - Desktop control contract for live bridge and stubs.
//
// Purpose: own the DesktopControlling protocol plus the stub-safe default
// batches so tests can inject a double without reimplementing session and
// declared-host plumbing on every conformer.
// Scope: protocol requirements and extension defaults only; live CGEvent
// dispatch, safety checks, and egress screening live with the bridge.
// Architectural role: seam beside the bridge following the tool seam idiom,
// so the live bridge stays the grant-aware implementation while stubs inherit
// fail-closed defaults that cannot bypass network_hosts scoping.

import Foundation
import RuneWeaverCore

// MARK: - Control protocol

/// Protocol for desktop control so tests can inject a stub.
public protocol DesktopControlling: Sendable {
    /// Executes a batch of actions sequentially, aborting on first failure.
    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String]
    ) async throws -> [DesktopActionStepResult]

    /// Session-aware batch entry point threading the egress session grant.
    /// Declared as a requirement (not an extension-only helper) so the live
    /// bridge's grant-aware implementation dispatches dynamically; stubs
    /// inherit the session-less fallback below.
    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String],
        sessionID: UUID?
    ) async throws -> [DesktopActionStepResult]

    /// Declared-hosts batch entry point for URL-typing scoping.
    ///
    /// Mirrors `bash.exec` `network_hosts`: every host typed in the batch
    /// must appear in `declaredHosts`, and the bridge denies undeclared dials
    /// through the shared supervisor check rather than a parallel checker.
    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String],
        sessionID: UUID?,
        declaredHosts: [String]
    ) async throws -> [DesktopActionStepResult]
}

extension DesktopControlling {
    /// Default session-aware batch for stubs without grant handling.
    /// Delegates to the session-less batch so existing conformers keep
    /// compiling; the live bridge overrides with grant-aware screening.
    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String],
        sessionID _: UUID?
    ) async throws -> [DesktopActionStepResult] {
        try await executeBatch(actions: actions, scaleX: scaleX, scaleY: scaleY, blockedApps: blockedApps)
    }

    /// Default declared-hosts batch for stubs without scoping.
    /// Fail-closed on typed URLs: collects the batch hosts first and refuses
    /// only when a typed host lacks a declaration, so a host-free batch with
    /// a non-empty claim still delegates while a batch that types URLs cannot
    /// silently bypass `network_hosts` scoping on an unscreened stub.
    func executeBatch(
        actions: [DesktopAction],
        scaleX: Double,
        scaleY: Double,
        blockedApps: [String],
        sessionID: UUID?,
        declaredHosts: [String]
    ) async throws -> [DesktopActionStepResult] {
        let batchHosts = stubBatchHosts(from: actions)
        guard !batchHosts.isEmpty else {
            return try await executeBatch(actions: actions, scaleX: scaleX, scaleY: scaleY, blockedApps: blockedApps, sessionID: sessionID)
        }
        let declared = Set(declaredHosts.map { SensitiveAddressNormalization.normalizedHost($0) }.filter { !$0.isEmpty })
        var seen = Set<String>()
        var undeclared: [String] = []
        for raw in batchHosts {
            let canonical = SensitiveAddressNormalization.normalizedHost(raw)
            guard !canonical.isEmpty, !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            if !declared.contains(canonical) {
                undeclared.append(raw)
            }
        }
        if !undeclared.isEmpty {
            let sorted = undeclared.sorted()
            let first = sorted.first ?? ""
            let listed = sorted.joined(separator: ", ")
            let declaredClause = declaredHosts.isEmpty
                ? "no declared hosts"
                : "declared: \(declaredHosts.sorted().joined(separator: ", "))"
            RuneWeaverLog.tools.warning(
                "desktop.action denied undeclared typed host(s) \(listed) (\(declaredClause)): conformer lacks declared-hosts screening"
            )
            throw DesktopControlError.blockedURL(
                host: first,
                url: first,
                reason: "Typed host '\(first)' not in declared hosts (\(declaredClause)); this conformer does not screen typed URLs"
            )
        }
        return try await executeBatch(actions: actions, scaleX: scaleX, scaleY: scaleY, blockedApps: blockedApps, sessionID: sessionID)
    }

    /// Collects typed hosts for the stub declared-hosts gate.
    ///
    /// Mirrors the live bridge batch scan (link plus schemeless hosts in
    /// first-seen order) so a host-free batch delegates even with a non-empty
    /// claim while any typed host still faces the declaration check.
    private func stubBatchHosts(from actions: [DesktopAction]) -> [String] {
        var hosts: [String] = []
        var seen = Set<String>()
        for action in actions {
            guard case let .typeText(text) = action else { continue }
            for rawURL in DesktopControlBridge.extractURLs(from: text) {
                guard let host = URL(string: rawURL)?.host, !host.isEmpty else { continue }
                let canonical = SensitiveAddressNormalization.normalizedHost(host)
                guard !seen.contains(canonical) else { continue }
                seen.insert(canonical)
                hosts.append(host)
            }
            for bareHost in ApprovalQueue.extractAllSchemelessHosts(in: text) {
                guard let assumedHost = URL(string: "https://" + bareHost)?.host,
                      !assumedHost.isEmpty
                else { continue }
                let canonical = SensitiveAddressNormalization.normalizedHost(assumedHost)
                guard !seen.contains(canonical) else { continue }
                seen.insert(canonical)
                hosts.append(assumedHost)
            }
        }
        return hosts
    }
}
