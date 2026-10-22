// Rune Weaver Server — Plugin management and marketplace REST endpoints.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
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
        var items = await fetchMarketplaceCatalog(context: context, installedIDs: installedIDs)
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
        // Body downloadURL stays display provenance only and never triggers a fetch;
        // catalog file fetches use https-only SSRF-guarded downloads with per-file
        // size cap plus manifest-ID verification.
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

        do {
            let doc = await loadMarketplaceIndex(context: context)
            let entry = doc?.items.first(where: { $0.id == pluginID })
            try await installPluginFiles(pluginID: pluginID, targetDir: targetDir, entry: entry, context: context)
        } catch {
            do {
                try fileManager.removeItem(at: targetDir)
            } catch {
                RuneWeaverLog.server.warning("Failed cleaning up aborted plugin scaffold at \(targetDir.path): \(error.localizedDescription)")
            }
            throw Abort(.internalServerError, reason: "Failed to install plugin '\(pluginID)': \(error.localizedDescription)")
        }

        // Trigger discovery sync: records plugin as 'discovered' (disabled by default!)
        // Marketplace installs keep their origin instead of collapsing to local disk.
        await context.pluginDiscovery.discoverAndSync(toolBus: context.toolBus, defaultSource: "marketplace")

        guard let summary = await fetchPluginSummary(id: pluginID, context: context) else {
            // Undiscoverable scaffold must not wedge retry behind a persistent 409.
            do {
                try fileManager.removeItem(at: targetDir)
            } catch {
                RuneWeaverLog.server.warning("Failed cleaning up undiscoverable plugin scaffold at \(targetDir.path): \(error.localizedDescription)")
            }
            throw Abort(.internalServerError, reason: "Plugin installed but could not be discovered.")
        }
        return summary
    }
}

// MARK: - Helper Functions

