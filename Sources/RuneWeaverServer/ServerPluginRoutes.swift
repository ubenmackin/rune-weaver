// Rune Weaver Server — Plugin management and marketplace REST endpoints.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers plugin and marketplace routes.
/// - Parameter app: Application receiving the routes.
func registerPluginRoutes(_ app: Application) {
    registerCorePluginRoutes(app)
    registerMarketplaceRoutes(app)
}

private func registerCorePluginRoutes(_ app: Application) {
    let plugins = app.grouped(PathComponent.constant(ServerPaths.plugins))

    // GET /plugins
    plugins.get { req async throws -> PluginsResponse in
        let context = req.application.runeWeaver
        return await fetchPluginsResponse(context: context)
    }

    // GET /plugins/:id
    plugins.get(PathComponent.parameter("id")) { req async throws -> PluginSummary in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing plugin ID parameter.")
        }
        let context = req.application.runeWeaver
        guard let summary = await fetchPluginSummary(id: id, context: context) else {
            throw Abort(.notFound, reason: "Plugin '\(id)' not found.")
        }
        return summary
    }

    // POST /plugins/rescan
    plugins.post(PathComponent.constant(ServerPaths.rescan)) { req async throws -> PluginsResponse in
        let context = req.application.runeWeaver
        await context.pluginDiscovery.discoverAndSync(toolBus: context.toolBus)
        return await fetchPluginsResponse(context: context)
    }

    // POST /plugins/:id/state
    plugins.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.state)) { req async throws -> PluginSummary in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing plugin ID parameter.")
        }
        let body = try req.content.decode(UpdatePluginStateRequest.self)
        let context = req.application.runeWeaver
        return try await handlePluginStateUpdate(id: id, body: body, context: context)
    }

    // DELETE /plugins/:id
    plugins.delete(PathComponent.parameter("id")) { req async throws -> Response in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing plugin ID parameter.")
        }
        let context = req.application.runeWeaver
        do {
            try await context.pluginDiscovery.uninstallPlugin(id: id, toolBus: context.toolBus)
            return Response(status: .noContent)
        } catch let error as PluginDiscoveryError {
            // A pen-escape refusal is a rejected request, not a server failure.
            throw Abort(.badRequest, reason: error.localizedDescription)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to uninstall plugin: \(error.localizedDescription)")
        }
    }
}

// MARK: - Marketplace Routes

