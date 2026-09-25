// Rune Weaver Core — Central tool registry, permission checking, and execution bus.

import Foundation
import os

/// Result of a ``ToolBus`` execution.
public struct ToolResult: Sendable, Codable, Equatable {
    /// Identifier correlating this result with its ``ToolInput/callID``.
    public let toolCallID: String
    /// Human- or machine-readable result content.
    public let content: String
    /// Whether the execution failed or was denied.
    public let isError: Bool
    /// Category of tool error, if failed.
    public let errorKind: ToolErrorKind?

    /// Creates a tool result.
    public init(toolCallID: String, content: String, isError: Bool = false, errorKind: ToolErrorKind? = nil) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
        self.errorKind = isError ? (errorKind ?? .executionError) : nil
    }

    /// Convenience success result.
    public static func success(toolCallID: String, content: String) -> ToolResult {
        ToolResult(toolCallID: toolCallID, content: content, isError: false, errorKind: nil)
    }

    /// Convenience failure result.
    public static func failure(toolCallID: String, content: String, errorKind: ToolErrorKind? = nil) -> ToolResult {
        ToolResult(toolCallID: toolCallID, content: content, isError: true, errorKind: errorKind)
    }

    /// Creates a result from a raw ``ToolOutput``.
    public init(_ output: ToolOutput, toolCallID: String? = nil) {
        self.toolCallID = toolCallID ?? output.callID ?? ""
        self.content = output.content
        self.isError = output.isError
        if output.isError {
            if let kind = output.errorKind {
                // An explicit kind is authoritative: a tool that can tell a
                // configuration or runtime failure from a bad-argument failure
                // must say so, and the bus never second-guesses it. Without this
                // precedence a runtime message that merely reads "Invalid ..."
                // would be masked as invalid_syntax.
                self.errorKind = kind
            } else if output.content.lowercased().hasPrefix("invalid ") {
                // Legacy best-effort sniff for tools that predate explicit kinds
                // and phrase argument validation as "Invalid <tool> arguments: ...".
                // It cannot separate a genuine argument failure from an environment
                // failure that happens to share the wording, so tools with runtime
                // or configuration failure modes must set `errorKind` themselves.
                self.errorKind = .invalidSyntax
            } else {
                self.errorKind = .executionError
            }
        } else {
            self.errorKind = nil
        }
    }

    /// Converts this result back to a ``ToolOutput``.
    /// - Returns: Equivalent tool output.
    public func asToolOutput() -> ToolOutput {
        ToolOutput(content: content, isError: isError, callID: toolCallID, errorKind: errorKind)
    }

    /// Converts this result to a `tool`-role ``Message`` for LLM history.
    /// Carries the error category alongside the failure flag so a reloaded history
    /// preserves the badge taxonomy instead of collapsing to a generic error.
    public func asMessage() -> Message {
        Message(role: .tool, content: content, toolCallID: toolCallID, isError: isError, errorKind: errorKind)
    }
}

/// Decides whether a gated tool call may run in its invocation context.
public typealias ToolApprovalHandler = @Sendable (any Tool, ToolInput, ToolContext) async -> Bool

/// One in-flight tool call's per-call cancellation slot.
///
/// The bus registers a slot for every running call so a user can stop exactly
/// one tool while its owning turn keeps running. The awaiting execution races
/// the tool task against this slot: whichever settles first wins, and a cancel
/// that wins hands the turn an injected failure instead of blocking, so a tool
/// that never observes cooperative cancellation still yields promptly and the
/// model can re-scope. Reference-typed and lock-protected because the tool task
/// settles off the bus actor while a cancel can arrive on it.
private final class ToolCallCancellation: Sendable {
    /// Mutable race state guarded by ``state``.
    private struct State: Sendable {
        /// Tool task once the bus attaches it, for cooperative cancellation.
        var task: Task<ToolResult, Never>?
        /// Waiter parked by the turn when the race has not settled yet.
        var continuation: CheckedContinuation<ToolResult, Never>?
        /// Tool outcome when the tool finished before the turn parked.
        var settled: ToolResult?
        /// Set once a per-call cancel wins the race.
        var cancelled = false
        /// Normalized user reason captured with the cancellation.
        var reason: String?
    }

