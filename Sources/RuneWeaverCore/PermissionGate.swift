// Rune Weaver Core — Graduated-trust permission gate.

import Foundation

/// Trust boundary between the agent and the real world.
public actor PermissionGate {
    /// Durable rules, mirrored to the store best-effort.
    private var rules: [AccessRule] = []
    /// Optional persistence backend for durable rules.
    private let ruleStore: any AccessRuleStoring?
    /// Configured plugins directory for protected path enforcement.
    public let pluginsDir: URL?
    /// Ephemeral grants valid for the remainder of an active task/turn, indexed by session ID.
    private var taskGrants: [UUID: Set<EphemeralGrant>] = [:]
    /// Ephemeral grants valid for the remainder of a conversation session, indexed by session ID.
    private var sessionGrants: [UUID: Set<EphemeralGrant>] = [:]
    /// First-seen time per session key present in either ephemeral table.
    private var ephemeralIssuedAt: [UUID: Date] = [:]
    /// Maximum sessions tracked across both ephemeral tables before the oldest evict. Fail-closed
    /// bound on in-memory trust so stale session residue cannot accumulate without limit when no
    /// explicit lifecycle signal arrives.
    private static let maxTrackedEphemeralSessions = 1000
    /// Maximum age of an ephemeral session key before it expires.
    private static let ephemeralSessionTTL: TimeInterval = 24 * 60 * 60
    /// Live bash shell policy consulted before parking `bash.exec` calls.
    private var bashConfig = BashConfig()
    /// Live file write policy consulted before parking `files.write` calls.
    private var filesConfig = FilesConfig()
    /// Workspace root execution resolves against for tier stamping.
    private var workspaceRoot: URL?
    /// Recurring task for pruning expired rules periodically.
    private var reaperTask: Task<Void, Never>?
    /// Optional egress policy evaluator for network egress admission.
    private var egressEvaluator: any EgressPolicyEvaluator?

    /// Refusal text when the write-path policy denies without naming a reason. Every real posture
    /// carries its own reason, so this only backstops a classification that somehow answered deny
    /// with nothing to say.
    private static let filesWriteRefusalFallback = "Path is refused by the files write policy."

    /// Creates a permission gate.
    public init(
        ruleStore: any AccessRuleStoring? = nil,
        pluginsDir: URL? = nil,
        egressEvaluator: any EgressPolicyEvaluator? = nil
    ) {
        self.ruleStore = ruleStore
        self.pluginsDir = pluginsDir
        self.egressEvaluator = egressEvaluator
    }

    /// Loads a permission gate hydrated from durable storage, pruning expired
    /// rules on startup.
    public static func load(
        ruleStore: any AccessRuleStoring? = nil,
        pluginsDir: URL? = nil,
        egressEvaluator: any EgressPolicyEvaluator? = nil
    ) async -> PermissionGate {
        let gate = PermissionGate(
            ruleStore: ruleStore,
            pluginsDir: pluginsDir,
            egressEvaluator: egressEvaluator
        )
        await gate.bootstrap()
        return gate
    }

    /// Updates the live egress policy evaluator consulted by the gate.
    /// - Parameter evaluator: Replacement egress evaluator.
    public func setEgressEvaluator(_ evaluator: any EgressPolicyEvaluator?) {
        egressEvaluator = evaluator
    }

    /// Updates the live bash shell policy consulted by the gate.
    /// - Parameter config: Replacement bash policy.
    public func updateBashConfig(_ config: BashConfig) {
        bashConfig = config
    }

    /// Live bash policy snapshot for approval stamping.
    /// - Returns: Current bash policy.
    public func bashConfigSnapshot() -> BashConfig {
        bashConfig
    }

    /// Updates the live file write policy consulted before parking `files.write` calls.
    /// - Parameter config: Replacement files policy.
    public func updateFilesConfig(_ config: FilesConfig) {
        filesConfig = config
    }

    /// Live files policy snapshot for write posture classification.
    /// - Returns: Current files policy.
    public func filesConfigSnapshot() -> FilesConfig {
        filesConfig
    }

    /// Updates the workspace root consulted when stamping bash tiers.
    /// - Parameter root: Workspace root execution resolves against.
    public func updateWorkspaceRoot(_ root: URL) {
        workspaceRoot = root
    }

    /// Workspace root snapshot for approval stamping.
    /// - Returns: Configured root, or nil when never set.
    public func workspaceRootSnapshot() -> URL? {
        workspaceRoot
    }

    /// Hydrates rules from storage, cleaning up expired records immediately.
    public func bootstrap() async {
        guard let ruleStore else { return }
        let now = Date()
        do {
            try await ruleStore.pruneExpired(at: now)
        } catch is CancellationError {
            return
        } catch {
            RuneWeaverLog.stores.debug("PermissionGate: failed to prune expired rules at bootstrap: \(error.localizedDescription)")
        }
        do {
            rules = try await ruleStore.load()
        } catch {
            rules = []
        }
        rules.removeAll { $0.action == .allow && $0.isExpired(at: now) }
        // Rows written before the rule model may key on a shape the scope canonicalizers refuse,
        // and a `messages.send` tool-wide row is the pre-invariant spelling that can never cover a
        // real send.
        rules.removeAll { AccessScope.canonicalized($0.scope) != $0.scope }
        rules.removeAll { !Self.isGrantableRule($0) }
    }

    /// Starts a periodic background reaper that checks and cleans up expired rules.
    public func startPeriodicCleanup(intervalSeconds: TimeInterval = 60) async {
        await stopPeriodicCleanup()
        let interval = max(0.01, intervalSeconds)
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                await self.pruneExpiredAndPersist()
            }
        }
    }

    /// Stops the periodic background cleanup reaper, waiting for any in-flight prune to finish.
    public func stopPeriodicCleanup() async {
        let task = reaperTask
        reaperTask = nil
        task?.cancel()
        _ = await task?.value
    }

    /// Prunes expired rules from memory and storage. Also ages out ephemeral session keys past
    /// their TTL so the periodic reaper bounds in-memory trust even when no teardown arrives.
    public func pruneExpiredAndPersist() async {
        let now = Date()
        pruneExpired()
        if let ruleStore {
            do {
                try await ruleStore.pruneExpired(at: now)
            } catch is CancellationError {
                return
            } catch {
                RuneWeaverLog.stores.debug("PermissionGate: failed to prune expired rules: \(error.localizedDescription)")
            }
        }
    }

    /// Checks whether a tool call targets a protected engine path.
    private func isProtectedTarget(toolCall: ToolInput) -> Bool {
        guard let object = ActionDescriptor.parsedArgumentsObject(from: toolCall.argumentsJSON)
        else {
            let target = ActionDescriptor.target(from: toolCall)
            guard !target.isEmpty else { return false }
            let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            return PluginSecurity.isProtectedPath(targetURL: url, pluginsDir: pluginsDir)
        }

        // Path-only keys: `to` is intentionally excluded because `email.send`
        // carries recipients under `to` as `[String]`, not a filesystem path;
        // scanning it would risk false protected-path denials on addresses.
        let candidateKeys = ["path", "file_path", "filePath", "target", "destination", "directory", "dir"]
        for key in candidateKeys {
            if let str = object[key] as? String, !str.isEmpty {
                let url = URL(fileURLWithPath: (str as NSString).expandingTildeInPath)
                if PluginSecurity.isProtectedPath(targetURL: url, pluginsDir: pluginsDir) {
                    return true
                }
            }
        }
        return false
    }

    private func checkEgressPermission(
        tool: any Tool,
        toolCall: ToolInput,
        sessionID: UUID?
    ) async -> PermissionDecision? {
        guard let evaluator = egressEvaluator else { return nil }
        let egressHosts = ApprovalQueue.extractAllEgressHosts(toolName: tool.name, argumentsJSON: toolCall.argumentsJSON)
        for host in egressHosts {
            let status = await evaluator.evaluateHostStatus(for: host, sessionID: sessionID)
            switch status {
            case let .explicitlyBlocked(reason):
                return .denied(reason)
            case .unlisted:
                // A covering domain allow authorizes this host without parking: durable egress
                // allows live as gate rules and the task tier lives as an ephemeral grant beside
                // them, so consulting them here keeps the next identical call auto-approved.
                if egressAllowCovers(host: host, toolName: tool.name, sessionID: sessionID) {
                    continue
                }
                let sandboxSummary = ApprovalQueue.stampedSandboxSummary(
                    toolName: tool.name,
                    argumentsJSON: toolCall.argumentsJSON,
                    bashConfig: bashConfig,
                    workspaceRoot: workspaceRoot
                )
                let request = PermissionRequest(
                    toolName: tool.name,
                    description: tool.description,
                    input: toolCall,
                    suggestedDurations: TrustDuration.allCases,
                    sessionID: sessionID,
                    egressHost: host,
                    sandboxSummary: sandboxSummary
                )
                return .requiresApproval(request)
            case .allowed:
                break
            }
        }
        return nil
    }

    /// Decides whether a tool call may run.
    public func checkPermission(
        toolCall: ToolInput,
        tool: any Tool,
        sessionID: UUID? = nil
    ) async -> PermissionDecision {
        pruneExpired()
        // Deny outranks: a durable refusal is evaluated before any grant
        // coverage, so no allow rule can override, shorten, or ride past it.
        if let rule = denyRule(matchingToolCall: toolCall, toolName: tool.name) {
            return .denied(denyReason(for: rule))
        }

        // Guard against automated agent modifications to protected engine paths
        if tool.permissionLevel != .readOnly, isProtectedTarget(toolCall: toolCall) {
            return .denied("Access denied: direct modification of protected Rune Weaver engine files or installed plugins is prohibited.")
        }

        if let egressVerdict = await checkEgressPermission(tool: tool, toolCall: toolCall, sessionID: sessionID) {
            return egressVerdict
        }

        switch tool.permissionLevel {
        case .readOnly, .trusted:
            return .allowed
        case .requiresApproval:
            if tool.name == "bash.exec", let command = Self.bashCommand(from: toolCall) {
                let decision = BashSecurity.evaluate(command: command, config: bashConfig)
                switch decision.action {
                case .deny:
                    return .denied(decision.reason)
                case .allow:
                    return .allowed
                case .ask:
                    break
                }
            }
            if tool.name == "files.write", let decision = writePathDecision(toolCall: toolCall) {
                // The write-path policy is the single owner of write posture: deny refuses here,
                // ask falls through to parking below, and stage or live proceeds so the tool's own
                // review flow is the gate instead of a second approval request.
                switch decision.posture {
                case .deny:
                    return .denied(decision.reason ?? Self.filesWriteRefusalFallback)
                case .ask:
                    break
                case .stage, .live:
                    return .allowed
                }
            }
            if coversEphemeral(toolName: tool.name, argumentsJSON: toolCall.argumentsJSON, sessionID: sessionID) {
                return .allowed
            }
            if coveringRule(toolName: tool.name, argumentsJSON: toolCall.argumentsJSON, at: Date()) != nil {
                return .allowed
            }
            let sandboxSummary = ApprovalQueue.stampedSandboxSummary(
                toolName: tool.name,
                argumentsJSON: toolCall.argumentsJSON,
                bashConfig: bashConfig,
                workspaceRoot: workspaceRoot
            )
            let request = PermissionRequest(
                toolName: tool.name,
                description: tool.description,
                input: toolCall,
                suggestedDurations: TrustDuration.allCases,
                sessionID: sessionID,
                sandboxSummary: sandboxSummary
            )
            return .requiresApproval(request)
        }
    }

    /// Records trust for an action.
    @discardableResult
    public func grantTrust(for descriptor: ActionDescriptor, duration: TrustDuration, sessionID: UUID? = nil, reason: String? = nil) async -> Bool {
        guard duration != .thisTime else { return true }
        // Every durable mint path funnels through the rule mint — the CLI approval handler,
        // `ApprovalQueue.decide`, and this wrapper — so the per-recipient send invariant is enforced
        // at one boundary: a `messages.send` target that is empty or not the canonical handle is invalid and stores nothing.
        guard Self.isGrantable(descriptor) else {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint trust for invalid descriptor \(descriptor.toolName).")
            return false
        }
        return await grant(
            Self.scope(for: descriptor),
            toolName: descriptor.toolName,
            duration: duration,
            sessionID: sessionID,
            reason: reason
        )
    }

    /// Clears ephemeral task-scoped grants for a session when the turn completes.
    public func clearTaskGrants(for sessionID: UUID) {
        taskGrants.removeValue(forKey: sessionID)
        releaseEphemeralSessionWhenEmpty(sessionID)
    }

    /// Clears session-scoped grants when a session is closed or reset. Grants also expire via TTL
    /// eviction and the tracked-session bound, so the tables cannot grow without bound when no
    /// explicit lifecycle signal arrives.
    public func clearSessionGrants(for sessionID: UUID) {
        sessionGrants.removeValue(forKey: sessionID)
        taskGrants.removeValue(forKey: sessionID)
        ephemeralIssuedAt.removeValue(forKey: sessionID)
    }

    /// Clears every ephemeral grant, for full teardown when all sessions reset.
    public func clearAllEphemeralGrants() {
        taskGrants.removeAll()
        sessionGrants.removeAll()
        ephemeralIssuedAt.removeAll()
    }

    /// Tracks one session key for TTL plus oldest-first bound enforcement.
    private func trackEphemeralSession(_ sessionID: UUID, now: Date = Date()) {
        evictStaleEphemeralGrants(now: now)
        if ephemeralIssuedAt[sessionID] == nil {
            ephemeralIssuedAt[sessionID] = now
        }
        enforceEphemeralBound()
    }

    /// Drops the eviction bookkeeping once neither ephemeral table holds the key.
    /// - Parameter sessionID: Session key to reconsider.
    private func releaseEphemeralSessionWhenEmpty(_ sessionID: UUID) {
        guard taskGrants[sessionID] == nil, sessionGrants[sessionID] == nil else { return }
        ephemeralIssuedAt.removeValue(forKey: sessionID)
    }

    /// Drops ephemeral session keys older than the session TTL.
    /// - Parameter now: Reference date, defaulting to now for test control.
    private func evictStaleEphemeralGrants(now: Date = Date()) {
        let expired = ephemeralIssuedAt.compactMap { id, issuedAt in
            now.timeIntervalSince(issuedAt) < Self.ephemeralSessionTTL ? nil : id
        }
        for id in expired {
            taskGrants.removeValue(forKey: id)
            sessionGrants.removeValue(forKey: id)
            ephemeralIssuedAt.removeValue(forKey: id)
        }
    }

    /// Evicts the oldest ephemeral sessions when the tables exceed their bound.
    private func enforceEphemeralBound() {
        guard ephemeralIssuedAt.count > Self.maxTrackedEphemeralSessions else { return }
        let ordered = ephemeralIssuedAt.sorted { $0.value < $1.value }
        for (id, _) in ordered.prefix(ephemeralIssuedAt.count - Self.maxTrackedEphemeralSessions) {
            taskGrants.removeValue(forKey: id)
            sessionGrants.removeValue(forKey: id)
            ephemeralIssuedAt.removeValue(forKey: id)
        }
    }

    /// Records one covered use of a live rule without notifying clients.
    public func recordUse(scope: AccessScope, toolName: String) async {
        pruneExpired()
        let now = Date()
        // Attribute usage exactly where an allow decision came from.
        // Staying silent keeps accounting out of the approval broadcast path.
        guard let index = coveringRuleIndex(scope: scope, toolName: toolName, at: now) else { return }
        // Saturate at the limit instead of trapping on overflow.
        if rules[index].useCount < Int.max {
            rules[index].useCount += 1
        }
        rules[index].lastUsedAt = now
        await persist()
    }
}

