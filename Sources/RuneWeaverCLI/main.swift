// Rune Weaver CLI — `rune-weaver` command entry point.

import ArgumentParser

/// `rune-weaver` terminal interface.
@main
struct RuneWeaverCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "rune-weaver",
        abstract: "Rune Weaver personal AI assistant harness.",
        version: "0.1.0",
        subcommands: [
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
