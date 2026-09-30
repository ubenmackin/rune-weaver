// Rune Weaver Core — Parallel worker fan-out engine.
//
// Runs explicit subtasks as bounded concurrent worker turns through the
// orchestrator. The engine is multi-agent by design: subtasks execute in
// parallel under a configured worker cap, each worker owns a fresh session
// so histories never interleave, and every worker turn is recorded in the run
// audit trail so the swarm stays auditable. Subtask prompts are composed by
// the CALLING agent — the engine never decomposes a task, it only executes
// the explicit list it is handed. Workers default to the read-only tool
// subset the caller chose; the subset is only widened to the full registry
// when the fanout policy explicitly allows it, so research fan-out cannot
// mutate state.
//
// Merge pass: after every subtask settles, a deterministic overlap check runs
// FIRST — exact file-path/URL collisions across the collected worker outputs
// are flagged conflict without spending a model round — then ONE background
// reviewer LLM call over those collected outputs produces a merged summary
// plus per-subtask verdicts. The reviewer judges content quality, never
// permissions or policy. The pass fails open by contract: a reviewer error
// or timeout degrades the summary to the raw concatenation with an honest
// note, so worker output is never lost because review was flaky.
//
// Cancellation: the engine owns an active-run registry so an owner can stop a
// swarm mid-flight through `cancel(rowID:)` — keyed by run-log row, the same
// vocabulary the Runs tab speaks. The parent row stops every worker; a child
// row stops exactly one worker and leaves its siblings running. A subtask the
// owner marked cancelled settles `cancelled` with an honest note whatever the
// worker reports, and an owner stop outranks a worker failure in the digest: a
// cancelled swarm must read as a deliberate stop, never as `error`. A cancel
// racing startup still lands because the run registers before its worker group
// starts and late workers settle cancelled without being awaited. Whole-call
// cancellation (the chat per-tool stop) reaches the same settle path, so
// stopped workers produce cancelled statuses instead of failures. The registry
// deregisters with the swarm, so a settled run never accepts a late cancel.
//
// Concurrency invariant: the orchestrator is an actor whose turns interleave
// at await points without corrupting per-call state, each worker owns its own
// session, and the shared stores (conversations, tool bus, run logs) are
// actors already — so workers run CONCURRENTLY via a task group. A positive
// wall-clock timeout bounds a worker that never observes cancellation: each
// turn races the configured budget and the first side of the race settles the
// worker while the losing task is abandoned. A zero timeout means no race at
// all — the worker awaits under the cancellation handler, so an unlimited
// worker can hold the parent run open until it finishes or is cancelled,
// intentional for slow local models and bounded by cancellation. The parent
// run never stays running past the last subtask settle; all-done reads
// completed and any failure reads failed so the digest stays honest.

import Foundation
import os

/// Collected output of one worker turn: the final assistant text plus whether
/// the turn parked waiting on approval. The text feeds the deterministic
/// overlap check and the background reviewer; the parked flag settles the
/// run-log row into the same `awaiting_approval` vocabulary chat and scheduler
/// turns use, so a worker awaiting a decision reads honestly beside them.
public struct FanOutWorkerOutput: Sendable, Equatable {
    /// Final assistant text the worker turn produced. Empty when the turn
    /// failed or timed out before any output landed.
    public let text: String
    /// Whether the turn parked awaiting an approval decision.
    public let isParked: Bool

    /// The empty output: the settled shape for a worker that produced nothing.
    public static let empty = FanOutWorkerOutput(text: "", isParked: false)

    /// Creates one collected output.
    /// - Parameters:
    ///   - text: Final assistant text.
    ///   - isParked: Whether the turn parked awaiting approval.
    public init(text: String, isParked: Bool) {
        self.text = text
        self.isParked = isParked
    }
}

/// Narrow orchestrator seam the fan-out engine drives so workers run through
/// the real orchestrator without the engine (or a test) needing the full LLM
/// stack. The production witness is the live orchestrator instance the server
/// context already constructed — the same instance is injected, never
/// self-built — while a stub keeps the engine testable without the stack.
public protocol OrchestratorFanOutSeam: Sendable {
    /// Runs one worker turn to completion. Throwing marks the worker failed;
    /// the response text itself is owned by the worker's own session, so the
    /// seam discards it and the run row carries only the settled outcome.
    func process(_ input: UserInput) async throws

    /// Runs one worker turn and collects its final assistant text and parked
    /// flag so the merge pass reviews real worker output. Throwing marks the
    /// worker failed the same way the plain seam does.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput
}

public extension OrchestratorFanOutSeam {
    /// Default collecting witness falls back to the plain seam: run the turn
    /// and report no output text. Witness types that predate the merge pass
    /// keep compiling unchanged, and the merge pass fails open to its honest
    /// fallback when nothing was collected.
    func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        try await process(input)
        return .empty
    }
}

/// Bridges the live orchestrator onto the fan-out seam. The forwarding
/// witness keeps the engine's seam shape (unlabeled `process`) while the
/// orchestrator's own labeled turn loop stays untouched; the collecting
/// witness returns the real response text and parked flag so the merge pass
/// reviews what workers actually produced.
extension Orchestrator: OrchestratorFanOutSeam {
    public func process(_ input: UserInput) async throws {
        _ = try await process(input: input)
    }

    public func processCollecting(_ input: UserInput) async throws -> FanOutWorkerOutput {
        let response = try await process(input: input)
        return FanOutWorkerOutput(text: response.text, isParked: response.isParked)
    }
}

/// Run-audit seam so the engine records its rows through the shared run-log
/// store without linking the server transport (or its entry types) into the
/// core module. Implementations never throw, so a store failure degrades to
/// a missing audit row instead of failing the swarm.
public protocol FanOutRunLogging: Sendable {
    /// Appends one run-log row and returns its identifier so a later settle
    /// can update the same row in place.
    /// - Parameters:
    ///   - kind: Row kind (`fanout` parent, `fanout_worker` children).
    ///   - status: Row status (`running` until the settle path flips it).
    ///   - message: Content-free display message.
    ///   - sessionID: Session the row belongs to.
    /// - Returns: The appended row's identifier.
    @discardableResult
    func appendFanOutRow(kind: String, status: String, message: String, sessionID: UUID) async -> UUID

    /// Updates one run-log row's status in place so live views flip the badge.
    /// - Parameters:
    ///   - id: Row identifier returned by ``appendFanOutRow(kind:status:message:sessionID:)``.
    ///   - status: Terminal row status.
    func updateFanOutRow(id: UUID, status: String) async

    /// Updates one run-log row's settled outcome in place so a worker's raw
    /// output and duration stay in the child rows (fully auditable) and the
    /// parent row renders the merged summary. The status-only variant above
    /// stays for callers that only flip a badge.
    /// - Parameters:
    ///   - id: Row identifier returned by ``appendFanOutRow(kind:status:message:sessionID:)``.
    ///   - status: Terminal row status.
    ///   - response: Raw output the settled row keeps, or nil to keep the
    ///     stored response untouched.
    ///   - durationMs: Wall-clock duration in milliseconds, or nil to keep
    ///     the stored duration.
    func updateFanOutRow(id: UUID, status: String, response: String?, durationMs: Int?) async
}

public extension FanOutRunLogging {
    /// Default settle witness degrades to the status-only flip so witnesses
    /// that predate the response-carrying settle keep compiling unchanged;
    /// stores that audit outputs implement the requirement directly.
    func updateFanOutRow(id: UUID, status: String, response _: String?, durationMs _: Int?) async {
        await updateFanOutRow(id: id, status: status)
    }
}

/// Resumes a checked continuation exactly once across the worker race.
///
/// The orchestrator call and the timeout both try to resume; the first wins
/// and every later attempt is dropped, so a worker settles on wall-clock time
/// without awaiting a turn that never observes cancellation. The abandoned
/// turn task is the deliberate cost of that bound.
private final class WorkerResumption: Sendable {
    /// Continuation captured at the start of the race, cleared on first resume.
    private let state: OSAllocatedUnfairLock<CheckedContinuation<WorkerOutcome, Never>?>

