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
        intent: String? = nil,
        assessment: ImpactAssessment? = nil,
        egressHost: String? = nil
    ) -> PermissionRequest {
        let effectiveEgressHost = egressHost ?? Self.extractEgressHost(toolName: toolName, argumentsJSON: input.argumentsJSON)
        let request = PermissionRequest(
            toolName: toolName,
            description: description,
            input: input,
            intent: intent,
            assessment: assessment,
            egressHost: effectiveEgressHost
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
        onEnriched: (@Sendable (PermissionRequest) async -> Void)? = nil
    ) async -> PermissionRequest {
        let effectiveEgressHost = egressHost ?? Self.extractEgressHost(toolName: tool.name, argumentsJSON: call.argumentsJSON)
        if let assessment {
            let request = PermissionRequest(
                toolName: tool.name,
                description: tool.description,
                input: call,
                sessionID: sessionID,
                intent: intent,
                assessment: assessment,
                egressHost: effectiveEgressHost
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
            egressHost: effectiveEgressHost
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
            egressHost: existing.egressHost
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
    ///   - widen: When true and duration is not `.thisTime`, grants tool-wide trust matching any target.
    /// - Returns: True when the request was pending and resolved.
    @discardableResult
    public func decide(id: UUID, approved: Bool, duration: TrustDuration = .thisTime, widen: Bool = false) async -> Bool {
        // Cancel the enrichment child first so a model result landing in the
        // gap cannot resurrect the entry or rebroadcast after the decision.
        enrichmentTasks.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else {
            return false
        }
        let wasTimedOut = timedOutIDs.remove(id) != nil
        // Continuation approvals resume a single parked batch, so they stay
        // one-shot: coerce any durable or widened tier back to thisTime so a
        // direct decide call cannot mint a dead forever grant for engine.continue.
        let effectiveDuration: TrustDuration = request.toolName == "engine.continue" ? .thisTime : duration
        let effectiveWiden: Bool = request.toolName == "engine.continue" ? false : widen
        let decision = ApprovalQueueDecision(approved: approved, duration: effectiveDuration)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: decision)
        } else if !wasTimedOut {
            earlyDecisions[id] = decision
        }
        if approved, effectiveDuration != .thisTime {
            // The durable grant must store the same descriptor the gate derives
            // for the next call, so narrow grants route through the shared
            // tool-aware derivation instead of a generic target extraction that
            // would not match `browser.act` or `api.request`. An empty target is
            // the widen scope and covers every target for the tool; the gate's
            // grant path enforces the never-shorten invariant for that scope, so
            // a shorter decision here cannot truncate an existing tool-wide
            // grant and both widen entry points agree on the same trust floor.
            let descriptor = effectiveWiden
                ? ActionDescriptor(toolName: request.toolName, target: "")
                : ActionDescriptor.descriptor(for: request.input, toolName: request.toolName)
            // A durable `messages.send` grant must key on the canonical handle
            // the owner is authorizing, so approving a request whose recipient
            // is a display name can never mint trust, and there is no tool-wide
            // send scope for a widen decision to promote. Admission refuses
            // name-shaped sends before filing on the orchestrator path; this
            // guard keeps the invariant for every other filing path (headless
            // bus handlers, direct enqueue), and the gate refuses invalid send
            // descriptors defensively beneath it. The approved call still fails
            // closed at execution when the arguments are malformed.
            if request.toolName == "messages.send",
               effectiveWiden || ActionDescriptor.messagesRecipientHandle(from: request.input) == nil
            {
                return true
            }
            await permissionGate?.grantTrust(for: descriptor, duration: effectiveDuration)
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
                    try? await Task.sleep(nanoseconds: nanoseconds)
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
            await queue.fileRequest(tool: tool, call: call, sessionID: context.conversationID)
            return false
        }
    }
}
