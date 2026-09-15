// Rune Weaver Server — Tool registry and invocation routes.
//
// Hosts tool listing, per-tool enable/disable toggles backed by durable
// tool-state storage, and direct tool invocation so the main service file
// stays within the length budget. List and toggle paths share one
// tool-info mapping so dashboard provenance labels never diverge.

import Foundation
import RuneWeaverCore
import Vapor

/// Builds one tool listing row with the provenance rules shared by tool routes.
///
/// Keeps `GET /tools` and `POST /tools/:name/state` on one mapping so the
/// dashboard never sees divergent builtin/plugin labels between list and
/// toggle responses. Builtins stay `builtin`/`valid`; bridge tools resolve
/// their registry record for source and tamper status, falling back to a
/// generic plugin label when the record is missing.
/// - Parameters:
///   - tool: Registered tool to describe.
///   - isEnabled: Live bus flag for the tool.
///   - recordByPluginID: Registry records indexed by plugin identifier.
/// - Returns: Listing row for the tool.
func buildToolInfo(
    for tool: any Tool,
    isEnabled: Bool,
    recordByPluginID: [String: PluginRecord]
) -> ToolInfo {
    var pluginID: String?
    var isBuiltIn = true
    var source = "builtin"
    var integrityStatus = "valid"

    if let bridge = tool as? SubprocessToolBridge {
        pluginID = bridge.pluginID
        isBuiltIn = false
        // Surface durable provenance so marketplace runes stay
        // distinguishable from local disk in the dashboard; unknown
        // tools keep the generic plugin label with unverified status.
        if let record = recordByPluginID[bridge.pluginID] {
            source = record.source
            switch record.status {
            case .tampered:
                integrityStatus = "tampered"
            case .discovered, .enabled, .disabled:
                integrityStatus = "valid"
            }
        } else {
            source = "plugin"
            integrityStatus = "unverified"
        }
    }

    return ToolInfo(
        tool,
        isEnabled: isEnabled,
        isBuiltIn: isBuiltIn,
        pluginID: pluginID,
        source: source,
        integrityStatus: integrityStatus
    )
}

/// Validates, persists, toggles, and describes one tool state change.
///
/// Trims the name and rejects blanks with 400, reports unknown registered
/// names with 404, then persists the flag before touching the live bus so a
/// crash between the two never leaves the bus ahead of disk on the next
/// boot. Accepts any registered name including memory tools.
/// - Parameters:
///   - toolName: Registered tool name.
///   - enabled: Desired enabled flag.
///   - context: Shared engine collaborators.
/// - Returns: Updated listing row for the tool.
/// - Throws: `Abort` with `.badRequest` for blank names or `.notFound` for unknown tools.
func updateToolState(toolName: String, enabled: Bool, context: ServerContext) async throws -> ToolInfo {
    let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
        throw Abort(.badRequest, reason: "Tool name must not be empty")
    }
    guard let tool = await context.toolBus.tool(named: name) else {
        throw Abort(.notFound, reason: "Unknown tool '\(name)'")
    }
    // Persist before toggling: the durable row is the restart source of
    // truth, so the bus must never run ahead of what a fresh boot would see.
    await context.toolStates.setEnabled(toolName: name, enabled: enabled)
    if enabled {
        await context.toolBus.enableTool(named: name)
    } else {
        await context.toolBus.disableTool(named: name)
    }
    let isEnabled = await context.toolBus.isToolEnabled(named: name)
    let records = await context.pluginStore.loadAll()
    let recordByPluginID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return buildToolInfo(for: tool, isEnabled: isEnabled, recordByPluginID: recordByPluginID)
}

/// Registers tool listing plus direct tool-call routes.
/// - Parameter app: Application receiving the routes.
func registerToolRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.tools)) { req async throws -> ToolsResponse in
        let context = req.application.runeWeaver
        // Late-registered builtin tools arrive after `make`, so reconcile
        // stored toggles on read: the cached load makes this a memory-only
        // pass after the first boot hydration.
        await context.restoreToolStates()
        let tools = await context.toolBus.allTools()
        let records = await context.pluginStore.loadAll()
        let recordByPluginID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var toolInfos: [ToolInfo] = []
        for tool in tools {
            let isEnabled = await context.toolBus.isToolEnabled(named: tool.name)
            toolInfos.append(buildToolInfo(for: tool, isEnabled: isEnabled, recordByPluginID: recordByPluginID))
        }
        toolInfos.sort { $0.name < $1.name }
        return ToolsResponse(tools: toolInfos)
    }

    app.post(
        PathComponent.constant(ServerPaths.tools),
        PathComponent.parameter("name"),
        PathComponent.constant(ServerPaths.state)
    ) { req async throws -> ToolInfo in
        guard let raw = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing tool name parameter.")
        }
        let body = try req.content.decode(UpdateToolStateRequest.self)
        let context = req.application.runeWeaver
        // Reconcile before validating so a persisted toggle for a
        // just-registered builtin never masquerades as an unknown name.
        await context.restoreToolStates()
        return try await updateToolState(toolName: raw, enabled: body.enabled, context: context)
    }

    app.post(PathComponent.constant(ServerPaths.tools), PathComponent.constant(ServerPaths.toolCall)) { req async throws -> ToolResult in
        let body = try req.content.decode(ToolCallRequest.self)
        guard !body.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "toolName must not be empty")
        }
        let context = req.application.runeWeaver
        let call = ToolInput(
            toolName: body.toolName,
            argumentsJSON: body.resolvedArgumentsJSON,
            callID: body.resolvedCallID
        )
        let startTime = Date()
        let result = await context.toolBus.execute(
            toolCall: call,
            context: ToolContext(conversationID: UUID())
        )
        // Direct tool calls are service-triggered writes, so they join the
        // same local audit trail as chat and scheduler runs instead of
        // returning silently.
        let action = ToolAction(
            toolName: call.toolName,
            callID: call.callID,
            argumentsJSON: call.argumentsJSON,
            result: result
        )
        await context.runs.append(
            kind: "tool",
            status: result.isError ? "error" : "ok",
            message: call.toolName,
            response: result.content,
            toolActions: [action],
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
        return result
    }
}
