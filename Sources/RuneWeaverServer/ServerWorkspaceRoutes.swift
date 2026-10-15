// Rune Weaver Server — Agent scratch workspace routes.
//
// Purpose: exposes the bounded `workspace/` scratch tree over HTTP so
// dashboards manage automation without shell access: usage with quotas,
// age-based `tmp/` pruning, and container machine lifecycle controls.
// Scope: route registration and request validation only;
// quotas stay with WorkspaceStore.
// Architectural role: thin Vapor adapter over the Core stores mirroring the
// goal route idioms (strict UUID checks, honest status codes, no
// route-specific auth).

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Registers every workspace route on the application.
///
/// Global middleware already guards data paths, so no route installs its own
/// auth.
/// - Parameter app: Application receiving the routes.
func registerWorkspaceRoutes(_ app: Application) {
    registerWorkspaceUsageRoute(app)
    registerWorkspacePruneRoute(app)
    registerWorkspaceMachineStatusRoute(app)
    registerWorkspaceMachineStopRoute(app)
    registerWorkspaceMachineRecycleRoute(app)
}

// MARK: - Workspace

/// Reports bounded scratch usage with quotas for dashboard bars.
///
/// A missing workspace reads as an empty snapshot rather than an error, so a
/// fresh install renders an honest empty state; a walk failure stays a 500
/// instead of masquerading as empty.
/// - Parameter app: Application receiving the route.
private func registerWorkspaceUsageRoute(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.workspace),
        PathComponent.constant(ServerPaths.workspaceUsage)
    ) { req async throws -> WorkspaceUsageResponse in
        let context = req.application.runeWeaver
        let store = context.workspaceStore
        let usage: WorkspaceUsage
        do {
            usage = try await store.usage()
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        let limits = await store.config.clamped()
        return WorkspaceUsageResponse(
            bytes: usage.bytes,
            files: usage.files,
            truncated: usage.truncated,
            quotaMB: limits.quotaMB,
            quotaFiles: limits.quotaFiles
        )
    }
}

/// Clears expired `tmp/` entries for dashboards.
///
/// Missing `tmp/` is a zero removal rather than an error, because a fresh
/// workspace has nothing to prune; a store failure stays a 500.
/// - Parameter app: Application receiving the route.
private func registerWorkspacePruneRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.workspace),
        PathComponent.constant(ServerPaths.workspaceTmp),
        PathComponent.constant(ServerPaths.workspacePrune)
    ) { req async throws -> WorkspacePruneResponse in
        let context = req.application.runeWeaver
        do {
            let removed = try await context.workspaceStore.pruneTmp()
            return WorkspacePruneResponse(removed: removed)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
    }
}

// MARK: - Workspace machine

/// Reports machine lifecycle state for dashboard control.
///
/// A missing machine reads as exists false rather than an error, so a fresh
/// install renders an honest empty state.
/// - Parameter app: Application receiving the route.
private func registerWorkspaceMachineStatusRoute(_ app: Application) {
    app.get(
        PathComponent.constant(ServerPaths.workspace),
        PathComponent.constant(ServerPaths.workspaceMachine)
    ) { req async -> WorkspaceMachineResponse in
        let context = req.application.runeWeaver
        let root = await context.workspaceStore.root()
        let networkDenied = !context.bashConfig.allowNetwork
        let status = await MachineScopedRunner.machineStatus(workspaceRoot: root, networkDenied: networkDenied)
        return WorkspaceMachineResponse(
            exists: status.exists,
            running: status.running,
            image: status.image,
            configMatch: status.configMatch
        )
    }
}

/// Stops the machine container without removing it.
///
/// The entry stays listed so the next ensure restarts it without recreating;
/// a missing machine reports exists false after the best-effort halt.
/// - Parameter app: Application receiving the route.
private func registerWorkspaceMachineStopRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.workspace),
        PathComponent.constant(ServerPaths.workspaceMachine),
        PathComponent.constant(ServerPaths.workspaceMachineStop)
    ) { req async -> WorkspaceMachineResponse in
        await MachineScopedRunner.stopMachine()
        let context = req.application.runeWeaver
        let root = await context.workspaceStore.root()
        let networkDenied = !context.bashConfig.allowNetwork
        let status = await MachineScopedRunner.machineStatus(workspaceRoot: root, networkDenied: networkDenied)
        return WorkspaceMachineResponse(
            exists: status.exists,
            running: status.running,
            image: status.image,
            configMatch: status.configMatch
        )
    }
}

/// Stops plus removes the machine container so the next ensure recreates it.
///
/// Removal follows the halt so a running entry never half-deletes; a missing
/// machine reports exists false after the best-effort remove.
/// - Parameter app: Application receiving the route.
private func registerWorkspaceMachineRecycleRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.workspace),
        PathComponent.constant(ServerPaths.workspaceMachine),
        PathComponent.constant(ServerPaths.workspaceMachineRecycle)
    ) { req async -> WorkspaceMachineResponse in
        await MachineScopedRunner.recycleMachine()
        let context = req.application.runeWeaver
        let root = await context.workspaceStore.root()
        let networkDenied = !context.bashConfig.allowNetwork
        let status = await MachineScopedRunner.machineStatus(workspaceRoot: root, networkDenied: networkDenied)
        return WorkspaceMachineResponse(
            exists: status.exists,
            running: status.running,
            image: status.image,
            configMatch: status.configMatch
        )
    }
}
