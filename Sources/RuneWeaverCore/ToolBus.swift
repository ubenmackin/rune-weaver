// Rune Weaver Core — Central tool registry, permission checking, and execution bus.

import Foundation

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

    /// Creates a bus.
    public init(approvalHandler: ToolApprovalHandler? = nil, permissionGate: PermissionGate? = nil) {
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
            // Graduated trust applies even to dry runs: denials must hold whether or not the tool
            // promises to avoid mutation, so the gate is always consulted and only the tool's side
            // effect is skipped via the dryRun flag it already receives.
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
        do {
            let output = try await tool.execute(input: toolCall, context: context)
            return ToolResult(output, toolCallID: toolCall.callID)
        } catch {
            return .failure(
                toolCallID: toolCall.callID,
                content: "Tool '\(toolCall.toolName)' failed: \(error.localizedDescription)",
                errorKind: .executionError
            )
        }
    }

    /// Resolves gated approval through the attached handler.
    private func resolveApproval(tool: any Tool, call: ToolInput, context: ToolContext) async -> ToolResult? {
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
