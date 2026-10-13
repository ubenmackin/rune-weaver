// Rune Weaver Core — Headless and interactive tool approval queue.

import Foundation

/// Decision resolving one headless approval request.
public struct ApprovalQueueDecision: Sendable, Equatable {
    /// Whether the tool call may run.
    public let approved: Bool
    /// Graduated-trust tier recorded on approval, if any.
    public let duration: TrustDuration?
    /// Whether the denial came from a wait timeout rather than an explicit decision.
    public let timedOut: Bool

    /// Creates a decision.
    public init(approved: Bool, duration: TrustDuration? = nil, timedOut: Bool = false) {
        self.approved = approved
        self.duration = duration
        self.timedOut = timedOut
    }
}

/// Pending approvals filed by headless scheduler turns.
///
/// Two-phase filing: `fileRequest` without an explicit assessment enqueues
/// immediately with a nil assessment and enriches in the background, so the
/// inbox renders instantly while the model (or heuristics on timeout) lands on
/// the same identifier shortly after. Late enrichment after a decision is
/// dropped without rebroadcast and without trust side effects.
public actor ApprovalQueue {
    /// Pending requests indexed by identifier.
    private var pending: [UUID: PermissionRequest] = [:]
    /// Decisions that arrived before their waiter started waiting.
    private var earlyDecisions: [UUID: ApprovalQueueDecision] = [:]
    /// Waiters suspended in `waitForDecision(id:)`.
    private var waiters: [UUID: CheckedContinuation<ApprovalQueueDecision, Never>] = [:]
    /// Timeout sleepers for `waitForDecision(id:timeoutSeconds:)`, indexed
    /// by request so an early `decide(id:...)` or `clear()` cancels the
    /// sleeper instead of leaving it alive for the full timeout.
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// Requests whose waiter timed out but whose inbox entry is retained.
    private var timedOutIDs: Set<UUID> = []
    /// Background enrichment tasks keyed by the request they will enrich.
    ///
    /// One entry per nil-assessment filing. Cancelled on `decide` and `clear`
    /// so a decision racing the model cannot be resurrected by a late result.
    private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]
    /// Rebroadcast hook invoked with the enriched request on identical id.
    ///
    /// The pipeline installs the same `broadcastApproval` plus `onEvent`
    /// approval path used for the initial filing here, so enriched updates
    /// travel the identical channel without the queue knowing the transport.
    private var enrichmentBroadcast: (@Sendable (PermissionRequest) async -> Void)?
    /// Graduated-trust gate receiving approved durations.
    private let permissionGate: PermissionGate?

    /// Creates an approval queue.
    /// - Parameter permissionGate: Gate receiving approved trust grants.
    ///   Defaults to nil (decisions resolve waiters only).
    public init(permissionGate: PermissionGate? = nil) {
        self.permissionGate = permissionGate
    }

    /// Live bash policy for headless tier stamping.
    /// - Returns: Current bash policy, or nil when no gate is wired.
    func stampedBashConfig() async -> BashConfig? {
        await permissionGate?.bashConfigSnapshot()
    }

    /// Workspace root for headless tier stamping.
    /// - Returns: Configured root, or nil for the production fallback.
    func stampedWorkspaceRoot() async -> URL? {
        await permissionGate?.workspaceRootSnapshot()
    }

    // MARK: - Enrichment broadcast hook

    /// Rebroadcast hook for enriched assessments on identical id.
    ///
    /// The pipeline installs the same broadcast plus event path used for the
    /// initial filing here, so enriched updates travel the identical channel
    /// without the queue knowing the transport. Nil until installed; late
    /// results for decided ids never reach it.
    public var onEnriched: (@Sendable (PermissionRequest) async -> Void)? {
        get { enrichmentBroadcast }
        set { enrichmentBroadcast = newValue }
    }

    /// Installs the rebroadcast hook for enriched assessments.
    /// - Parameter handler: Hook receiving the updated request on identical id.
    public func setOnEnriched(_ handler: (@Sendable (PermissionRequest) async -> Void)?) {
        enrichmentBroadcast = handler
    }

    /// Enqueues a prebuilt request, replacing any same-id entry.
    /// - Parameter request: Request to track.
    public func enqueue(_ request: PermissionRequest) {
        pending[request.id] = request
    }

    /// Builds and enqueues a request for a tool call.
    @discardableResult
    public func enqueue(
        toolName: String,
        description: String = "",
        input: ToolInput,
        sessionID: UUID? = nil,
        intent: String? = nil,
        assessment: ImpactAssessment? = nil,
        egressHost: String? = nil,
        bashConfig: BashConfig? = nil,
        workspaceRoot: URL? = nil
    ) -> PermissionRequest {
        let effectiveEgressHost = egressHost
        let sandboxSummary = Self.stampedSandboxSummary(
            toolName: toolName,
            argumentsJSON: input.argumentsJSON,
            bashConfig: bashConfig,
            workspaceRoot: workspaceRoot
        )
        let request = PermissionRequest(
            toolName: toolName,
            description: description,
            input: input,
            sessionID: sessionID,
            intent: intent,
            assessment: assessment,
            egressHost: effectiveEgressHost,
            sandboxSummary: sandboxSummary
        )
        pending[request.id] = request
        return request
    }

    /// Files a gated tool call into the queue.
    ///
    /// Immediate enqueue: when no explicit assessment is supplied the pending
    /// request is built with a nil assessment, stored, and returned without
    /// awaiting the model. A background child task then evaluates (model with
    /// a 2.5-second budget, heuristics on timeout, refusal, parse failure, or
    /// unavailable model) and enriches the same identifier in place. When an
    /// explicit assessment is supplied the request enqueues directly with that
    /// value and no child task spawns. Filing always succeeds even when
    /// enrichment later fails; the assessment always resolves through
    /// heuristics as the fail-closed floor. The per-request hook, when
    /// supplied, fires once with the enriched request on identical id
    /// alongside the queue-wide rebroadcast; explicit assessments never invoke
    /// it, and late results after decide never invoke it so a racing decision
    /// wins.
    @discardableResult
    public func fileRequest(
        tool: any Tool,
        call: ToolInput,
        sessionID: UUID? = nil,
        intent: String? = nil,
        assessment: ImpactAssessment? = nil,
        egressHost: String? = nil,
        onEnriched: (@Sendable (PermissionRequest) async -> Void)? = nil,
        bashConfig: BashConfig? = nil,
        workspaceRoot: URL? = nil
    ) async -> PermissionRequest {
        let effectiveEgressHost = egressHost ?? Self.extractEgressHost(toolName: tool.name, argumentsJSON: call.argumentsJSON)
        let sandboxSummary = Self.stampedSandboxSummary(
            toolName: tool.name,
            argumentsJSON: call.argumentsJSON,
            bashConfig: bashConfig,
            workspaceRoot: workspaceRoot
        )
        if let assessment {
            let request = PermissionRequest(
                toolName: tool.name,
                description: tool.description,
                input: call,
                sessionID: sessionID,
                intent: intent,
                assessment: assessment,
                egressHost: effectiveEgressHost,
                sandboxSummary: sandboxSummary
            )
            pending[request.id] = request
            return request
        }
        let request = PermissionRequest(
            toolName: tool.name,
            description: tool.description,
            input: call,
            sessionID: sessionID,
            intent: intent,
            assessment: nil,
            egressHost: effectiveEgressHost,
            sandboxSummary: sandboxSummary
        )
        pending[request.id] = request
        spawnEnrichment(
            id: request.id,
            toolName: tool.name,
            argumentsJSON: call.argumentsJSON,
            intent: intent,
            perRequestHandler: onEnriched
        )
        return request
    }

    /// Spawns the background enrichment child for one pending request.
    private func spawnEnrichment(
        id: UUID,
        toolName: String,
        argumentsJSON: String,
        intent: String?,
        perRequestHandler: (@Sendable (PermissionRequest) async -> Void)?
    ) {
        enrichmentTasks[id]?.cancel()
        enrichmentTasks[id] = Task { [perRequestHandler] in
            let assessed = await AppleIntelligenceAssessor.shared.assess(
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                intent: intent
            )
            guard !Task.isCancelled else { return }
            await self.finishEnrichment(id: id, assessment: assessed, perRequestHandler: perRequestHandler)
        }
    }

    /// Applies one enriched assessment and rebroadcasts on identical id.
    ///
    /// Single actor hop after the model resolves: a pending-existence check
    /// drops late results for already-decided ids without rebroadcast and
    /// without trust-grant side effects, so a decision racing the model wins.
    private func finishEnrichment(
        id: UUID,
        assessment: ImpactAssessment,
        perRequestHandler: (@Sendable (PermissionRequest) async -> Void)?
    ) async {
        guard !Task.isCancelled else {
            enrichmentTasks.removeValue(forKey: id)
            return
        }
        guard pending[id] != nil else {
            enrichmentTasks.removeValue(forKey: id)
            return
        }
        guard let updated = applyAssessment(id: id, assessment: assessment) else {
            enrichmentTasks.removeValue(forKey: id)
            return
        }
        enrichmentTasks.removeValue(forKey: id)
        if let perRequestHandler {
            await perRequestHandler(updated)
            // A decision racing the per-request broadcast must win, so confirm
            // the entry is still parked before touching the shared channel.
            guard pending[id] != nil else { return }
        }
        if let broadcast = enrichmentBroadcast {
            await broadcast(updated)
        }
    }

    /// Applies an assessment in place for one pending request.
    /// - Parameters:
    ///   - id: Request identifier to enrich.
    ///   - assessment: Assessment to set.
    /// - Returns: Updated request, or nil when the id is already decided and removed.
    private func applyAssessment(id: UUID, assessment: ImpactAssessment) -> PermissionRequest? {
        guard let existing = pending[id] else { return nil }
        let updated = PermissionRequest(
            id: existing.id,
            toolName: existing.toolName,
            description: existing.description,
            input: existing.input,
            suggestedDurations: existing.suggestedDurations,
            sessionID: existing.sessionID,
            intent: existing.intent,
            assessment: assessment,
            egressHost: existing.egressHost,
            sandboxSummary: existing.sandboxSummary
        )
        pending[id] = updated
        return updated
    }

    /// Sets the assessment for one pending request in place.
    ///
    /// Preserves the filing identity while refreshing its safety grading, so
    /// live views can replace the pending card without re-parking. A decided
    /// id stays decided: the call no-ops without side effects. A successful
    /// update rebroadcasts on the identical channel as background enrichment.
    /// - Parameters:
    ///   - id: Request identifier to enrich.
    ///   - assessment: Assessment to set.
    /// - Returns: Updated request, or nil when unknown or already decided.
    @discardableResult
    public func updateAssessment(id: UUID, assessment: ImpactAssessment) async -> PermissionRequest? {
        guard let updated = applyAssessment(id: id, assessment: assessment) else { return nil }
        if let broadcast = enrichmentBroadcast {
            await broadcast(updated)
        }
        return updated
    }

    /// Lists pending requests for one session, in no guaranteed order.
    public func requests(for sessionID: UUID) -> [PermissionRequest] {
        pending.values.filter { $0.sessionID == sessionID }
    }

    /// Discards a parked early decision without suspending.
    @discardableResult
    public func takeEarlyDecision(id: UUID) -> ApprovalQueueDecision? {
        earlyDecisions.removeValue(forKey: id)
    }

    /// Lists pending requests in no guaranteed order.
    public func list() -> [PermissionRequest] {
        Array(pending.values)
    }

    /// Number of pending requests.
    /// - Returns: Pending count.
    public func count() -> Int {
        pending.count
    }

    /// Looks up one pending request.
    /// - Parameter id: Request identifier.
    /// - Returns: The request, or nil when unknown or already decided.
    public func request(id: UUID) -> PermissionRequest? {
        pending[id]
    }

    /// Resolves one pending request.
    /// - Parameters:
    ///   - id: Request identifier.
    ///   - approved: Whether the request was approved.
    ///   - duration: Trust duration tier. Defaults to `.thisTime`.
    ///   - scope: How wide a durable decision reaches. Nil derives the
    ///     request's own scope: an egress-shaped request resolves to the
    ///     host it parked on, every other request to the descriptor
    ///     target the gate derives for the next identical call.
    /// - Returns: True when the request was pending and resolved.
    @discardableResult
    public func decide(
        id: UUID,
        approved: Bool,
        duration: TrustDuration = .thisTime,
        scope: AccessScope? = nil
    ) async -> Bool {
        // Cancel the enrichment child first so a model result landing in the
        // gap cannot resurrect the entry or rebroadcast after the decision.
        enrichmentTasks.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else {
            return false
        }
        let wasTimedOut = timedOutIDs.remove(id) != nil
        // Continuation, question, desktop resume, and brake approvals resolve a
        // single parked batch rather than gating a repeatable call, so they stay
        // one-shot: coerce any durable tier back to thisTime so a direct decide
        // call cannot mint a dead row. `behavior.brake` is not an executable
        // tool, so a durable vote on it would only store a rule no call can hit.
        let isOneShotTool = Self.oneShotToolNames.contains(request.toolName)
        let effectiveDuration: TrustDuration = isOneShotTool ? .thisTime : duration
        let decision = ApprovalQueueDecision(approved: approved, duration: effectiveDuration)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: decision)
        } else if !wasTimedOut {
            earlyDecisions[id] = decision
        }
        if approved, effectiveDuration != .thisTime {
            let resolvedScope = scope ?? Self.derivedScope(for: request)
            // A durable `messages.send` grant must key on the canonical handle
            // or recipient set the owner is authorizing, so approving a request
            // whose recipient is a display name can never mint trust, and there
            // is no tool-wide send scope. Admission refuses name-shaped sends
            // before filing on the orchestrator path; this guard keeps the
            // invariant for every other filing path (headless bus handlers,
            // direct enqueue), and the gate refuses invalid send scopes
            // defensively beneath it. The approved call still fails closed at
            // execution when the arguments are malformed.
            if request.toolName == "messages.send", !resolvedScope.isMintableSendScope {
                return true
            }
            // The durable mint routes through the shared grant boundary with
            // the resolved scope, so the never-shorten invariant and scope
            // canonicalization apply exactly as they do on every other mint
            // entry point.
            await permissionGate?.grant(
                resolvedScope,
                toolName: request.toolName,
                duration: effectiveDuration,
                sessionID: request.sessionID
            )
        } else if !approved, effectiveDuration == .forever {
            // An explicit durable denial is the only owner decision that mints
            // a deny rule: it outranks every allow decision and never expires,
            // so the denied call fails closed on every later repeat.
            let resolvedScope = scope ?? Self.derivedScope(for: request)
            await permissionGate?.denyRule(
                resolvedScope,
                toolName: request.toolName,
                reason: "Denied by owner decision on \(request.toolName)."
            )
        }
        return true
    }

    /// Default seconds a service approval handler waits before denying.
    public static var defaultDecisionTimeoutSeconds: Double {
        300
    }

    /// Waits for the decision resolving one request.
    public func waitForDecision(id: UUID) async -> ApprovalQueueDecision {
        if let early = earlyDecisions.removeValue(forKey: id) {
            return early
        }
        guard pending[id] != nil else {
            return ApprovalQueueDecision(approved: false, duration: nil)
        }
        if Task.isCancelled {
            cancelWaiter(id: id)
            return ApprovalQueueDecision(approved: false, duration: nil)
        }
        // Cancellation contract: onCancel is synchronous and hops onto the actor via an
        // asynchronous Task to invoke cancelWaiter.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalQueueDecision, Never>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { [self, id] in
                await self.cancelWaiter(id: id)
            }
        }
    }

    /// Waits for the decision resolving one request, denying on timeout.
    public func waitForDecision(id: UUID, timeoutSeconds: Double) async -> ApprovalQueueDecision {
        guard timeoutSeconds > 0 else {
            return await waitForDecision(id: id)
        }
        if let early = earlyDecisions.removeValue(forKey: id) {
            return early
        }
        guard pending[id] != nil else {
            return ApprovalQueueDecision(approved: false, duration: nil)
        }
        if Task.isCancelled {
            cancelWaiter(id: id)
            return ApprovalQueueDecision(approved: false, duration: nil)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalQueueDecision, Never>) in
                waiters[id] = continuation
                let nsDouble = (timeoutSeconds * 1_000_000_000).rounded(.down)
                let nanoseconds: UInt64 = nsDouble >= Double(UInt64.max) ? UInt64.max : UInt64(max(nsDouble, 0))
                timeoutTasks[id] = Task { [self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self.timeoutWaiter(id: id)
                }
            }
        } onCancel: {
            Task { [self, id] in
                await self.cancelWaiter(id: id)
            }
        }
    }

    /// Denies one waiter when its decision timeout elapses.
    private func timeoutWaiter(id: UUID) async {
        timeoutTasks.removeValue(forKey: id)
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        guard pending[id] != nil else { return }
        timedOutIDs.insert(id)
        waiter.resume(returning: ApprovalQueueDecision(approved: false, duration: nil, timedOut: true))
    }

    /// Denies one waiter when its waiting task is cancelled.
    private func cancelWaiter(id: UUID) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        timedOutIDs.remove(id)
        pending.removeValue(forKey: id)
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: ApprovalQueueDecision(approved: false, duration: nil))
    }

    /// Removes every pending request and parks denials for waiters.
    ///
    /// Cancels all background enrichment children alongside the timeout
    /// sleepers, so a clear racing the model leaves no late rebroadcast and
    /// no resurrected entry.
    public func clear() {
        for (_, task) in timeoutTasks {
            task.cancel()
        }
        timeoutTasks.removeAll()
        for (_, task) in enrichmentTasks {
            task.cancel()
        }
        enrichmentTasks.removeAll()
        let suspended = waiters
        waiters.removeAll()
        pending.removeAll()
        earlyDecisions.removeAll()
        timedOutIDs.removeAll()
        for (_, waiter) in suspended {
            waiter.resume(returning: ApprovalQueueDecision(approved: false, duration: nil))
        }
    }

    /// Headless approval handler for scheduler tool buses.
    public func headlessApprovalHandler() -> ToolApprovalHandler {
        { [queue = self] tool, call, context in
            let bashConfig = await queue.stampedBashConfig()
            let workspaceRoot = await queue.stampedWorkspaceRoot()
            await queue.fileRequest(
                tool: tool,
                call: call,
                sessionID: context.conversationID,
                bashConfig: bashConfig,
                workspaceRoot: workspaceRoot
            )
            return false
        }
    }
}

