// Rune Weaver Server — Marketplace update rollback and request handling.

import Foundation
import RuneWeaverCore
import Vapor

/// Rollback plus request entry split from the update core.
extension MarketplaceUpdate {
    /// Restores backup and staged runtime after a failed update.
    /// Rollback is authoritative on Plan flags captured at preserve time.
    static func rollbackMarketplaceUpdate(plan: Plan) {
        let fileManager = FileManager.default
        // Staging stays gated on Plan flags so unpreserved partials never promote.
        // Backup holds payload only, so staged venv plus session cache merge back after restore.
        MarketplaceUpdate.stageAsideRollbackRuntime(plan: plan)
        MarketplaceUpdate.clearRollbackPayloadOnly(plan: plan)
        do {
            if fileManager.fileExists(atPath: plan.backupDir.path) {
                if fileManager.fileExists(atPath: plan.targetDir.path) {
                    // Target stays in place so staged runtime is never deleted wholesale.
                    let backupItems = try fileManager.contentsOfDirectory(at: plan.backupDir, includingPropertiesForKeys: nil, options: [])
                    for item in backupItems {
                        let destination = plan.targetDir.appendingPathComponent(item.lastPathComponent)
                        if fileManager.fileExists(atPath: destination.path) {
                            try fileManager.removeItem(at: destination)
                        }
                        try fileManager.moveItem(at: item, to: destination)
                    }
                    try fileManager.removeItem(at: plan.backupDir)
                } else {
                    try fileManager.moveItem(at: plan.backupDir, to: plan.targetDir)
                }
            }
        } catch {
            // Keep backup for manual recovery; it is the only rollback artifact.
            let detail = "Failed restoring plugin backup for '\(plan.pluginID)' at \(plan.targetDir.path):"
            RuneWeaverLog.server.warning(
                "\(detail) \(error.localizedDescription). Backup kept at \(plan.backupDir.path)."
            )
        }
        MarketplaceUpdate.restoreStagedRuntime(
            pluginID: plan.pluginID,
            targetDir: plan.targetDir,
            venvStaging: plan.venvStaging,
            mmStaging: plan.mmStaging,
            preservedVenv: plan.preservedVenv,
            preservedMM: plan.preservedMM
        )
    }

