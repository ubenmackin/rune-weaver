// Rune Weaver Server — Marketplace update venv reuse and finalization.

import Foundation
import RuneWeaverCore
import Vapor

/// Venv plus finalize split from the update core so each body stays scannable.
extension MarketplaceUpdate {
    /// Returns staged runtime and session cache before the venv decision.
    static func restorePreservedMarketplaceRuntime(
        targetDir: URL,
        venvStaging: URL,
        mmStaging: URL,
        preservedVenv: Bool,
        preservedMM: Bool
    ) throws {
        let fileManager = FileManager.default
        if preservedVenv {
            let restoredVenvDir = targetDir.appendingPathComponent(".venv")
            if fileManager.fileExists(atPath: restoredVenvDir.path) {
                try fileManager.removeItem(at: restoredVenvDir)
            }
            try fileManager.moveItem(at: venvStaging, to: restoredVenvDir)
        }
        if preservedMM {
            let restoredMMDir = targetDir.appendingPathComponent(".mm")
            if fileManager.fileExists(atPath: restoredMMDir.path) {
                try fileManager.removeItem(at: restoredMMDir)
            }
            try fileManager.moveItem(at: mmStaging, to: restoredMMDir)
        }
    }

    /// Reuses the preserved venv unless the lockfile changed.
    /// Staging stays on disk until provisioning succeeds so a failed pip keeps the original.
    static func ensureMarketplaceUpdateVenv(
        targetDir: URL,
        oldHash: String?,
        newHash: String?,
        venvStaging: URL,
        preservedVenv: Bool,
        context: ServerContext
    ) async throws {
        try Task.checkCancellation()
        // Hermetic suites skip provisioning; the caller restores staging directly.
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else { return }
        let fileManager = FileManager.default
        let targetPython = targetDir.appendingPathComponent(".venv/bin/python3")
        let stagedPython = venvStaging.appendingPathComponent("bin/python3")
        // Fail closed on missing hashes so unknown requirements always reprovision.
        let unchanged = oldHash != nil && oldHash == newHash
        // Executable bit alone decides reuse so a corrupt non-executable python never counts.
        let targetUsable = fileManager.isExecutableFile(atPath: targetPython.path)
        let stagedUsable = preservedVenv && fileManager.isExecutableFile(atPath: stagedPython.path)
        // Reuse when hashes match and a usable venv sits in target or staging.
        if unchanged, targetUsable || stagedUsable {
            try Task.checkCancellation()
            return
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        let requirementsPath = targetDir.appendingPathComponent("requirements.txt").path
        if fileManager.fileExists(atPath: requirementsPath) {
            do {
                try await context.pluginDiscovery.provisionVenvIfNeeded(at: targetDir, forceRecreate: !unchanged)
            } catch is CancellationError {
                throw CancellationError()
            }
        } else {
            // Dropped requirements orphan the live venv; staged original stays for rollback.
            // Staged original leaves only in finalize after version plus sync succeed.
            let liveVenv = targetDir.appendingPathComponent(".venv")
            if fileManager.fileExists(atPath: liveVenv.path) {
                do {
                    try fileManager.removeItem(at: liveVenv)
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let detail = "Failed to remove orphaned virtual environment at \(liveVenv.path):"
                    throw Abort(.internalServerError, reason: "\(detail) \(error.localizedDescription)")
                }
            }
        }
        try Task.checkCancellation()
    }

    /// Records the new hash, syncs the bus, and returns the updated summary.
    static func finalizeMarketplaceUpdate(plan: Plan, context: ServerContext) async throws -> PluginSummary {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        guard let newHash = PluginSecurity.calculateDirectoryHash(at: plan.targetDir) else {
            throw Abort(.internalServerError, reason: "Failed to calculate plugin integrity hash.")
        }
        let manifestFile = plan.targetDir.appendingPathComponent("rune.json")
        // Bounded manifest read keeps a swapped symlink or oversized file from stalling the update.
        guard let manifestValues = try? manifestFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true,
              let manifestAttrs = try? FileManager.default.attributesOfItem(atPath: manifestFile.path),
              let manifestSize = manifestAttrs[.size] as? NSNumber,
              manifestSize.int64Value <= MarketplaceCatalog.pluginFileMaxBytes,
              let manifestData = PluginSecurity.secureCappedFileData(
                  at: manifestFile,
                  maxBytes: MarketplaceCatalog.pluginFileMaxBytes
              ),
              manifestData.count <= MarketplaceCatalog.pluginFileMaxBytes
        else {
            throw Abort(.internalServerError, reason: "Failed to read updated plugin manifest.")
        }
        let updatedManifest = try PluginManifest.from(jsonData: manifestData)
        guard let updated = await context.pluginStore.setVersion(id: plan.pluginID, version: updatedManifest.version, integrityHash: newHash) else {
            throw Abort(.internalServerError, reason: "Failed to update plugin record.")
        }
        await context.pluginDiscovery.discoverAndSync(toolBus: context.toolBus)
        let summary = await makePluginSummary(record: updated, manifest: updatedManifest, context: context, catalogEntry: plan.entry)
        do {
            try fileManager.removeItem(at: plan.backupDir)
        } catch {
            RuneWeaverLog.server.warning("Failed removing marketplace backup at \(plan.backupDir.path): \(error.localizedDescription)")
        }
        // Staged original plus orphan leave only after version plus sync succeed.
        if fileManager.fileExists(atPath: plan.venvStaging.path) {
            do {
                try fileManager.removeItem(at: plan.venvStaging)
            } catch {
                RuneWeaverLog.server.warning("Failed removing venv staging at \(plan.venvStaging.path): \(error.localizedDescription)")
            }
        }
        if fileManager.fileExists(atPath: plan.mmStaging.path) {
            do {
                try fileManager.removeItem(at: plan.mmStaging)
            } catch {
                RuneWeaverLog.server.warning("Failed removing session staging at \(plan.mmStaging.path): \(error.localizedDescription)")
            }
        }
        return summary
    }

    /// Applies file replacement plus venv reuse for a validated update.
    /// Plan flags come from preserve time; staging stays aside through failure.
    static func applyMarketplaceUpdateFiles(plan: Plan, context: ServerContext) async throws {
        try Task.checkCancellation()
        try await MarketplaceUpdate.clearTargetAndInstallUpdate(pluginID: plan.pluginID, targetDir: plan.targetDir, entry: plan.entry, context: context)
        try Task.checkCancellation()
        do {
            try await MarketplaceUpdate.ensureMarketplaceUpdateVenv(
                targetDir: plan.targetDir,
                oldHash: plan.oldHash,
                newHash: plan.newHash,
                venvStaging: plan.venvStaging,
                preservedVenv: plan.preservedVenv,
                context: context
            )
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()
        // Session cache always returns; venv returns only when the lockfile is unchanged.
        // Executable bit alone decides reuse so corrupt staging never restores.
        let isHermetic = ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] == "1"
        let stagedPythonURL = plan.venvStaging.appendingPathComponent("bin/python3")
        let stagedUsable = plan.preservedVenv
            && FileManager.default.isExecutableFile(atPath: stagedPythonURL.path)
        let reuseVenv: Bool = if isHermetic {
            // Hermetic suites never provision, so staged venv always returns.
            plan.preservedVenv
        } else {
            plan.oldHash != nil && plan.oldHash == plan.newHash && stagedUsable
        }
        try MarketplaceUpdate.restorePreservedMarketplaceRuntime(
            targetDir: plan.targetDir,
            venvStaging: plan.venvStaging,
            mmStaging: plan.mmStaging,
            preservedVenv: reuseVenv,
            preservedMM: plan.preservedMM
        )
    }
}
