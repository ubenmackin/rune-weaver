// Rune Weaver Server — Agent scratch workspace plus hash-pinned script registry routes.
//
// Purpose: exposes the bounded `workspace/` scratch tree and the `agent-tools`
// promotion registry over HTTP so dashboards manage automation without shell
// access: usage with quotas, age-based `tmp/` pruning, listing with pins,
// promotion confined to `workspace/tools/`, explicit enable/disable, removal,
// and verified single-flight execution.
// Scope: route registration, request validation, and run contention only;
// pinning and hashing stay with AgentToolStore, shell dispatch stays with
// BashTool, and quotas stay with WorkspaceStore.
// Architectural role: thin Vapor adapter over the Core stores mirroring the
// goal route idioms (strict UUID checks, honest status codes, no
// route-specific auth) while keeping every promotion observable from one
// registry the CLI shares.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor

/// Registers every workspace plus agent-tool route on the application.
///
/// Global middleware already guards data paths, so no route installs its own
/// auth; the `promote` and `run` literals register as exact segments so they
/// win over the `:id` parameter without relying on registration order.
/// - Parameter app: Application receiving the routes.
func registerWorkspaceRoutes(_ app: Application) {
    registerWorkspaceUsageRoute(app)
    registerWorkspacePruneRoute(app)
    registerAgentToolListRoute(app)
    registerAgentToolPromoteRoute(app)
    registerAgentToolPatchRoute(app)
    registerAgentToolDeleteRoute(app)
    registerAgentToolRunRoute(app)
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

// MARK: - Agent tools listing + promotion

/// Lists every pinned script ordered by name for stable rendering.
/// - Parameter app: Application receiving the route.
private func registerAgentToolListRoute(_ app: Application) {
    app.get(PathComponent.constant(ServerPaths.agentTools)) { req async throws -> AgentToolsResponse in
        let context = req.application.runeWeaver
        do {
            let records = try await context.agentTools.list()
            return AgentToolsResponse(tools: records.map(AgentToolDTO.init))
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
    }
}

/// Promotes a `workspace/tools/` script, pinning its exact bytes.
///
/// Every present field validates before any row writes so a bad name never
/// half-pins a path; store-typed refusals (outside workspace, missing file)
/// surface as 400 with the honest reason, while transport failures stay 500.
/// - Parameter app: Application receiving the route.
private func registerAgentToolPromoteRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.agentTools),
        PathComponent.constant(ServerPaths.agentToolsPromote)
    ) { req async throws -> AgentToolDTO in
        let body = try req.content.decode(PromoteAgentToolRequest.self)
        guard let name = body.resolvedName else {
            throw Abort(.badRequest, reason: "name must not be empty")
        }
        guard let scriptPath = body.resolvedScriptPath else {
            throw Abort(.badRequest, reason: "script_path must not be empty. Only scripts inside workspace/tools/ can be promoted.")
        }
        let context = req.application.runeWeaver
        do {
            let record = try await context.agentTools.promote(name: name, scriptPath: scriptPath)
            return AgentToolDTO(record)
        } catch let error as AgentToolStoreError {
            throw mapAgentToolStoreError(error)
        }
    }
}

// MARK: - Agent tool enable/disable + removal

/// Enables or disables one pinned script by identifier.
///
/// The body accepts `status`, `enabled`, or `action` spellings so dashboard
/// toggles and hand-built curls converge; nothing usable is a 400, unknown
/// rows are a 404, and the updated row returns so the viewer patches one row
/// instead of refetching the list.
/// - Parameter app: Application receiving the route.
private func registerAgentToolPatchRoute(_ app: Application) {
    app.patch(PathComponent.constant(ServerPaths.agentTools), PathComponent.parameter("id")) { req async throws -> AgentToolDTO in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(PatchAgentToolRequest.self)
        guard let status = body.resolvedStatus else {
            throw Abort(.badRequest, reason: "Provide status 'enabled'/'disabled', enabled true/false, or action 'enable'/'disable'.")
        }
        let context = req.application.runeWeaver
        do {
            let updated = try await context.agentTools.setStatus(id: id, status: status)
            return AgentToolDTO(updated)
        } catch let error as AgentToolStoreError {
            throw mapAgentToolStoreError(error, raw: raw)
        }
    }
}

