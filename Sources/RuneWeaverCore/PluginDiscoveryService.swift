// Rune Weaver Core — Plugin discovery, registration, and lifecycle orchestration.

import Foundation
import os

/// Service discovering and managing plugins on disk and in the live engine.
public final class PluginDiscoveryService: Sendable {
    public let pluginsDirectory: URL
    public let store: ToolRegistryStore
    public let secrets: SecretsManager?
    public let toolStates: ToolStateStore?
    private let egressBox: OSAllocatedUnfairLock<any EgressPolicyEvaluator?>

    /// Creates a plugin discovery service.
    public init(
        pluginsDirectory: URL,
        store: ToolRegistryStore,
        secrets: SecretsManager? = nil,
        egressEvaluator: any EgressPolicyEvaluator? = nil,
        toolStates: ToolStateStore? = nil
    ) {
        self.pluginsDirectory = pluginsDirectory
        self.store = store
        self.secrets = secrets
        self.toolStates = toolStates
        self.egressBox = OSAllocatedUnfairLock(initialState: egressEvaluator)
    }

    /// Updates the evaluator screening network-capable tools after boot wires supervision.
    public func updateEgressEvaluator(_ evaluator: any EgressPolicyEvaluator?) {
        egressBox.withLock { $0 = evaluator }
    }