private func makePluginSummary(record: PluginRecord, manifest: PluginManifest) -> PluginSummary {
    // Single mapping keeps list and detail rows identical by construction.
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

private func fetchPluginsResponse(context: ServerContext) async -> PluginsResponse {
    let records = await context.pluginStore.loadAll()
    var summaries: [PluginSummary] = []

    for record in records {
        if let manifestInfo = context.pluginDiscovery.findManifest(for: record.id) {
            summaries.append(makePluginSummary(record: record, manifest: manifestInfo.manifest))
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

    return makePluginSummary(record: record, manifest: manifestInfo.manifest)
}

private func getCuratedMarketplaceItems(installedIDs _: Set<String>) -> [MarketplacePluginItem] {
    // Catalog mirrors the remote index, so the curated set stays empty.
    []
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

struct MarketplaceIndexDocument: Codable, Sendable {
    let version: Int?
    let items: [MarketplaceIndexEntry]
}

struct MarketplaceIndexEntry: Codable, Sendable {
    let id: String
    let name: String
    let version: String
    let author: String?
    let description: String
    let downloadURL: String?
    let tags: [String]
    let runtime: String
    let declaredTools: [String]
    let path: String?
    let files: [String]?
}

private let marketplaceIndexMaxBytes = 1_048_576

private func isValidMarketplaceIndex(_ doc: MarketplaceIndexDocument) -> Bool {
    // Version plus per-entry identity keep malformed catalogs from entering the merge.
    guard let version = doc.version, version >= 1 else { return false }
    for entry in doc.items {
        guard !entry.id.isEmpty, !entry.name.isEmpty, !entry.version.isEmpty,
              entry.runtime == "python" || entry.runtime == "executable",
              !entry.declaredTools.isEmpty,
              isValidMarketplaceCatalogID(entry.id) else { return false }
        if let files = entry.files {
            guard !files.isEmpty, files.allSatisfy(isSafeMarketplaceFileName) else { return false }
        }
        if let rawPath = entry.path, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           validatedMarketplaceSourceDir(rawPath) == nil
        {
            return false
        }
        if let rawURL = entry.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawURL.isEmpty
        {
            guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return false }
        }
    }
    return true
}

private func isValidMarketplaceCatalogID(_ id: String) -> Bool {
    // Catalog IDs become directory names, so enforce the install allowlist early.
    guard !id.isEmpty, id != ".", id != "..",
          id.range(of: "^[a-zA-Z0-9_.-]+$", options: .regularExpression) != nil,
          !id.contains("/"), !id.contains("\\"), !id.contains("..") else { return false }
    return true
}

private func loadValidatedMarketplaceIndexFile(at url: URL) -> MarketplaceIndexDocument? {
    // Size cap plus validation keep oversized or malformed catalogs out.
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? NSNumber, size.int64Value <= marketplaceIndexMaxBytes,
          let data = try? Data(contentsOf: url), data.count <= marketplaceIndexMaxBytes,
          let doc = try? JSONDecoder().decode(MarketplaceIndexDocument.self, from: data),
          isValidMarketplaceIndex(doc)
    else {
        return nil
    }
    return doc
}

private func loadValidatedMarketplaceIndexFile(atExpandedPath rawPath: String) -> MarketplaceIndexDocument? {
    // Expand tilde plus reject traversal so configured paths cannot escape via "..".
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for scalar in trimmed.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
        return nil
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    let parts = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    let fileURL: URL
    if expanded.hasPrefix("/") {
        // Absolute catalog paths stay inside the workspace or the owner data dir.
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        let ownerDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".runeweaver").standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedWorkspace = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedOwner = ownerDir.resolvingSymlinksInPath().standardizedFileURL
        let workspacePrefix = resolvedWorkspace.path.hasSuffix("/") ? resolvedWorkspace.path : resolvedWorkspace.path + "/"
        let ownerPrefix = resolvedOwner.path.hasSuffix("/") ? resolvedOwner.path : resolvedOwner.path + "/"
        guard resolvedCandidate.path.hasPrefix(workspacePrefix) || resolvedCandidate.path.hasPrefix(ownerPrefix) else { return nil }
        fileURL = candidate
    } else {
        let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        fileURL = workspaceRoot.appendingPathComponent(expanded).standardizedFileURL
    }
    return loadValidatedMarketplaceIndexFile(at: fileURL)
}

private func fetchValidatedMarketplaceBytes(from initialURL: URL, maxBytes: Int, timeout: TimeInterval) async -> Data? {
    // Manual redirect chain re-validates https plus SSRF plus size cap per hop.
    var current = initialURL
    for _ in 0 ..< HTTPRedirectFollower.maxRedirects {
        guard current.scheme?.lowercased() == "https", current.host?.isEmpty == false,
              await ApiSSRFGuard.denyReasonAsync(for: current.absoluteString, allowlistedOrigins: []) == nil
        else { return nil }
        var request = URLRequest(url: current)
        request.timeoutInterval = timeout
        // Streaming cap enforces per-byte during download so oversized bodies never buffer.
        guard let (data, response) = try? await CappedNoRedirectDelegate.downloadCapped(
            request: request,
            maxBytes: maxBytes,
            timeoutSeconds: timeout
        ), let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 200 {
            guard data.count <= maxBytes else { return nil }
            return data
        }
        guard (300 ..< 400).contains(http.statusCode),
              let next = HTTPRedirectFollower.redirectTarget(http: http, currentURL: current),
              next.scheme?.lowercased() == "https", next.host?.isEmpty == false
        else { return nil }
        current = next
    }
    return nil
}

private func loadMarketplaceIndex(context: ServerContext) async -> MarketplaceIndexDocument? {
    let urlString = context.pluginConfig.marketplaceIndexURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = urlString.lowercased()

    // Remote catalog requires https only so plain http cannot tamper the merge.
    if lower.hasPrefix("https://") {
        if let url = URL(string: urlString),
           url.scheme?.lowercased() == "https",
           url.host?.isEmpty == false,
           let data = await fetchValidatedMarketplaceBytes(from: url, maxBytes: marketplaceIndexMaxBytes, timeout: 5.0),
           let doc = try? JSONDecoder().decode(MarketplaceIndexDocument.self, from: data),
           isValidMarketplaceIndex(doc)
        {
            return doc
        }
    } else if !lower.hasPrefix("http://"), !urlString.isEmpty, let doc = loadValidatedMarketplaceIndexFile(atExpandedPath: urlString) {
        // Configured file path honors tilde, containment, size cap, plus validation.
        return doc
    }

    // File path from environment with the same size and validation bounds.
    if let envPath = ProcessInfo.processInfo.environment["RUNEWEAVER_MARKETPLACE_INDEX_PATH"],
       !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let doc = loadValidatedMarketplaceIndexFile(atExpandedPath: envPath)
    {
        return doc
    }

    // Fallback to local Plugins/index.json relative to current directory, plugins pen, or home.
    let candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins/index.json"),
        context.pluginDiscovery.pluginsDirectory.deletingLastPathComponent().appendingPathComponent("Plugins/index.json"),
        URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path).appendingPathComponent(".runeweaver/Plugins/index.json")
    ]
    for candidate in candidates {
        if let doc = loadValidatedMarketplaceIndexFile(at: candidate) {
            return doc
        }
    }

    return nil
}