    /// Creates a resumption owning the awaiting continuation.
    /// - Parameter continuation: Continuation to resume once.
    init(continuation: CheckedContinuation<WorkerOutcome, Never>) {
        self.state = OSAllocatedUnfairLock<CheckedContinuation<WorkerOutcome, Never>?>(initialState: continuation)
    }

    /// Resumes the awaiting caller once; later calls are no-ops.
    /// - Parameter outcome: Settled worker outcome, or the timeout's failure.
    func resume(_ outcome: WorkerOutcome) {
        let pending = state.withLock { state -> CheckedContinuation<WorkerOutcome, Never>? in
            let continuation = state
            state = nil
            return continuation
        }
        pending?.resume(returning: outcome)
    }
}

/// One worker's settled outcome before it lands on the run.
private struct WorkerOutcome: Sendable {
    /// Whether the worker turn finished without error.
    let succeeded: Bool
    /// Whether the turn ended because its task was cancelled rather than
    /// failing on its own; the settle path keeps an owner stop out of the
    /// failure vocabulary.
    let cancelled: Bool
    /// Honest failure note, nil on success.
    let note: String?
    /// Collected output text and parked flag; empty when the turn failed or
    /// timed out before anything landed.
    let output: FanOutWorkerOutput
    /// Wall-clock duration of the turn in milliseconds, measured at outcome
    /// creation so the audit row keeps an honest duration even when the
    /// timeout side settled the race.
    let durationMs: Int

    /// The settle shape for a worker stopped before its turn produced
    /// anything: a cancel racing startup reports the same honest stop as one
    /// that lands mid-turn.
    static let cancelledBeforeStart = WorkerOutcome(
        succeeded: false,
        cancelled: true,
        note: nil,
        output: .empty,
        durationMs: 0
    )
}

/// One worker's settle payload from the task group: identity, outcome, and
/// the collected output, bundled so the group element stays a named struct
/// instead of a wide positional tuple.
private struct WorkerSettle: Sendable {
    /// Subtask the worker ran.
    let subtaskID: UUID
    /// Whether the worker turn finished without error.
    let succeeded: Bool
    /// Whether the turn ended as a cancellation rather than a failure; the
    /// settle path pairs this with whole-call cancellation to decide whether
    /// the stop reads cancelled.
    let cancelled: Bool
    /// Honest failure note, nil on success.
    let note: String?
    /// Collected output text and parked flag.
    let output: FanOutWorkerOutput
    /// Wall-clock duration of the turn in milliseconds.
    let durationMs: Int

    /// Builds the settle payload from a settled outcome.
    /// - Parameters:
    ///   - subtaskID: Subtask the worker ran.
    ///   - outcome: Settled worker outcome.
    init(subtaskID: UUID, outcome: WorkerOutcome) {
        self.subtaskID = subtaskID
        self.succeeded = outcome.succeeded
        self.cancelled = outcome.cancelled
        self.note = outcome.note
        self.output = outcome.output
        self.durationMs = outcome.durationMs
    }
}

/// Worker inputs with fresh sessions and the audit row identifiers parallel to them.
private struct RecordedSwarmRows: Sendable {
    /// Worker inputs with fresh sessions parallel to the subtask order.
    let inputs: [UserInput]
    /// Identifier of the parent swarm audit row.
    let parentRowID: UUID
    /// Identifiers of child worker audit rows parallel to the subtask order.
    let childRowIDs: [UUID]
}

/// One worker task's cancellation surface inside a live run.
private struct ActiveFanOutWorker: Sendable {
    /// Child audit row the settle path flips to the terminal status.
    let childRowID: UUID
    /// Stops the worker's turn. `Task.cancel()` is idempotent and safe from
    /// any thread, so the registry invokes it while the worker runs.
    let cancel: @Sendable () -> Void
}

/// One in-flight run's cancellation surface.
///
/// Registered as soon as the parent audit row exists and removed only when the
/// swarm and merge pass settle, so the window where a cancel can be lost is
/// none: a cancel before the workers start marks their subtasks and each late
/// worker settles cancelled without being awaited, and a cancel after the run
/// settles finds no entry at all.
private struct ActiveFanOutRun: Sendable {
    /// Parent audit row that identifies the run to the owner.
    let parentRowID: UUID
    /// Every subtask id in run order; a parent cancel marks the not-yet-settled
    /// ones whether or not their worker task exists yet.
    let subtaskIDs: [UUID]
    /// In-flight worker handles keyed by subtask id; entries leave as each
    /// worker settles so an already-settled row reports not running.
    var workers: [UUID: ActiveFanOutWorker]
    /// Subtask id for every child row appended so far, so a child-row cancel
    /// reaches its subtask even before the worker task exists.
    var subtaskByChildRow: [UUID: UUID]
    /// Subtasks already marked cancelled; the settle path settles these
    /// `cancelled` whatever the worker reports.
    var cancelledSubtaskIDs: Set<UUID>
    /// Subtasks whose settle already applied, so a late cancel cannot rewrite
    /// a terminal outcome.
    var settledSubtaskIDs: Set<UUID>
}

/// Resumes a checked continuation exactly once across the background review
/// race. The provider call and the timeout both try to resume; the first wins
/// and every later attempt is dropped, so the merge pass returns on
/// wall-clock time without awaiting a provider stream that never observes
/// cancellation. Mirrors the worker race's resumption so the two bounded
/// races read identically.
private final class MergeReviewResumption: Sendable {
    /// Continuation captured at the start of the race, cleared on first resume.
    private let state: OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>

    /// Creates a resumption owning the awaiting continuation.
    /// - Parameter continuation: Continuation to resume once.
    init(continuation: CheckedContinuation<String?, Never>) {
        self.state = OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>(initialState: continuation)
    }

