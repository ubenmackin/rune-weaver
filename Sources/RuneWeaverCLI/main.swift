// Rune Weaver CLI — `rune-weaver` command entry point.
//
// Declares the top-level `RuneWeaverCommand` and registers every
// subcommand (`chat`, `config`, `memory`, `plugin`, `scheduler`, `serve`,
// `status`). The CLI links `RuneWeaverCore` directly for terminal use with
// no service running, and launches the shared engine service via `serve`
// for the web dashboard, iOS, and macOS clients.

import ArgumentParser

/// `rune-weaver` terminal interface.
///
/// The CLI links `RuneWeaverCore` directly for v1 (`chat` and
/// `scheduler run` build their own `ToolBus` and `Orchestrator` via
/// `CLIShared`, so terminal use works with no service running) and
/// launches the shared engine service via `serve` for the web
/// dashboard, iOS, and macOS clients (see the Engine-to-Service Shift in
/// ARCHITECTURE.md). Subcommands: `chat` (interactive REPL), `config`
/// (show/set values), `memory` (search semantic memory, show known facts),
/// `scheduler` (list jobs, run the foreground loop), `serve` (start the
/// engine API service on loopback), and `status` (system
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
            PluginCommand.self,
            SchedulerCommand.self,
            ServeCommand.self,
            StatusCommand.self
        ]
    )
}