private func registerMarketplaceRoutes(_ app: Application) {
    let marketplace = app.grouped(PathComponent.constant(ServerPaths.marketplace))

    // GET /marketplace/plugins
    marketplace.get(PathComponent.constant(ServerPaths.plugins)) { req async throws -> MarketplaceResponse in
        let context = req.application.runeWeaver
        let installedRecords = await context.pluginStore.loadAll()
        let installedIDs = Set(installedRecords.map(\.id))
        var items = getCuratedMarketplaceItems(installedIDs: installedIDs)
        items.sort { $0.name < $1.name }
        return MarketplaceResponse(items: items)
    }

    // POST /marketplace/install
    marketplace.post(PathComponent.constant(ServerPaths.install)) { req async throws -> PluginSummary in
        let body = try req.content.decode(InstallMarketplacePluginRequest.self)
        let context = req.application.runeWeaver
        // Marketplace IDs become directory names and manifest fields, so reject traversal and
        // injection payloads up front with the same allowlist the manifest parser enforces;
        // containment below remains as a second layer.
        let pluginID = body.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginID.isEmpty,
              pluginID != ".",
              pluginID != "..",
              pluginID.range(of: "^[a-zA-Z0-9_.-]+$", options: .regularExpression) != nil,
              !pluginID.contains("/"),
              !pluginID.contains("\\"),
              !pluginID.contains("..")
        else {
            throw Abort(.badRequest, reason: "Invalid plugin ID. Only alphanumeric, '.', '-', and '_' are allowed.")
        }
        // The marketplace URL rides along as display provenance only. The loopback service never
        // fetches remote URLs server-side, so a crafted install cannot turn this endpoint into a
        // fetch oracle; only well-formed https URLs are accepted to keep stored provenance usable.
        if let rawDownloadURL = body.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDownloadURL.isEmpty
        {
            guard let downloadURL = URL(string: rawDownloadURL),
                  downloadURL.scheme?.lowercased() == "https",
                  downloadURL.host?.isEmpty == false
            else {
                throw Abort(.badRequest, reason: "downloadURL must be a valid https URL.")
            }
        }
        let pluginsDir = context.pluginDiscovery.pluginsDirectory
        let targetDir = pluginsDir.appendingPathComponent(pluginID)

        // Keep a crafted ID or symlinked plugins root from escaping the holding
        // pen; both sides resolve symlinks so a linked pen or parent traversal
        // cannot bypass the prefix check. Verified before any directory is made.
        let resolvedPluginsDir = pluginsDir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = targetDir.resolvingSymlinksInPath().standardizedFileURL
        let pluginsPrefix = resolvedPluginsDir.path.hasSuffix("/") ? resolvedPluginsDir.path : resolvedPluginsDir.path + "/"
        guard resolvedTarget.path.hasPrefix(pluginsPrefix) else {
            throw Abort(.badRequest, reason: "Plugin ID escapes the plugins directory.")
        }

        // Scaffold from the advertised catalog when the ID is curated so the
        // installed manifest declares the same tools, descriptions, and schemas
        // the marketplace lists; ad-hoc IDs fall back to a single namespaced entrypoint tool.
        let curated = getCuratedMarketplaceItems(installedIDs: []).first(where: { $0.id == pluginID })
        let displayName = curated?.name ?? (pluginID.components(separatedBy: ".").last?.capitalized ?? pluginID)
        let itemDescription = curated?.description ?? "Installed community rune package."
        let itemVersion = curated?.version ?? "1.0.0"

        let toolsMetadata: [[String: Any]] = getCuratedToolsMetadata(
            for: pluginID,
            fallbackTools: curated?.declaredTools ?? ["\(pluginID).run"]
        )

        // Scaffold the manifest through structured encoding so quotes or
        // backslashes in the ID stay inside JSON string values and can never
        // inject sibling manifest keys such as entrypoint or permission_level.
        let manifestObject: [String: Any] = [
            "id": pluginID,
            "name": displayName,
            "version": itemVersion,
            "description": itemDescription,
            "runtime": "python",
            "entrypoint": "main.py",
            "tools": toolsMetadata
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        let scriptContent = generateScaffoldScript(for: pluginID, tools: toolsMetadata)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: targetDir.path) {
            throw Abort(.conflict, reason: "Plugin '\(pluginID)' is already installed.")
        }

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw Abort(.conflict, reason: "Plugin '\(pluginID)' is already installed.")
        }

        let manifestFile = targetDir.appendingPathComponent("rune.json")
        let scriptFile = targetDir.appendingPathComponent("main.py")

        // Both scaffold files inherit containment from the verified target directory since their
        // leaf names are fixed server-side constants. A failed write removes the fresh pen so a
        // half-installed directory never wedges later installs behind a persistent conflict.
        do {
            try manifestData.write(to: manifestFile, options: .atomic)
            try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            do {
                try fileManager.removeItem(at: targetDir)
            } catch {
                RuneWeaverLog.server.warning("Failed cleaning up aborted plugin scaffold at \(targetDir.path): \(error.localizedDescription)")
            }
            throw Abort(.internalServerError, reason: "Failed to scaffold plugin '\(pluginID)'.")
        }

        // Trigger discovery sync: records plugin as 'discovered' (disabled by default!)
        // Marketplace installs keep their origin instead of collapsing to local disk.
        await context.pluginDiscovery.discoverAndSync(toolBus: context.toolBus, defaultSource: "marketplace")

        guard let summary = await fetchPluginSummary(id: pluginID, context: context) else {
            throw Abort(.internalServerError, reason: "Plugin installed but could not be discovered.")
        }
        return summary
    }
}

// MARK: - Helper Functions

