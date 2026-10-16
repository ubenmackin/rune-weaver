// Rune Weaver Tools — Container backends for sandboxed bash execution.

import Foundation
import RuneWeaverCore

extension BashTool {
    /// Runs one command in the session strict container.
    func runStrictContainer(
        command: String,
        timeoutSeconds: TimeInterval,
        effectiveAllowNetwork: Bool,
        context: ToolContext,
        decision: BashDecision,
        callID: String,
        requestedCwd: URL? = nil
    ) async throws -> ToolOutput {
        let runtime = effectiveContainerRuntime
        let registry = effectiveStrictRegistry
        guard runtime.resolveRuntimeURL() != nil else {
            return missingRuntimeDenied(command: command, decision: decision, callID: callID)
        }
        do {
            try runtime.probe()
        } catch {
            let message = error.localizedDescription
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: message,
                reason: message
            )
            return .failure(Self.encodeEnvelope(envelope), callID: callID)
        }
        let workspace = effectiveWorkspaceStore
        let ensuredRoot: URL
        do {
            ensuredRoot = try await workspace.ensure()
        } catch {
            let message = (error as? WorkspaceError).map(\.reason) ?? error.localizedDescription
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: message,
                reason: message
            )
            return .failure(Self.encodeEnvelope(envelope), callID: callID)
        }
        let workspaceTmp = BashSandboxRouter.workspaceTmpURL(for: ensuredRoot)
        let entry: StrictTurnRegistry.Entry
        do {
            entry = try await registry.ensure(
                sessionID: context.sessionID,
                workspaceTmp: workspaceTmp,
                networkDenied: !effectiveAllowNetwork,
                memory: effectiveContainerMemory
            )
        } catch {
            return containerFailureOutput(command: command, decision: decision, error: error, callID: callID)
        }
        let guestWorkdirResult = strictGuestWorkdir(
            requestedCwd: requestedCwd,
            workspaceRoot: ensuredRoot,
            entry: entry,
            command: command,
            decision: decision,
            callID: callID
        )
        if let failure = guestWorkdirResult.failure {
            return failure
        }
        let guestWorkdir = guestWorkdirResult.workdir ?? entry.workdir
        ensureStrictGuestSubdir(relative: guestWorkdirResult.relative, scratchURL: entry.scratchURL)
        let bounded = boundedRunCommand(command, tier: .strictContainer)
        do {
            let result = try await registry.exec(
                sessionID: context.sessionID,
                workdir: guestWorkdir,
                command: bounded,
                timeoutSeconds: timeoutSeconds
            )
            return containerResultOutput(command: command, result: result, decision: decision, callID: callID)
        } catch {
            return containerFailureOutput(command: command, decision: decision, error: error, callID: callID)
        }
    }

    /// Runs one command in the long-lived workspace container. Ensures the machine container then
    /// execs with cwd set to the workspace root, which is the only mount.
    func runMachineScoped(
        command: String,
        timeoutSeconds: TimeInterval,
        effectiveAllowNetwork: Bool,
        decision: BashDecision,
        callID: String,
        requestedCwd: URL? = nil
    ) async throws -> ToolOutput {
        let runtime = effectiveContainerRuntime
        let client = effectiveMachineClient
        guard runtime.resolveRuntimeURL() != nil else {
            return missingRuntimeDenied(command: command, decision: decision, callID: callID)
        }
        do {
            try client.probe()
        } catch {
            let message = error.localizedDescription
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: message,
                reason: message
            )
            return .failure(Self.encodeEnvelope(envelope), callID: callID)
        }
        let workspace = effectiveWorkspaceStore
        let ensuredRoot: URL
        do {
            ensuredRoot = try await workspace.ensure()
        } catch {
            let message = (error as? WorkspaceError).map(\.reason) ?? error.localizedDescription
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: message,
                reason: message
            )
            return .failure(Self.encodeEnvelope(envelope), callID: callID)
        }
        do {
            try await client.ensureMachine(
                workspaceRoot: ensuredRoot,
                networkDenied: !effectiveAllowNetwork,
                memory: effectiveContainerMemory
            )
        } catch {
            return containerFailureOutput(command: command, decision: decision, error: error, callID: callID)
        }
        let machineWorkdirResult = machineGuestWorkdir(
            requestedCwd: requestedCwd,
            workspaceRoot: ensuredRoot,
            command: command,
            decision: decision,
            callID: callID
        )
        if let failure = machineWorkdirResult.failure {
            return failure
        }
        let workdir = machineWorkdirResult.workdir ?? ensuredRoot.standardizedFileURL.path
        let bounded = boundedRunCommand(command, tier: .machineScoped)
        do {
            let result = try await client.exec(
                workdir: workdir,
                command: bounded,
                timeoutSeconds: timeoutSeconds
            )
            return containerResultOutput(command: command, result: result, decision: decision, callID: callID)
        } catch {
            return containerFailureOutput(command: command, decision: decision, error: error, callID: callID)
        }
    }

    /// Resolved strict guest workdir inside the scratch mount.
    private struct StrictGuestWorkdirResolution: Sendable {
        let workdir: String?
        let relative: String?
        let failure: ToolOutput?
    }

    /// Resolves the strict guest workdir inside the scratch mount.
    private func strictGuestWorkdir(
        requestedCwd: URL?,
        workspaceRoot: URL,
        entry: StrictTurnRegistry.Entry,
        command: String,
        decision: BashDecision,
        callID: String
    ) -> StrictGuestWorkdirResolution {
        guard let requested = requestedCwd else {
            return StrictGuestWorkdirResolution(workdir: nil, relative: nil, failure: nil)
        }
        guard let relative = Self.relativePathInsideRoot(requested, root: workspaceRoot) else {
            let detail = "Working directory outside strict container mount: isolated turns run inside fresh workspace scratch."
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: detail,
                reason: detail
            )
            return StrictGuestWorkdirResolution(workdir: nil, relative: nil, failure: .failure(Self.encodeEnvelope(envelope), callID: callID))
        }
        if relative.isEmpty {
            return StrictGuestWorkdirResolution(workdir: entry.workdir, relative: "", failure: nil)
        }
        let guest = entry.workdir.hasSuffix("/") ? entry.workdir + relative : entry.workdir + "/" + relative
        return StrictGuestWorkdirResolution(workdir: guest, relative: relative, failure: nil)
    }

    /// Best-effort scratch subdir creation so a relative cwd exists in the guest. Failures fall
    /// through to the exec, which surfaces the honest missing-directory error.
    private func ensureStrictGuestSubdir(relative: String?, scratchURL: URL) {
        guard let relative, !relative.isEmpty else { return }
        let target = scratchURL.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Resolves the machine guest workdir inside the workspace root mount.
    private func machineGuestWorkdir(
        requestedCwd: URL?,
        workspaceRoot: URL,
        command: String,
        decision: BashDecision,
        callID: String
    ) -> (workdir: String?, failure: ToolOutput?) {
        guard let requested = requestedCwd else {
            return (nil, nil)
        }
        guard Self.relativePathInsideRoot(requested, root: workspaceRoot) != nil else {
            let detail = "Working directory outside workspace container mount: machine turns run inside the workspace root."
            let envelope = BashResultEnvelope(
                command: command,
                approvalRequired: false,
                isChained: decision.isChained,
                denied: true,
                error: detail,
                reason: detail
            )
            return (nil, .failure(Self.encodeEnvelope(envelope), callID: callID))
        }
        return (requested.standardizedFileURL.path, nil)
    }

    /// Relative tail of a path inside a root, nil when outside.
    private static func relativePathInsideRoot(_ path: URL, root: URL) -> String? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = path.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedPath == resolvedRoot {
            return ""
        }
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedPath.hasPrefix(prefix) else { return nil }
        return String(resolvedPath.dropFirst(prefix.count))
    }

    /// Denied envelope for isolated tiers without a container runtime.
    ///
    /// Names the Apple container install with no Seatbelt fallback.
    private func missingRuntimeDenied(command: String, decision: BashDecision, callID: String) -> ToolOutput {
        let detail = ContainerOperationError.runtimeNotFound("container").localizedDescription
        let envelope = BashResultEnvelope(
            command: command,
            approvalRequired: false,
            isChained: decision.isChained,
            denied: true,
            error: detail,
            reason: detail
        )
        return .failure(Self.encodeEnvelope(envelope), callID: callID)
    }

    private func containerResultOutput(command: String, result: BoundedProcessResult, decision: BashDecision, callID: String) -> ToolOutput {
        let killReason = Self.killReason(
            didTimeOut: false,
            terminationReason: .exit,
            terminationStatus: result.exitCode,
            stderr: result.stderrString
        )
        let envelope = BashResultEnvelope(
            command: command,
            stdout: result.stdoutString,
            stderr: result.stderrString,
            exitCode: result.exitCode,
            approvalRequired: false,
            isChained: decision.isChained,
            denied: false,
            error: result.exitCode != 0 ? "Command exited with status \(result.exitCode)" : nil,
            reason: nil,
            killReason: killReason
        )
        let json = Self.encodeEnvelope(envelope)
        if result.exitCode == 0 {
            return .success(json, callID: callID, exitCode: result.exitCode)
        }
        return .failure(json, callID: callID, exitCode: result.exitCode)
    }

    private func containerFailureOutput(command: String, decision: BashDecision, error: Error, callID: String) -> ToolOutput {
        if effectiveContainerRuntime.resolveRuntimeURL() == nil {
            return missingRuntimeDenied(command: command, decision: decision, callID: callID)
        }
        let kill: BashKillReason = (error as? BoundedProcessError).map {
            if case .timedOut = $0 {
                return BashKillReason.wallTimeout
            }
            return BashKillReason.clean
        } ?? .clean
        let exitCode: Int32 = kill == .wallTimeout ? 124 : 1
        let envelope = BashResultEnvelope(
            command: command,
            exitCode: exitCode,
            approvalRequired: false,
            isChained: decision.isChained,
            denied: false,
            error: "Container execution failed: \(error.localizedDescription)",
            reason: error.localizedDescription,
            killReason: kill
        )
        return .failure(Self.encodeEnvelope(envelope), callID: callID, exitCode: exitCode)
    }
}
