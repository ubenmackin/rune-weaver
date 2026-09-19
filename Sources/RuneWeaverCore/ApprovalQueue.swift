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
    /// Graduated-trust gate receiving approved durations.
    private let permissionGate: PermissionGate?

    /// Creates an approval queue.
    /// - Parameter permissionGate: Gate receiving approved trust grants.
    ///   Defaults to nil (decisions resolve waiters only).
    public init(permissionGate: PermissionGate? = nil) {
        self.permissionGate = permissionGate
    }

    /// Enqueues a prebuilt request, replacing any same-id entry.
    /// - Parameter request: Request to track.
    public func enqueue(_ request: PermissionRequest) {
        pending[request.id] = request
    }

    /// Builds and enqueues a request for a tool call.
    @discardableResult
    public func enqueue(toolName: String, description: String, input: ToolInput) -> PermissionRequest {
        let request = PermissionRequest(toolName: toolName, description: description, input: input)
        pending[request.id] = request
        return request
    }

    /// Files a gated tool call into the queue.
    @discardableResult
    public func fileRequest(tool: any Tool, call: ToolInput, sessionID: UUID? = nil) -> PermissionRequest {
        let request = PermissionRequest(
            toolName: tool.name,
            description: tool.description,
            input: call,
            sessionID: sessionID
        )
        enqueue(request)
        return request
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
    public func clear() {
        for (_, task) in timeoutTasks {
            task.cancel()
        }
        timeoutTasks.removeAll()
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
