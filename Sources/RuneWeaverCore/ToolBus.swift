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
    /// Process exit status recorded by the producing tool, if it spawned a process. Typed metadata
    /// carried end-to-end (wire, SQLite, dashboard) so exit badges never depend on parsing untrusted
    /// `content`.
    public let exitCode: Int32?

    /// Creates a tool result.
    public init(
        toolCallID: String,
        content: String,
        isError: Bool = false,
        errorKind: ToolErrorKind? = nil,
        exitCode: Int32? = nil
    ) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
        self.errorKind = isError ? (errorKind ?? .executionError) : nil
        self.exitCode = exitCode
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
        self.exitCode = output.exitCode
        if output.isError {
            if let kind = output.errorKind {
                // An explicit kind is authoritative: a tool that can tell a configuration or
                // runtime failure from a bad-argument failure must say so, and the bus never
                // second-guesses it.
                self.errorKind = kind
            } else if output.content.lowercased().hasPrefix("invalid ") {
                // Best-effort sniff for tools that lack explicit kinds and phrase
                // argument validation as "Invalid <tool> arguments: ...".
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
        ToolOutput(content: content, isError: isError, callID: toolCallID, errorKind: errorKind, exitCode: exitCode)
    }

    /// Converts this result to a `tool`-role ``Message`` for LLM history.
    public func asMessage() -> Message {
        Message(
            role: .tool,
            content: content,
            toolCallID: toolCallID,
            isError: isError,
            errorKind: errorKind,
            exitCode: exitCode
        )
    }
}

/// Decides whether a gated tool call may run in its invocation context.
public typealias ToolApprovalHandler = @Sendable (any Tool, ToolInput, ToolContext) async -> Bool

