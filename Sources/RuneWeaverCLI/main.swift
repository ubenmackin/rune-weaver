// Rune Weaver CLI — `rune-weaver` command entry point.

import ArgumentParser
import RuneWeaverCore

/// `rune-weaver` terminal interface.
@main
struct RuneWeaverCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "rune-weaver",
        abstract: "Rune Weaver personal AI assistant harness.",
        version: RuneWeaverVersion.current,
        subcommands: [
            AuthCommand.self,
            ChatCommand.self,
            ConfigCommand.self,
            MemoryCommand.self,
            PluginCommand.self,
            SchedulerCommand.self,
            ServeCommand.self,
            StatusCommand.self
        ]
    )
}