// MARK: - Decision Scope Derivation

extension ApprovalQueue {
    /// Scope a decision resolves to when the caller supplies none.
    ///
    /// Egress-shaped requests (a parked unlisted host) resolve to that host, so
    /// a durable egress decision reaches exactly the domain the call dialed.
    /// Every other request resolves to the descriptor target the gate derives
    /// for the next identical call, which keeps a narrow grant covering the
    /// repeat instead of re-prompting; an empty target is the malformed-call
    /// signature and stores nothing rather than widening to tool-wide.
    /// - Parameter request: Pending request the decision resolves.
    /// - Returns: Scope the decision reaches.
    private static func derivedScope(for request: PermissionRequest) -> AccessScope {
        if let egressHost = request.egressHost {
            return .domain(host: egressHost, subdomains: false)
        }
        return .exactTarget(ActionDescriptor.descriptor(for: request.input, toolName: request.toolName).target)
    }

    /// Tools whose decision resolves one parked batch instead of gating a
    /// repeatable call, so a durable tier on them is meaningless: the tier
    /// coerces to thisTime and no rule is minted. `behavior.brake` is not an
    /// executable tool at all, so a durable vote would only store a dead row.
    private static let oneShotToolNames: Set<String> = [
        "engine.continue",
        "question.ask",
        "desktop.resume",
        "behavior.brake"
    ]
}