private func fetchPluginsResponse(context: ServerContext) async -> PluginsResponse {
    let records = await context.pluginStore.loadAll()
    var summaries: [PluginSummary] = []

    for record in records {
        if let manifestInfo = context.pluginDiscovery.findManifest(for: record.id) {
            let manifest = manifestInfo.manifest
            let tools = manifest.tools.map { decl -> ToolInfo in
                let effectiveLevel = record.permissionOverrides[decl.name] ?? decl.permissionLevel.rawValue
                return ToolInfo(
                    name: decl.name,
                    description: decl.description,
                    permissionLevel: effectiveLevel,
                    inputSchema: decl.inputSchema,
                    isEnabled: record.isEnabled,
                    isBuiltIn: false,
                    pluginID: record.id,
                    source: record.source,
                    integrityStatus: record.status == .tampered ? "tampered" : "valid"
                )
            }

            summaries.append(PluginSummary(
                id: record.id,
                name: record.name,
                version: record.version,
                author: manifest.author,
                description: manifest.description,
                runtime: manifest.runtime.rawValue,
                source: record.source,
                status: record.status.rawValue,
                isEnabled: record.isEnabled,
                integrityHash: record.integrityHash,
                tools: tools,
                permissionOverrides: record.permissionOverrides,
                discoveredAt: record.discoveredAt,
                updatedAt: record.updatedAt
            ))
        }
    }

    return PluginsResponse(plugins: summaries)
}

private func fetchPluginSummary(id: String, context: ServerContext) async -> PluginSummary? {
    guard let record = await context.pluginStore.get(id: id),
          let manifestInfo = context.pluginDiscovery.findManifest(for: id)
    else {
        return nil
    }

    let manifest = manifestInfo.manifest
    let tools = manifest.tools.map { decl -> ToolInfo in
        let effectiveLevel = record.permissionOverrides[decl.name] ?? decl.permissionLevel.rawValue
        return ToolInfo(
            name: decl.name,
            description: decl.description,
            permissionLevel: effectiveLevel,
            inputSchema: decl.inputSchema,
            isEnabled: record.isEnabled,
            isBuiltIn: false,
            pluginID: record.id,
            source: record.source,
            integrityStatus: record.status == .tampered ? "tampered" : "valid"
        )
    }

    return PluginSummary(
        id: record.id,
        name: record.name,
        version: record.version,
        author: manifest.author,
        description: manifest.description,
        runtime: manifest.runtime.rawValue,
        source: record.source,
        status: record.status.rawValue,
        isEnabled: record.isEnabled,
        integrityHash: record.integrityHash,
        tools: tools,
        permissionOverrides: record.permissionOverrides,
        discoveredAt: record.discoveredAt,
        updatedAt: record.updatedAt
    )
}

private func getCuratedMarketplaceItems(installedIDs: Set<String>) -> [MarketplacePluginItem] {
    [
        MarketplacePluginItem(
            id: "community.playwright-browser",
            name: "Playwright Web Browser",
            version: "1.0.0",
            author: "Rune Weaver Team",
            description: "Automate web browsing, webpage reading, and screenshot capture in a sandboxed browser.",
            downloadURL: "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/plugins/playwright-browser.json",
            tags: ["web", "automation", "browser"],
            runtime: "python",
            declaredTools: ["browser.navigate", "browser.read_page", "browser.screenshot"],
            isInstalled: installedIDs.contains("community.playwright-browser")
        ),
        MarketplacePluginItem(
            id: "community.homeassistant-control",
            name: "Home Assistant Controller",
            version: "1.1.0",
            author: "Community",
            description: "Query and control smart lights, switches, and climate thermostats via Home Assistant REST API.",
            downloadURL: "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/plugins/homeassistant.json",
            tags: ["home", "iot", "automation"],
            runtime: "python",
            declaredTools: ["home.get_state", "home.call_service"],
            isInstalled: installedIDs.contains("community.homeassistant-control")
        ),
        MarketplacePluginItem(
            id: "community.github-explorer",
            name: "GitHub Repository Explorer",
            version: "1.0.2",
            author: "OpenSource",
            description: "Search repositories, list pull requests, and query issues using GitHub Personal Access Tokens.",
            downloadURL: "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/plugins/github.json",
            tags: ["developer", "github", "git"],
            runtime: "python",
            declaredTools: ["github.search_repos", "github.list_issues"],
            isInstalled: installedIDs.contains("community.github-explorer")
        ),
        MarketplacePluginItem(
            id: "community.clock-timer",
            name: "World Clock & Timer",
            version: "1.0.0",
            author: "Rune Weaver Team",
            description: "Current time queries across world timezones and relative interval countdowns.",
            downloadURL: "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/plugins/clock.json",
            tags: ["utility", "clock", "time"],
            runtime: "python",
            declaredTools: ["clock.current_time", "clock.convert_timezone"],
            isInstalled: installedIDs.contains("community.clock-timer")
        )
    ]
}