// MARK: - Rule Administration & Lifecycle

extension PermissionGate {
    /// Mints a durable allow rule or an ephemeral grant for one scope.
    @discardableResult
    public func grant(
        _ scope: AccessScope,
        toolName: String,
        duration: TrustDuration?,
        sessionID: UUID? = nil,
        reason: String? = nil
    ) async -> Bool {
        if let duration, duration == .thisTime {
            return true
        }
        guard AccessRule.canonicalToolName(toolName) != nil else {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint trust for a blank tool name.")
            return false
        }
        // The tool-wide send scope is the signature of a malformed call, never a scope a send may
        // be trusted under: send trust is keyed to the exact canonical handle the owner approved.
        guard Self.isMintableScope(scope, toolName: toolName) else {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint a tool-wide rule for \(toolName).")
            return false
        }
        // Send trust keys on the exact canonical handle or a recipient set; a
        // display-name target can never match an honest send, so it stores
        // nothing rather than a dead row no call can exercise.
        if toolName == "messages.send", !scope.isMintableSendScope {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint a non-handle send scope for \(toolName).")
            return false
        }

        if duration == .forTask || duration == .forSession {
            guard let sessionID else {
                assertionFailure("PermissionGate: ephemeral grant without owning session mints nothing.")
                RuneWeaverLog.stores.warning("PermissionGate: \(duration?.rawValue ?? "ephemeral") grant without owning session mints nothing for \(toolName).")
                return false
            }
            let kind: EphemeralGrant.Kind = duration == .forTask ? .task : .session
            guard let grant = EphemeralGrant(toolName: toolName, scope: scope, kind: kind) else {
                RuneWeaverLog.stores.warning("PermissionGate: refusing to mint an ephemeral grant with a malformed scope for \(toolName).")
                return false
            }
            if kind == .task {
                taskGrants[sessionID, default: []].insert(grant)
            } else {
                sessionGrants[sessionID, default: []].insert(grant)
            }
            trackEphemeralSession(sessionID)
            return true
        }

        pruneExpired()
        let now = Date()
        let expiresAt: Date? = if let duration, let interval = duration.timeInterval {
            now.addingTimeInterval(interval)
        } else {
            nil
        }
        // A tool-wide rule covers every target for its tool, so installing one is a widening act
        // and must obey the same never-shorten invariant as the explicit widen path: when an
        // existing rule for the same scope already survives at least as long as the replacement.
        if let existingIndex = rules.firstIndex(where: {
            $0.action == .allow && $0.toolName == toolName && $0.scope == scope && $0.isValid(at: now)
        }), !Self.expiryLifetime(expiresAt, outlives: rules[existingIndex].expiresAt) {
            if rules[existingIndex].reason != reason,
               let refreshed = AccessRule(
                   id: rules[existingIndex].id,
                   toolName: rules[existingIndex].toolName,
                   scope: rules[existingIndex].scope,
                   action: .allow,
                   grantedAt: rules[existingIndex].grantedAt,
                   duration: rules[existingIndex].duration,
                   expiresAt: rules[existingIndex].expiresAt,
                   reason: reason
               )
            {
                var merged = refreshed
                merged.useCount = rules[existingIndex].useCount
                merged.lastUsedAt = rules[existingIndex].lastUsedAt
                rules[existingIndex] = merged
                await persist()
            }
            return true
        }
        // Dedupe allow rows for the same tool plus scope. A deny row for that
        // scope is never touched: deny outranks, and an allow mint must not
        // evict the refusal that already covers it.
        rules.removeAll { $0.action == .allow && $0.toolName == toolName && $0.scope == scope }
        // A replacement rule starts its usage history fresh so prior counters
        // cannot leak into the new lifetime.
        guard let rule = AccessRule(
            toolName: toolName,
            scope: scope,
            action: .allow,
            grantedAt: now,
            duration: duration,
            reason: reason
        ) else {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint an allow rule with a malformed scope for \(toolName).")
            return false
        }
        rules.append(rule)
        await persist()
        return true
    }

