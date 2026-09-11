import ArgumentParser

/// `rune-weaver` terminal interface.
///
/// The MVP interaction layer is the terminal CLI — terminal-only by
/// design. There is no web frontend in this MVP. Subcommands:
/// `chat` (interactive REPL), `config` (show/set values), `memory`
/// (search semantic memory, show known facts), and `status` (system
/// status: LLM providers, memory stats, active tools).
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
            StatusCommand.self
        ]
    )
}