    /// Default directory URL for plugins (`~/.runeweaver/plugins`).
    public static func defaultPluginsDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".runeweaver/plugins")
    }

    /// Scans the plugins directory, synchronizes durable records, and registers enabled tools into `ToolBus`.
    @discardableResult
    public func discoverAndSync(toolBus: ToolBus, defaultSource: String = "local_disk") async -> [(manifest: PluginManifest, record: PluginRecord)] {
        // Refresh store from SQLite so external mutations (e.g. from CLI) are visible
        _ = await store.reload()

        let fileManager = FileManager.default
        let expandedPath = pluginsDirectory.path
        var isDir: ObjCBool = false

        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue, let subdirs = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(PluginManifest, PluginRecord)] = []

        // Persisted per-tool toggles survive rescan so it never revives a mini-card disable.
        let persistedStates: [String: Bool]? = if let toolStates {
            await toolStates.loadAll()
        } else {
            nil
        }

        for subdir in subdirs {
            guard (try? subdir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            // Look for rune.json or plugin.json
            let runeJSON = subdir.appendingPathComponent("rune.json")
            let pluginJSON = subdir.appendingPathComponent("plugin.json")
            let manifestFile: URL

            if fileManager.fileExists(atPath: runeJSON.path) {
                manifestFile = runeJSON
            } else if fileManager.fileExists(atPath: pluginJSON.path) {
                manifestFile = pluginJSON
            } else {
                continue
            }

            let data: Data
            do {
                data = try Data(contentsOf: manifestFile)
            } catch {
                RuneWeaverLog.tools.warning("PluginDiscoveryService: failed to read manifest at \(manifestFile.path): \(error.localizedDescription)")
                continue
            }

            let manifest: PluginManifest
            do {
                manifest = try PluginManifest.from(jsonData: data)
            } catch {
                RuneWeaverLog.tools.warning("PluginDiscoveryService: failed to parse manifest at \(manifestFile.path): \(error.localizedDescription)")
                continue
            }

            let currentHash = PluginSecurity.calculateDirectoryHash(at: subdir)

            // Record in durable SQLite store (defaults to .discovered if new).
            // Existing rows preserve their stored source inside the store so a
            // marketplace rune rescanned from disk never regresses to local.
            let record = await store.recordDiscovered(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                source: defaultSource,
                currentHash: currentHash
            )

            results.append((manifest, record))

            // Registered disabled for listing, then restore only was-enabled.
            // Fail-closed start avoids exposing disabled tools to concurrent executes.
            await registerFailClosed(manifest: manifest, dir: subdir, record: record, toolBus: toolBus) {
                record.status == .enabled && persistedStates?[$0] != false
            }
        }

        // Execution refuses quarantined plugins even when a stale toggle says enabled.
        let allRecords = await store.loadAll()
        await toolBus.setQuarantinedPluginIDs(Set(allRecords.filter { $0.status == .tampered }.map(\.id)))

        return results
    }

    /// Enables a plugin, calculating its cryptographic tree hash and activating its tools on the live bus.
    public func enablePlugin(id: String, toolBus: ToolBus) async throws -> PluginRecord {
        guard let manifestInfo = findManifest(for: id) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        if manifestInfo.manifest.runtime == .python {
            try await provisionVenvIfNeeded(at: manifestInfo.dir)
        }

        guard let hash = PluginSecurity.calculateDirectoryHash(at: manifestInfo.dir) else {
            throw PluginDiscoveryError.unreadablePluginDirectory(manifestInfo.dir.path)
        }

        guard let updated = await store.setStatus(id: id, status: .enabled, integrityHash: hash) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        // Preserve mini-card toggles across re-registration so enable never revives them.
        let persisted: [String: Bool]? = if let toolStates {
            await toolStates.loadAll()
        } else {
            nil
        }
        await registerFailClosed(
            manifest: manifestInfo.manifest,
            dir: manifestInfo.dir,
            record: updated,
            toolBus: toolBus
        ) { persisted?[$0] != false }
        // Re-verified hash clears quarantine; plugin enable is the only unquarantine path.
        await toolBus.updateQuarantine(pluginID: id, quarantined: false)

        return updated
    }

    /// Disables a plugin, disabling its tools on the live bus.
    public func disablePlugin(id: String, toolBus: ToolBus) async throws -> PluginRecord {
        guard let current = await store.get(id: id) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }
        // Tampered stays tampered until enablePlugin re-verifies the tree hash;
        // downgrading to disabled would clear quarantine on next restore.
        let targetStatus: PluginStatus = current.status == .tampered ? .tampered : .disabled
        guard let updated = await store.setStatus(id: id, status: targetStatus) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        if let manifestInfo = findManifest(for: id) {
            for tool in manifestInfo.manifest.tools {
                await toolBus.disableTool(named: tool.name)
            }
        }
        if targetStatus == .tampered {
            await toolBus.updateQuarantine(pluginID: id, quarantined: true)
        }

        return updated
    }

    /// Sets or clears a user permission override for a tool within a plugin.
    public func setPermissionOverride(
        id: String,
        toolName: String,
        overrideLevel: PermissionLevel?,
        toolBus: ToolBus
    ) async throws -> PluginRecord {
        if let overrideLevel, overrideLevel == .trusted {
            throw PluginManifestError.trustedPermissionProhibited(
                tool: toolName,
                reason: "External plugins may not be overridden to 'trusted'. Only 'readOnly' and 'requiresApproval' are permitted."
            )
        }
        guard let updated = try await store.setPermissionOverride(
            id: id,
            toolName: toolName,
            overrideLevel: overrideLevel
        ) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        if updated.status == .enabled, let manifestInfo = findManifest(for: id) {
            // Snapshot live per-tool states so re-registration never revives a disabled tool.
            var previousStates: [String: Bool] = [:]
            for toolDecl in manifestInfo.manifest.tools where await toolBus.tool(named: toolDecl.name) != nil {
                previousStates[toolDecl.name] = await toolBus.isToolEnabled(named: toolDecl.name)
            }
            await registerFailClosed(
                manifest: manifestInfo.manifest,
                dir: manifestInfo.dir,
                record: updated,
                toolBus: toolBus
            ) { previousStates[$0] == true }
        }

        return updated
    }

    /// Uninstalls a plugin by removing its directory and deleting its record.
    public func uninstallPlugin(id: String, toolBus: ToolBus) async throws {
        // Snapshot declared tool names before the directory is removed: disabling only flips the
        // enabled flag while bridge definitions stay registered for listing, so uninstall must
        // fully unregister each tool or stale disabled entries would linger in the live registry...
        let toolNames = findManifest(for: id)?.manifest.tools.map(\.name) ?? []
        do {
            _ = try await disablePlugin(id: id, toolBus: toolBus)
        } catch {
            RuneWeaverLog.tools.debug("PluginDiscoveryService: disablePlugin during uninstall of '\(id)' ignored: \(error.localizedDescription)")
        }

        if let manifestInfo = findManifest(for: id) {
            guard PluginSecurity.isProtectedPath(targetURL: manifestInfo.dir, pluginsDir: pluginsDirectory) else {
                throw PluginDiscoveryError.escapesPluginsDirectory(manifestInfo.dir.path)
            }
            try FileManager.default.removeItem(at: manifestInfo.dir)
        }
        for toolName in toolNames {
            await toolBus.unregister(toolNamed: toolName)
        }
        _ = await store.remove(id: id)
        await toolBus.updateQuarantine(pluginID: id, quarantined: false)
    }

    /// Finds a plugin directory and parsed manifest matching the given ID.
    public func findManifest(for id: String) -> (manifest: PluginManifest, dir: URL)? {
        let fileManager = FileManager.default
        guard let subdirs = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for subdir in subdirs {
            for filename in ["rune.json", "plugin.json"] {
                let manifestURL = subdir.appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
                do {
                    let data = try Data(contentsOf: manifestURL)
                    let manifest = try PluginManifest.from(jsonData: data)
                    if manifest.id == id {
                        return (manifest, subdir)
                    }
                } catch {
                    RuneWeaverLog.tools.debug("PluginDiscoveryService: failed to read candidate manifest at \(manifestURL.path): \(error.localizedDescription)")
                }
            }
        }
        return nil
    }

    private func registerFailClosed(
        manifest: PluginManifest,
        dir: URL,
        record: PluginRecord,
        toolBus: ToolBus,
        restore: (String) -> Bool
    ) async {
        // Fail-closed start avoids exposing disabled tools to concurrent executes.
        await registerPluginTools(manifest: manifest, pluginDir: dir, record: record, toolBus: toolBus, isEnabled: false)
        for toolDecl in manifest.tools where restore(toolDecl.name) {
            await toolBus.enableTool(named: toolDecl.name)
        }
    }

    private func registerPluginTools(
        manifest: PluginManifest,
        pluginDir: URL,
        record: PluginRecord,
        toolBus: ToolBus,
        isEnabled: Bool = true
    ) async {
        for toolDecl in manifest.tools {
            // Manifest parsing already bars trusted, but a tampered database row
            // could still rehydrate to it. Omit the tool fail-closed instead of
            // letting an external rune escalate past human approval.
            if toolDecl.permissionLevel == .trusted {
                await toolBus.unregister(toolNamed: toolDecl.name)
                continue
            }
            let overrideLevel: PermissionLevel? = if let levelStr = record.permissionOverrides[toolDecl.name] {
                PermissionLevel(rawValue: levelStr)
            } else {
                nil
            }
            if overrideLevel == .trusted {
                await toolBus.unregister(toolNamed: toolDecl.name)
                continue
            }

            do {
                let evaluator = egressBox.withLock { $0 }
                let bridge = try SubprocessToolBridge(
                    pluginID: manifest.id,
                    declaration: toolDecl,
                    pluginDirectory: pluginDir,
                    entrypoint: manifest.entrypoint,
                    runtime: manifest.runtime,
                    permissionOverride: overrideLevel,
                    capabilities: toolDecl.capabilities,
                    secrets: secrets,
                    egressEvaluator: evaluator
                )
                await toolBus.register(tool: bridge, isEnabled: isEnabled)
            } catch {
                // A rejected override never reaches the live bus;
                // ensure any stale registration for the name is removed.
                await toolBus.unregister(toolNamed: toolDecl.name)
            }
        }
    }
}