// MARK: - Bash Sandbox Copy Wiring

extension ApprovalQueue {
    /// Single shared call site so triage badges, approval cards, and the dashboard DTO read identical bytes.
    public static func bashSandboxSummary(sandboxMode: BashSandboxMode, networkAllowed: Bool) -> String {
        BashSandboxCopy.approvalSummary(sandboxMode: sandboxMode, networkAllowed: networkAllowed)
    }

    /// Canonical triage badge for bash requests, single-sourced on the copy owner.
    ///
    /// Nil for non-bash tools so badges stay bash-scoped. The summary carries
    /// only the resolved tier plus network flag with no command, path, or host
    /// interpolation, so inbox and dashboard render identical bytes.
    /// - Parameters:
    ///   - toolName: Tool name gating badge scope.
    ///   - sandboxMode: Resolved sandbox tier for the command.
    ///   - networkAllowed: Whether network egress is allowed for the tier.
    /// - Returns: Shared summary for bash tools, or nil otherwise.
    public static func bashSandboxBadge(
        toolName: String,
        sandboxMode: BashSandboxMode,
        networkAllowed: Bool
    ) -> String? {
        guard toolName == "bash.exec" else { return nil }
        return bashSandboxSummary(sandboxMode: sandboxMode, networkAllowed: networkAllowed)
    }