    /// Correlation identifier the model used for the call.
    private let callID: String
    /// Name of the tool being called.
    private let toolName: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a slot for one call.
    /// - Parameters:
    ///   - callID: Correlation identifier of the call.
    ///   - toolName: Tool being called.
    init(callID: String, toolName: String) {
        self.callID = callID
        self.toolName = toolName
    }

    /// Attaches the tool task, cancelling it immediately when a cancel arrived
    /// before the task existed so a fast user cancel is never lost.
    /// - Parameter task: The running tool task.
    func attach(_ task: Task<ToolResult, Never>) {
        let alreadyCancelled = state.withLock { lockState -> Bool in
            lockState.task = task
            return lockState.cancelled
        }
        if alreadyCancelled {
            task.cancel()
        }
    }

    /// Awaits the tool outcome, resuming early with the injected cancellation
    /// failure when the user cancels this call instead.
    /// - Returns: The tool's result, or the injected cancellation failure.
    func awaitOutcome() async -> ToolResult {
        await withCheckedContinuation { continuation in
            enum Decision: Sendable {
                case settled(ToolResult)
                case cancelled(String?)
                case parked
            }
            let decision = state.withLock { lockState -> Decision in
                if let settled = lockState.settled {
                    return .settled(settled)
                }
                if lockState.cancelled {
                    return .cancelled(lockState.reason)
                }
                lockState.continuation = continuation
                return .parked
            }
            switch decision {
            case let .settled(result):
                continuation.resume(returning: result)
            case let .cancelled(reason):
                continuation.resume(
                    returning: OrchestratorToolLoop.cancelledToolResult(toolName: toolName, callID: callID, reason: reason)
                )
            case .parked:
                break
            }
        }
    }

    /// Records the tool's own outcome unless a user cancel already won the race.
    /// - Parameter result: Outcome produced by the tool.
    func settle(_ result: ToolResult) {
        let waiter = state.withLock { lockState -> CheckedContinuation<ToolResult, Never>? in
            guard lockState.settled == nil, !lockState.cancelled else { return nil }
            lockState.settled = result
            let parked = lockState.continuation
            lockState.continuation = nil
            return parked
        }
        waiter?.resume(returning: result)
    }

    /// Cancels this call and wakes the turn with the injected failure.
    /// - Parameter reason: Optional user reason, already normalized by the caller.
    /// - Returns: True when this cancel won the race; false when the call had
    ///   already finished or been cancelled, so a retry never double-reports.
    @discardableResult
    func cancel(reason: String?) -> Bool {
        let decision = state.withLock { lockState -> (won: Bool, waiter: CheckedContinuation<ToolResult, Never>?) in
            guard !lockState.cancelled, lockState.settled == nil else { return (false, nil) }
            lockState.cancelled = true
            lockState.reason = reason
            let parked = lockState.continuation
            lockState.continuation = nil
            return (true, parked)
        }
        guard decision.won else { return false }
        let task = state.withLock { $0.task }
        task?.cancel()
        decision.waiter?.resume(
            returning: OrchestratorToolLoop.cancelledToolResult(toolName: toolName, callID: callID, reason: reason)
        )
        return true
    }

    /// Cancels the tool task without injecting the user-facing reason: the
    /// owning turn was aborted, so its own cancellation check ends the turn and
    /// a "cancelled by user" label would misattribute the abort.
    func cancelForTurn() {
        let task = state.withLock { $0.task }
        task?.cancel()
    }
}

/// Identity of one in-flight tool call.
///
/// A model mints `callID`s per turn, not globally, so two sessions can legitimately
/// pick the same identifier. Pairing it with the owning session keeps their
/// cancellation slots distinct: keyed on the identifier alone, the second call
/// overwrites the first's slot and the earlier call becomes uncancellable.
private struct ToolCallKey: Hashable {
    /// Session that owns the call.
    let sessionID: UUID
    /// Correlation identifier the model used for the call.
    let callID: String
}