/// Venv provisioning lives here so the main service body stays within budget.
/// Enable-time provisioning runs ahead of hashing; behavior is unchanged.
extension PluginDiscoveryService {
    private func provisionVenvIfNeeded(at directory: URL) async throws {
        guard ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] != "1" else {
            return
        }
        let fileManager = FileManager.default
        let reqURL = directory.appendingPathComponent("requirements.txt")
        let venvDir = directory.appendingPathComponent(".venv")
        let venvPython = venvDir.appendingPathComponent("bin/python3")

        guard fileManager.fileExists(atPath: reqURL.path),
              !fileManager.fileExists(atPath: venvPython.path)
        else {
            return
        }

        // Pinned hashes plus rejected pip options keep enable on the default PyPI index.
        // Enable is an explicit operator action with bounded timeouts, the documented egress exception.
        try validatePinnedRequirements(at: reqURL)

        // Fresh enables converge on the pinned runtime before venv creation.
        let provisioner = PythonProvisioner()
        do {
            _ = try await provisioner.ensureProvisioned()
        } catch {
            throw PluginDiscoveryError.provisioningFailed(
                "Failed to provision Python 3.12 runtime at \(provisioner.destinationInterpreterURL.path) (unknown): \(error.localizedDescription)"
            )
        }

        RuneWeaverLog.tools.info("PluginDiscoveryService: provisioning .venv for \(directory.lastPathComponent)...")
        let python = resolveProvisioningInterpreter()
        let version = await provisioningInterpreterVersion(for: python)
        do {
            let venvResult = try await BoundedProcessRunner.runAsync(
                executableURL: python,
                arguments: ["-m", "venv", venvDir.path],
                timeoutSeconds: 120,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
            guard venvResult.exitCode == 0 else {
                throw PluginDiscoveryError.provisioningFailed(
                    "Failed to create Python virtual environment at \(directory.path) using interpreter "
                        + "\(python.path) (\(version)) (code \(venvResult.exitCode)): \(venvResult.stderrString)"
                )
            }
        } catch let error as PluginDiscoveryError {
            throw error
        } catch {
            throw PluginDiscoveryError.provisioningFailed(
                "Failed to create Python virtual environment at \(directory.path) using interpreter \(python.path) (\(version)): \(error.localizedDescription)"
            )
        }

        do {
            let pipResult = try await BoundedProcessRunner.runAsync(
                executableURL: venvPython,
                arguments: ["-m", "pip", "install", "--require-hashes", "--no-input", "--index-url", "https://pypi.org/simple", "-r", reqURL.path],
                timeoutSeconds: 180,
                maxOutputBytes: 64 * 1024,
                maxErrorBytes: 64 * 1024
            )
            guard pipResult.exitCode == 0 else {
                // Partial installs must not masquerade as ready venvs.
                try? fileManager.removeItem(at: venvDir)
                throw PluginDiscoveryError.provisioningFailed(
                    "Failed to install requirements.txt for \(directory.lastPathComponent) using interpreter "
                        + "\(python.path) (\(version)) (code \(pipResult.exitCode)): \(pipResult.stderrString)"
                )
            }
        } catch let error as PluginDiscoveryError {
            throw error
        } catch {
            // Failed installs leave no partial venv behind.
            try? fileManager.removeItem(at: venvDir)
            throw PluginDiscoveryError.provisioningFailed(
                "Failed to install requirements.txt for \(directory.lastPathComponent) using interpreter "
                    + "\(python.path) (\(version)): \(error.localizedDescription)"
            )
        }
    }