private func handlePluginStateUpdate(
    id: String,
    body: UpdatePluginStateRequest,
    context: ServerContext
) async throws -> PluginSummary {
    switch body.action.lowercased() {
    case "enable":
        do {
            _ = try await context.pluginDiscovery.enablePlugin(id: id, toolBus: context.toolBus)
        } catch let error as PluginDiscoveryError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }

    case "disable":
        do {
            _ = try await context.pluginDiscovery.disablePlugin(id: id, toolBus: context.toolBus)
        } catch let error as PluginDiscoveryError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }

    case "override_permission":
        guard let toolName = body.toolName, !toolName.isEmpty else {
            throw Abort(.badRequest, reason: "toolName is required for permission override.")
        }
        guard let levelStr = body.permissionLevel, let level = PermissionLevel(rawValue: levelStr) else {
            throw Abort(.badRequest, reason: "Valid permissionLevel ('readOnly' or 'requiresApproval') is required.")
        }
        guard level != .trusted else {
            throw Abort(.badRequest, reason: "External plugins may not be overridden to 'trusted'.")
        }
        do {
            _ = try await context.pluginDiscovery.setPermissionOverride(
                id: id,
                toolName: toolName,
                overrideLevel: level,
                toolBus: context.toolBus
            )
        } catch let error as PluginManifestError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        } catch let error as PluginDiscoveryError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }

    case "clear_override":
        guard let toolName = body.toolName, !toolName.isEmpty else {
            throw Abort(.badRequest, reason: "toolName is required to clear permission override.")
        }
        do {
            _ = try await context.pluginDiscovery.setPermissionOverride(
                id: id,
                toolName: toolName,
                overrideLevel: nil,
                toolBus: context.toolBus
            )
        } catch let error as PluginManifestError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        } catch let error as PluginDiscoveryError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }

    default:
        throw Abort(
            .badRequest,
            reason: "Unknown action '\(body.action)'. Must be 'enable', 'disable', 'override_permission', or 'clear_override'."
        )
    }

    guard let summary = await fetchPluginSummary(id: id, context: context) else {
        throw Abort(.internalServerError, reason: "Failed to reload plugin summary after state update.")
    }
    return summary
}

private func toolMeta(name: String, description: String, schema: String, permission: String) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "input_schema": schema,
        "permission_level": permission
    ]
}

