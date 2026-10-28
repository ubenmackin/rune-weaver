// Rune Weaver Server — Tool registry and invocation routes.

import Foundation
import RuneWeaverCore
import Vapor

/// Builds one tool listing row with the provenance rules shared by tool routes.
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

    // The server owns which tools expose settings so the dashboard never keeps a name allowlist:
    // media tools share the Sonarr/Radarr patch, browser/web/API tools configure timeouts plus the
    // allowed homelab origins SSRF exemption, desktop tools configure capture dimensions, quality.
    let configurableName = tool.name == "media.arr"
        || tool.name == "media.arr.read"
        || tool.name == "browser.navigate"
        || tool.name == "browser.act"
        || tool.name == "web.fetch"
        || tool.name == "api.request"
        || tool.name == "desktop.screenshot"
        || tool.name == "desktop.action"
        || tool.name == "fanout.run"
    let hasConfig = isBuiltIn && configurableName

    return ToolInfo(
        tool,
        isEnabled: isEnabled,
        isBuiltIn: isBuiltIn,
        pluginID: pluginID,
        source: source,
        integrityStatus: integrityStatus,
        hasConfig: hasConfig
    )
}

/// Validates, persists, toggles, and describes one tool state change.
func updateToolState(toolName: String, enabled: Bool, context: ServerContext) async throws -> ToolInfo {
    let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
        throw Abort(.badRequest, reason: "Tool name must not be empty")
    }
    guard let tool = await context.toolBus.tool(named: name) else {
        throw Abort(.notFound, reason: "Unknown tool '\(name)'")
    }
    let records = await context.pluginStore.loadAll()
    let recordByPluginID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // Holding pen stays fail-closed: per-tool enable never arms a pending
    // or disabled rune; plugin enable must hash and provision first.
    if enabled, let bridge = tool as? SubprocessToolBridge,
       let record = recordByPluginID[bridge.pluginID]
    {
        if record.status == .tampered {
            throw Abort(
                .conflict,
                reason: "Tool '\(name)' is quarantined (owning plugin '\(bridge.pluginID)' failed integrity verification). "
                    + "Re-enable the plugin to re-verify before enabling individual tools."
            )
        }
        if record.status != .enabled || record.integrityHash == nil {
            throw Abort(
                .conflict,
                reason: "Tool '\(name)' belongs to plugin '\(bridge.pluginID)' which is not enabled. "
                    + "Enable the plugin via POST /plugins/\(bridge.pluginID)/state first."
            )
        }
        if let expected = record.integrityHash {
            var stale = true
            if let manifestInfo = context.pluginDiscovery.findManifest(for: bridge.pluginID) {
                if let current = PluginSecurity.calculateDirectoryHash(at: manifestInfo.dir) {
                    stale = !PluginSecurity.hashesEqual(expected, current)
                }
            }
            if stale {
                throw Abort(
                    .conflict,
                    reason: "Tool '\(name)' is quarantined (owning plugin '\(bridge.pluginID)' failed integrity verification). "
                        + "Re-enable the plugin to re-verify before enabling individual tools."
                )
            }
        }
    }
    // Single-gate contract: the persisted tool-state toggle is the sole authority for desktop
    // tools, so no config gate refines the enable here.
    await context.toolStates.setEnabled(toolName: name, enabled: enabled)
    if enabled {
        await context.toolBus.enableTool(named: name)
    } else {
        await context.toolBus.disableTool(named: name)
    }
    // The persisted toggle changes what Settings lists, so open tabs refetch.
    await context.hub.broadcastSettingsChanged()
    let isEnabled = await context.toolBus.isToolEnabled(named: name)
    return buildToolInfo(for: tool, isEnabled: isEnabled, recordByPluginID: recordByPluginID)
}

/// Cancels one in-flight tool call owned by a session. REST and WebSocket paths both go through
/// here, keeping the blank call-ID rejection and the session-scoped lookup in one place.
func cancelInFlightToolCall(callID: String, sessionID: UUID, reason: String?, context: ServerContext) async throws -> Bool {
    let trimmed = callID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw Abort(.badRequest, reason: "callID must not be empty")
    }
    return await context.toolBus.cancelToolCall(callID: trimmed, sessionID: sessionID, reason: reason)
}

/// Registers tool listing plus direct tool-call routes.
/// - Parameter app: Application receiving the routes.
func registerToolRoutes(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.tools)) { req async throws -> ToolsResponse in
        let context = req.application.runeWeaver
        // Reconcile before listing so a persisted toggle for a
        // just-registered builtin never reads as enabled.
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
        let entry = await context.runs.append(
            kind: "tool",
            status: result.isError ? "error" : "ok",
            message: call.toolName,
            response: result.content,
            toolActions: [action],
            durationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
        // No silent run writes: the settled row reaches dashboards now instead
        // of surfacing only after the next run-history poll.
        await context.hub.broadcastRun(entry)
        return result
    }
}