    private func provisioningInterpreterVersion(for python: URL) async -> String {
        // --version may report on either stream, so both are combined.
        do {
            let result = try await BoundedProcessRunner.runAsync(
                executableURL: python,
                arguments: ["--version"],
                timeoutSeconds: 10,
                maxOutputBytes: 4 * 1024,
                maxErrorBytes: 4 * 1024
            )
            let combined = "\(result.stdoutString) \(result.stderrString)".trimmingCharacters(in: .whitespacesAndNewlines)
            return combined.isEmpty ? "unknown" : combined
        } catch {
            return "unknown"
        }
    }

    private func resolveProvisioningInterpreter() -> URL {
        // Env override first so operators pin the interpreter without editing code.
        if let override = ProcessInfo.processInfo.environment["RUNEWEAVER_PYTHON_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        // Provisioned 3.12 next so fresh enables use the pinned runtime.
        let provisioned = PythonProvisioner().destinationInterpreterURL
        if FileManager.default.fileExists(atPath: provisioned.path) {
            return provisioned
        }
        for candidate in ["/usr/bin/python3", "/usr/local/bin/python3"] where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func validatePinnedRequirements(at reqURL: URL) throws {
        // Unpinned ranges plus missing hashes would let enable fetch arbitrary code.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: reqURL.path),
              let size = attrs[.size] as? NSNumber, size.int64Value <= 64 * 1024,
              let content = try? String(contentsOf: reqURL, encoding: .utf8)
        else {
            throw PluginDiscoveryError.provisioningFailed("Could not read requirements.txt for hash verification.")
        }
        var stanzaHashes: [Int] = []
        var sawRequirement = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("--hash=") {
                guard sawRequirement else {
                    throw PluginDiscoveryError.provisioningFailed("requirements.txt has stray --hash without a requirement.")
                }
                try validateRequirementHashToken(line)
                stanzaHashes[stanzaHashes.count - 1] += 1
                continue
            }
            if line.hasPrefix("-") {
                throw PluginDiscoveryError.provisioningFailed("requirements.txt must not contain pip options.")
            }
            // Inline flags would bypass the pin check and reach pip on the default index.
            let inlineTokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            for token in inlineTokens {
                var core = token
                if core.hasSuffix("\\") {
                    core = String(core.dropLast())
                }
                if core == "\\" || core.hasPrefix("--hash=") {
                    continue
                }
                if core.hasPrefix("-") {
                    throw PluginDiscoveryError.provisioningFailed("requirements.txt must not contain pip options.")
                }
            }
            let loweredLine = line.lowercased()
            let pipOptionMarkers = ["extra-index-url", "index-url", "trusted-host", "find-links", "no-index"]
            if pipOptionMarkers.contains(where: { loweredLine.contains($0) }) {
                throw PluginDiscoveryError.provisioningFailed("requirements.txt must not contain pip options.")
            }
            sawRequirement = true
            var requirementPart = line
            var inlineCount = 0
            if line.contains("--hash=") {
                let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("--hash=") }
                for token in tokens {
                    try validateRequirementHashToken(token)
                }
                inlineCount = tokens.count
                if let hashStart = line.range(of: "--hash=") {
                    requirementPart = String(line[..<hashStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let pinCandidate = requirementPart.hasSuffix("\\")
                ? String(requirementPart.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                : requirementPart
            guard pinCandidate.contains("=="), [">=", "<=", "~=", "!="].allSatisfy({ !pinCandidate.contains($0) }) else {
                throw PluginDiscoveryError.provisioningFailed("requirements.txt must pin exact versions with '=='.")
            }
            stanzaHashes.append(inlineCount)
        }
        guard sawRequirement, !stanzaHashes.isEmpty, stanzaHashes.allSatisfy({ $0 >= 1 }) else {
            throw PluginDiscoveryError.provisioningFailed("requirements.txt must pin versions and include --hash entries.")
        }
    }

    private func validateRequirementHashToken(_ token: String) throws {
        // Malformed hashes fail closed so pip never resolves an unverifiable stanza.
        var cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("\\") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cleaned.hasPrefix("--hash=") else {
            throw PluginDiscoveryError.provisioningFailed("requirements.txt contains a malformed --hash entry.")
        }
        let value = String(cleaned.dropFirst("--hash=".count))
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["sha256", "sha384", "sha512"].contains(parts[0].lowercased()) else {
            throw PluginDiscoveryError.provisioningFailed("requirements.txt --hash must use sha256, sha384, or sha512.")
        }
        let expectedLength = parts[0].lowercased() == "sha256" ? 64 : parts[0].lowercased() == "sha384" ? 96 : 128
        guard parts[1].count == expectedLength, parts[1].allSatisfy(\.isHexDigit) else {
            throw PluginDiscoveryError.provisioningFailed("requirements.txt --hash value is malformed.")
        }
    }
}

/// Errors raised by the plugin discovery service.
public enum PluginDiscoveryError: Error, Sendable, Equatable, LocalizedError {
    case pluginNotFound(String)
    case unreadablePluginDirectory(String)
    case escapesPluginsDirectory(String)
    case provisioningFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .pluginNotFound(id):
            "Plugin with identifier '\(id)' was not found."
        case let .unreadablePluginDirectory(path):
            "Could not read plugin directory at '\(path)'."
        case let .escapesPluginsDirectory(path):
            "Refusing to remove plugin directory outside the plugins pen at '\(path)'."
        case let .provisioningFailed(reason):
            "Plugin provisioning failed: \(reason)"
        }
    }
}