private func getCuratedToolsMetadata(for pluginID: String, fallbackTools: [String]) -> [[String: Any]] {
    switch pluginID {
    case "community.playwright-browser":
        [
            toolMeta(
                name: "browser.navigate",
                description: "Navigate the browser to a specific URL.",
                schema: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}",
                permission: "requiresApproval"
            ),
            toolMeta(
                name: "browser.read_page",
                description: "Read text content and metadata of the current page.",
                schema: "{\"type\":\"object\",\"properties\":{\"selector\":{\"type\":\"string\"}},\"required\":[]}",
                permission: "readOnly"
            ),
            toolMeta(
                name: "browser.screenshot",
                description: "Capture screenshot of current browser window.",
                schema: "{\"type\":\"object\",\"properties\":{\"filename\":{\"type\":\"string\"}},\"required\":[]}",
                permission: "requiresApproval"
            )
        ]
    case "community.homeassistant-control":
        [
            toolMeta(
                name: "home.get_state",
                description: "Get state of an entity in Home Assistant.",
                schema: "{\"type\":\"object\",\"properties\":{\"entity_id\":{\"type\":\"string\"}},\"required\":[\"entity_id\"]}",
                permission: "readOnly"
            ),
            toolMeta(
                name: "home.call_service",
                description: "Call a service on an entity in Home Assistant.",
                schema: "{\"type\":\"object\",\"properties\":{\"domain\":{\"type\":\"string\"},"
                    + "\"service\":{\"type\":\"string\"},\"entity_id\":{\"type\":\"string\"}},\"required\":[\"domain\",\"service\",\"entity_id\"]}",
                permission: "requiresApproval"
            )
        ]
    case "community.github-explorer":
        [
            toolMeta(
                name: "github.search_repos",
                description: "Search GitHub repositories with a query string.",
                schema: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}",
                permission: "readOnly"
            ),
            toolMeta(
                name: "github.list_issues",
                description: "List open issues for a repository.",
                schema: "{\"type\":\"object\",\"properties\":{\"repo\":{\"type\":\"string\"}},\"required\":[\"repo\"]}",
                permission: "readOnly"
            )
        ]
    case "community.clock-timer":
        [
            toolMeta(
                name: "clock.current_time",
                description: "Get current system and UTC time.",
                schema: "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
                permission: "readOnly"
            ),
            toolMeta(
                name: "clock.convert_timezone",
                description: "Convert current time to target timezone.",
                schema: "{\"type\":\"object\",\"properties\":{\"timezone\":{\"type\":\"string\"}},\"required\":[\"timezone\"]}",
                permission: "readOnly"
            )
        ]
    default:
        fallbackTools.map { toolName in
            toolMeta(
                name: toolName,
                description: "Runs execution for \(toolName).",
                schema: "{\"type\":\"object\",\"properties\":{}}",
                permission: "requiresApproval"
            )
        }
    }
}

private func generateScaffoldScript(for _: String, tools _: [[String: Any]]) -> String {
    """
    #!/usr/bin/env python3
    import sys, json

    def handle_request(req):
        call_id = req.get("id")
        method = req.get("method", "")
        params = req.get("params", {})

        if method == "browser.navigate":
            url = params.get("url", "about:blank")
            return {"jsonrpc": "2.0", "result": f"Navigated to {url}", "id": call_id}
        elif method == "browser.read_page":
            return {"jsonrpc": "2.0", "result": "Title: Rune Weaver Community Page\\nContent: Sample extracted text content.", "id": call_id}
        elif method == "browser.screenshot":
            fn = params.get("filename", "screenshot.png")
            return {"jsonrpc": "2.0", "result": f"Screenshot captured to {fn}", "id": call_id}
        elif method == "home.get_state":
            eid = params.get("entity_id", "light.living_room")
            return {"jsonrpc": "2.0", "result": f"Entity {eid} state: on, brightness: 80%", "id": call_id}
        elif method == "home.call_service":
            return {"jsonrpc": "2.0", "result": f"Called service {params.get('domain')}.{params.get('service')} on {params.get('entity_id')}", "id": call_id}
        elif method == "github.search_repos":
            q = params.get("query", "")
            return {"jsonrpc": "2.0", "result": f"Top repos matching '{q}': ubenmackin/rune-weaver (★120)", "id": call_id}
        elif method == "github.list_issues":
            r = params.get("repo", "")
            return {"jsonrpc": "2.0", "result": f"Open issues for {r}: #1 Add plugin marketplace support", "id": call_id}
        elif method == "clock.current_time":
            import datetime
            now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
            return {"jsonrpc": "2.0", "result": f"Current UTC time: {now_iso}", "id": call_id}
        elif method == "clock.convert_timezone":
            tz = params.get("timezone", "UTC")
            return {"jsonrpc": "2.0", "result": f"Time in {tz}: 12:00:00 PM", "id": call_id}
        else:
            return {"jsonrpc": "2.0", "result": f"Executed {method} successfully with parameters: {params}", "id": call_id}

    def main():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                resp = handle_request(req)
                print(json.dumps(resp), flush=True)
            except Exception as exc:
                err_resp = {"jsonrpc": "2.0", "error": {"code": -32603, "message": str(exc)}, "id": None}
                print(json.dumps(err_resp), flush=True)

    if __name__ == "__main__":
        main()
    """
}