    /// Clears payload files while staged runtime stays aside on disk.
    static func clearRollbackPayloadOnly(plan: Plan) {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: plan.targetDir, includingPropertiesForKeys: nil, options: [])) ?? []
        // Payload-only clear skips staged-aside names so a missed stage never deletes venv.
        for item in items {
            let name = item.lastPathComponent
            guard !MarketplaceUpdate.isPreservedMarketplaceRuntimeName(name) else { continue }
            do {
                try fileManager.removeItem(at: item)
            } catch {
                RuneWeaverLog.server.warning(
                    "Failed removing partial update at \(item.path): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Stages one live runtime aside, keeping staged originals across provision failure.
    /// Unpreserved live partials are discarded so they never promote to staging.
    static func stageAsideOneRuntime(liveDir: URL, staging: URL, pluginID: String, label: String, preserved: Bool) {
        let fileManager = FileManager.default
        guard preserved else {
            // No original was staged, so live plus stray staging are partials.
            if fileManager.fileExists(atPath: liveDir.path) {
                do {
                    try fileManager.removeItem(at: liveDir)
                } catch {
                    RuneWeaverLog.server.warning("Failed clearing partial \(label) for '\(pluginID)' rollback: \(error.localizedDescription).")
                }
            }
            if fileManager.fileExists(atPath: staging.path) {
                do {
                    try fileManager.removeItem(at: staging)
                } catch {
                    RuneWeaverLog.server.warning("Failed clearing stray \(label) staging for '\(pluginID)' rollback: \(error.localizedDescription).")
                }
            }
            return
        }
        // UUID-scoped staging holds the pre-update copy when restore never ran.
        if fileManager.fileExists(atPath: staging.path) {
            // Keep staged original; drop the live partial so rollback restores it.
            if fileManager.fileExists(atPath: liveDir.path) {
                do {
                    try fileManager.removeItem(at: liveDir)
                } catch {
                    RuneWeaverLog.server.warning("Failed clearing partial \(label) for '\(pluginID)' rollback: \(error.localizedDescription).")
                }
            }
            return
        }
        if fileManager.fileExists(atPath: liveDir.path) {
            do {
                try fileManager.moveItem(at: liveDir, to: staging)
            } catch {
                RuneWeaverLog.server.warning("Failed staging \(label) aside for '\(pluginID)' rollback: \(error.localizedDescription).")
            }
        }
    }

    /// Stages live venv plus session cache aside so target clearing never deletes them.
    /// Staging is gated on Plan flags so unpreserved partials never promote.
    static func stageAsideRollbackRuntime(plan: Plan) {
        let liveVenvDir = plan.targetDir.appendingPathComponent(".venv")
        let liveMMDir = plan.targetDir.appendingPathComponent(".mm")
        // Staged originals take precedence over live partials, so failed provisioning keeps them.
        MarketplaceUpdate.stageAsideOneRuntime(
            liveDir: liveVenvDir,
            staging: plan.venvStaging,
            pluginID: plan.pluginID,
            label: "venv",
            preserved: plan.preservedVenv
        )
        MarketplaceUpdate.stageAsideOneRuntime(
            liveDir: liveMMDir,
            staging: plan.mmStaging,
            pluginID: plan.pluginID,
            label: "session cache",
            preserved: plan.preservedMM
        )
    }

    /// Returns staged runtime when preserved; discards stray staging otherwise.
    static func restoreStagedRuntime(
        pluginID: String,
        targetDir: URL,
        venvStaging: URL,
        mmStaging: URL,
        preservedVenv: Bool,
        preservedMM: Bool
    ) {
        let fileManager = FileManager.default
        if preservedVenv {
            if fileManager.fileExists(atPath: venvStaging.path) {
                do {
                    let restoredVenvDir = targetDir.appendingPathComponent(".venv")
                    if fileManager.fileExists(atPath: restoredVenvDir.path) {
                        try fileManager.removeItem(at: restoredVenvDir)
                    }
                    if fileManager.fileExists(atPath: targetDir.path) {
                        try fileManager.moveItem(at: venvStaging, to: restoredVenvDir)
                    } else {
                        // Missing target must not strand staging; drop it with a warning.
                        RuneWeaverLog.server.warning(
                            "Target missing for '\(pluginID)' rollback; dropping venv staging at \(venvStaging.path)."
                        )
                        try fileManager.removeItem(at: venvStaging)
                    }
                } catch {
                    let prefix = "Failed restoring preserved venv for '\(pluginID)':"
                    RuneWeaverLog.server.warning(
                        "\(prefix) \(error.localizedDescription). Staging kept at \(venvStaging.path)."
                    )
                }
            }
        } else if fileManager.fileExists(atPath: venvStaging.path) {
            // No original to return; drop stray staging so partials never promote.
            do {
                try fileManager.removeItem(at: venvStaging)
            } catch {
                RuneWeaverLog.server.warning("Failed dropping stray venv staging for '\(pluginID)' rollback: \(error.localizedDescription).")
            }
        }
        if preservedMM {
            if fileManager.fileExists(atPath: mmStaging.path) {
                do {
                    let restoredMMDir = targetDir.appendingPathComponent(".mm")
                    if fileManager.fileExists(atPath: restoredMMDir.path) {
                        try fileManager.removeItem(at: restoredMMDir)
                    }
                    if fileManager.fileExists(atPath: targetDir.path) {
                        try fileManager.moveItem(at: mmStaging, to: restoredMMDir)
                    } else {
                        // Missing target must not strand staging; drop it with a warning.
                        RuneWeaverLog.server.warning(
                            "Target missing for '\(pluginID)' rollback; dropping session staging at \(mmStaging.path)."
                        )
                        try fileManager.removeItem(at: mmStaging)
                    }
                } catch {
                    let prefix = "Failed restoring preserved session cache for '\(pluginID)':"
                    RuneWeaverLog.server.warning(
                        "\(prefix) \(error.localizedDescription). Staging kept at \(mmStaging.path)."
                    )
                }
            }
        } else if fileManager.fileExists(atPath: mmStaging.path) {
            // No original to return; drop stray staging so partials never promote.
            do {
                try fileManager.removeItem(at: mmStaging)
            } catch {
                RuneWeaverLog.server.warning("Failed dropping stray session staging for '\(pluginID)' rollback: \(error.localizedDescription).")
            }
        }
    }

    /// POST /marketplace/update
    static func handleUpdateMarketplacePlugin(req: Request) async throws -> PluginSummary {
        let body = try req.content.decode(UpdateMarketplacePluginRequest.self)
        let context = req.application.runeWeaver
        let pluginID = try MarketplaceUpdate.validatedMarketplaceUpdateID(body.id)
        guard let installedRecord = await context.pluginStore.get(id: pluginID) else {
            throw Abort(.notFound, reason: "Plugin '\(pluginID)' is not installed.")
        }
        let pluginsDir = context.pluginDiscovery.pluginsDirectory
        let targetDir = try MarketplaceUpdate.marketplaceUpdateTargetDir(pluginID: pluginID, pluginsDir: pluginsDir)
        guard FileManager.default.fileExists(atPath: targetDir.path) else {
            throw Abort(.notFound, reason: "Plugin directory does not exist.")
        }
        let entry = try await MarketplaceUpdate.marketplaceUpdateEntry(pluginID: pluginID, installedVersion: installedRecord.version, context: context)
        // Hash live payload before copying so the backup read never repeats it.
        let oldHash = MarketplaceCatalog.requirementsSHA256(at: targetDir)
        let backupDir = try MarketplaceUpdate.stageMarketplaceUpdateBackup(pluginID: pluginID, targetDir: targetDir, pluginsDir: pluginsDir)
        let suffix = UUID().uuidString
        let newHash = await MarketplaceCatalog.catalogRequirementsSHA(for: pluginID, entry: entry)
        var plan = Plan(
            pluginID: pluginID,
            targetDir: targetDir,
            backupDir: backupDir,
            venvStaging: pluginsDir.appendingPathComponent(".\(pluginID).venv-staging-\(suffix)"),
            mmStaging: pluginsDir.appendingPathComponent(".\(pluginID).mm-staging-\(suffix)"),
            entry: entry,
            oldHash: oldHash,
            newHash: newHash
        )
        // Capture staging flags at preserve time so rollback stays authoritative.
        do {
            let preserved = try MarketplaceUpdate.preserveMarketplaceRuntime(
                targetDir: plan.targetDir,
                venvStaging: plan.venvStaging,
                mmStaging: plan.mmStaging
            )
            plan.preservedVenv = preserved.preservedVenv
            plan.preservedMM = preserved.preservedMM
        } catch {
            // Preserve never touches payload, so return staged copies when live is gone.
            let fileManager = FileManager.default
            let liveVenv = plan.targetDir.appendingPathComponent(".venv")
            let liveMM = plan.targetDir.appendingPathComponent(".mm")
            if fileManager.fileExists(atPath: plan.venvStaging.path), !fileManager.fileExists(atPath: liveVenv.path) {
                try? fileManager.moveItem(at: plan.venvStaging, to: liveVenv)
            }
            if fileManager.fileExists(atPath: plan.mmStaging.path), !fileManager.fileExists(atPath: liveMM.path) {
                try? fileManager.moveItem(at: plan.mmStaging, to: liveMM)
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw Abort(.internalServerError, reason: "Failed to preserve plugin runtime for '\(pluginID)': \(error.localizedDescription)")
        }
        do {
            try Task.checkCancellation()
            try await MarketplaceUpdate.applyMarketplaceUpdateFiles(plan: plan, context: context)
            try Task.checkCancellation()
            return try await MarketplaceUpdate.finalizeMarketplaceUpdate(plan: plan, context: context)
        } catch is CancellationError {
            MarketplaceUpdate.rollbackMarketplaceUpdate(plan: plan)
            throw CancellationError()
        } catch let abort as Abort {
            MarketplaceUpdate.rollbackMarketplaceUpdate(plan: plan)
            throw abort
        } catch {
            // Cancellation outranks mapping so cooperative cancels never surface as 500s.
            if Task.isCancelled {
                MarketplaceUpdate.rollbackMarketplaceUpdate(plan: plan)
                throw CancellationError()
            }
            let updateError = error
            MarketplaceUpdate.rollbackMarketplaceUpdate(plan: plan)
            throw Abort(.internalServerError, reason: "Failed to update plugin '\(pluginID)': \(updateError.localizedDescription)")
        }
    }
}