    /// Approval-card plus dashboard summary for one filed bash request.
    ///
    /// Resolves the tier from the request command against the live bash policy
    /// and derives the network flag from the policy plus the request flag, then
    /// routes through the canonical badge so cards, inbox, and the
    /// dashboard DTO cannot drift. Nil for non-bash tools or missing commands.
    /// - Parameters:
    ///   - request: Filed approval request carrying bash arguments.
    ///   - bashConfig: Live bash policy owning tier plus network defaults.
    ///   - workspaceRoot: Workspace root execution resolves against, or nil for the production root.
    /// - Returns: Shared summary for bash requests, or nil otherwise.
    public static func bashSandboxSummary(
        for request: PermissionRequest,
        bashConfig: BashConfig,
        workspaceRoot: URL? = nil
    ) -> String? {
        stampedSandboxSummary(
            toolName: request.toolName,
            argumentsJSON: request.input.argumentsJSON,
            bashConfig: bashConfig,
            workspaceRoot: workspaceRoot
        )
    }

    /// File-time sandbox summary for one tool call.
    ///
    /// Hermetic scratch roots and relative system-temp working directories only
    /// resolve against a concrete root, so callers pass the root execution will
    /// use; a nil root falls back to the production root so the sync stamping
    /// path still applies the identical host fallback execution runs.
    /// - Parameters:
    ///   - toolName: Tool name gating badge scope.
    ///   - argumentsJSON: Raw tool arguments document.
    ///   - bashConfig: Live bash policy, or nil when unavailable.
    ///   - workspaceRoot: Workspace root execution resolves against, or nil for the production root.
    /// - Returns: Shared summary for bash calls, or nil otherwise.
    static func stampedSandboxSummary(
        toolName: String,
        argumentsJSON: String,
        bashConfig: BashConfig?,
        workspaceRoot: URL? = nil
    ) -> String? {
        guard let bashConfig else { return nil }
        guard toolName == "bash.exec" else { return nil }
        guard let command = bashCommand(from: argumentsJSON) else { return nil }
        let rawCwd = bashCwd(from: argumentsJSON)
        let effectiveRoot = workspaceRoot ?? WorkspaceStore.resolveRoot()
        let tier = BashSandboxRouter.effectiveTier(command: command, config: bashConfig, rawCwd: rawCwd, workspaceRoot: effectiveRoot)
        let requestedNetwork = bashRequestNetwork(from: argumentsJSON)
        return bashSandboxBadge(toolName: toolName, sandboxMode: tier, networkAllowed: bashConfig.allowNetwork || requestedNetwork)
    }

    /// Extracts the shell command from bash arguments without a Tools dependency.
    ///
    /// JSONSerialization keeps Core free of the Tools Codable so tier resolution
    /// cannot drift from the gate decode while staying dependency-free.
    /// - Parameter argumentsJSON: Raw tool arguments document.
    /// - Returns: Trimmed non-empty command, or nil when absent.
    private static func bashCommand(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dict["command"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads the network request flag from bash arguments.
    ///
    /// Missing or malformed flags fail closed to false so the summary never
    /// advertises internet access the policy did not grant.
    /// - Parameter argumentsJSON: Raw tool arguments document.
    /// - Returns: True when the caller requested network access.
    private static func bashRequestNetwork(from argumentsJSON: String) -> Bool {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (dict["request_network"] as? Bool) ?? false
    }

    /// Reads the requested working directory from bash arguments.
    /// - Parameter argumentsJSON: Raw tool arguments document.
    /// - Returns: Raw cwd value, or nil when absent.
    private static func bashCwd(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dict["cwd"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
