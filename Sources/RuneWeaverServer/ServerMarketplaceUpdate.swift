// Rune Weaver Server — Marketplace plugin update orchestration core.

import Foundation
import RuneWeaverCore
import Vapor

/// Update helpers share one namespace so generic names never leak globally.
enum MarketplaceUpdate {
    /// Bundled validated update inputs so helpers stay within param budgets.
    struct Plan: Sendable {
        let pluginID: String
        let targetDir: URL
        let backupDir: URL
        let venvStaging: URL
        let mmStaging: URL
        let entry: MarketplaceIndexEntry
        let oldHash: String?
        let newHash: String?
        // Staging flags captured at preserve time so rollback stays authoritative.
        var preservedVenv: Bool = false
        var preservedMM: Bool = false
    }

    /// Validates the raw update identifier against the install allowlist.
    static func validatedMarketplaceUpdateID(_ rawID: String) throws -> String {
        let pluginID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MarketplaceCatalog.isValidMarketplaceCatalogID(pluginID) else {
            throw Abort(.badRequest, reason: "Invalid plugin ID.")
        }
        return pluginID
    }

    /// Resolves the update target while keeping symlinked pens contained.
    static func marketplaceUpdateTargetDir(pluginID: String, pluginsDir: URL) throws -> URL {
        let targetDir = pluginsDir.appendingPathComponent(pluginID)
        let resolvedPluginsDir = pluginsDir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = targetDir.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedPluginsDir.path.hasSuffix("/") ? resolvedPluginsDir.path : resolvedPluginsDir.path + "/"
        guard resolvedTarget.path.hasPrefix(prefix) else {
            throw Abort(.badRequest, reason: "Plugin ID escapes the plugins directory.")
        }
        return targetDir
    }

    /// Loads the catalog entry and rejects missing or stale versions.
    static func marketplaceUpdateEntry(
        pluginID: String,
        installedVersion: String,
        context: ServerContext
    ) async throws -> MarketplaceIndexEntry {
        // Fresh catalog read keeps version decisions live with no restart.
        let doc = await MarketplaceCatalog.loadMarketplaceIndex(context: context)
        guard let entry = doc?.items.first(where: { $0.id == pluginID }) else {
            throw Abort(.notFound, reason: "Plugin '\(pluginID)' not found in marketplace catalog.")
        }
        guard MarketplaceCatalog.isVersionNewer(entry.version, than: installedVersion) else {
            throw Abort(.conflict, reason: "Plugin '\(pluginID)' is already up to date.")
        }
        return entry
    }

    /// Preserved runtime names kept staged aside across file replacement.
    static func isPreservedMarketplaceRuntimeName(_ name: String) -> Bool {
        name == ".venv" || name == ".mm"
    }

    /// Copies the live plugin directory to a rollback backup location.
    static func stageMarketplaceUpdateBackup(pluginID: String, targetDir: URL, pluginsDir: URL) throws -> URL {
        let backupDir = pluginsDir.appendingPathComponent(".\(pluginID).update-backup-\(UUID().uuidString)")
        do {
            // Live venv plus session cache stay staged separately, so backup skips them.
            // Skipping keeps rollback copies to payload weight only.
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let items = try FileManager.default.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil, options: [])
            for item in items {
                let name = item.lastPathComponent
                guard !MarketplaceUpdate.isPreservedMarketplaceRuntimeName(name) else { continue }
                try FileManager.default.copyItem(at: item, to: backupDir.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: backupDir)
            throw Abort(.internalServerError, reason: "Failed to create backup: \(error.localizedDescription)")
        }
        return backupDir
    }

    /// Moves live runtime and session cache aside before clearing the target.
    static func preserveMarketplaceRuntime(
        targetDir: URL,
        venvStaging: URL,
        mmStaging: URL
    ) throws -> (preservedVenv: Bool, preservedMM: Bool) {
        let fileManager = FileManager.default
        var preservedVenv = false
        var preservedMM = false
        let liveVenvDir = targetDir.appendingPathComponent(".venv")
        let liveMMDir = targetDir.appendingPathComponent(".mm")
        if fileManager.fileExists(atPath: liveVenvDir.path) {
            if fileManager.fileExists(atPath: venvStaging.path) {
                // Stale staging would block the move, so drop it with a warning.
                RuneWeaverLog.server.warning("Dropping leftover venv staging at \(venvStaging.path) before preserving live runtime.")
                try fileManager.removeItem(at: venvStaging)
            }
            try fileManager.moveItem(at: liveVenvDir, to: venvStaging)
            preservedVenv = true
        }
        if fileManager.fileExists(atPath: liveMMDir.path) {
            if fileManager.fileExists(atPath: mmStaging.path) {
                // Stale staging would block the move, so drop it with a warning.
                RuneWeaverLog.server.warning("Dropping leftover session staging at \(mmStaging.path) before preserving live cache.")
                try fileManager.removeItem(at: mmStaging)
            }
            try fileManager.moveItem(at: liveMMDir, to: mmStaging)
            preservedMM = true
        }
        return (preservedVenv, preservedMM)
    }

    /// Clears stale files then copies the catalog payload over the target.
    static func clearTargetAndInstallUpdate(
        pluginID: String,
        targetDir: URL,
        entry: MarketplaceIndexEntry,
        context: ServerContext
    ) async throws {
        let fileManager = FileManager.default
        let existing = try fileManager.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil, options: [])
        // Live runtime stays staged aside, so clearing skips it to avoid slow deletes.
        for existingURL in existing {
            let name = existingURL.lastPathComponent
            guard !MarketplaceUpdate.isPreservedMarketplaceRuntimeName(name) else { continue }
            try fileManager.removeItem(at: existingURL)
        }
        try await MarketplaceCatalog.installPluginFiles(
            pluginID: pluginID,
            targetDir: targetDir,
            entry: entry,
            context: context,
            overwrite: true,
            allowScaffold: false
        )
    }
}
