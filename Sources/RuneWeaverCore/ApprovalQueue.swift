// Rune Weaver Core — Headless and interactive tool approval queue.
//
// Manages pending tool execution approval requests when running in headless
// mode (e.g. background scheduler jobs) or across disconnected clients.
// Suspends tool execution until an explicit decision (approve/reject with
// optional graduated-trust tier) is submitted via REST, WebSocket, or CLI.

import Foundation

/// Decision resolving one headless approval request.
public struct ApprovalQueueDecision: Sendable, Equatable {
    /// Whether the tool call may run.
    public let approved: Bool
    /// Graduated-trust tier recorded on approval, if any.
    public let duration: TrustDuration?
    /// Whether the denial came from a wait timeout rather than an explicit decision.
    ///
    /// Surfaces the timeout reason to callers: service waits deny the
    /// in-flight call with `timedOut == true` while retaining the inbox
    /// entry for an explicit later decision (aligned with headless retention).
    public let timedOut: Bool

    /// Creates a decision.
    /// - Parameters:
    ///   - approved: Whether the call may run.
    ///   - duration: Trust tier recorded on approval. Defaults to nil.
    ///   - timedOut: Whether the denial came from a timeout. Defaults to false.
    public init(approved: Bool, duration: TrustDuration? = nil, timedOut: Bool = false) {
        self.approved = approved
        self.duration = duration
        self.timedOut = timedOut
    }
}

