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
    private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]
    /// Rebroadcast hook invoked with the enriched request on identical id.
    private var enrichmentBroadcast: (@Sendable (PermissionRequest) async -> Void)?
    /// Broadcast hook carrying a newly filed system notice to live dashboards, fired inside
    /// `enqueueSystemNoticeIfAbsent` so the filed frame rides the insert's actor hop.
    private var noticeBroadcast: (@Sendable (PermissionRequest) async -> Void)?
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

    /// Rebroadcast hook for enriched assessments on identical id. Nil until installed; late results
    /// for decided ids never reach it.
    public var onEnriched: (@Sendable (PermissionRequest) async -> Void)? {
        get { enrichmentBroadcast }
        set { enrichmentBroadcast = newValue }
    }

    /// Installs the rebroadcast hook for enriched assessments.
    /// - Parameter handler: Hook receiving the updated request on identical id.
    public func setOnEnriched(_ handler: (@Sendable (PermissionRequest) async -> Void)?) {
        enrichmentBroadcast = handler
    }

    /// Broadcast hook for newly filed system notices. Nil until installed; a nil hook files the
    /// notice silently (headless hosts and tests).
    public var onNoticeFiled: (@Sendable (PermissionRequest) async -> Void)? {
        get { noticeBroadcast }
        set { noticeBroadcast = newValue }
    }

    /// Installs the broadcast hook for newly filed system notices.
    /// - Parameter handler: Hook receiving the filed request on the insert hop.
    public func setOnNoticeFiled(_ handler: (@Sendable (PermissionRequest) async -> Void)?) {
        noticeBroadcast = handler
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
        // System notices are surfacing-only: the registry, not a name prefix,
        // decides they never schedule a safety assessment.
        guard !SystemNoticeTools.isSystemNotice(toolName) else { return }
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

    /// Applies an assessment in place for one pending request. id: Request
    /// identifier to enrich.
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

    /// Whether any pending request carries one tool name.
    /// - Parameter toolName: Tool name to match.
    /// - Returns: True when at least one pending request carries the name.
    public func hasPending(toolName: String) -> Bool {
        pending.values.contains { $0.toolName == toolName }
    }

    /// Files a system notice only when no pending notice carries the tool name, so dedup, insert,
    /// and the filed-frame broadcast are one atomic actor hop. Returns the filed request, or nil
    /// when one is already parked for the tool or the name is not a registered system-notice tier.
    @discardableResult
    public func enqueueSystemNoticeIfAbsent(toolName: String, description: String) async -> PermissionRequest? {
        guard SystemNoticeTools.isSystemNotice(toolName) else { return nil }
        guard !pending.values.contains(where: { $0.toolName == toolName }) else { return nil }
        let request = enqueue(
            toolName: toolName,
            description: description,
            input: ToolInput(toolName: toolName, argumentsJSON: "{}")
        )
        // The filed frame rides this same actor hop, so any settle that observes the entry does so
        // only after the frame is already in flight: a settle racing a filing can never strand a
        // phantom notice card behind a late caller-side broadcast.
        if let broadcast = noticeBroadcast {
            await broadcast(request)
        }
        return request
    }

    /// Removes every pending item for one system-notice tool, returning them for the settle
    /// broadcast; the caller owns carrying the recovery note into the decision history.
    /// - Returns: Every removed request in no guaranteed order.
    public func settleSystemNotice(toolName: String) -> [PermissionRequest] {
        let settled = pending.values.filter { $0.toolName == toolName }
        for request in settled {
            // Cancel in-flight enrichment so a late assessment cannot
            // resurrect a settled card.
            enrichmentTasks.removeValue(forKey: request.id)?.cancel()
            timeoutTasks.removeValue(forKey: request.id)?.cancel()
            timedOutIDs.remove(request.id)
            earlyDecisions.removeValue(forKey: request.id)
            pending.removeValue(forKey: request.id)
            // A defensively filed waiter releases with the recovery verdict
            // instead of staying suspended; one arriving after the settle
            // parks the same verdict so it cannot read the miss as a denial.
            let recovery = ApprovalQueueDecision(approved: true, duration: nil)
            if let waiter = waiters.removeValue(forKey: request.id) {
                waiter.resume(returning: recovery)
            } else {
                earlyDecisions[request.id] = recovery
            }
        }
        return settled
    }

    /// Resolves one pending request. id: Request identifier.
    @discardableResult
    public func decide(
        id: UUID,
        approved: Bool,
        duration: TrustDuration = .thisTime,
        scope: AccessScope? = nil
    ) async -> Bool {
        // Resolution is never a decision: a system notice settles only through its mapped
        // remedy, so a decide call cannot resolve one or mint durable trust on it.
        if let request = pending[id], SystemNoticeTools.isSystemNotice(request.toolName) {
            return false
        }
        // Cancel the enrichment child first so a model result landing in the
        // gap cannot resurrect the entry or rebroadcast after the decision.
        enrichmentTasks.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else {
            return false
        }
        let wasTimedOut = timedOutIDs.remove(id) != nil
        // Continuation, question, desktop resume, and brake approvals resolve a single parked batch
        // rather than gating a repeatable call, so they stay one-shot: coerce any durable tier back
        // to thisTime so a direct decide call cannot mint a dead row.
        let isOneShotTool = Self.oneShotToolNames.contains(request.toolName)
        let isScheduledSend = Self.isScheduledSend(toolName: request.toolName, argumentsJSON: request.input.argumentsJSON)
        let effectiveDuration: TrustDuration = (isOneShotTool || isScheduledSend) ? .thisTime : duration
        let decision = ApprovalQueueDecision(approved: approved, duration: effectiveDuration)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: decision)
        } else if !wasTimedOut {
            earlyDecisions[id] = decision
        }
        if approved, effectiveDuration != .thisTime {
            let resolvedScope = scope ?? Self.derivedScope(for: request)
            // A durable `messages.send` grant must key on the canonical handle or recipient set the
            // owner is authorizing, so approving a request whose recipient is a display name can
            // never mint trust, and there is no tool-wide send scope.
            if request.toolName == "messages.send", !resolvedScope.isMintableSendScope {
                return true
            }
            // The durable mint routes through the shared grant boundary with the resolved scope, so
            // the never-shorten invariant and scope canonicalization apply exactly as they do on
            // every other mint entry point.
            await permissionGate?.grant(
                resolvedScope,
                toolName: request.toolName,
                duration: effectiveDuration,
                sessionID: request.sessionID
            )
        } else if !approved, duration == .forever, !isOneShotTool {
            // An explicit durable denial is the only owner decision that mints a deny rule: it
            // outranks every allow decision and never expires, so the denied call fails closed on
            // every later repeat.
            let resolvedScope = scope ?? Self.derivedScope(for: request)
            await permissionGate?.denyRule(
                resolvedScope,
                toolName: request.toolName,
                reason: "Denied by owner decision on \(request.toolName)."
            )
        }
        return true
    }

    /// Removes every pending request and parks denials for waiters.
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