    /// Mints a standing deny rule that outranks every allow decision. Deny rows carry no expiry, so
    /// they never age out and are removed only by ``revokeRule(id:)``.
    public func denyRule(_ scope: AccessScope, toolName: String, reason: String? = nil) async {
        guard Self.isMintableScope(scope, toolName: toolName) else {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint a tool-wide deny rule for \(toolName).")
            return
        }
        // A display-name send target can never match an honest send, so it
        // stores nothing rather than a dead refusal.
        if toolName == "messages.send", !scope.isMintableSendScope {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint a non-handle send deny rule for \(toolName).")
            return
        }
        // Only a standing refusal mints here: a dated deny would let a refusal
        // lapse into the allow decision underneath it, which is exactly the
        // trust inversion the deny-outranks contract forbids.
        guard let rule = AccessRule(
            toolName: toolName,
            scope: scope,
            action: .deny,
            duration: nil,
            reason: reason
        ) else {
            RuneWeaverLog.stores.warning("PermissionGate: refusing to mint a deny rule with a malformed scope for \(toolName).")
            return
        }
        // One refusal per tool plus scope: a second mint replaces the row
        // instead of stacking duplicates the list would keep reporting.
        rules.removeAll { $0.action == .deny && $0.toolName == toolName && $0.scope == scope }
        rules.append(rule)
        await persist()
    }