private func fetchMarketplaceCatalog(context: ServerContext, installedIDs: Set<String>) async -> [MarketplacePluginItem] {
    var itemsByID: [String: MarketplacePluginItem] = [:]

    for item in getCuratedMarketplaceItems(installedIDs: installedIDs) {
        itemsByID[item.id] = item
    }

    if let doc = await loadMarketplaceIndex(context: context) {
        for entry in doc.items {
            let item = MarketplacePluginItem(
                id: entry.id,
                name: entry.name,
                version: entry.version,
                author: entry.author ?? "Community",
                description: entry.description,
                downloadURL: entry.downloadURL ?? "",
                tags: entry.tags,
                runtime: entry.runtime,
                declaredTools: entry.declaredTools,
                isInstalled: installedIDs.contains(entry.id)
            )
            itemsByID[entry.id] = item
        }
    }

    return Array(itemsByID.values)
}

private func isSafeMarketplaceFileName(_ fileName: String) -> Bool {
    // Single-component allowlist so catalog entries cannot escape the pen.
    guard !fileName.isEmpty, fileName != ".", fileName != "..",
          !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains(".."),
          !fileName.hasPrefix("/"), !fileName.hasPrefix("\\") else { return false }
    for scalar in fileName.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
        return false
    }
    return true
}

private func containedMarketplaceDestination(for fileName: String, in targetDir: URL) -> URL? {
    // Fail closed on traversal payloads, then re-resolve symlinks for pen containment.
    guard isSafeMarketplaceFileName(fileName) else { return nil }
    let dst = targetDir.appendingPathComponent(fileName).standardizedFileURL
    let resolvedTarget = targetDir.resolvingSymlinksInPath().standardizedFileURL
    let resolvedDst = dst.resolvingSymlinksInPath().standardizedFileURL
    let prefix = resolvedTarget.path.hasSuffix("/") ? resolvedTarget.path : resolvedTarget.path + "/"
    guard resolvedDst.path.hasPrefix(prefix) else { return nil }
    return dst
}

private func validatedMarketplaceSourceDir(_ rawPath: String) -> URL? {
    // Catalog sources stay under Plugins/ so workspace files never enter the pen.
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\"), !trimmed.hasPrefix("~"),
          !trimmed.contains("\\"), !trimmed.contains(".."),
          trimmed == "Plugins" || trimmed.hasPrefix("Plugins/") else { return nil }
    for scalar in trimmed.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
        return nil
    }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    let candidate = workspaceRoot.appendingPathComponent(trimmed).standardizedFileURL
    let resolvedRoot = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
    guard resolvedCandidate.path.hasPrefix(prefix) else { return nil }
    return candidate
}

private let marketplacePluginFileMaxBytes = 5_242_880

private func isSafeLocalSourceFile(at src: URL, within localDir: URL) -> Bool {
    // lstat-style check rejects symlinks plus directories before any copy.
    guard let values = try? src.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
          values.isSymbolicLink != true,
          values.isRegularFile == true,
          values.isDirectory != true
    else {
        return false
    }
    let resolvedDir = localDir.resolvingSymlinksInPath().standardizedFileURL
    let resolvedSrc = src.resolvingSymlinksInPath().standardizedFileURL
    let prefix = resolvedDir.path.hasSuffix("/") ? resolvedDir.path : resolvedDir.path + "/"
    return resolvedSrc.path.hasPrefix(prefix)
}

private func verifyInstalledManifestID(pluginID: String, in targetDir: URL) throws {
    // Copied catalog bytes must describe the requested ID, not a swapped manifest.
    let runeURL = targetDir.appendingPathComponent("rune.json")
    guard let data = try? Data(contentsOf: runeURL),
          let manifest = try? PluginManifest.from(jsonData: data),
          manifest.id == pluginID
    else {
        throw PluginDiscoveryError.provisioningFailed("Installed manifest ID mismatch for '\(pluginID)'.")
    }
}

private func copyMarketplaceFilesFromLocal(
    pluginID: String,
    targetDir: URL,
    entry: MarketplaceIndexEntry?
) throws -> Bool {
    // Prefer workspace copies so reviewed local bytes win before any network fetch.
    let fileManager = FileManager.default
    var candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins/\(pluginID)")
    ]
    if let rawPath = entry?.path, let validated = validatedMarketplaceSourceDir(rawPath) {
        candidates.append(validated)
    }

    for localDir in candidates where fileManager.fileExists(atPath: localDir.path) {
        let filesToCopy = entry?.files ?? ["rune.json", "main.py", "requirements.txt", "README.md"]
        // Fail closed: any unsafe name aborts the install, never silently skipped.
        for fileName in filesToCopy {
            guard containedMarketplaceDestination(for: fileName, in: targetDir) != nil else {
                throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'.")
            }
        }
        var hasMissing = false
        for fileName in filesToCopy {
            let src = localDir.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: src.path) {
                hasMissing = true
                break
            }
            guard isSafeLocalSourceFile(at: src, within: localDir) else {
                throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe local source '\(fileName)' for plugin '\(pluginID)'.")
            }
            // Cap local bytes like remote fetch so hashing never reads oversized files.
            guard let attrs = try? fileManager.attributesOfItem(atPath: src.path),
                  let size = attrs[.size] as? NSNumber,
                  size.int64Value <= marketplacePluginFileMaxBytes
            else {
                throw PluginDiscoveryError.provisioningFailed("Local file '\(fileName)' exceeds size limit for plugin '\(pluginID)'.")
            }
        }
        if hasMissing {
            continue
        }
        for fileName in filesToCopy {
            guard let dst = containedMarketplaceDestination(for: fileName, in: targetDir) else {
                throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'.")
            }
            let src = localDir.appendingPathComponent(fileName)
            try fileManager.copyItem(at: src, to: dst)
        }
        try verifyInstalledManifestID(pluginID: pluginID, in: targetDir)
        return true
    }
    return false
}

