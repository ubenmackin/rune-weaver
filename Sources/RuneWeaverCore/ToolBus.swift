// Rune Weaver Core — Central tool registry, permission checking, and execution bus.
//
// Manages tool registration, toggle state, permission gate consultation,
// and synchronized tool dispatch for orchestrators and headless workers.

import Foundation

/// Result of a ``ToolBus`` execution.
///
/// `ToolResult` is the bus-level view of a ``ToolOutput``: it carries
/// the correlation identifier of the originating call so the
/// orchestrator can feed results back to the LLM, plus the content
/// and error flag produced by the tool.
public struct ToolResult: Sendable, Codable, Equatable {
    /// Identifier correlating this result with its ``ToolInput/callID``.
    public let toolCallID: String
    /// Human- or machine-readable result content.
    public let content: String
    /// Whether the execution failed or was denied.
    public let isError: Bool

    /// Creates a tool result.
    /// - Parameters:
    ///   - toolCallID: Correlation identifier of the originating call.
    ///   - content: Result content.
    ///   - isError: Whether this represents a failure.
    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }

    /// Convenience success result.
    /// - Parameters:
    ///   - toolCallID: Correlation identifier.
    ///   - content: Result content.
    /// - Returns: A non-error result.
    public static func success(toolCallID: String, content: String) -> ToolResult {
        ToolResult(toolCallID: toolCallID, content: content, isError: false)
    }

    /// Convenience failure result.
    /// - Parameters:
    ///   - toolCallID: Correlation identifier.
    ///   - content: Error description.
    /// - Returns: An error result.
    public static func failure(toolCallID: String, content: String) -> ToolResult {
        ToolResult(toolCallID: toolCallID, content: content, isError: true)
    }

    /// Creates a result from a raw ``ToolOutput``.
    /// - Parameters:
    ///   - output: Output produced by the tool.
    ///   - toolCallID: Correlation identifier. Defaults to the output's
    ///     `callID` when present, otherwise an empty string.
    public init(_ output: ToolOutput, toolCallID: String? = nil) {
        self.toolCallID = toolCallID ?? output.callID ?? ""
        self.content = output.content
        self.isError = output.isError
    }

    /// Converts this result back to a ``ToolOutput``.
    /// - Returns: Equivalent tool output.
    public func asToolOutput() -> ToolOutput {
        ToolOutput(content: content, isError: isError, callID: toolCallID)
    }

    /// Converts this result to a `tool`-role ``Message`` for LLM history.
    ///
    /// Carries the error flag so persisted history renders failures as
    /// errors instead of success.
    /// - Returns: Message carrying the result content and error flag.
    public func asMessage() -> Message {
        Message(role: .tool, content: content, toolCallID: toolCallID, isError: isError)
    }
}

/// Decides whether a gated tool call may run.
///
/// Return `true` to allow the execution, `false` to deny it. The bus
/// invokes this hook before any state-changing tool runs; `readOnly`
/// and `trusted` tools consult it only when the gate unexpectedly
/// returns `requiresApproval`, so a future gate change cannot silently
/// bypass approval, though they still honor explicit `PermissionGate`
/// denials.
public typealias ToolApprovalHandler = @Sendable (any Tool, ToolInput) async -> Bool