/// Central registry dispatching LLM-requested tool calls to plugins.
public actor ToolBus {
    /// Tools indexed by name.
    private var tools: [String: any Tool] = [:]
    /// Enablement state indexed by tool name. Absent entries default to true.
    private var enabledStates: [String: Bool] = [:]
    /// Approval hook for `requiresApproval` tools.
    private var approvalHandler: ToolApprovalHandler?
    /// Graduated-trust gate consulted before the approval handler.
    private let permissionGate: PermissionGate?
    /// In-flight tool call slots indexed by owning session and correlation identifier.
    /// A per-call cancel stops exactly one entry here while its owning turn keeps
    /// running, making this registry the single place that maps a wire `callID`
    /// onto a running execution. The session is part of the key because a `callID`
    /// is only unique within its session; keying on the identifier alone would let
    /// two sessions' colliding calls overwrite one another's slots. Entries are
    /// removed as soon as the call settles, so a late cancel for a reused
    /// identifier can never abort an unrelated call.
    private var activeCalls: [ToolCallKey: ToolCallCancellation] = [:]

    /// Creates a bus.
    /// Labeling posture lives with the turn owner (`Orchestrator` /
    /// `ChatTurnContext`), never here: the bus carries no `SecurityConfig`
    /// copy so the two can never diverge silently.
    public init(
        approvalHandler: ToolApprovalHandler? = nil,
        permissionGate: PermissionGate? = nil
    ) {
        self.approvalHandler = approvalHandler
        self.permissionGate = permissionGate
    }

    /// Sets or clears the approval hook.
    /// - Parameter handler: New handler, or nil to deny all `requiresApproval` calls.
    public func setApprovalHandler(_ handler: ToolApprovalHandler?) {
        approvalHandler = handler
    }

    /// Sets or clears the approval hook with a handler that ignores invocation context.
    ///
    /// This lives under its own name because two same-named overloads both accepting
    /// optionals made a bare `setApprovalHandler(nil)` ambiguous, so callers could not
    /// clear the context-aware hook without an explicit cast. Handlers registered here
    /// bridge into the context-aware hook and discard the context they never receive;
    /// `nil` clears the hook exactly as the context-aware setter does.
    /// - Parameter handler: New handler ignoring ToolContext.
    public func setLegacyApprovalHandler(_ handler: (@Sendable (any Tool, ToolInput) async -> Bool)?) {
        if let handler {
            approvalHandler = { tool, call, _ in await handler(tool, call) }
        } else {
            approvalHandler = nil
        }
    }

    /// Registers a tool, replacing any existing tool with the same name.
    public func register(tool: any Tool, isEnabled: Bool = true) {
        tools[tool.name] = tool
        enabledStates[tool.name] = isEnabled
    }

    /// Enables a registered tool by name.
    /// - Parameter name: Tool name to enable.
    public func enableTool(named name: String) {
        if tools[name] != nil {
            enabledStates[name] = true
        }
    }

    /// Disables a registered tool by name without unregistering its definition.
    /// - Parameter name: Tool name to disable.
    public func disableTool(named name: String) {
        if tools[name] != nil {
            enabledStates[name] = false
        }
    }

    /// Whether the tool is registered and currently enabled.
    /// - Parameter name: Tool name.
    /// - Returns: True if registered and enabled.
    public func isToolEnabled(named name: String) -> Bool {
        guard tools[name] != nil else { return false }
        return enabledStates[name] ?? true
    }

    /// Removes the tool with the given name. Missing names are a no-op.
    /// - Parameter name: Name of the tool to remove.
    public func unregister(toolNamed name: String) {
        tools.removeValue(forKey: name)
        enabledStates.removeValue(forKey: name)
    }

    /// Returns the registered tools that are currently enabled.
    /// - Returns: All enabled tools, unsorted.
    public func availableTools() -> [any Tool] {
        tools.values.filter { isToolEnabled(named: $0.name) }
    }

    /// Returns all registered tools, including those currently disabled.
    /// - Returns: All registered tools, unsorted.
    public func allTools() -> [any Tool] {
        Array(tools.values)
    }

    /// Returns the registered tool names.
    /// - Returns: All registered tool names, unsorted.
    public func toolNames() -> [String] {
        Array(tools.keys)
    }

    /// Looks up a tool by name.
    /// - Parameter name: Tool name.
    /// - Returns: The tool, or nil when not registered.
    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// Records graduated trust for an action via the attached gate.
    public func grantTrust(for descriptor: ActionDescriptor, duration: TrustDuration) async {
        await permissionGate?.grantTrust(for: descriptor, duration: duration)
    }

    /// Executes a tool call with permission checking.
    public func execute(toolCall: ToolInput, context: ToolContext) async -> ToolResult {
        guard let tool = tools[toolCall.toolName] else {
            let available = availableTools().map(\.name).sorted()
            let hint = available.isEmpty ? "No tools are currently registered." : "Available tools: \(available.joined(separator: ", "))"
            return .failure(
                toolCallID: toolCall.callID,
                content: "Error: Tool '\(toolCall.toolName)' is not recognized or not available. \(hint)",
                errorKind: .invalidTool
            )
        }
        guard isToolEnabled(named: toolCall.toolName) else {
            return .failure(
                toolCallID: toolCall.callID,
                content: "Error: Tool '\(toolCall.toolName)' is currently disabled.",
                errorKind: .invalidTool
            )
        }
        let trimmedArgs = toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArgs.isEmpty, trimmedArgs != "{}" {
            guard let data = trimmedArgs.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [])) is [String: Any]
            else {
                return .failure(
                    toolCallID: toolCall.callID,
                    content: "Error: Invalid arguments JSON for tool '\(toolCall.toolName)': \(toolCall.argumentsJSON). Expected a JSON object.",
                    errorKind: .invalidSyntax
                )
            }
        }
        switch tool.permissionLevel {
        case .readOnly, .trusted:
            if let gate = permissionGate {
                switch await gate.checkPermission(toolCall: toolCall, tool: tool) {
                case .allowed:
                    break
                case let .denied(reason):
                    return .failure(
                        toolCallID: toolCall.callID,
                        content: "Tool '\(toolCall.toolName)' was denied: \(reason)",
                        errorKind: .executionError
                    )
                case .requiresApproval:
                    // Defense in depth: the gate never returns this verdict for these levels today,
                    // but a future gate change must not silently bypass approval, so honor it
                    // through the same handler path as gated writes.
                    if let denial = await resolveApproval(tool: tool, call: toolCall, context: context) {
                        return denial
                    }
                }
            }
        case .requiresApproval:
            // Denials hold even for dry runs, while needs-approval previews
            // through the tool's dryRun path instead of filing; only the side
            // effect is skipped via the flag the tool already receives.
            if let gate = permissionGate {
                switch await gate.checkPermission(toolCall: toolCall, tool: tool) {
                case .allowed:
                    // Attribute this run to the covering grant so later review
                    // can see which trust is actually exercised. Persistence
                    // stays best-effort inside the gate, so a store failure
                    // never blocks the already-authorized tool call. Dry-run
                    // previews never execute, so they leave counters alone.
                    if !context.dryRun {
                        let descriptor = ActionDescriptor.descriptor(for: toolCall, tool: tool)
                        await gate.recordUse(for: descriptor)
                    }
                case let .denied(reason):
                    return .failure(
                        toolCallID: toolCall.callID,
                        content: "Tool '\(toolCall.toolName)' was denied: \(reason)",
                        errorKind: .executionError
                    )
                case .requiresApproval:
                    if let denial = await resolveApproval(tool: tool, call: toolCall, context: context) {
                        return denial
                    }
                }
            } else if let denial = await resolveApproval(tool: tool, call: toolCall, context: context) {
                return denial
            }
        }
        let effectiveContext = progressContext(for: toolCall, base: context)
        return await runRegisteredTool(tool: tool, call: toolCall, context: effectiveContext)
    }

    /// Runs one admitted tool call under its per-call cancellation slot.
    ///
    /// Split from ``execute`` so admission (lookup, enablement, argument and
    /// permission checks) stays separate from execution. The tool runs in its own
    /// task so a per-call cancel can stop exactly this execution without aborting
    /// its turn, and the slot races that task's outcome against a cancel so the
    /// awaiting loop resumes even when the tool is slow to observe cooperative
    /// cancellation.
    /// - Parameters:
    ///   - tool: Registered tool to run.
    ///   - call: Admitted invocation.
    ///   - context: Progress-attributed execution context.
    /// - Returns: The tool outcome, or the injected failure when a cancel wins.
    private func runRegisteredTool(tool: any Tool, call: ToolInput, context: ToolContext) async -> ToolResult {
        let slot = ToolCallCancellation(callID: call.callID, toolName: call.toolName)
        let key = ToolCallKey(sessionID: context.conversationID, callID: call.callID)
        activeCalls[key] = slot
        let task = Task<ToolResult, Never> { [weak slot] in
            let result: ToolResult
            do {
                let output = try await tool.execute(input: call, context: context)
                result = ToolResult(output, toolCallID: call.callID)
            } catch {
                result = .failure(
                    toolCallID: call.callID,
                    content: "Tool '\(call.toolName)' failed: \(error.localizedDescription)",
                    errorKind: .executionError
                )
            }
            slot?.settle(result)
            return result
        }
        slot.attach(task)
        // Turn cancellation must still stop the running tool, but it is not a user
        // per-call cancel, so the handler only cancels the task; the loop's own
        // cancellation check ends the turn.
        let result = await withTaskCancellationHandler {
            await slot.awaitOutcome()
        } onCancel: {
            slot.cancelForTurn()
        }
        // Only release the slot this call registered, so a same-session retry
        // that reuses the identifier mid-flight is never dropped out from under it.
        if activeCalls[key] === slot {
            activeCalls.removeValue(forKey: key)
        }
        return result
    }

    /// Cancels one in-flight tool call without ending its owning turn.
    ///
    /// The owning turn keeps running and receives the aborted call as an injected
    /// failure result, so the model can re-scope and continue instead of the whole
    /// request failing. The session is a required part of the lookup, not an
    /// optional filter: a `callID` is only unique within its session, so an
    /// owner-less lookup could only guess between colliding calls and might abort
    /// another session's work.
    /// - Parameters:
    ///   - callID: Correlation identifier of the running call.
    ///   - sessionID: Session that owns the call; the lookup is scoped to it.
    ///   - reason: Optional user reason, trimmed and capped before it reaches the model.
    /// - Returns: True when a running call was cancelled.
    public func cancelToolCall(callID: String, sessionID: UUID, reason: String? = nil) -> Bool {
        let trimmedID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return false }
        // A miss is a clean false rather than a broadened search, because no
        // owner-less path exists to disambiguate a colliding identifier.
        guard let slot = activeCalls[ToolCallKey(sessionID: sessionID, callID: trimmedID)] else { return false }
        return slot.cancel(reason: OrchestratorToolLoop.normalizedToolCancelReason(reason))
    }

    /// Binds the base context's progress sink to one call's identity.
    ///
    /// Tools emit progress without carrying their own call identifier, and the bus
    /// is the only layer that authoritatively knows it, so the identity is stamped
    /// here instead of trusted from each emitter. The base sink is invoked
    /// unchanged, so the caller's routing (session tagging, framing, throttling)
    /// still owns the report; an unwired base context stays silent through its
    /// no-op sink.
    /// - Parameters:
    ///   - call: Invocation whose identity stamps each report.
    ///   - base: Caller-supplied context whose sink receives the report.
    /// - Returns: A context that forwards progress attributed to `call`.
    private func progressContext(for call: ToolInput, base: ToolContext) -> ToolContext {
        ToolContext(conversationID: base.conversationID, dryRun: base.dryRun) { report in
            await base.progress(report.attributed(callID: call.callID, toolName: call.toolName))
        }
    }

    /// Resolves gated approval through the attached handler.
    ///
    /// Dry-run previews never file: they fall through to the tool's preview
    /// envelope instead of parking and waiting on the inbox.
    private func resolveApproval(tool: any Tool, call: ToolInput, context: ToolContext) async -> ToolResult? {
        if context.dryRun {
            return nil
        }
        guard let approvalHandler else {
            return .failure(
                toolCallID: call.callID,
                content: "Tool '\(call.toolName)' requires approval and no approval handler is set"
            )
        }
        let allowed = await approvalHandler(tool, call, context)
        if !allowed {
            return .failure(
                toolCallID: call.callID,
                content: "Tool '\(call.toolName)' was denied by the approval gate"
            )
        }
        return nil
    }
}