private func fetchMarketplaceFilesFromRemote(
    pluginID: String,
    targetDir: URL,
    entry: MarketplaceIndexEntry?
) async throws -> Bool {
    // Fetch catalog bytes over https with SSRF guard when local copies are absent.
    guard let entry, let rawURL = entry.downloadURL, let baseDownloadURL = URL(string: rawURL),
          baseDownloadURL.scheme?.lowercased() == "https",
          let files = entry.files, !files.isEmpty
    else {
        return false
    }
    for fileName in files {
        guard containedMarketplaceDestination(for: fileName, in: targetDir) != nil else {
            throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'.")
        }
    }
    let baseURL = baseDownloadURL.deletingLastPathComponent()
    var remoteComplete = true
    var writtenFiles: [URL] = []
    for fileName in files {
        guard let dst = containedMarketplaceDestination(for: fileName, in: targetDir) else {
            throw PluginDiscoveryError.escapesPluginsDirectory("Unsafe marketplace file name '\(fileName)' for plugin '\(pluginID)'.")
        }
        let fileURL = baseURL.appendingPathComponent(fileName)
        // Manual redirect chain re-validates each hop before accepting 200 bytes.
        if let data = await fetchValidatedMarketplaceBytes(from: fileURL, maxBytes: marketplacePluginFileMaxBytes, timeout: 10.0) {
            guard data.count <= marketplacePluginFileMaxBytes else {
                throw PluginDiscoveryError.provisioningFailed("Remote file '\(fileName)' exceeds size limit for plugin '\(pluginID)'.")
            }
            try data.write(to: dst, options: .atomic)
            writtenFiles.append(dst)
        } else {
            remoteComplete = false
            break
        }
    }
    if remoteComplete {
        try verifyInstalledManifestID(pluginID: pluginID, in: targetDir)
        return true
    }
    // Partial fetch must not leave fetched bytes beside a scaffolded fallback.
    for written in writtenFiles {
        try? FileManager.default.removeItem(at: written)
    }
    return false
}

private func installPluginFiles(
    pluginID: String,
    targetDir: URL,
    entry: MarketplaceIndexEntry?,
    context _: ServerContext
) async throws {
    if try copyMarketplaceFilesFromLocal(pluginID: pluginID, targetDir: targetDir, entry: entry) {
        return
    }
    if try await fetchMarketplaceFilesFromRemote(pluginID: pluginID, targetDir: targetDir, entry: entry) {
        return
    }

    // Fallback: scaffold manifest and stub script
    let curated = getCuratedMarketplaceItems(installedIDs: []).first(where: { $0.id == pluginID })
    let displayName = entry?.name ?? curated?.name ?? (pluginID.components(separatedBy: ".").last?.capitalized ?? pluginID)
    let itemDescription = entry?.description ?? curated?.description ?? "Installed community rune package."
    let itemVersion = entry?.version ?? curated?.version ?? "1.0.0"

    let toolsMetadata: [[String: Any]] = getCuratedToolsMetadata(
        for: pluginID,
        fallbackTools: entry?.declaredTools ?? curated?.declaredTools ?? ["\(pluginID).run"]
    )

    let manifestObject: [String: Any] = [
        "id": pluginID,
        "name": displayName,
        "version": itemVersion,
        "description": itemDescription,
        // Scaffold emits a Python stub, so the manifest stays python-only.
        "runtime": "python",
        "entrypoint": "main.py",
        "tools": toolsMetadata
    ]
    let manifestData = try JSONSerialization.data(
        withJSONObject: manifestObject,
        options: [.prettyPrinted, .sortedKeys]
    )
    let scriptContent = generateScaffoldScript(for: pluginID, tools: toolsMetadata)

    let manifestFile = targetDir.appendingPathComponent("rune.json")
    let scriptFile = targetDir.appendingPathComponent("main.py")

    try manifestData.write(to: manifestFile, options: .atomic)
    try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
}