/// Central registry dispatching LLM-requested tool calls to plugins.
///
/// The bus owns the tool registry, routes invocations from the
/// orchestrator to the matching ``Tool``, and enforces the permission
/// gate before any execution: `readOnly` and `trusted` tools run unless
/// explicitly denied via ``PermissionGate/deny(_:reason:)`` (checked
/// first, matching ``PermissionGate/checkPermission(toolCall:tool:)``),
/// with an unexpected `requiresApproval` verdict honored through the
/// approval handler as defense in depth so the service layer never
/// bypasses approvals; `requiresApproval` tools consult the
/// ``PermissionGate`` (when one is attached) for graduated-trust grants,
/// denials, and live coverage before falling back to the approval handler
/// (or being denied when no handler is set). Dry runs keep the same gate:
/// denials still hold and approvals are still required, with only the
/// tool's external side effect suppressed via the `dryRun` flag it receives).
public actor ToolBus {
    /// Tools indexed by name.
    private var tools: [String: any Tool] = [:]
    /// Enablement state indexed by tool name. Absent entries default to true.
    private var enabledStates: [String: Bool] = [:]
    /// Approval hook for `requiresApproval` tools.
    private var approvalHandler: ToolApprovalHandler?
    /// Graduated-trust gate consulted before the approval handler.
    private let permissionGate: PermissionGate?

    /// Creates a bus.
    /// - Parameters:
    ///   - approvalHandler: Hook consulted for
    ///     `requiresApproval` tools. Defaults to nil (deny).
    ///   - permissionGate: Graduated-trust gate consulted before the
    ///     handler. Defaults to nil (handler-only decisions).
    public init(approvalHandler: ToolApprovalHandler? = nil, permissionGate: PermissionGate? = nil) {
        self.approvalHandler = approvalHandler
        self.permissionGate = permissionGate
    }

    /// Sets or clears the approval hook.
    /// - Parameter handler: New handler, or nil to deny all
    ///   `requiresApproval` calls.
    public func setApprovalHandler(_ handler: ToolApprovalHandler?) {
        approvalHandler = handler
    }

    /// Registers a tool, replacing any existing tool with the same name.
    /// - Parameters:
    ///   - tool: The tool to register.
    ///   - isEnabled: Whether the tool is active for execution. Defaults to true.
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
    ///
    /// Forwards to ``PermissionGate/grantTrust(for:duration:)``; a no-op
    /// when no gate is attached. `thisTime` approvals are one-shot and
    /// intentionally not persisted.
    /// - Parameters:
    ///   - descriptor: The action to trust.
    ///   - duration: How long the trust lasts.
    public func grantTrust(for descriptor: ActionDescriptor, duration: TrustDuration) async {
        await permissionGate?.grantTrust(for: descriptor, duration: duration)
    }

    /// Executes a tool call with permission checking.
    ///
    /// Unknown tools and denied approvals return an error
    /// ``ToolResult`` rather than throwing, so the orchestrator can
    /// feed the failure back to the LLM. Tool-thrown errors are caught
    /// and mapped to error results the same way.
    /// - Parameters:
    ///   - toolCall: Invocation arguments.
    ///   - context: Ambient execution context.
    /// - Returns: The tool result.
    public func execute(toolCall: ToolInput, context: ToolContext) async -> ToolResult {
        guard let tool = tools[toolCall.toolName] else {
            return .failure(toolCallID: toolCall.callID, content: "Unknown tool: \(toolCall.toolName)")
        }
        guard isToolEnabled(named: toolCall.toolName) else {
            return .failure(toolCallID: toolCall.callID, content: "Tool '\(toolCall.toolName)' is currently disabled.")
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
                        content: "Tool '\(toolCall.toolName)' was denied: \(reason)"
                    )
                case .requiresApproval:
                    // Defense in depth: the gate never returns this verdict
                    // for these levels today, but a future gate change must
                    // not silently bypass approval, so honor it through the
                    // same handler path as gated writes.
                    if let denial = await resolveApproval(tool: tool, call: toolCall) {
                        return denial
                    }
                }
            }
        case .requiresApproval:
            // Graduated trust applies even to dry runs: denials must hold
            // whether or not the tool promises to avoid mutation, so the gate
            // is always consulted and only the tool's side effect is skipped
            // via the dryRun flag it already receives. Trusting every plugin
            // to honor dryRun without a gate check would bypass approvals.
            if let gate = permissionGate {
                switch await gate.checkPermission(toolCall: toolCall, tool: tool) {
                case .allowed:
                    break
                case let .denied(reason):
                    return .failure(
                        toolCallID: toolCall.callID,
                        content: "Tool '\(toolCall.toolName)' was denied: \(reason)"
                    )
                case .requiresApproval:
                    if let denial = await resolveApproval(tool: tool, call: toolCall) {
                        return denial
                    }
                }
            } else if let denial = await resolveApproval(tool: tool, call: toolCall) {
                return denial
            }
        }
        do {
            let output = try await tool.execute(input: toolCall, context: context)
            return ToolResult(output, toolCallID: toolCall.callID)
        } catch {
            return .failure(toolCallID: toolCall.callID, content: "Tool '\(toolCall.toolName)' failed: \(error.localizedDescription)")
        }
    }

    /// Resolves gated approval through the attached handler.
    ///
    /// Single shared branch for gate-attached and no-gate paths so both
    /// agree on denial text: a missing handler denies, otherwise the
    /// handler's verdict decides. Also covers the unexpected
    /// `requiresApproval` verdict for `readOnly`/`trusted` tools so a
    /// future gate change cannot silently bypass approval.
    /// - Parameters:
    ///   - tool: Tool requesting approval.
    ///   - call: Invocation arguments.
    /// - Returns: Denial result, or nil when the call is approved.
    private func resolveApproval(tool: any Tool, call: ToolInput) async -> ToolResult? {
        guard let approvalHandler else {
            return .failure(
                toolCallID: call.callID,
                content: "Tool '\(call.toolName)' requires approval and no approval handler is set"
            )
        }
        let allowed = await approvalHandler(tool, call)
        if !allowed {
            return .failure(
                toolCallID: call.callID,
                content: "Tool '\(call.toolName)' was denied by the approval gate"
            )
        }
        return nil
    }
}
