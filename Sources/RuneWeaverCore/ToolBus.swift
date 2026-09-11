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
    /// - Returns: Message carrying the result content.
    public func asMessage() -> Message {
        Message(role: .tool, content: content, toolCallID: toolCallID)
    }
}

/// Decides whether a `requiresApproval` tool call may run.
///
/// Return `true` to allow the execution, `false` to deny it. The bus
/// invokes this hook before any state-changing tool runs; `readOnly`
/// and `trusted` tools never consult it, though they still honor
/// explicit `PermissionGate` denials.
public typealias ToolApprovalHandler = @Sendable (any Tool, ToolInput) async -> Bool

/// Central registry dispatching LLM-requested tool calls to plugins.
///
/// The bus owns the tool registry, routes invocations from the
/// orchestrator to the matching ``Tool``, and enforces the permission
/// gate before any execution: `readOnly` and `trusted` tools run unless
/// explicitly denied via ``PermissionGate/deny(_:reason:)`` (checked
/// first, matching ``PermissionGate/checkPermission(toolCall:tool:)``),
/// `requiresApproval` tools consult the ``PermissionGate`` (when
/// one is attached) for graduated-trust grants, denials, and live
/// coverage before falling back to the approval handler (or being
/// denied when no handler is set, unless the context is a `dryRun`
/// which tools must honor without mutating state).
public actor ToolBus {
    /// Tools indexed by name.
    private var tools: [String: any Tool] = [:]
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
    /// - Parameter tool: The tool to register.
    public func register(tool: any Tool) {
        tools[tool.name] = tool
    }

    /// Removes the tool with the given name. Missing names are a no-op.
    /// - Parameter name: Name of the tool to remove.
    public func unregister(toolNamed name: String) {
        tools.removeValue(forKey: name)
    }

    /// Returns the registered tools.
    /// - Returns: All registered tools, unsorted.
    public func availableTools() -> [any Tool] {
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
                    break
                }
            }
        case .requiresApproval:
            if !context.dryRun {
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
        }
        do {
            let output = try await tool.execute(input: toolCall, context: context)
            return ToolResult(output, toolCallID: toolCall.callID)
        } catch {
            return .failure(toolCallID: toolCall.callID, content: "Tool '\(toolCall.toolName)' failed: \(error.localizedDescription)")
        }
    }

    /// Resolves `requiresApproval` approval through the attached handler.
    ///
    /// Single shared branch for gate-attached and no-gate paths so both
    /// agree on denial text: a missing handler denies, otherwise the
    /// handler's verdict decides.
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