/// Removes one pinned row by identifier.
///
/// The removal itself is the existence check: a `false` return maps to 404
/// so concurrent deletes converge explicitly instead of trusting a
/// check-then-act pre-read; success answers 204 with no body.
/// - Parameter app: Application receiving the route.
private func registerAgentToolDeleteRoute(_ app: Application) {
    app.delete(PathComponent.constant(ServerPaths.agentTools), PathComponent.parameter("id")) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        let removed: Bool
        do {
            removed = try await context.agentTools.remove(id: id)
        } catch let error as AgentToolStoreError {
            throw mapAgentToolStoreError(error, raw: raw)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        guard removed else {
            throw Abort(.notFound, reason: "Unknown agent tool \(raw)")
        }
        return .noContent
    }
}

// MARK: - Agent tool verified run

/// Runs one pinned script with literal argv under a single-flight lock.
///
/// The lock mirrors the goal-advance contention path: a second run while one
/// is in flight answers 409 instead of stacking shells. The lock is held
/// across verify plus spawn, and verification stages the exact verified bytes
/// to an immutable temp copy that the shell executes, so a concurrent
/// `bash.exec` write to `workspace/tools/` after verification cannot swap
/// bytes under the running shell; a changed script flips disabled and answers
/// 400 instead of executing, and a disabled row answers 400 without spawning.
/// - Parameter app: Application receiving the route.
private func registerAgentToolRunRoute(_ app: Application) {
    app.post(
        PathComponent.constant(ServerPaths.agentTools),
        PathComponent.parameter("id"),
        PathComponent.constant(ServerPaths.agentToolsRun)
    ) { req async throws -> ToolResult in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(RunAgentToolRequest.self)
        let argv = body.resolvedArgv
        guard argv.count <= RunAgentTool.maxArgvCount else {
            throw Abort(.badRequest, reason: "argv carries at most \(RunAgentTool.maxArgvCount) entries (got \(argv.count))")
        }
        let context = req.application.runeWeaver
        let record: AgentToolRecord?
        do {
            record = try await context.agentTools.get(id: id)
        } catch let error as AgentToolStoreError {
            throw mapAgentToolStoreError(error, raw: raw)
        } catch {
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        guard let record else {
            throw Abort(.notFound, reason: "Unknown agent tool \(raw)")
        }
        // Single-flight first: the lock is held across verify plus spawn so a
        // concurrent run cannot interleave verify and spawn, mirroring the
        // goal-advance contention path.
        guard await context.agentRunLock.tryAcquire(id: record.id) else {
            throw Abort(.conflict, reason: "Agent tool \(raw) is already running")
        }
        // Verification stages the exact verified bytes to an immutable temp
        // copy; the shell executes the copy, never the workspace original, so
        // a concurrent `bash.exec` write to `workspace/tools/` after the hash
        // check cannot swap bytes under the running shell.
        let staged: StagedAgentTool
        do {
            staged = try await context.agentTools.verifyAndStage(name: record.name)
        } catch let error as AgentToolStoreError {
            await context.agentRunLock.release(id: record.id)
            throw mapAgentToolStoreError(error, raw: raw)
        } catch {
            await context.agentRunLock.release(id: record.id)
            throw Abort(.internalServerError, reason: error.localizedDescription)
        }
        let verified = staged.record
        let stagedURL = staged.stagedURL
        // Disabled rows fail without spawning: the pin may still match, but
        // the owner parked the capability and only an explicit PATCH may lift it.
        guard verified.status == .enabled else {
            AgentToolStore.removeStagedCopy(at: stagedURL)
            await context.agentRunLock.release(id: verified.id)
            throw Abort(.badRequest, reason: "Agent tool '\(verified.name)' is disabled. Re-enable it after review before running.")
        }
        // The lock stays held across verify plus spawn: this call executes the
        // staged copy while holding the slot, then releases it on every path.
        return try await executeStagedAgentTool(staged: staged, argv: argv, context: context)
    }
}

/// Executes one staged script with literal argv under the single-flight lock.
///
/// The staged copy (never the workspace original) rides the command so the
/// bytes the shell maps are exactly the bytes that matched the pin. Every
/// terminal path releases the lock and removes the staged copy before
/// answering, so the next acquire never observes a stale held lock and
/// verified bytes never accumulate in system temp.
/// - Parameters:
///   - staged: Verified record plus its immutable staged copy.
///   - argv: Caller arguments appended after `--` as literal argv.
///   - context: Server context owning the shell bus, workspace, and run lock.
/// - Returns: Shell tool result for the staged execution.
private func executeStagedAgentTool(staged: StagedAgentTool, argv: [String], context: ServerContext) async throws -> ToolResult {
    let verified = staged.record
    let stagedURL = staged.stagedURL
    // Every terminal path below releases the lock and removes the staged
    // copy before answering, so the next acquire never observes a stale
    // held lock and verified bytes never accumulate in system temp;
    // throwing paths release plus remove first instead of relying on a
    // detached task that could race the next request.
    do {
        guard let bash = await context.toolBus.tool(named: "bash.exec") as? BashTool else {
            AgentToolStore.removeStagedCopy(at: stagedURL)
            await context.agentRunLock.release(id: verified.id)
            throw Abort(.internalServerError, reason: "Shell execution is unavailable.")
        }
        let toolsDir = await context.workspaceStore.root().appendingPathComponent(AgentToolStore.toolsDirectoryName)
        // Defense in depth single-sourced with promotion and `tool.run`:
        // the check resolves symlinks, so a moved or symlinked root after
        // promotion still refuses instead of spawning outside `tools/`.
        guard AgentToolStore.isContainedInTools(scriptPath: verified.scriptPath, toolsDir: toolsDir) else {
            AgentToolStore.removeStagedCopy(at: stagedURL)
            await context.agentRunLock.release(id: verified.id)
            throw Abort(.badRequest, reason: "Agent tool '\(verified.name)' points outside workspace/tools/ and will not run.")
        }
        // The staged copy (not the workspace original) rides the command
        // so the bytes the shell maps are exactly the bytes that matched
        // the pin. Construction is single-sourced with `tool.run` so both
        // agree byte-for-byte on quoting plus argv handling.
        let bashJSON: String
        do {
            bashJSON = try AgentToolStaging.bashInput(stagedURL: stagedURL, argv: argv, cwd: toolsDir.path)
        } catch {
            AgentToolStore.removeStagedCopy(at: stagedURL)
            await context.agentRunLock.release(id: verified.id)
            throw Abort(.internalServerError, reason: "Could not encode agent tool command.")
        }
        // REST runs are owner-authenticated service writes, so they execute
        // with the approved flag rather than parking in the approvals inbox
        // like an interactive model turn would.
        let bashCallID = UUID().uuidString
        let output: ToolOutput
        do {
            output = try await bash.execute(
                input: ToolInput(toolName: bash.name, argumentsJSON: bashJSON, callID: bashCallID),
                context: ToolContext(conversationID: UUID(), approved: true)
            )
        } catch is CancellationError {
            AgentToolStore.removeStagedCopy(at: stagedURL)
            await context.agentRunLock.release(id: verified.id)
            throw CancellationError()
        } catch {
            AgentToolStore.removeStagedCopy(at: stagedURL)
            await context.agentRunLock.release(id: verified.id)
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
        AgentToolStore.removeStagedCopy(at: stagedURL)
        await context.agentRunLock.release(id: verified.id)
        return ToolResult(output, toolCallID: bashCallID)
    } catch let abort as Abort {
        // The lock is already released and the staged copy removed on every
        // throwing path above, but a future edit adding a new throw must
        // not strand either: both cleanups are idempotent, so repeating
        // them here only guarantees cleanup.
        AgentToolStore.removeStagedCopy(at: stagedURL)
        await context.agentRunLock.release(id: verified.id)
        throw abort
    } catch is CancellationError {
        AgentToolStore.removeStagedCopy(at: stagedURL)
        await context.agentRunLock.release(id: verified.id)
        throw CancellationError()
    } catch {
        AgentToolStore.removeStagedCopy(at: stagedURL)
        await context.agentRunLock.release(id: verified.id)
        throw error
    }
}

// MARK: - Error mapping

/// Maps store failures to HTTP codes without leaking driver detail.
///
/// Unknown rows become 404, caller-shaped refusals (name, workspace, missing
/// file, tamper, disabled) become 400 with the honest reason, and transport
/// failures stay 500.
/// - Parameters:
///   - error: Store failure.
///   - raw: Raw identifier for the not-found message.
/// - Returns: Abort with the mapped status.
private func mapAgentToolStoreError(_ error: AgentToolStoreError, raw: String = "") -> Abort {
    switch error {
    case let .notFound(detail):
        Abort(.notFound, reason: detail.isEmpty ? "Unknown agent tool \(raw)" : detail)
    case let .invalidName(detail),
         let .outsideWorkspace(detail),
         let .fileMissing(detail),
         let .unreadable(detail),
         let .tampered(detail),
         let .disabled(detail):
        Abort(.badRequest, reason: detail)
    case let .storeUnavailable(detail),
         let .persistenceFailed(detail):
        Abort(.internalServerError, reason: detail)
    }
}