/// Pending approvals filed by headless scheduler turns.
///
/// The foreground scheduler runs without an interactive prompter:
/// `readOnly` and `trusted` tools execute directly through the
/// `ToolBus`, while `requiresApproval` tools file a
/// ``PermissionRequest`` here via ``ApprovalQueue/headlessApprovalHandler()``
/// and deny the in-flight call so the turn completes with a denial note
/// instead of blocking. The user later approves or denies from the
/// engine API approvals inbox (`GET /approvals`,
/// `POST /approvals/:id/decide`) or the dashboard, optionally recording
/// graduated trust so repeats run without prompting. Interactive chat
/// keeps its own inline prompter; this queue is the headless counterpart
/// with identical graduated-trust semantics.
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
    ///
    /// A timed-out wait denies the in-flight call yet keeps the pending
    /// request visible (aligned with headless retention) so a late explicit
    /// `decide` still resolves the inbox instead of `404`. Entries are
    /// cleared on `decide` or `clear`.
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
    /// - Parameters:
    ///   - toolName: Name of the tool requesting approval.
    ///   - description: Human-readable summary.
    ///   - input: Original invocation arguments.
    /// - Returns: The tracked request.
    @discardableResult
    public func enqueue(toolName: String, description: String, input: ToolInput) -> PermissionRequest {
        let request = PermissionRequest(toolName: toolName, description: description, input: input)
        pending[request.id] = request
        return request
    }

    /// Files a gated tool call into the queue.
    ///
    /// Single shared filing path for every approval handler: the headless
    /// scheduler handler and the service broadcast handler both file through
    /// here so field extraction (tool name, description, input) cannot drift.
    /// Service callers decorate the returned request (broadcast, timed wait);
    /// headless callers deny the in-flight call immediately. Narrated parked
    /// turns file through here with their owning session so the later
    /// decision can resume the same conversation.
    /// - Parameters:
    ///   - tool: Tool requesting approval.
    ///   - call: Original invocation arguments.
    ///   - sessionID: Owning session for parked narration. Defaults to nil (untagged).
    /// - Returns: The tracked request.
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
    ///
    /// Lets the approvals inbox and the narrated resume path scope prompts
    /// to their owning conversation without scanning every pending entry
    /// at the call site.
    /// - Parameter sessionID: Owning session to filter by.
    /// - Returns: Pending requests tagged with `sessionID`.
    public func requests(for sessionID: UUID) -> [PermissionRequest] {
        pending.values.filter { $0.sessionID == sessionID }
    }

    /// Discards a parked early decision without suspending.
    ///
    /// Narrated parked turns never wait, so a decision that arrives after
    /// filing parks an early entry nobody will consume. The resume path
    /// drains it here so one parked approval cannot leak an entry that a
    /// later unrelated wait would mistake for a live decision.
    /// - Parameter id: Request identifier whose early decision is dropped.
    /// - Returns: The discarded decision, or nil when none was parked.
    @discardableResult
    public func takeEarlyDecision(id: UUID) -> ApprovalQueueDecision? {
        earlyDecisions.removeValue(forKey: id)
    }

    /// Lists pending requests in no guaranteed order.
    ///
    /// Backed by a dictionary, so insertion order is not preserved.
    /// - Returns: Pending requests.
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
    ///
    /// Approved decisions with a duration other than `thisTime` record
    /// graduated trust for the call's descriptor so repeats run without
    /// prompting; `thisTime` approvals and denials record nothing. The
    /// waiter suspended in `waitForDecision(id:)` resumes with the
    /// decision, or the decision is parked for the next waiter when none
    /// is suspended yet. A late decision after a wait timeout still
    /// resolves the retained inbox entry (no `404`); the timed-out waiter
    /// already resumed denied with `timedOut == true`, so no stale parked
    /// decision is left behind.
    /// - Parameters:
    ///   - id: Request identifier.
    ///   - approved: Whether the call may run.
    ///   - duration: Trust tier recorded on approval. Defaults to
    ///     `thisTime` (one-shot).
    /// - Returns: True when a pending request was resolved.
    @discardableResult
    public func decide(id: UUID, approved: Bool, duration: TrustDuration = .thisTime) async -> Bool {
        guard let request = pending.removeValue(forKey: id) else {
            return false
        }
        let wasTimedOut = timedOutIDs.remove(id) != nil
        let decision = ApprovalQueueDecision(approved: approved, duration: duration)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: decision)
        } else if !wasTimedOut {
            earlyDecisions[id] = decision
        }
        if approved, duration != .thisTime {
            let descriptor = ActionDescriptor(
                toolName: request.toolName,
                target: ActionDescriptor.target(from: request.input)
            )
            await permissionGate?.grantTrust(for: descriptor, duration: duration)
        }
        return true
    }

    /// Default seconds a service approval handler waits before denying.
    ///
    /// Caps how long an HTTP or WebSocket worker suspends on a forgotten
    /// approval so one undecided prompt cannot hang the worker forever.
    public static var defaultDecisionTimeoutSeconds: Double {
        300
    }

    /// Waits for the decision resolving one request.
    ///
    /// When `decide(id:approved:duration:)` already ran for `id`, the
    /// parked decision returns immediately; otherwise the caller suspends
    /// until a decision arrives. Unknown identifiers deny immediately so
    /// tool execution never suspends forever. Task cancellation resumes
    /// denied promptly and removes the waiter so workers never stay
    /// suspended across close or shutdown.
    /// - Parameter id: Request identifier to wait for.
    /// - Returns: The approval decision.
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
    ///
    /// Service entry points (REST, WebSocket) suspend on this variant so
    /// a forgotten approval denies instead of hanging the worker forever
    /// (DoS protection). A timeout denies the in-flight call with
    /// `timedOut == true` but retains the pending inbox entry (aligned with
    /// headless retention) so the dashboard still shows it and a late
    /// `decide(id:approved:duration:)` still resolves instead of `404`.
    /// Task cancellation resumes denied promptly and removes the waiter
    /// plus its timeout sleeper so workers never stay suspended across
    /// close or shutdown.
    /// - Parameters:
    ///   - id: Request identifier to wait for.
    ///   - timeoutSeconds: Seconds to wait before denying. Non-positive
    ///     waits indefinitely like `waitForDecision(id:)`.
    /// - Returns: The approval decision, or a `timedOut` denial when the timeout elapses.
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
    ///
    /// Retains the pending request so the inbox entry stays visible and a
    /// late decision can still resolve it (aligned with the headless
    /// handler, which retains pending indefinitely). Records the timeout so
    /// the late `decide` does not park a stale early decision. No-op when
    /// the waiter already resolved.
    /// - Parameter id: Request identifier that timed out.
    private func timeoutWaiter(id: UUID) async {
        timeoutTasks.removeValue(forKey: id)
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        guard pending[id] != nil else { return }
        timedOutIDs.insert(id)
        waiter.resume(returning: ApprovalQueueDecision(approved: false, duration: nil, timedOut: true))
    }

    /// Denies one waiter when its waiting task is cancelled.
    ///
    /// Removes the pending request plus the waiter and its timeout
    /// sleeper so a later `decide(id:approved:duration:)` reports false
    /// and no continuation leaks. No-op when the waiter already resolved.
    /// - Parameter id: Request identifier whose waiter was cancelled.
    private func cancelWaiter(id: UUID) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        timedOutIDs.remove(id)
        pending.removeValue(forKey: id)
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: ApprovalQueueDecision(approved: false, duration: nil))
    }

    /// Removes every pending request and parks denials for waiters.
    ///
    /// Waiters suspended in `waitForDecision(id:)` resume denied so tool
    /// execution never suspends across a reset. Parked early decisions are
    /// discarded as well, so a later `waitForDecision(id:)` for a cleared
    /// id denies like an unknown id instead of returning stale approval.
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
    ///
    /// Returns a `ToolApprovalHandler` that files every gated call into
    /// this queue and denies the in-flight execution so the headless
    /// turn completes instead of blocking on user input. `readOnly` and
    /// `trusted` tools never reach this handler (the `ToolBus` runs them
    /// directly), preserving read-by-default semantics; only
    /// `requiresApproval` tools file here. The pending request stays
    /// visible through the engine API approvals inbox until decided, the
    /// same retention a timed-out service wait provides, so both paths
    /// share one inbox lifecycle with `timedOut` distinguishing the
    /// in-flight denial reason.
    /// Filing goes through ``fileRequest(tool:call:)`` so the service
    /// broadcast handler decorates the same path instead of duplicating it.
    /// - Returns: Handler filing gated calls and denying them headless.
    public func headlessApprovalHandler() -> ToolApprovalHandler {
        { [queue = self] tool, call in
            await queue.fileRequest(tool: tool, call: call)
            return false
        }
    }
}
