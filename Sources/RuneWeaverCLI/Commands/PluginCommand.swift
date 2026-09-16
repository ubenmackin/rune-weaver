// Rune Weaver CLI — Plugin and rune lifecycle management commands.

import ArgumentParser
import Foundation
import RuneWeaverCore

/// Manages external plugins and community runes.
struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage external plugins, runes, and tool permissions.",
        subcommands: [
            PluginListCommand.self,
            PluginEnableCommand.self,
            PluginDisableCommand.self,
            PluginRescanCommand.self,
            PluginVerifyCommand.self
        ]
    )
}

/// Lists all discovered and installed plugins and their current states.
struct PluginListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all discovered and installed plugins."
    )

    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let dbPath = loaded.config.memory.episodesDBPath
        let store = ToolRegistryStore(dbPath: dbPath)
        let pluginsURL = URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: store)

        // Rescan to reflect current disk state
        let bus = ToolBus()
        _ = await discovery.discoverAndSync(toolBus: bus)
        let records = await store.loadAll()

        if records.isEmpty {
            print(TerminalStyle.dim("No external plugins found in \(pluginsURL.path)."))
            print(TerminalStyle.dim("Place rune directories containing 'rune.json' into \(pluginsURL.path) to discover them."))
            return
        }

        print(TerminalStyle.bold("Discovered & Installed Runes (\(records.count)):"))
        print(TerminalStyle.dim("--------------------------------------------------------------------------------"))

        for record in records {
            let statusBadge: String = switch record.status {
            case .enabled:
                TerminalStyle.wrap(" [ENABLED] ", "32;1") // green bold
            case .discovered:
                TerminalStyle.wrap(" [DISCOVERED - PENDING REVIEW] ", "33;1") // yellow bold
            case .disabled:
                TerminalStyle.wrap(" [DISABLED] ", "90") // dim
            case .tampered:
                TerminalStyle.wrap(" [TAMPERED - QUARANTINED] ", "31;1") // red bold
            }

            print("\(TerminalStyle.bold(record.name)) (\(record.id)) v\(record.version)\(statusBadge)")
            if let manifestInfo = discovery.findManifest(for: record.id) {
                let manifest = manifestInfo.manifest
                if !manifest.description.isEmpty {
                    print("  \(manifest.description)")
                }
                print("  Runtime: \(manifest.runtime.rawValue) | Entrypoint: \(manifest.entrypoint)")
                let toolNames = manifest.tools.map { tool -> String in
                    if let override = record.permissionOverrides[tool.name] {
                        return "\(tool.name) (\(tool.permissionLevel.rawValue) -> \(override))"
                    }
                    return "\(tool.name) (\(tool.permissionLevel.rawValue))"
                }.joined(separator: ", ")
                print("  Tools: \(toolNames)")
            }
            if let hash = record.integrityHash {
                let prefix = String(hash.prefix(16))
                print("  Hash: \(prefix)...")
            }
            print(TerminalStyle.dim("--------------------------------------------------------------------------------"))
        }
    }
}

/// Approves and enables a discovered or disabled plugin.
struct PluginEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Approve and enable a plugin, registering its tools for use."
    )

    @Argument(help: "Plugin identifier to enable.")
    var id: String

    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let dbPath = loaded.config.memory.episodesDBPath
        let store = ToolRegistryStore(dbPath: dbPath)
        let pluginsURL = URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: store)

        let bus = ToolBus()
        do {
            let updated = try await discovery.enablePlugin(id: id, toolBus: bus)
            print(TerminalStyle.wrap("Successfully enabled plugin '\(updated.name)' (\(updated.id)).", "32;1"))
            if let hash = updated.integrityHash {
                print("Recorded integrity hash: \(hash)")
            }
        } catch {
            cliPrintError(TerminalStyle.wrap("Failed to enable plugin: \(error.localizedDescription)", "31;1"))
            throw ExitCode.failure
        }
    }
}

/// Disables an enabled plugin.
struct PluginDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a plugin, preventing its tools from running."
    )

    @Argument(help: "Plugin identifier to disable.")
    var id: String

    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let dbPath = loaded.config.memory.episodesDBPath
        let store = ToolRegistryStore(dbPath: dbPath)
        let pluginsURL = URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: store)

        let bus = ToolBus()
        do {
            let updated = try await discovery.disablePlugin(id: id, toolBus: bus)
            print(TerminalStyle.wrap("Successfully disabled plugin '\(updated.name)' (\(updated.id)).", "33;1"))
        } catch {
            cliPrintError(TerminalStyle.wrap("Failed to disable plugin: \(error.localizedDescription)", "31;1"))
            throw ExitCode.failure
        }
    }
}

/// Scans the plugins directory and registers any new or modified plugins.
struct PluginRescanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rescan",
        abstract: "Rescan plugin directory for new, updated, or modified runes."
    )

    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let dbPath = loaded.config.memory.episodesDBPath
        let store = ToolRegistryStore(dbPath: dbPath)
        let pluginsURL = URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: store)

        print("Scanning \(pluginsURL.path)...")
        let bus = ToolBus()
        let results = await discovery.discoverAndSync(toolBus: bus)

        print(TerminalStyle.wrap("Discovered \(results.count) plugin(s) on disk.", "32;1"))
        for (manifest, record) in results {
            print("  • \(manifest.name) (\(manifest.id)) — status: \(record.status.rawValue)")
        }
    }
}

/// Verifies disk files of an enabled plugin against its approved cryptographic hash.
struct PluginVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a plugin's directory integrity against its approved hash."
    )

    @Argument(help: "Plugin identifier to verify.")
    var id: String

    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let dbPath = loaded.config.memory.episodesDBPath
        let store = ToolRegistryStore(dbPath: dbPath)
        let pluginsURL = URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        let discovery = PluginDiscoveryService(pluginsDirectory: pluginsURL, store: store)

        guard let record = await store.get(id: id) else {
            cliPrintError(TerminalStyle.wrap("Plugin '\(id)' not found in registry.", "31;1"))
            throw ExitCode.failure
        }

        guard let manifestInfo = discovery.findManifest(for: id) else {
            cliPrintError(TerminalStyle.wrap("Plugin directory for '\(id)' not found on disk.", "31;1"))
            throw ExitCode.failure
        }

        guard let currentHash = PluginSecurity.calculateDirectoryHash(at: manifestInfo.dir) else {
            cliPrintError(TerminalStyle.wrap("Could not compute hash for plugin directory at \(manifestInfo.dir.path).", "31;1"))
            throw ExitCode.failure
        }

        guard let approvedHash = record.integrityHash else {
            print(TerminalStyle.wrap("Plugin '\(id)' has no recorded approval hash (current status: \(record.status.rawValue)).", "33;1"))
            print("Current disk hash: \(currentHash)")
            return
        }

        if currentHash == approvedHash {
            print(TerminalStyle.wrap("INTEGRITY VERIFIED: Plugin '\(id)' matches recorded approval hash.", "32;1"))
            print("SHA-256: \(approvedHash)")
        } else {
            cliPrintError(TerminalStyle.wrap("INTEGRITY VIOLATION: Plugin '\(id)' files have been modified since approval!", "31;1"))
            print("Approved hash: \(approvedHash)")
            print("Current  hash: \(currentHash)")
            throw ExitCode.failure
        }
    }
}