// MARK: - Decision Waiting

extension ApprovalQueue {
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
}

// MARK: - Decision Scope Derivation

extension ApprovalQueue {
    /// Scope a decision resolves to when the caller supplies none.
    private static func derivedScope(for request: PermissionRequest) -> AccessScope {
        if let egressHost = request.egressHost {
            return .domain(host: egressHost, subdomains: false)
        }
        return .exactTarget(ActionDescriptor.descriptor(for: request.input, toolName: request.toolName).target)
    }

    /// Tools whose decision resolves one parked batch instead of gating a repeatable call, so a
    /// durable tier on them is meaningless: the tier coerces to thisTime and no rule is minted.
    private static let oneShotToolNames: Set<String> = [
        "engine.continue",
        "question.ask",
        "desktop.resume",
        "behavior.brake"
    ]

    /// Send tools whose approval may book a scheduled send instead of sending now.
    private static let scheduledSendToolNames: Set<String> = [
        "email.send",
        "messages.send"
    ]

    /// Whether one send approval carries a wire-valid fire time, so the booking is the sole effect
    /// and no repeat trust is minted. toolName: Tool the pending request filed.
    private static func isScheduledSend(toolName: String, argumentsJSON: String) -> Bool {
        guard scheduledSendToolNames.contains(toolName) else { return false }
        return hasValidScheduleAt(argumentsJSON)
    }

    /// Wire-shape validity for a scheduleAt fire time: an epoch-seconds number or an ISO-8601
    /// datetime, mirroring the send-tool wire contract.
    private static func hasValidScheduleAt(_ argumentsJSON: String) -> Bool {
        guard let data = argumentsJSON.data(using: .utf8),
              let probe = try? JSONDecoder().decode(ScheduleAtProbe.self, from: data),
              let value = probe.scheduleAt
        else { return false }
        switch value {
        case let .number(seconds):
            return seconds.isFinite
        case let .string(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return SharedDateFormatters.isoWithFractionalSecondsDate(from: trimmed) != nil
                || SharedDateFormatters.isoInternetTimeDate(from: trimmed) != nil
        }
    }

    /// Polymorphic scheduleAt probe decoding the two wire shapes without
    /// failing the whole document on a malformed value.
    private struct ScheduleAtProbe: Decodable {
        var scheduleAt: ScheduleAtValue?
    }

    /// The two accepted fire-time shapes: epoch seconds or ISO-8601 text.
    private enum ScheduleAtValue: Decodable {
        case number(Double)
        case string(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                self = .number(seconds)
                return
            }
            if let raw = try? container.decode(String.self) {
                self = .string(raw)
                return
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "scheduleAt must be an epoch-seconds number or an ISO-8601 datetime"
                )
            )
        }
    }
}

// MARK: - Bash Sandbox Copy Wiring

extension ApprovalQueue {
    /// Single shared call site so triage badges, approval cards, and the dashboard DTO read identical bytes.
    public static func bashSandboxSummary(sandboxMode: BashSandboxMode, networkAllowed: Bool) -> String {
        BashSandboxCopy.approvalSummary(sandboxMode: sandboxMode, networkAllowed: networkAllowed)
    }

    /// Canonical triage badge for bash requests, single-sourced on the copy owner.
    public static func bashSandboxBadge(
        toolName: String,
        sandboxMode: BashSandboxMode,
        networkAllowed: Bool
    ) -> String? {
        guard toolName == "bash.exec" else { return nil }
        return bashSandboxSummary(sandboxMode: sandboxMode, networkAllowed: networkAllowed)
    }

    /// Approval-card plus dashboard summary for one filed bash request.
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
    private static func bashCommand(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dict["command"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads the network request flag from bash arguments. Missing or malformed flags fail closed
    /// to false so the summary never advertises internet access the policy did not grant.
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
