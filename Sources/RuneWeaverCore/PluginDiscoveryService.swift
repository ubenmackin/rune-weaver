// Rune Weaver Core — Plugin discovery, registration, and lifecycle orchestration.

import Foundation

/// Service discovering and managing plugins on disk and in the live engine.
public final class PluginDiscoveryService: Sendable {
    public let pluginsDirectory: URL
    public let store: ToolRegistryStore

    /// Creates a plugin discovery service.
    public init(pluginsDirectory: URL, store: ToolRegistryStore) {
        self.pluginsDirectory = pluginsDirectory
        self.store = store
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

        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let subdirs = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(PluginManifest, PluginRecord)] = []

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

            guard let data = try? Data(contentsOf: manifestFile),
                  let manifest = try? PluginManifest.from(jsonData: data)
            else {
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

            // Register discovered plugin tools into the live ToolBus. Enabled tools
            // are active for execution; disabled or tampered tools are registered as disabled
            // so they appear in allTools() for GET /tools while availableTools() hides them.
            await registerPluginTools(
                manifest: manifest,
                pluginDir: subdir,
                record: record,
                toolBus: toolBus,
                isEnabled: record.status == .enabled
            )
        }

        return results
    }

    /// Enables a plugin, calculating its cryptographic tree hash and activating its tools on the live bus.
    public func enablePlugin(id: String, toolBus: ToolBus) async throws -> PluginRecord {
        guard let manifestInfo = findManifest(for: id) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        guard let hash = PluginSecurity.calculateDirectoryHash(at: manifestInfo.dir) else {
            throw PluginDiscoveryError.unreadablePluginDirectory(manifestInfo.dir.path)
        }

        guard let updated = await store.setStatus(id: id, status: .enabled, integrityHash: hash) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        await registerPluginTools(
            manifest: manifestInfo.manifest,
            pluginDir: manifestInfo.dir,
            record: updated,
            toolBus: toolBus,
            isEnabled: true
        )

        return updated
    }

    /// Disables a plugin, disabling its tools on the live bus.
    public func disablePlugin(id: String, toolBus: ToolBus) async throws -> PluginRecord {
        guard let updated = await store.setStatus(id: id, status: .disabled) else {
            throw PluginDiscoveryError.pluginNotFound(id)
        }

        if let manifestInfo = findManifest(for: id) {
            for tool in manifestInfo.manifest.tools {
                await toolBus.disableTool(named: tool.name)
            }
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
            await registerPluginTools(
                manifest: manifestInfo.manifest,
                pluginDir: manifestInfo.dir,
                record: updated,
                toolBus: toolBus
            )
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
                if let data = try? Data(contentsOf: manifestURL),
                   let manifest = try? PluginManifest.from(jsonData: data),
                   manifest.id == id
                {
                    return (manifest, subdir)
                }
            }
        }
        return nil
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
                let bridge = try SubprocessToolBridge(
                    pluginID: manifest.id,
                    declaration: toolDecl,
                    pluginDirectory: pluginDir,
                    entrypoint: manifest.entrypoint,
                    runtime: manifest.runtime,
                    permissionOverride: overrideLevel
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

/// Errors raised by the plugin discovery service.
public enum PluginDiscoveryError: Error, Sendable, Equatable, LocalizedError {
    case pluginNotFound(String)
    case unreadablePluginDirectory(String)
    case escapesPluginsDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .pluginNotFound(id):
            "Plugin with identifier '\(id)' was not found."
        case let .unreadablePluginDirectory(path):
            "Could not read plugin directory at '\(path)'."
        case let .escapesPluginsDirectory(path):
            "Refusing to remove plugin directory outside the plugins pen at '\(path)'."
        }
    }
}