    /// Resumes the awaiting caller once; later calls are no-ops.
    /// - Parameter value: Review text, or nil when the timeout won.
    func resume(_ value: String?) {
        let pending = state.withLock { state -> CheckedContinuation<String?, Never>? in
            let continuation = state
            state = nil
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// One subtask's merge verdict, emitted by the background reviewer or forced
/// deterministically by the overlap check.
enum FanOutVerdict: String, CaseIterable, Sendable, Equatable {
    /// Output stands as produced.
    case keep
    /// Output was superseded and is folded out of the merged summary.
    case drop
    /// Output collides with another subtask's (identical file path or URL),
    /// so the owner should reconcile the targets.
    case conflict
}

/// One parsed verdict before it lands on the merged summary.
struct ParsedVerdict: Sendable, Equatable {
    /// Subtask title the verdict applies to, matched verbatim against the
    /// run's own titles.
    let title: String
    /// Verdict emitted by the reviewer.
    let verdict: FanOutVerdict
}

/// One parsed background review before the merged summary composes it.
struct ParsedMergeReview: Sendable, Equatable {
    /// Reviewer's merged summary of the collected outputs.
    let summary: String
    /// Per-subtask verdicts, in the reviewer's order.
    let verdicts: [ParsedVerdict]
}

/// The merge-review outcome the settle path composes the summary from.
/// The three-way split is the fail-open contract: a parsed review wins, a
/// wired reviewer that flaked degrades to the raw concatenation with an
/// honest note, and an unwired reviewer keeps the pre-existing outcome digest
/// shape so callers without review wiring see no summary change.
enum MergeReview: Sendable {
    /// Reviewer output parsed and usable.
    case parsed(ParsedMergeReview)
    /// A wired reviewer errored or timed out; worker output is never lost.
    case unavailable
    /// No reviewer is wired into the engine.
    case unwired
}

/// Runs explicit subtasks as bounded concurrent worker turns.
public actor FanOutEngine {
    /// Run-log kind for the parent row, so the Runs tab renders the swarm's
    /// parent record.
    public static let parentRowKind = "fanout"
    /// Run-log kind for the child worker rows, so each worker turn renders
    /// under its parent's swarm.
    public static let workerRowKind = "fanout_worker"
    /// Input origin stamped on every worker turn so the audit trail can
    /// distinguish worker turns from chat, scheduler, and CLI turns.
    public static let workerSource = "fanout_worker"

    /// Orchestrator seam injected from the live context; never self-built so
    /// workers observe the same model, routing, and tool posture as chat.
    private let orchestrator: any OrchestratorFanOutSeam
    /// Run-audit seam injected from the shared run-log store.
    private let runLogs: any FanOutRunLogging
    /// Fanout policy backing the worker cap, timeout, and tool-subset reads.
    /// Mutable so a settings save can push fresh values live without
    /// rebuilding the engine; every write goes through `clamped()` so a
    /// persisted-but-unvalidated hand-built config still degrades to the
    /// nearest sane bound instead of oversubscribing the serving model.
    private var config: FanOutConfig
    /// Background reviewer over the collected worker outputs, injected from
    /// the same serving instance the Muse uses so review quality tracks the
    /// active model posture; nil keeps the merge pass on its deterministic
    /// and fail-open fallbacks instead of spending a review call.
    private let reviewer: (any LLMProvider)?

    /// In-flight runs keyed by parent audit-row id, the cancellation surface
    /// the owner drives through ``cancel(rowID:)``. A run registers before its
    /// worker group starts and deregisters once the group and merge pass
    /// settle, so a settled run can never accept a late cancel.
    private var activeRuns: [UUID: ActiveFanOutRun] = [:]

    /// Creates a fan-out engine over shared collaborators.
    /// - Parameters:
    ///   - orchestrator: Seam running each worker turn; the same instance the
    ///     calling context serves chat turns through.
    ///   - runLogs: Shared run-log store recording the audit rows.
    ///   - config: Fanout policy.
    ///   - reviewer: Optional background reviewer over collected outputs.
    public init(
        orchestrator: any OrchestratorFanOutSeam,
        runLogs: any FanOutRunLogging,
        config: FanOutConfig,
        reviewer: (any LLMProvider)? = nil
    ) {
        self.orchestrator = orchestrator
        self.runLogs = runLogs
        self.config = config.clamped()
        self.reviewer = reviewer
    }

    /// Whether the fanout policy widens workers to the full tool registry.
    /// The fanout.run tool consults this per call so a settings change takes
    /// effect without re-registering, mirroring the per-turn config reads.
    public var fullTools: Bool {
        config.fullTools
    }

    /// Current fanout policy backing live workers.
    /// Exposes the clamped snapshot so settings callers can observe a saved
    /// patch without re-running a swarm; the engine remains the sole writer
    /// through `updateConfig`.
    public var currentConfig: FanOutConfig {
        config
    }

    /// Pushes a freshly persisted `[fanout]` policy into the live engine so a
    /// settings save takes effect without a restart.
    /// Clamps defensively so a hand-built config degrades to the nearest sane
    /// bound; the settings route validates before persisting, so a clamped
    /// live value never masks a 400 on the durable file.
    /// - Parameter newConfig: Persisted fanout policy from the settings save.
    public func updateConfig(_ newConfig: FanOutConfig) {
        config = newConfig.clamped()
    }

    /// Derives the read-only tool names from a tool snapshot so the calling
    /// agent passes one deterministic subset without hand-listing names.
    /// Only `readOnly` tools travel — trusted tiers can still mutate state,
    /// so research fan-out must not carry them — and the names sort so the
    /// subset stays deterministic regardless of registry iteration order.
    /// - Parameter tools: Registry snapshot (already enabled tools).
    /// - Returns: Sorted read-only tool names.
    public static func readOnlyToolNames(in tools: [any Tool]) -> [String] {
        tools.filter { $0.permissionLevel == .readOnly }.map(\.name).sorted()
    }

    /// Runs the explicit subtasks as concurrent worker turns.
    ///
    /// Over-cap lists are rejected before any worker turn spends a model
    /// round. Each subtask becomes one orchestrator turn
    /// on a fresh session; the run audit trail records the parent row
    /// (content-free joined titles) plus one child row per worker so the
    /// Runs tab renders the swarm and the audit trail is complete. The parent
    /// run completes when all subtasks settle and never stays running past
    /// the last settle, so a timed-out worker cannot hold the caller hostage.
    /// An unlimited worker (zero timeout) can hold the parent run open until
    /// it finishes or is cancelled, intentional for slow local models. The
    /// run is cancellable from the moment its parent row exists through
    /// ``cancel(rowID:)``, and it deregisters before returning, so a settled
    /// run ignores a late cancel.
    /// - Parameters:
    ///   - subtasks: Explicit subtask list; prompts are the caller's, never
    ///     decomposed here.
    ///   - originSessionID: Session that spawned the run.
    ///   - allowedTools: Explicit tool names workers may call, or nil for the
    ///     full registry. The fanout.run tool passes the read-only names
    ///     unless its policy widens to the full registry, so research
    ///     fan-out cannot mutate.
    /// - Returns: The settled run with per-subtask statuses and an honest
    ///   outcome digest.
    /// - Throws: ``FanOutError`` when the list is empty,
    ///   or the list exceeds the configured worker cap.
    @discardableResult
    public func runFanOut(
        subtasks: [FanOutSubtask],
        originSessionID: UUID,
        allowedTools: [String]? = nil
    ) async throws -> FanOutRun {
        // Gate before any worker turn so an over-cap list cannot spend model
        // rounds; the typed errors are the caller's only honest signal.
        guard !subtasks.isEmpty else { throw FanOutError.emptySubtasks }
        let maxWorkers = config.maxWorkers
        guard subtasks.count <= maxWorkers else {
            throw FanOutError.maxWorkersReached(limit: maxWorkers)
        }

        let runID = UUID()
        let startedAt = Date()
        // Every worker starts with the group (the cap is the count), so the
        // in-flight snapshot marks each subtask running up front and the
        // settle path flips each badge in place by id.
        let running = subtasks.map { subtask -> FanOutSubtask in
            var started = subtask
            started.status = .running
            return started
        }
        var run = FanOutRun(
            id: runID,
            parentSessionID: originSessionID,
            subtasks: running,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        // Parent plus child audit rows land before the first turn so the
        // Runs tab renders the swarm while workers are in flight; the parent
        // append also registers the run's cancel surface, so a cancel racing
        // startup is never lost.
        let swarmRows = await recordSwarmRows(
            subtasks: subtasks,
            originSessionID: originSessionID,
            allowedTools: allowedTools
        )
        let workerInputs = swarmRows.inputs
        let parentRowID = swarmRows.parentRowID
        let childRowIDs = swarmRows.childRowIDs
        // The cancel surface must never outlive the swarm: every exit path —
        // including a cancelled caller — deregisters here, so a settled run
        // rejects a late cancel.
        defer { activeRuns[parentRowID] = nil }

        // Workers run concurrently under the group so a slow worker never
        // delays its siblings. Each child races the bounded wall-clock
        // timeout; settled outcomes are applied on the actor between group
        // iterations so the run status, the subtask badge, and the audit row
        // flip as each worker settles rather than only at the end. Outputs
        // collect per worker so the merge pass reviews real worker text.
        let orchestrator = self.orchestrator
        let timeoutSeconds = config.workerTimeoutSeconds
        var notes: [UUID: String] = [:]
        var outputs: [UUID: FanOutWorkerOutput] = [:]
        await withTaskGroup(of: WorkerSettle.self) { group in
            for index in subtasks.indices {
                let subtaskID = subtasks[index].id
                let input = workerInputs[index]
                // The turn is created up front so its handle exists to cancel.
                // Registration runs before the pre-cancel check, so a cancel
                // that landed while the worker was still starting is honored:
                // the subtask is already marked and the task is cancelled now,
                // settling cancelled without ever being awaited.
                let worker = Self.makeWorkerTask(input: input, orchestrator: orchestrator)
                registerWorkerHandle(
                    parentRowID: parentRowID,
                    subtaskID: subtaskID,
                    childRowID: childRowIDs[index],
                    cancel: { worker.cancel() }
                )
                if isSubtaskCancelled(parentRowID: parentRowID, subtaskID: subtaskID) {
                    worker.cancel()
                    group.addTask {
                        WorkerSettle(subtaskID: subtaskID, outcome: .cancelledBeforeStart)
                    }
                } else {
                    group.addTask {
                        let outcome = await FanOutEngine.runWorker(worker, timeoutSeconds: timeoutSeconds)
                        return WorkerSettle(subtaskID: subtaskID, outcome: outcome)
                    }
                }
            }
            for await settle in group {
                let index = run.subtasks.firstIndex(where: { $0.id == settle.subtaskID })
                let childRowID = index.flatMap { $0 < childRowIDs.count ? childRowIDs[$0] : nil }
                await applyWorkerSettle(
                    settle,
                    run: &run,
                    notes: &notes,
                    outputs: &outputs,
                    parentRowID: parentRowID,
                    childRowID: childRowID
                )
            }
        }

        // The merge pass settles the parent: deterministic overlap detection
        // first, then one background reviewer call, then the merged summary
        // and the run-log row flip. The parent never stays running past the
        // last settle, so a flaky reviewer cannot hold the caller hostage.
        await settleParent(
            run: &run,
            outputs: outputs,
            notes: notes,
            parentRowID: parentRowID,
            startedAt: startedAt
        )
        return run
    }

    /// Applies one settled worker's outcome to the in-flight run and audit row.
    ///
    /// The owner cancellation check outranks worker success and failure: an
    /// aborted turn can surface as a rushed success, and an owner stop is
    /// never a failure. Whole-call cancellation is the second signal: the
    /// parent task is cancelled and a cooperative worker observed the stop
    /// as a cancellation, so the swarm reads cancelled rather than failed
    /// exactly where the old path reported failures.
    /// - Parameters:
    ///   - settle: Settle payload from the worker task.
    ///   - run: In-flight run being updated.
    ///   - notes: Failure or cancellation notes keyed by subtask identifier.
    ///   - outputs: Collected worker outputs keyed by subtask identifier.
    ///   - parentRowID: Run registry key.
    ///   - childRowID: Child audit row identifier, if one exists for the subtask.
    private func applyWorkerSettle(
        _ settle: WorkerSettle,
        run: inout FanOutRun,
        notes: inout [UUID: String],
        outputs: inout [UUID: FanOutWorkerOutput],
        parentRowID: UUID,
        childRowID: UUID?
    ) async {
        guard let index = run.subtasks.firstIndex(where: { $0.id == settle.subtaskID }) else { return }
        let markedCancelled = isSubtaskCancelled(parentRowID: parentRowID, subtaskID: settle.subtaskID)
        let stoppedByOwner = markedCancelled || (settle.cancelled && Task.isCancelled)
        markWorkerSettled(parentRowID: parentRowID, subtaskID: settle.subtaskID)
        if stoppedByOwner {
            run.subtasks[index].status = .cancelled
            run.updatedAt = Date()
            notes[settle.subtaskID] = Self.ownerCancellationNote
            outputs[settle.subtaskID] = .empty
            if let childRowID {
                await runLogs.updateFanOutRow(
                    id: childRowID,
                    status: Self.cancelledRowStatus,
                    response: nil,
                    durationMs: settle.durationMs
                )
            }
            return
        }
        run.subtasks[index].status = settle.succeeded ? .done : .failed
        run.updatedAt = Date()
        if !settle.succeeded {
            // The note travels into the run digest so a timeout reads
            // honestly instead of a bare failure with no cause.
            notes[settle.subtaskID] = settle.note ?? "failed"
        }
        outputs[settle.subtaskID] = settle.output
        if let childRowID {
            // A parked worker persists as awaiting_approval like chat
            // and scheduler turns, resolving through the same inbox
            // resume path in its own session; the raw output and
            // duration ride the row so the audit trail stays complete.
            let rowStatus = if settle.succeeded {
                settle.output.isParked ? "awaiting_approval" : "ok"
            } else {
                "failed"
            }
            await runLogs.updateFanOutRow(
                id: childRowID,
                status: rowStatus,
                response: settle.output.text.isEmpty ? nil : settle.output.text,
                durationMs: settle.durationMs
            )
        }
    }

    // MARK: - Merge pass

    /// Settles the parent run after every subtask settles.
    ///
    /// Deterministic overlap detection runs FIRST so exact file-path/URL
    /// collisions across the collected outputs are flagged conflict without
    /// spending a model round — duplicate targets never depend on a flaky
    /// review to surface. One background reviewer call follows over the
    /// collected outputs; the reviewer judges content quality, never
    /// permissions, and its output becomes the merged summary. A run with
    /// every subtask cancelled has nothing left to merge, so the reviewer
    /// call is skipped and the digest states the owner stop plainly. The
    /// run-log row settles into the executeJob vocabulary — `ok`,
    /// `awaiting_approval` when a worker parked, `cancelled` when the owner
    /// stopped work, `error` when work was lost — with the merged summary as
    /// its response, exactly like the scheduler's job runs.
    /// - Parameters:
    ///   - run: Settled run to complete with the merged summary.
    ///   - outputs: Collected worker outputs keyed by subtask identifier.
    ///   - notes: Settle notes keyed by subtask identifier.
    ///   - parentRowID: Parent audit row to flip in place.
    ///   - startedAt: Instant the run began, for the honest duration.
    private func settleParent(
        run: inout FanOutRun,
        outputs: [UUID: FanOutWorkerOutput],
        notes: [UUID: String],
        parentRowID: UUID,
        startedAt: Date
    ) async {
        // Cancellation reads first: a stopped swarm must never be dressed as a
        // review of output that was never produced, so an entirely cancelled
        // run skips the reviewer call and states the stop plainly instead.
        let allCancelled = run.subtasks.allSatisfy { $0.status == .cancelled }
        if allCancelled {
            run.summary = Self.allCancelledSummary(for: run.subtasks)
        } else {
            let conflictedIDs = Self.overlapConflictIDs(subtasks: run.subtasks, outputs: outputs)
            let review = await reviewMerge(subtasks: run.subtasks, outputs: outputs, conflictedIDs: conflictedIDs)
            run.summary = Self.mergedSummary(
                subtasks: run.subtasks,
                outputs: outputs,
                conflictedIDs: conflictedIDs,
                notes: notes,
                review: review
            )
        }
        // The parent never stays running past the last settle: all-done reads
        // completed and any failure reads failed so the returned digest stays
        // honest. An owner stop outranks a failure — cancelled is a deliberate
        // outcome, error is a lost one — and the run-log row carries the same
        // executeJob vocabulary so the Runs tab renders one pill across kinds.
        let anyCancelled = run.subtasks.contains { $0.status == .cancelled }
        let allDone = run.subtasks.allSatisfy { $0.status == .done }
        if anyCancelled {
            run.status = .cancelled
        } else {
            run.status = allDone ? .completed : .failed
        }
        let anyFailed = run.subtasks.contains { $0.status == .failed }
        let anyParked = run.subtasks.contains { subtask in
            subtask.status == .done && (outputs[subtask.id]?.isParked ?? false)
        }
        // A cancelled subtask outranks a failure and a park: the owner asked
        // for the stop, so the row must not read as an error or as work that
        // is merely parked. A failure outranks a park: work that was lost is
        // the more severe reading, and a parked worker still resolves through
        // the approvals inbox while an error needs the owner's attention.
        let rowStatus: String = if anyCancelled {
            Self.cancelledRowStatus
        } else if anyFailed {
            "error"
        } else if anyParked {
            "awaiting_approval"
        } else {
            "ok"
        }
        await runLogs.updateFanOutRow(
            id: parentRowID,
            status: rowStatus,
            response: run.summary,
            durationMs: Self.elapsedMs(since: startedAt)
        )
    }

    /// Records the parent plus child audit rows, registers the run's cancel
    /// surface, and mints the worker inputs.
    ///
    /// The parent row stays content-free (joined titles) so subtask prompts
    /// never leak into the trail, and it travels on the caller's session so
    /// the swarm links back to the turn that asked for it. The cancel entry
    /// goes live immediately after the parent row exists — before the child
    /// rows and the worker group — so a cancel racing startup still lands: a
    /// parent cancel marks every subtask, and a worker created after that mark
    /// settles cancelled without running. Each child row maps to its subtask
    /// as soon as it is appended for the same reason: a child-row cancel
    /// arriving before the worker task exists still reaches the subtask.
    /// Each worker owns a fresh session: the UUID is minted here and the
    /// orchestrator creates the session record when the turn runs, mirroring
    /// the per-run scheduler isolation — the fresh identifiers are what keep
    /// concurrent worker histories from interleaving with the caller's session
    /// or each other on the shared conversation store. Child rows carry each
    /// worker's own fresh session so live views open the turn that produced
    /// them.
    /// - Parameters:
    ///   - subtasks: Explicit subtask list.
    ///   - originSessionID: Session that spawned the run.
    ///   - allowedTools: Tool subset workers may call, or nil for the full
    ///     registry; travels verbatim so the orchestrator's tool loop filters
    ///     its registry to the caller's subset before the loop.
    /// - Returns: Worker inputs with fresh sessions, the parent row id, and
    ///   child row ids parallel to the subtask order.
    private func recordSwarmRows(
        subtasks: [FanOutSubtask],
        originSessionID: UUID,
        allowedTools: [String]?
    ) async -> RecordedSwarmRows {
        let parentRowID = await runLogs.appendFanOutRow(
            kind: Self.parentRowKind,
            status: "running",
            message: Self.parentMessage(for: subtasks),
            sessionID: originSessionID
        )
        // Registration runs beside the parent row, before the child rows and
        // the worker group, so a cancel arriving while the run is still
        // starting cannot fall into a gap: it marks the subtasks and the
        // late-created workers settle cancelled without running.
        activeRuns[parentRowID] = ActiveFanOutRun(
            parentRowID: parentRowID,
            subtaskIDs: subtasks.map(\.id),
            workers: [:],
            subtaskByChildRow: [:],
            cancelledSubtaskIDs: [],
            settledSubtaskIDs: []
        )
        let workerInputs = subtasks.map { subtask in
            UserInput(
                text: subtask.prompt,
                sessionID: UUID(),
                source: Self.workerSource,
                allowedTools: allowedTools
            )
        }
        // Sequential appends keep the row order deterministic (oldest first)
        // and the cap keeps the count small enough that the loop never
        // stalls the run meaningfully.
        var childRowIDs: [UUID] = []
        for (index, subtask) in subtasks.enumerated() {
            let rowID = await runLogs.appendFanOutRow(
                kind: Self.workerRowKind,
                status: "running",
                message: subtask.title,
                sessionID: workerInputs[index].sessionID
            )
            childRowIDs.append(rowID)
            mapChildRow(parentRowID: parentRowID, childRowID: rowID, subtaskID: subtask.id)
        }
        return RecordedSwarmRows(
            inputs: workerInputs,
            parentRowID: parentRowID,
            childRowIDs: childRowIDs
        )
    }
}

// MARK: - Composition, worker, and merge-pass helpers

/// Composition, worker, and merge-pass helpers kept in one extension so the
/// actor body stays within the lint budget while the overlap check, the
/// reviewer prompt, and the summary composition stay beside the engine they
/// serve.
extension FanOutEngine {
    // MARK: - Composition and worker helpers

    /// Composes the content-free parent-row message: joined subtask titles so
    /// the Runs tab renders the swarm shape. The store truncates overlong
    /// rows anyway, so a wide subtask list degrades to a bounded row instead
    /// of failing the audit append.
    /// - Parameter subtasks: Explicit subtask list.
    /// - Returns: Titles joined for the parent row.
    static func parentMessage(for subtasks: [FanOutSubtask]) -> String {
        subtasks.map(\.title).joined(separator: "; ")
    }

    /// Composes the honest outcome digest for the parent run.
    ///
    /// Worker prompt text never travels here — each worker's own session
    /// already carries it — so the digest names only counts and the reason
    /// each failure settled, letting the caller render an accurate summary
    /// without leaking subtask content into the run record. A cancelled
    /// subtask never reads as completed, so the all-done line is reserved for
    /// runs where nothing was stopped; the cancellation note carries the
    /// titles and reasons separately.
    /// - Parameters:
    ///   - subtasks: Settled subtasks.
    ///   - notes: Settle notes keyed by subtask identifier.
    /// - Returns: The outcome digest line.
    static func outcomeSummary(subtasks: [FanOutSubtask], notes: [UUID: String]) -> String {
        let done = subtasks.filter { $0.status == .done }.count
        let failures = subtasks.filter { $0.status == .failed }
        let anyCancelled = subtasks.contains { $0.status == .cancelled }
        if failures.isEmpty, !anyCancelled {
            return "All \(subtasks.count) subtasks completed."
        }
        var summary = "\(done)/\(subtasks.count) subtasks completed"
        if !failures.isEmpty {
            let reasons = failures.map { subtask in
                let note = notes[subtask.id] ?? "failed"
                return "\(subtask.title) (\(note))"
            }
            summary += "; failed: \(reasons.joined(separator: ", "))"
        }
        return summary
    }

    /// Composes the summary for a run whose every subtask was cancelled.
    ///
    /// Nothing survived to merge, so the reviewer call is skipped entirely and
    /// the digest states the owner stop plainly instead of spending a model
    /// round to summarize an empty result.
    /// - Parameter subtasks: Settled subtasks (all cancelled).
    /// - Returns: The cancelled-run summary line.
    static func allCancelledSummary(for subtasks: [FanOutSubtask]) -> String {
        "Cancelled by owner: all \(subtasks.count) subtasks stopped before completion."
    }

    /// Composes the cancellation note, or nil when no subtask was stopped.
    /// Reasons travel so an owner stop keeps its cause beside the title.
    /// - Parameters:
    ///   - subtasks: Settled subtasks.
    ///   - notes: Settle notes keyed by subtask identifier.
    /// - Returns: The cancellation note, or nil when none apply.
    static func cancellationNote(subtasks: [FanOutSubtask], notes: [UUID: String]) -> String? {
        let cancelled = subtasks.filter { $0.status == .cancelled }
        guard !cancelled.isEmpty else { return nil }
        let reasons = cancelled.map { subtask in
            "\(subtask.title) (\(notes[subtask.id] ?? Self.ownerCancellationNote))"
        }
        return "Cancelled subtasks: \(reasons.joined(separator: ", "))"
    }

    /// Normalizes one worker failure into an honest note.
    /// Cancellation reads as its own reason; every other failure keeps its
    /// underlying reason so the note never reads as success and never hides
    /// the cause from the run digest. A typed error without a localized
    /// description falls back to its structural description — the default
    /// localized description alone renders as a generic operation failure
    /// that drops the thrown reason.
    /// - Parameter error: The error the worker turn threw.
    /// - Returns: The retained note.
    static func failureNote(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            return described
        }
        return error.localizedDescription
    }

    /// Runs one already-created worker turn to its settle, bounded by the
    /// wall-clock timeout when positive.
    ///
    /// The turn handle is created and registered by the caller so an owner
    /// cancel can reach exactly one worker before this race starts; both an
    /// owner cancel and whole-call cancellation stop the turn through that
    /// same handle. A positive budget races the handle against the timeout
    /// for one continuation: the first side to settle wins and the loser is
    /// cancelled (or abandoned if it never observes cancellation), so a
    /// worker settles within its budget without holding the parent run
    /// hostage. A zero timeout means no race at all — the worker awaits under
    /// the cancellation handler, so an unlimited worker can hold the parent
    /// run open until it finishes or is cancelled, intentional for slow local
    /// models and bounded by cancellation. A throwing turn reads as a failed
    /// worker carrying the error's own reason, except that a cancellation is
    /// flagged so the settle path can keep an owner stop out of the failure
    /// vocabulary. The collecting seam returns the final assistant text and
    /// parked flag so the merge pass reviews real worker output; a stub
    /// without the collecting witness still works and reports an empty output.
    /// - Parameters:
    ///   - worker: The worker turn handle created by the engine.
    ///   - timeoutSeconds: Wall-clock budget for the turn, or zero for no timeout.
    /// - Returns: Settled outcome with the collected output and an honest
    ///   failure note.
    private static func runWorker(
        _ worker: Task<FanOutWorkerOutput, Error>,
        timeoutSeconds: Int
    ) async -> WorkerOutcome {
        // Unlimited workers skip the sleep/race entirely so a slow local model
        // is never cut off by a stale bound; cancellation still ends the turn.
        if timeoutSeconds <= 0 {
            let startedAt = Date()
            return await withTaskCancellationHandler {
                do {
                    let output = try await worker.value
                    return WorkerOutcome(
                        succeeded: true,
                        cancelled: false,
                        note: nil,
                        output: output,
                        durationMs: Self.elapsedMs(since: startedAt)
                    )
                } catch {
                    return WorkerOutcome(
                        succeeded: false,
                        cancelled: error is CancellationError,
                        note: Self.failureNote(for: error),
                        output: .empty,
                        durationMs: Self.elapsedMs(since: startedAt)
                    )
                }
            } onCancel: {
                worker.cancel()
            }
        }
        let seconds = max(1, timeoutSeconds)
        let timeoutNS = UInt64(seconds) * 1_000_000_000
        let startedAt = Date()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumption = WorkerResumption(continuation: continuation)
                Task {
                    do {
                        let output = try await worker.value
                        resumption.resume(WorkerOutcome(
                            succeeded: true,
                            cancelled: false,
                            note: nil,
                            output: output,
                            durationMs: Self.elapsedMs(since: startedAt)
                        ))
                    } catch {
                        resumption.resume(WorkerOutcome(
                            succeeded: false,
                            cancelled: error is CancellationError,
                            note: Self.failureNote(for: error),
                            output: .empty,
                            durationMs: Self.elapsedMs(since: startedAt)
                        ))
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: timeoutNS)
                    worker.cancel()
                    resumption.resume(WorkerOutcome(
                        succeeded: false,
                        cancelled: false,
                        note: "timed out after \(seconds)s",
                        output: .empty,
                        durationMs: Self.elapsedMs(since: startedAt)
                    ))
                }
            }
        } onCancel: {
            worker.cancel()
        }
    }

    /// Elapsed wall-clock milliseconds since a start instant, floored at zero
    /// so a clock skew never reports a negative duration.
    /// - Parameter startedAt: Instant the measured interval began.
    /// - Returns: Non-negative elapsed milliseconds.
    static func elapsedMs(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - Cancellation registry

    /// Note every owner-stopped settle carries, so the digest names the stop's
    /// author instead of a bare status.
    static let ownerCancellationNote = "cancelled by owner"
    /// Run-log status for an owner-stopped run or worker row; it matches the
    /// terminal vocabulary the scheduler's cancelled runs already use, so the
    /// Runs tab renders one pill vocabulary across run kinds.
    static let cancelledRowStatus = "cancelled"

    /// Creates one worker turn as an unstructured task.
    ///
    /// The turn runs unstructured — not as a task-group child — because only
    /// an owned handle lets the engine cancel exactly one worker; the group
    /// child still carries the timeout race and structured cancellation.
    /// Created through a nonisolated helper so the turn runs off the engine's
    /// actor executor instead of serializing workers behind the swarm actor.
    /// - Parameters:
    ///   - input: Worker turn input carrying the fresh session.
    ///   - orchestrator: Seam running the turn.
    /// - Returns: The worker turn handle the registry cancels.
    private static func makeWorkerTask(
        input: UserInput,
        orchestrator: any OrchestratorFanOutSeam
    ) -> Task<FanOutWorkerOutput, Error> {
        Task { try await orchestrator.processCollecting(input) }
    }

    /// Attaches a worker's live handle to its registry slot.
    ///
    /// The slot exists as soon as the child audit row lands, so this only
    /// fills in the cancel closure; a subtask marked cancelled before this
    /// point is caught by the caller's pre-cancel check right after.
    /// - Parameters:
    ///   - parentRowID: Run registry key.
    ///   - subtaskID: Subtask the handle belongs to.
    ///   - childRowID: Child row the settle path flips.
    ///   - cancel: Stops the worker's turn.
    private func registerWorkerHandle(
        parentRowID: UUID,
        subtaskID: UUID,
        childRowID: UUID,
        cancel: @escaping @Sendable () -> Void
    ) {
        guard var entry = activeRuns[parentRowID] else { return }
        entry.workers[subtaskID] = ActiveFanOutWorker(childRowID: childRowID, cancel: cancel)
        activeRuns[parentRowID] = entry
    }

    /// Maps one appended child audit row to its subtask.
    ///
    /// The mapping exists before the worker task does, so a child-row cancel
    /// that races startup still reaches its subtask and marks it cancelled.
    /// - Parameters:
    ///   - parentRowID: Run registry key.
    ///   - childRowID: Child audit row that just landed.
    ///   - subtaskID: Subtask the child row belongs to.
    private func mapChildRow(parentRowID: UUID, childRowID: UUID, subtaskID: UUID) {
        guard var entry = activeRuns[parentRowID] else { return }
        entry.subtaskByChildRow[childRowID] = subtaskID
        activeRuns[parentRowID] = entry
    }

    /// Whether the run has marked this subtask cancelled.
    /// - Parameters:
    ///   - parentRowID: Run registry key.
    ///   - subtaskID: Subtask to inspect.
    /// - Returns: True when the subtask is marked cancelled.
    private func isSubtaskCancelled(parentRowID: UUID, subtaskID: UUID) -> Bool {
        activeRuns[parentRowID]?.cancelledSubtaskIDs.contains(subtaskID) ?? false
    }

    /// Removes a settled worker from the registry.
    ///
    /// The handle and its child-row lookup leave together as the settle
    /// applies, so cancelling an already-settled row answers `.notRunning`
    /// instead of rewriting a terminal outcome. The subtask id stays in
    /// `settledSubtaskIDs`, so a parent cancel no longer counts it.
    /// - Parameters:
    ///   - parentRowID: Run registry key.
    ///   - subtaskID: Subtask whose settle applied.
    private func markWorkerSettled(parentRowID: UUID, subtaskID: UUID) {
        guard var entry = activeRuns[parentRowID] else { return }
        entry.settledSubtaskIDs.insert(subtaskID)
        if let worker = entry.workers.removeValue(forKey: subtaskID) {
            entry.subtaskByChildRow.removeValue(forKey: worker.childRowID)
        }
        activeRuns[parentRowID] = entry
    }

    /// Cancels the in-flight swarm or worker that owns an audit row.
    ///
    /// The parent row stops the whole swarm: every in-flight worker task is
    /// cancelled and every still-running subtask is marked cancelled, so each
    /// settle reads `.cancelled` and the run settles `cancelled` — an owner
    /// stop outranks a worker failure rather than masquerading as an error. A
    /// child row stops just that worker and leaves its siblings running. A row
    /// that no live run or worker owns — unknown, already settled, or a run
    /// whose workers all settled before the merge pass — answers
    /// `.notRunning`: a settled run must never accept a late cancel.
    /// - Parameter rowID: Run-log row identifier (parent or child).
    /// - Returns: The honest cancel boundary the caller hit.
    public func cancel(rowID: UUID) -> FanOutCancelOutcome {
        if var entry = activeRuns[rowID] {
            let running = entry.subtaskIDs.filter { !entry.settledSubtaskIDs.contains($0) }
            guard !running.isEmpty else { return .notRunning }
            // Only workers with a live task handle can be stopped now; the
            // rest are marked so their registration path cancels them on
            // arrival instead of letting them run.
            let inFlight = running.filter { entry.workers[$0] != nil }
            for subtaskID in inFlight {
                if let worker = entry.workers[subtaskID] {
                    worker.cancel()
                }
            }
            entry.cancelledSubtaskIDs.formUnion(running)
            activeRuns[rowID] = entry
            return .runCancelled(workerCount: inFlight.count)
        }
        // A child row resolves through the row-to-subtask map, which exists as
        // soon as the child audit row lands — before the worker task does — so
        // a cancel racing startup still marks the subtask.
        guard let match = activeRuns.first(where: { $0.value.subtaskByChildRow[rowID] != nil }),
              let subtaskID = match.value.subtaskByChildRow[rowID]
        else { return .notRunning }
        var entry = match.value
        if let worker = entry.workers[subtaskID] {
            worker.cancel()
        }
        entry.cancelledSubtaskIDs.insert(subtaskID)
        activeRuns[match.key] = entry
        return .workerCancelled
    }

    // MARK: - Merge pass helpers

    /// Honest note the fail-open summary carries when a wired reviewer flaked.
    /// Worker output is never lost to a flaky review, so the note names the
    /// miss instead of letting raw text read as a merged summary.
    static let reviewUnavailableNote = "Background review was unavailable; worker output is shown unmerged."
    /// Longest merged summary accepted from the reviewer; longer text
    /// truncates rather than drop so one chatty reply cannot widen the run
    /// record without bound.
    static let maxMergedSummaryLength = 2000
    /// Per-subtask output cap quoted in the review prompt, so one verbose
    /// worker cannot crowd the single review call.
    static let maxReviewOutputChars = 2000

    /// Flags exact file-path/URL collisions across collected worker outputs.
    ///
    /// Deterministic by contract: the same reference appearing in two
    /// different subtasks' outputs flags both, with no model round involved,
    /// so duplicate targets never depend on a flaky review to surface.
    /// - Parameters:
    ///   - subtasks: Settled subtasks; only outputs of these travel.
    ///   - outputs: Collected outputs keyed by subtask identifier.
    /// - Returns: Identifiers of subtasks whose output collides with another's.
    static func overlapConflictIDs(subtasks: [FanOutSubtask], outputs: [UUID: FanOutWorkerOutput]) -> Set<UUID> {
        var owners: [String: [UUID]] = [:]
        for subtask in subtasks {
            guard let output = outputs[subtask.id], !output.text.isEmpty else { continue }
            for reference in pathReferences(in: output.text) {
                owners[reference, default: []].append(subtask.id)
            }
        }
        var conflicted: Set<UUID> = []
        for (_, ownerIDs) in owners where ownerIDs.count > 1 {
            conflicted.formUnion(ownerIDs)
        }
        return conflicted
    }

    /// Extracts file-path and URL references from one worker output for the
    /// deterministic overlap check. Mirrors the doc-recall file-like token
    /// shape so the two scanners cannot drift, and adds scheme'd URLs so web
    /// fetch targets collide the same way file targets do.
    /// - Parameter text: Raw worker output.
    /// - Returns: The exact references found.
    static func pathReferences(in text: String) -> Set<String> {
        // Trailing prose punctuation never reads as part of the reference, so
        // "visit /tmp/report.md." collides with a bare "/tmp/report.md".
        let punctuation = CharacterSet(charactersIn: "\"'()[]{}<>,;:!?…")
        var references: Set<String> = []
        for rawToken in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let token = String(rawToken).trimmingCharacters(in: punctuation)
            guard isReferenceToken(token) else { continue }
            references.insert(token)
        }
        return references
    }

    /// Whether a token has a file-path or URL shape worth overlap-flagging.
    ///
    /// Mirrors the doc-recall file-like token shape (slash tokens need a
    /// length with the slash away from the edges; dot tokens need a stem plus
    /// a short alphabetic extension) with output-specific tightenings: a
    /// relative slash token must carry a dotted final segment and a bare
    /// number before the slash never qualifies, so output prose carrying
    /// ratios ("24/7"), fractions ("1.5/2"), and "and/or" joins never reads
    /// as a file collision.
    private static func isReferenceToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.contains("://") {
            // Scheme'd URLs are references outright; the host-plus-path shape
            // never reads as prose, so no further shape test applies.
            return token.count >= 8
        }
        guard token.contains("/") || token.contains(".") else { return false }
        if token.contains("/") {
            // Absolute or home-rooted paths qualify outright.
            if token.hasPrefix("/") || token.hasPrefix("~/") {
                guard token.count >= 3, !token.hasSuffix("/") else { return false }
                return token.contains { $0.isLetter || $0.isNumber }
            }
            // Relative paths need a dotted final segment so "src/report.md"
            // qualifies while prose ratios and conjunction joins do not.
            guard token.count >= 3, !token.hasPrefix("/"), !token.hasSuffix("/") else { return false }
            let segments = token.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return false }
            guard let last = segments.last, last.contains(".") else { return false }
            return token.contains { $0.isLetter || $0.isNumber }
        }
        // Dot-only tokens mirror the doc-recall file rule: stem plus dot plus
        // a short alphabetic extension, so "report.pdf" qualifies while
        // "e.g.", "i.e.", and "v1.2" do not.
        guard token.count >= 4 else { return false }
        guard !token.hasPrefix("."), !token.hasSuffix(".") else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let ext = parts.last, ext.count >= 1, ext.count <= 5 else { return false }
        guard ext.contains(where: \.isLetter) else { return false }
        guard ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return true
    }

    /// Runs the merge-review pass: at most one background reviewer call.
    ///
    /// The reviewer judges content quality only. When no reviewer is wired
    /// the pass reports `.unwired` (the pre-existing digest stands); when a
    /// wired reviewer errors or times out it reports `.unavailable` and the
    /// caller fails open to the raw concatenation, so worker output is never
    /// lost because review was flaky.
    /// - Parameters:
    ///   - subtasks: Settled subtasks.
    ///   - outputs: Collected outputs keyed by subtask identifier.
    ///   - conflictedIDs: Deterministic overlap conflicts, quoted in the
    ///     prompt so the reviewer's verdicts cannot undo them silently.
    /// - Returns: The merge-review outcome.
    private func reviewMerge(
        subtasks: [FanOutSubtask],
        outputs: [UUID: FanOutWorkerOutput],
        conflictedIDs: Set<UUID>
    ) async -> MergeReview {
        guard reviewer != nil else { return .unwired }
        // A review with nothing to read is wasted spend: all workers failed
        // (or produced nothing), so the failure digest is the honest summary
        // without a model round.
        guard outputs.values.contains(where: { !$0.text.isEmpty }) else { return .unavailable }
        let prompt = Self.reviewPrompt(subtasks: subtasks, outputs: outputs, conflictedIDs: conflictedIDs)
        guard let raw = await collectReviewText(prompt: prompt),
              let parsed = Self.parseReview(from: raw)
        else { return .unavailable }
        return .parsed(parsed)
    }

    /// Builds the single-shot merge-review instruction.
    ///
    /// The JSON-object demand and the verdict vocabulary are explicit so even
    /// a terse local model returns a parseable review; the per-subtask cap
    /// repeats in words so one verbose worker cannot crowd the call. Only the
    /// collected outputs travel — the deterministic conflicts are named so
    /// the reviewer's verdicts cannot silently undo them.
    static func reviewPrompt(
        subtasks: [FanOutSubtask],
        outputs: [UUID: FanOutWorkerOutput],
        conflictedIDs: Set<UUID>
    ) -> String {
        var lines: [String] = []
        lines.append("You are the background reviewer for Rune Weaver's parallel worker fan-out.")
        lines.append("Merge the worker outputs below into one merged summary, and give each subtask a verdict.")
        lines.append("Judge content quality only — never permissions, tool access, or policy.")
        lines.append("")
        lines.append("Worker outputs:")
        for subtask in subtasks {
            let bounded = String((outputs[subtask.id]?.text ?? "").prefix(Self.maxReviewOutputChars))
            if bounded.isEmpty {
                lines.append("- \(subtask.title): (no output)")
            } else {
                lines.append("- \(subtask.title):")
                lines.append(bounded)
            }
        }
        if !conflictedIDs.isEmpty {
            let titles = subtasks.filter { conflictedIDs.contains($0.id) }.map(\.title)
            lines.append("")
            lines.append("The deterministic overlap check already flagged these subtasks with identical file paths or URLs: \(titles.joined(separator: ", ")).")
        }
        lines.append("")
        lines.append(
            "Reply with ONLY a JSON object like "
                + "{\"summary\":\"<merged summary>\",\"verdicts\":[{\"title\":\"<subtask title>\",\"verdict\":\"keep\"}]}."
        )
        lines.append(
            "\"verdict\" must be one of: \(FanOutVerdict.allCases.map(\.rawValue).joined(separator: ", ")). "
                + "Keep each \"title\" verbatim from the outputs above. No prose outside the object."
        )
        return lines.joined(separator: "\n")
    }

    /// Extracts a bounded review from chatty model output.
    ///
    /// Fences are removed before scanning so ```json blocks decode, and the
    /// outermost braces win so leading prose and trailing sign-offs survive.
    /// Elements missing a usable title or verdict drop rather than becoming
    /// empty verdicts; an unparsable object or an empty summary yields nil,
    /// which the caller turns into the fail-open summary instead of a
    /// fabricated review.
    /// - Parameter raw: Raw model text.
    /// - Returns: The parsed review, or nil when nothing parseable remains.
    static func parseReview(from raw: String) -> ParsedMergeReview? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("```") {
            // Fence-tolerant: drop markers rather than trying to pair them,
            // so unclosed or language-tagged fences still expose the object.
            text = text.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            text = text.replacingOccurrences(of: "```", with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close
        else { return nil }
        let candidate = String(text[open ... close])
        guard let data = candidate.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = parsed as? [String: Any]
        else { return nil }
        let summary = ((object["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        var verdicts: [ParsedVerdict] = []
        for element in (object["verdicts"] as? [Any]) ?? [] {
            guard let verdictObject = element as? [String: Any] else { continue }
            let title = ((verdictObject["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let rawVerdict = ((verdictObject["verdict"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let verdict = FanOutVerdict(rawValue: rawVerdict) else { continue }
            verdicts.append(ParsedVerdict(title: title, verdict: verdict))
        }
        return ParsedMergeReview(
            summary: String(summary.prefix(Self.maxMergedSummaryLength)),
            verdicts: verdicts
        )
    }

    /// Composes the parent run's summary from the merge outcome.
    ///
    /// A parsed review wins: the reviewer's merged summary plus verdict lines,
    /// with the deterministic conflicts overriding the reviewer's verdict for
    /// a colliding subtask. A wired reviewer that flaked fails open to the raw
    /// concatenation with an honest note, so worker output is never lost. An
    /// unwired reviewer keeps the pre-existing outcome digest shape so callers
    /// without review wiring see no summary change. The deterministic
    /// conflict note and the cancellation note travel in every posture, so a
    /// partially cancelled run states the stop even beside a merged review.
    /// - Parameters:
    ///   - subtasks: Settled subtasks.
    ///   - outputs: Collected outputs keyed by subtask identifier.
    ///   - conflictedIDs: Deterministic overlap conflicts.
    ///   - notes: Settle notes keyed by subtask identifier.
    ///   - review: The merge-review outcome.
    /// - Returns: The summary line set stored on the run and its parent row.
    static func mergedSummary(
        subtasks: [FanOutSubtask],
        outputs: [UUID: FanOutWorkerOutput],
        conflictedIDs: Set<UUID>,
        notes: [UUID: String],
        review: MergeReview
    ) -> String {
        let conflictNote = Self.conflictNote(subtasks: subtasks, conflictedIDs: conflictedIDs)
        let cancellationNote = Self.cancellationNote(subtasks: subtasks, notes: notes)
        switch review {
        case let .parsed(parsed):
            var lines: [String] = [parsed.summary]
            let verdictLines = subtasks.compactMap { subtask -> String? in
                // A deterministic conflict outranks whatever the reviewer said:
                // duplicate targets are the overlap check's own finding.
                if conflictedIDs.contains(subtask.id) {
                    return "- \(subtask.title): \(FanOutVerdict.conflict.rawValue)"
                }
                guard let verdict = parsed.verdicts.first(where: { $0.title == subtask.title }) else {
                    return nil
                }
                return "- \(subtask.title): \(verdict.verdict.rawValue)"
            }
            if !verdictLines.isEmpty {
                lines.append("")
                lines.append("Subtask review:")
                lines.append(contentsOf: verdictLines)
            }
            if let conflictNote {
                lines.append("")
                lines.append(conflictNote)
            }
            if let cancellationNote {
                lines.append("")
                lines.append(cancellationNote)
            }
            return lines.joined(separator: "\n")
        case .unavailable:
            // Fail-open: a wired reviewer flaked, so the raw concatenation
            // carries every worker output with an honest note and the failure
            // digest; nothing reads as merged when it is not.
            var parts: [String] = []
            for subtask in subtasks {
                let text = outputs[subtask.id]?.text ?? ""
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            if let failureLine = Self.failureDigest(subtasks: subtasks, notes: notes) {
                parts.append(failureLine)
            }
            if let conflictNote {
                parts.append(conflictNote)
            }
            if let cancellationNote {
                parts.append(cancellationNote)
            }
            parts.append(Self.reviewUnavailableNote)
            return parts.joined(separator: "\n\n")
        case .unwired:
            // No reviewer wired: the pre-existing outcome digest stands, with
            // the conflict and cancellation notes appended when they apply, so
            // the summary shape never shifts for callers without review wiring.
            var summary = Self.outcomeSummary(subtasks: subtasks, notes: notes)
            if let conflictNote {
                summary += "\n" + conflictNote
            }
            if let cancellationNote {
                summary += "\n" + cancellationNote
            }
            return summary
        }
    }

    /// Composes the deterministic conflict note, or nil when no subtask
    /// collides. Titles travel so the owner can reconcile the targets without
    /// re-reading every worker row.
    /// - Parameters:
    ///   - subtasks: Settled subtasks.
    ///   - conflictedIDs: Deterministic overlap conflicts.
    /// - Returns: The conflict note, or nil when none apply.
    static func conflictNote(subtasks: [FanOutSubtask], conflictedIDs: Set<UUID>) -> String? {
        let titles = subtasks.filter { conflictedIDs.contains($0.id) }.map(\.title)
        guard !titles.isEmpty else { return nil }
        return "Overlap check flagged \(titles.count) subtask(s) with identical file paths or URLs: \(titles.joined(separator: ", "))."
    }

    /// Composes the failure digest line for the fail-open summary, or nil when
    /// every subtask settled done. Mirrors the outcome digest's failure part
    /// so a lost worker keeps its cause even when review never ran.
    /// - Parameters:
    ///   - subtasks: Settled subtasks.
    ///   - notes: Failure notes keyed by subtask identifier.
    /// - Returns: The failure digest line, or nil when nothing failed.
    static func failureDigest(subtasks: [FanOutSubtask], notes: [UUID: String]) -> String? {
        let failures = subtasks.filter { $0.status == .failed }
        guard !failures.isEmpty else { return nil }
        let reasons = failures.map { subtask in
            "\(subtask.title) (\(notes[subtask.id] ?? "failed"))"
        }
        return "Failed subtasks: \(reasons.joined(separator: ", "))"
    }

    /// Collects one review reply, bounded by the wall-clock timeout when positive.
    ///
    /// Exactly one chat call runs. A positive budget races the provider
    /// against the timeout: the timeout resumes the caller, cancels the
    /// provider task, and returns nil on its own budget without awaiting the
    /// losing task, so a provider stream that ignores cooperative
    /// cancellation cannot stretch the merge pass past the configured worker
    /// budget. A zero timeout means no race — the review awaits under the
    /// cancellation handler, mirroring the unlimited worker posture. Every
    /// failure degrades to nil, which the caller turns into the fail-open summary.
    private func collectReviewText(prompt: String) async -> String? {
        // Unlimited policy skips the review race too, mirroring the worker
        // posture so a slow local model still gets its single review pass.
        if config.workerTimeoutSeconds <= 0 {
            let provider = Task { await self.collectOnce(prompt: prompt) }
            return await withTaskCancellationHandler {
                await provider.value
            } onCancel: {
                provider.cancel()
            }
        }
        let timeoutSeconds = max(1, config.workerTimeoutSeconds)
        let timeoutNS = UInt64(timeoutSeconds) * 1_000_000_000
        let provider = Task { await self.collectOnce(prompt: prompt) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumption = MergeReviewResumption(continuation: continuation)
                Task {
                    let text = await provider.value
                    resumption.resume(text)
                }
                Task {
                    try? await Task.sleep(nanoseconds: timeoutNS)
                    provider.cancel()
                    resumption.resume(nil)
                }
            }
        } onCancel: {
            // Caller cancellation still reaches the provider so a cooperative
            // stream ends promptly; a non-cooperative one stays bounded by the
            // timeout side of the race instead of by the losing task.
            provider.cancel()
        }
    }

    /// Runs the single review chat call and folds its stream to text.
    ///
    /// No tools travel because the review is pure text in, JSON out; a
    /// mid-stream provider error or a cancellation yields nil so the caller
    /// fails open instead of parsing a truncated fragment.
    private func collectOnce(prompt: String) async -> String? {
        guard let reviewer else { return nil }
        let messages = [Message(role: .user, content: prompt)]
        let stream = reviewer.chat(messages: messages, tools: [])
        var text = ""
        for await chunk in stream {
            if Task.isCancelled {
                return nil
            }
            if chunk.errorMessage != nil {
                return nil
            }
            text += chunk.delta
            if chunk.isFinished {
                break
            }
        }
        if Task.isCancelled {
            return nil
        }
        return text
    }
}