    /// Removes one rule by identifier, persisting only when something changed. Expired rules are
    /// pruned first so an expired identifier reports no match.
    public func revokeRule(id: UUID) async -> Bool {
        pruneExpired()
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return false }
        await persist()
        return true
    }

    /// Promotes an existing active rule to its tool-wide scope. Preserves the original rule's ID,
    /// grantedAt, expiresAt, duration, and usage counters.
    public func widenGrant(id: UUID) async -> GrantWidenOutcome {
        pruneExpired()
        guard let current = rules.first(where: { $0.id == id && $0.isValid() }) else {
            return .notFound
        }
        // Widening answers for allow rules only: a refusal is not trust to
        // promote, so a deny row reports unknown rather than losing its scope.
        guard current.action == .allow else { return .notFound }
        // A send rule is per-recipient by design: an empty target is an invalid scope there, never
        // a tool-wide scope, so send trust is never promoted past the canonical handle the owner
        // approved.
        guard current.toolName != "messages.send" else {
            return .notWidenable(reason: GrantWidenOutcome.messagesSendRefusal)
        }
        guard current.scope != .toolWide else {
            return .widened
        }
        // A pre-existing tool-wide rule may outlive the narrow rule the user is promoting.
        if let covering = rules.first(where: {
            $0.id != id && $0.action == .allow && $0.toolName == current.toolName && $0.scope == .toolWide
        }), !Self.expiryLifetime(current.expiresAt, outlives: covering.expiresAt) {
            rules.removeAll { $0.id == id }
            await persist()
            return .widened
        }
        // Dedupe can remove a tool-wide rule positioned before the target, shifting the target's
        // slot; a pre-removal index would then land on an unrelated rule or read past the end when
        // the target was last.
        rules.removeAll {
            $0.id != id && $0.action == .allow && $0.toolName == current.toolName && $0.scope == .toolWide
        }
        // Identity, creation time, and usage counters survive so the dashboard
        // keeps proving liveness across the change and no second row is minted.
        guard var widened = AccessRule(
            id: current.id,
            toolName: current.toolName,
            scope: .toolWide,
            action: .allow,
            grantedAt: current.grantedAt,
            duration: current.duration,
            expiresAt: current.expiresAt,
            reason: current.reason
        ) else { return .notWidenable(reason: GrantWidenOutcome.messagesSendRefusal) }
        widened.useCount = current.useCount
        widened.lastUsedAt = current.lastUsedAt
        if let index = rules.firstIndex(where: { $0.id == id }) {
            rules[index] = widened
        } else {
            // The dedupe excludes the target's own identifier, so it should
            // always survive; append only as a last resort so a promoted rule
            // is never silently dropped if in-memory state ever drifts.
            rules.append(widened)
        }
        await persist()
        return .widened
    }

    /// Re-arms an existing active allow rule to a new duration tier.
    public func rearmGrant(id: UUID, duration: TrustDuration) async -> GrantRearmOutcome {
        pruneExpired()
        guard let current = rules.first(where: { $0.id == id && $0.isValid() && $0.action == .allow }) else {
            return .notFound
        }
        // One-shot approvals store no row, so there is no lifetime to extend.
        // Allowlist the durable tiers so any future tier defaults to refusal
        // instead of silently minting an unexpected lifetime.
        guard duration.isDurable else {
            return .invalidDuration(reason: GrantRearmOutcome.thisTimeRefusal)
        }
        // Recompute from confirmation time: a nil interval is the forever tier
        // and clears expiry, while a dated tier expires that far from now.
        let expiresAt = duration.timeInterval.map { Date().addingTimeInterval($0) }
        guard var rearmed = AccessRule(
            id: current.id,
            toolName: current.toolName,
            scope: current.scope,
            action: .allow,
            grantedAt: current.grantedAt,
            duration: duration,
            expiresAt: expiresAt,
            reason: current.reason
        ) else { return .invalidDuration(reason: GrantRearmOutcome.thisTimeRefusal) }
        rearmed.useCount = current.useCount
        rearmed.lastUsedAt = current.lastUsedAt
        if let index = rules.firstIndex(where: { $0.id == id }) {
            rules[index] = rearmed
        } else {
            // The lookup above found the rule, so it should still be present;
            // append only as a last resort so a re-armed rule is never dropped
            // if in-memory state ever drifts.
            rules.append(rearmed)
        }
        await persist()
        return .rearmed
    }

    /// Returns the currently valid rules, pruning expired ones first.
    /// - Returns: Live rules, allow and deny together.
    public func activeRules() -> [AccessRule] {
        pruneExpired()
        return rules
    }

    /// Lists the ephemeral grants a session currently holds.
    public func ephemeralGrants(sessionID: UUID) -> [EphemeralGrant] {
        pruneExpired()
        let task = Array(taskGrants[sessionID] ?? [])
        let session = Array(sessionGrants[sessionID] ?? [])
        // Set iteration order is unspecified, so sort for a stable listing the
        // caller can compare without flaking on hash order.
        return (task + session).sorted {
            if $0.kind != $1.kind {
                return $0.kind == .task
            }
            if $0.toolName != $1.toolName {
                return $0.toolName < $1.toolName
            }
            return Self.scopeLabel($0.scope) < Self.scopeLabel($1.scope)
        }
    }

    /// Whether a live rule or ephemeral grant covers the scope.
    public func isTrusted(scope: AccessScope, toolName: String, sessionID: UUID? = nil) -> Bool {
        pruneExpired()
        if let sessionID, coversEphemeral(scope: scope, toolName: toolName, sessionID: sessionID) {
            return true
        }
        return rules.contains {
            $0.action == .allow && $0.isValid() && $0.toolName == toolName && Self.scope($0.scope, covers: scope, toolName: toolName)
        }
    }

    /// Whether a covering domain allow authorizes egress to a host.
    public func egressAllowCovers(host: String, toolName: String?, sessionID: UUID?) -> Bool {
        pruneExpired()
        guard let want = AccessScope.canonicalDomain(host) else { return false }
        if let sessionID {
            let tables = [taskGrants[sessionID], sessionGrants[sessionID]].compactMap(\.self)
            for table in tables {
                for grant in table where toolName == nil || grant.toolName == toolName {
                    if case let .domain(ruleHost, subdomains) = grant.scope,
                       want == ruleHost || (subdomains && want.hasSuffix("." + ruleHost))
                    {
                        return true
                    }
                }
            }
        }
        for rule in rules where rule.action == .allow && rule.isValid() {
            if let toolName, rule.toolName != toolName {
                continue
            }
            if case let .domain(ruleHost, subdomains) = rule.scope,
               want == ruleHost || (subdomains && want.hasSuffix("." + ruleHost))
            {
                return true
            }
        }
        return false
    }

    /// Whether a live rule or ephemeral grant covers the descriptor.
    public func isTrusted(_ descriptor: ActionDescriptor, sessionID: UUID? = nil) -> Bool {
        isTrusted(scope: Self.scope(for: descriptor), toolName: descriptor.toolName, sessionID: sessionID)
    }

    // MARK: - Private

    /// Extracts the bash command for rule evaluation via the shared decoder.
    /// - Parameter toolCall: Raw invocation arguments.
    /// - Returns: Trimmed command (possibly empty so `evaluate` denies), or nil only when unparseable.
    private static func bashCommand(from toolCall: ToolInput) -> String? {
        guard let data = toolCall.argumentsJSON.data(using: .utf8) else { return nil }
        do {
            let args = try JSONDecoder().decode(BashCommandArgs.self, from: data)
            // Blank commands return empty so the evaluator denies closed instead
            // of skipping evaluation and parking for approval.
            return args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            RuneWeaverLog.stores.debug("bashCommand: failed to decode arguments JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether the first effective expiry strictly outlives the second. A nil expiry is the forever
    /// tier, so it outlives every dated rule while two forever rules tie.
    private static func expiryLifetime(_ candidate: Date?, outlives incumbent: Date?) -> Bool {
        guard let candidate else { return incumbent != nil }
        guard let incumbent else { return false }
        return candidate > incumbent
    }

    /// Scope a descriptor maps to.
    static func scope(for descriptor: ActionDescriptor) -> AccessScope {
        descriptor.target.isEmpty ? .toolWide : .exactTarget(descriptor.target)
    }

    /// Whether a scope may be minted for a tool.
    private static func isMintableScope(_ scope: AccessScope, toolName: String) -> Bool {
        guard toolName == "messages.send", scope == .toolWide else { return true }
        return false
    }

    /// Whether a stored rule may be loaded and evaluated.
    private static func isGrantableRule(_ rule: AccessRule) -> Bool {
        isMintableScope(rule.scope, toolName: rule.toolName)
    }

    /// Whether a descriptor may key a durable grant. A `messages.send` grant must store the exact
    /// canonical handle the owner authorized.
    private static func isGrantable(_ descriptor: ActionDescriptor) -> Bool {
        guard descriptor.toolName == "messages.send" else { return true }
        return scope(for: descriptor).isMintableSendScope
    }

    /// Index of the live allow rule covering a scope, if any.
    private func coveringRuleIndex(scope: AccessScope, toolName: String, at date: Date) -> Int? {
        if let exact = rules.firstIndex(where: {
            $0.action == .allow && $0.isValid(at: date) && $0.toolName == toolName && $0.scope == scope
        }) {
            return exact
        }
        if let covering = rules.firstIndex(where: {
            $0.action == .allow && $0.isValid(at: date) && $0.toolName == toolName && Self.scope($0.scope, covers: scope, toolName: toolName)
        }) {
            return covering
        }
        guard scope != .toolWide else { return nil }
        return rules.firstIndex(where: {
            $0.action == .allow && $0.isValid(at: date) && $0.toolName == toolName && $0.scope == .toolWide
        })
    }

    /// Whether a stored scope covers a requested scope. Exact scope equality first, then the
    /// tool-wide fallback.
    private static func scope(_ stored: AccessScope, covers requested: AccessScope, toolName: String) -> Bool {
        if stored == requested {
            return true
        }
        if stored == .toolWide {
            return true
        }
        if case let .exactTarget(storedPattern) = stored,
           case let .exactTarget(requestedTarget) = requested
        {
            return AccessScope.matchesTarget(callTarget: requestedTarget, pattern: storedPattern, toolName: toolName)
        }
        return false
    }

    /// Whether either ephemeral table covers the scope for one session.
    private func coversEphemeral(scope: AccessScope, toolName: String, sessionID: UUID) -> Bool {
        let tables = [taskGrants[sessionID], sessionGrants[sessionID]].compactMap(\.self)
        for table in tables where table.contains(where: { $0.toolName == toolName && Self.scope($0.scope, covers: scope, toolName: toolName) }) {
            return true
        }
        return false
    }

    /// Whether either ephemeral table covers a live call for one session.
    private func coversEphemeral(toolName: String, argumentsJSON: String, sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        let tables = [taskGrants[sessionID], sessionGrants[sessionID]].compactMap(\.self)
        for table in tables where table.contains(where: {
            $0.toolName == toolName && $0.scope.matches(toolName: toolName, argumentsJSON: argumentsJSON)
        }) {
            return true
        }
        return false
    }

    /// The durable deny rule covering a live call, if any.
    private func denyRule(matchingToolCall toolCall: ToolInput, toolName: String) -> AccessRule? {
        rules.first {
            $0.action == .deny && $0.isValid() && $0.covers(toolName: toolName, argumentsJSON: toolCall.argumentsJSON)
        }
    }

    /// The durable allow rule covering a live call, if any.
    private func coveringRule(toolName: String, argumentsJSON: String, at date: Date) -> AccessRule? {
        rules.first {
            $0.action == .allow && $0.isValid(at: date)
                && $0.covers(toolName: toolName, argumentsJSON: argumentsJSON)
        }
    }

    /// Refusal text for a deny rule, naming the rule's scope and reason.
    /// - Parameter rule: Deny rule that refused the call.
    /// - Returns: Caller-facing denial carrying no argument content.
    private func denyReason(for rule: AccessRule) -> String {
        let scope = Self.scopeLabel(rule.scope)
        let reason = rule.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reason.isEmpty {
            return "Denied by rule: \(rule.toolName) is refused for \(scope)."
        }
        return "Denied by rule: \(rule.toolName) is refused for \(scope) (\(reason))."
    }

    /// Human-readable scope label, shared so denial and listing spell it alike.
    /// - Parameter scope: Scope to label.
    /// - Returns: Display label.
    private static func scopeLabel(_ scope: AccessScope) -> String {
        switch scope {
        case .toolWide:
            "every target"
        case let .exactTarget(target):
            "target '\(target)'"
        case let .recipientSet(members):
            "recipients \(AccessScope.normalizeRecipients(members).joined(separator: ", "))"
        case let .domain(host, subdomains):
            subdomains ? "domain \(host) and its subdomains" : "domain \(host)"
        case let .pathPrefix(prefix):
            "path prefix \(prefix)"
        case let .glob(pattern):
            "command pattern \(pattern)"
        }
    }

    /// Write posture for a `files.write` call, or nil when the call carries no usable path.
    private func writePathDecision(toolCall: ToolInput) -> WritePathPolicy.Decision? {
        guard let path = Self.writePath(from: toolCall) else { return nil }
        // The model-authored mode travels with the call so the `.model` write
        // posture resolves exactly as the tool it hands the call to does.
        let requestedMode = Self.writeRequestedMode(from: toolCall)
        return WritePathPolicy.classify(
            path: path,
            filesConfig: filesConfig,
            requestedMode: requestedMode
        )
    }

    /// Per-call write mode a `files.write` call requests, or nil when absent. Only a real string
    /// value reaches the policy, so a malformed mode is an absent one and the write stays on its
    /// safe default.
    private static func writeRequestedMode(from toolCall: ToolInput) -> String? {
        guard let object = ActionDescriptor.parsedArgumentsObject(from: toolCall.argumentsJSON), let raw = object["mode"], !(raw is NSNull),
              let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First non-empty path-shaped argument of a `files.write` call. Reads the same key list the
    /// protected-path guard screens, so the write posture and the engine-file guard look at one call
    /// the same way.
    private static func writePath(from toolCall: ToolInput) -> String? {
        let candidateKeys = ["path", "file_path", "filePath", "target", "destination", "directory", "dir"]
        guard let object = ActionDescriptor.parsedArgumentsObject(from: toolCall.argumentsJSON) else { return nil }
        for key in candidateKeys {
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    /// Drops expired rules from memory only, without touching storage. A deny rule carries no
    /// expiry, so it never ages out; only allow rules do.
    private func pruneExpired() {
        let now = Date()
        rules.removeAll { $0.action == .allow && $0.isExpired(at: now) }
        evictStaleEphemeralGrants(now: now)
    }

    /// Mirrors the current rules to the store in actor order.
    private func persist() async {
        guard let ruleStore else { return }
        let snapshot = rules
        do {
            try await ruleStore.save(snapshot)
        } catch {
            RuneWeaverLog.stores.error("PermissionGate: Failed to persist access rules: \(error)")
        }
    }
}