/// One in-flight tool call's per-call cancellation slot.
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

    /// Creates a slot for one call. callID: Correlation identifier of the call.
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
    /// Aliases mapping alternative tool names to primary registered tool names.
    private var aliases: [String: String] = [:]
    /// Enablement state indexed by tool name. Absent entries default to true.
    private var enabledStates: [String: Bool] = [:]
    /// Approval hook for `requiresApproval` tools.
    private var approvalHandler: ToolApprovalHandler?
    /// Graduated-trust gate consulted before the approval handler.
    private let permissionGate: PermissionGate?
    /// Trusted-tool anomaly watchdog counting executions and denials.
    private var watchdog: BehaviorWatchdog?
    /// In-flight tool call slots indexed by owning session and correlation identifier.
    private var activeCalls: [ToolCallKey: ToolCallCancellation] = [:]

    /// Tracker guarding against duplicate retries of timed-out or unconfirmed mutating actions.
    public let uncertainTracker: UncertainActionTracker

    /// Creates a bus. Labeling posture lives with the turn owner (`Orchestrator` and the surfaces
    /// driving it), never here: the bus carries no `SecurityConfig` copy so the two can never
    /// diverge silently.
    public init(
        approvalHandler: ToolApprovalHandler? = nil,
        permissionGate: PermissionGate? = nil,
        uncertainTracker: UncertainActionTracker? = nil
    ) {
        self.approvalHandler = approvalHandler
        self.permissionGate = permissionGate
        self.uncertainTracker = uncertainTracker ?? UncertainActionTracker()
    }

    /// Sets or clears the approval hook.
    /// - Parameter handler: New handler, or nil to deny all `requiresApproval` calls.
    public func setApprovalHandler(_ handler: ToolApprovalHandler?) {
        approvalHandler = handler
    }

    /// Sets or clears the trusted-tool anomaly watchdog.
    /// - Parameter watchdog: Watchdog receiving outcome counts, or nil to detach.
    public func setWatchdog(_ watchdog: BehaviorWatchdog?) {
        self.watchdog = watchdog
    }

    /// Records one trusted-tool observation as a count, never content.
    private func recordWatchdog(tool: any Tool, sessionID: UUID, outcome: WatchdogOutcome) async {
        if outcome == .executed {
            guard tool.permissionLevel == .trusted else { return }
        }
        await watchdog?.ingest(toolName: tool.name, sessionID: sessionID, outcome: outcome)
    }

    /// Records one egress-supervisor refusal as a firewall-blocked count.
    public func recordFirewallBlocked(toolName: String, sessionID: UUID) async {
        await watchdog?.ingest(toolName: toolName, sessionID: sessionID, outcome: .firewallBlocked)
    }

    /// Whether error content describes an egress-supervisor refusal.
    private static func isFirewallBlockedContent(_ content: String) -> Bool {
        let lower = content.lowercased()
        return lower.contains("egress supervisor")
            || lower.contains("security policy violation")
            || lower.contains("ssrf denied")
    }

    /// Registers a tool, replacing any existing tool with the same name.
    public func register(tool: any Tool, isEnabled: Bool = true) {
        tools[tool.name] = tool
        enabledStates[tool.name] = isEnabled
    }

    /// Registers an alias name pointing to a primary registered tool name.
    public func registerAlias(from aliasName: String, to targetToolName: String) {
        aliases[aliasName] = targetToolName
    }

    /// Enables a registered tool by name or alias.
    /// - Parameter name: Tool name to enable.
    public func enableTool(named name: String) {
        let target = aliases[name] ?? name
        if tools[target] != nil {
            enabledStates[target] = true
        }
    }

    /// Disables a registered tool by name or alias without unregistering its definition.
    /// - Parameter name: Tool name to disable.
    public func disableTool(named name: String) {
        let target = aliases[name] ?? name
        if tools[target] != nil {
            enabledStates[target] = false
        }
    }

    /// Whether the tool is registered and currently enabled.
    /// - Parameter name: Tool name.
    /// - Returns: True if registered and enabled.
    public func isToolEnabled(named name: String) -> Bool {
        let target = aliases[name] ?? name
        guard tools[target] != nil else { return false }
        return enabledStates[target] ?? true
    }

    /// Removes the tool with the given name. Missing names are a no-op.
    public func unregister(toolNamed name: String) {
        tools.removeValue(forKey: name)
        enabledStates.removeValue(forKey: name)
        aliases = aliases.filter { $0.key != name && $0.value != name }
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

    /// Looks up a tool by name or alias.
    /// - Parameter name: Tool name.
    /// - Returns: The tool, or nil when not registered.
    public func tool(named name: String) -> (any Tool)? {
        let target = aliases[name] ?? name
        return tools[target]
    }

    /// Executes a tool call with permission checking.
    public func execute(toolCall: ToolInput, context: ToolContext) async -> ToolResult {
        let resolvedName = aliases[toolCall.toolName] ?? toolCall.toolName
        guard let tool = tools[resolvedName] else {
            let available = availableTools().map(\.name).sorted()
            let hint = available.isEmpty ? "No tools are currently registered." : "Available tools: \(available.joined(separator: ", "))"
            return .failure(
                toolCallID: toolCall.callID,
                content: "Error: Tool '\(toolCall.toolName)' is not recognized or not available. \(hint)",
                errorKind: .invalidTool
            )
        }
        guard isToolEnabled(named: resolvedName) else {
            return .failure(
                toolCallID: toolCall.callID,
                content: "Error: Tool '\(toolCall.toolName)' is currently disabled.",
                errorKind: .invalidTool
            )
        }
        let effectiveCall = (resolvedName == toolCall.toolName)
            ? toolCall
            : ToolInput(toolName: resolvedName, argumentsJSON: toolCall.argumentsJSON, callID: toolCall.callID)
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
        if await uncertainTracker.isBlocked(toolName: effectiveCall.toolName, argumentsJSON: effectiveCall.argumentsJSON) {
            let message = "REFUSED (IDEMPOTENCY_GUARD): Identical mutating action '\(toolCall.toolName)' was previously "
                + "executed with uncertain outcome (timed out or unconfirmed). You must verify whether the action took effect "
                + "before re-attempting, or use a read tool to inspect current state."
            return .failure(
                toolCallID: toolCall.callID,
                content: message,
                errorKind: .idempotencyBlocked
            )
        }
        let approved: Bool
        switch await evaluateToolPermission(tool: tool, call: effectiveCall, context: context) {
        case let .authorized(isApproved):
            approved = isApproved
        case let .denied(denial):
            // A denied trusted call still counts: the denial spike rule fires
            // on exactly this signal. Dry runs never count; nothing executed.
            if !context.dryRun {
                await recordWatchdog(tool: tool, sessionID: context.sessionID, outcome: .denied)
            }
            return denial
        }
        let baseContext: ToolContext = if approved {
            ToolContext(
                conversationID: context.conversationID,
                dryRun: context.dryRun,
                approved: true,
                progress: context.progress
            )
        } else {
            context
        }
        let effectiveContext = progressContext(for: effectiveCall, base: baseContext)
        let result = await runRegisteredTool(tool: tool, call: effectiveCall, context: effectiveContext)
        // Count the execution outcome; dry-run previews never count. An
        // egress-supervisor refusal files as firewall-blocked so the
        // firewall rule observes it instead of a plain execution.
        if !context.dryRun {
            if result.isError, Self.isFirewallBlockedContent(result.content) {
                await recordWatchdog(tool: tool, sessionID: context.sessionID, outcome: .firewallBlocked)
            } else {
                await recordWatchdog(tool: tool, sessionID: context.sessionID, outcome: .executed)
            }
        }
        return result
    }

    private enum PermissionOutcome {
        case authorized(approved: Bool)
        case denied(ToolResult)
    }

    /// Evaluates permissions for a tool call against the gate and approval handlers.
    /// Returns `.authorized(approved:)` on authorization, or `.denied(ToolResult)` if denied.
    private func evaluateToolPermission(
        tool: any Tool,
        call: ToolInput,
        context: ToolContext
    ) async -> PermissionOutcome {
        var approved = false
        switch tool.permissionLevel {
        case .readOnly, .trusted:
            if let gate = permissionGate {
                switch await gate.checkPermission(toolCall: call, tool: tool, sessionID: context.sessionID) {
                case .allowed:
                    break
                case let .denied(reason):
                    return .denied(.failure(
                        toolCallID: call.callID,
                        content: "Tool '\(call.toolName)' was denied: \(reason)",
                        errorKind: .executionError
                    ))
                case .requiresApproval:
                    // Pre-admission partitioning parks approval-required tools, but egress or gate
                    // changes can return this for read-only/trusted levels too; honors it through the
                    // same handler path as gated writes instead of executing unsupervised.
                    if let denial = await resolveApproval(tool: tool, call: call, context: context) {
                        return .denied(denial)
                    }
                    approveIfAuthorized(context: context, approved: &approved)
                }
            }
        case .requiresApproval:
            // Denials hold even for dry runs, while needs-approval previews
            // through the tool's dryRun path instead of filing; only the side
            // effect is skipped via the flag the tool already receives.
            if let gate = permissionGate {
                switch await gate.checkPermission(toolCall: call, tool: tool, sessionID: context.sessionID) {
                case .allowed:
                    // Attribute this run to the covering rule so later review can see which trust
                    // is actually exercised.
                    if !context.dryRun {
                        let descriptor = ActionDescriptor.descriptor(for: call, tool: tool)
                        await gate.recordUse(scope: PermissionGate.scope(for: descriptor), toolName: descriptor.toolName)
                        approved = true
                    }
                case let .denied(reason):
                    return .denied(.failure(
                        toolCallID: call.callID,
                        content: "Tool '\(call.toolName)' was denied: \(reason)",
                        errorKind: .executionError
                    ))
                case .requiresApproval:
                    if let denial = await resolveApproval(tool: tool, call: call, context: context) {
                        return .denied(denial)
                    }
                    approveIfAuthorized(context: context, approved: &approved)
                }
            } else {
                if let denial = await resolveApproval(tool: tool, call: call, context: context) {
                    return .denied(denial)
                }
                approveIfAuthorized(context: context, approved: &approved)
            }
        }
        return .authorized(approved: approved)
    }

    /// Runs one admitted tool call under its per-call cancellation slot. - Returns: The tool
    /// outcome, or the injected failure when a cancel wins.
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
        if !result.isError {
            await uncertainTracker.clear(toolName: call.toolName, argumentsJSON: call.argumentsJSON)
            return result
        }
        if result.errorKind == .uncertainOutcome || Self.isTimeoutOrNetworkLoss(result.content) {
            if UncertainActionTracker.isMutating(toolName: call.toolName, argumentsJSON: call.argumentsJSON) {
                await uncertainTracker.recordUncertain(toolName: call.toolName, argumentsJSON: call.argumentsJSON)
                let message = "REFUSED (IDEMPOTENCY_GUARD): Outcome of call to '\(call.toolName)' is uncertain: "
                    + "\(result.content). Repeat attempt blocked until verification probe is performed."
                return .failure(
                    toolCallID: call.callID,
                    content: message,
                    errorKind: .uncertainOutcome
                )
            }
        }
        return result
    }

    /// Evaluates whether an error content indicates a timeout or network loss.
    private static func isTimeoutOrNetworkLoss(_ content: String) -> Bool {
        let lower = content.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("connection reset")
            || lower.contains("network connection was lost")
            || lower.contains("deadline exceeded")
            || lower.contains("socket not connected")
    }

    /// Cancels one in-flight tool call without ending its owning turn.
    public func cancelToolCall(callID: String, sessionID: UUID, reason: String? = nil) -> Bool {
        let trimmedID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return false }
        // A miss is a clean false rather than a broadened search, because no
        // owner-less path exists to disambiguate a colliding identifier.
        guard let slot = activeCalls[ToolCallKey(sessionID: sessionID, callID: trimmedID)] else { return false }
        return slot.cancel(reason: OrchestratorToolLoop.normalizedToolCancelReason(reason))
    }

    /// Binds the base context's progress sink to one call's identity.
    private func progressContext(for call: ToolInput, base: ToolContext) -> ToolContext {
        ToolContext(conversationID: base.conversationID, dryRun: base.dryRun, approved: base.approved) { report in
            await base.progress(report.attributed(callID: call.callID, toolName: call.toolName))
        }
    }

    /// Propagates handler authorization into the tool context. Centralizes the
    /// post-`resolveApproval` propagation so the read-only, gated, and no-gate branches cannot
    /// drift.
    private func approveIfAuthorized(context: ToolContext, approved: inout Bool) {
        if !context.dryRun, approvalHandler != nil {
            approved = true
        }
    }

    /// Resolves gated approval through the attached handler. Dry-run previews never file: they fall
    /// through to the tool's preview envelope instead of parking and waiting on the inbox.
    private func resolveApproval(tool: any Tool, call: ToolInput, context: ToolContext) async -> ToolResult? {
        if context.dryRun {
            return nil
        }
        // Pre-admission validation is the admission seam for target-shaped tools: the orchestrator
        // consults it before parking, while a direct bus execution (the CLI REPL, the live-approval
        // backstop) reaches the prompt without that partition, so the same verdict is consulted.
        if let validator = tool as? any ToolAdmissionValidating,
           case let .refuse(reason) = await validator.admissionVerdict(for: call)
        {
            return .failure(toolCallID: call.callID, content: reason)
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
