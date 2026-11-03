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

    // POST /plugins/:id/config
    plugins.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.config)) { req async throws -> PluginSummary in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing plugin ID parameter.")
        }
        let body = try req.content.decode(UpdatePluginConfigRequest.self)
        let context = req.application.runeWeaver
        do {
            let updated = try await context.pluginDiscovery.setUserConfig(id: id, config: body.config, toolBus: context.toolBus)
            guard let manifestInfo = context.pluginDiscovery.findManifest(for: id) else {
                throw Abort(.notFound, reason: "Plugin manifest not found.")
            }
            // Config saves keep live update truth so direct API reads match list views.
            let marketplaceDoc = await MarketplaceCatalog.loadMarketplaceIndex(context: context)
            let catalogEntry = marketplaceDoc?.items.first(where: { $0.id == id })
            return await makePluginSummary(record: updated, manifest: manifestInfo.manifest, context: context, catalogEntry: catalogEntry)
        } catch let error as PluginDiscoveryError {
            // Unknown IDs are 404; oversized or protected config stays 400.
            if case .pluginNotFound = error {
                throw Abort(.notFound, reason: error.localizedDescription)
            }
            throw Abort(.badRequest, reason: error.localizedDescription)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to update plugin configuration: \(error.localizedDescription)")
        }
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
    marketplace.get(PathComponent.constant(ServerPaths.plugins), use: handleGetMarketplacePlugins)
    marketplace.post(PathComponent.constant(ServerPaths.install), use: handleInstallMarketplacePlugin)
    marketplace.post(PathComponent.constant(ServerPaths.update), use: MarketplaceUpdate.handleUpdateMarketplacePlugin)
}

/// GET /marketplace/plugins
private func handleGetMarketplacePlugins(req: Request) async throws -> MarketplaceResponse {
    let context = req.application.runeWeaver
    let installedRecords = await context.pluginStore.loadAll()
    let installedByID = Dictionary(uniqueKeysWithValues: installedRecords.map { ($0.id, $0) })
    var items = await MarketplaceCatalog.fetchMarketplaceCatalog(context: context, installedRecordsByID: installedByID)
    items.sort { $0.name < $1.name }
    return MarketplaceResponse(items: items)
}

/// POST /marketplace/install
private func handleInstallMarketplacePlugin(req: Request) async throws -> PluginSummary {
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
        try Task.checkCancellation()
        let doc = await MarketplaceCatalog.loadMarketplaceIndex(context: context)
        let entry = doc?.items.first(where: { $0.id == pluginID })
        try await MarketplaceCatalog.installPluginFiles(pluginID: pluginID, targetDir: targetDir, entry: entry, context: context)
    } catch is CancellationError {
        try? fileManager.removeItem(at: targetDir)
        throw CancellationError()
    } catch {
        do {
            try fileManager.removeItem(at: targetDir)
        } catch {
            RuneWeaverLog.server.warning("Failed cleaning up aborted plugin scaffold at \(targetDir.path): \(error.localizedDescription)")
        }
        // Cancellation outranks mapping so cooperative cancels never surface as 500s.
        if Task.isCancelled {
            throw CancellationError()
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

// Update flow lives in ServerMarketplaceUpdate to keep this file within budget.

// MARK: - Helper Functions

// Version plus hash helpers live in ServerMarketplaceCatalog.

func makePluginSummary(
    record: PluginRecord,
    manifest: PluginManifest,
    context: ServerContext,
    catalogEntry: MarketplaceIndexEntry? = nil
) async -> PluginSummary {
    // Per-tool truth lives on the live bus (same source as GET /tools);
    // coarse plugin flag would flatten mixed per-tool states to all-or-nothing.
    var tools: [ToolInfo] = []
    for decl in manifest.tools {
        let effectiveLevel = record.permissionOverrides[decl.name] ?? decl.permissionLevel.rawValue
        var liveEnabled = record.isEnabled
        if await context.toolBus.tool(named: decl.name) != nil {
            liveEnabled = await context.toolBus.isToolEnabled(named: decl.name)
        }
        tools.append(
            ToolInfo(
                name: decl.name,
                description: decl.description,
                permissionLevel: effectiveLevel,
                inputSchema: decl.inputSchema,
                isEnabled: liveEnabled,
                isBuiltIn: false,
                pluginID: record.id,
                source: record.source,
                integrityStatus: record.status == .tampered ? "tampered" : "valid"
            )
        )
    }

    let latestVer = catalogEntry?.version
    let hasUpdate: Bool = if let latestVer {
        MarketplaceCatalog.isVersionNewer(latestVer, than: record.version)
    } else {
        false
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
        updatedAt: record.updatedAt,
        latestVersion: latestVer,
        hasUpdate: hasUpdate,
        credentials: manifest.effectiveCredentials,
        options: manifest.options ?? [],
        declaredNetworkHosts: manifest.effectiveNetworkHosts,
        userConfig: record.userConfig
    )
}

private func fetchPluginsResponse(context: ServerContext) async -> PluginsResponse {
    // Live bus is the truth on reads; quarantine refreshes at boot and mutations.
    let records = await context.pluginStore.loadAll()
    let marketplaceDoc = await MarketplaceCatalog.loadMarketplaceIndex(context: context)
    // Duplicates fail catalog validation; map is defensive last-wins.
    let catalogByID = Dictionary((marketplaceDoc?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var summaries: [PluginSummary] = []

    for record in records {
        if let manifestInfo = context.pluginDiscovery.findManifest(for: record.id) {
            let catalogEntry = catalogByID[record.id]
            await summaries.append(makePluginSummary(record: record, manifest: manifestInfo.manifest, context: context, catalogEntry: catalogEntry))
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

    let marketplaceDoc = await MarketplaceCatalog.loadMarketplaceIndex(context: context)
    let catalogEntry = marketplaceDoc?.items.first(where: { $0.id == id })

    return await makePluginSummary(record: record, manifest: manifestInfo.manifest, context: context, catalogEntry: catalogEntry)
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

// Catalog plus install helpers live in ServerMarketplaceCatalog.
