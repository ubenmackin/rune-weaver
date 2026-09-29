// Rune Weaver CLI — Long-horizon goal management over the durable store.
//
// Purpose: inspects and drives steady goal pursuit direct-core, without the
// engine service: listing with status filtering, creation with background
// planning, detail with bounded audit history, pause and resume, manual
// advancement bypassing cadence, abandonment, and step-level moves.
// Scope: terminal rendering plus direct GoalStore and GoalEngine calls only;
// planning and advancement turns reuse the serving provider, and session
// linkage stays nil because the dashboard and agent own that story.
// Architectural role: thin ArgumentParser adapter over the core pursuit engine,
// mirroring the scheduler command idioms (config loading, provider wiring,
// headless approval handling) while keeping every mutation observable in the
// same episodes database the service advances.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Manages long-horizon goals: list, add, show, pause, resume, advance, abandon, and steps.
struct GoalsCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "goals",
        abstract: "Manage long-horizon goals: list, add, advance, and track steps.",
        subcommands: [
            GoalsListCommand.self,
            GoalsAddCommand.self,
            GoalsShowCommand.self,
            GoalsPauseCommand.self,
            GoalsResumeCommand.self,
            GoalsAdvanceCommand.self,
            GoalsAbandonCommand.self,
            GoalsStepsCommand.self
        ]
    )
}

/// Lists durable goals, optionally filtered by lifecycle state.
struct GoalsListCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List goals from the durable store."
    )

    /// Lifecycle state filter (active, paused, needs_input, achieved, abandoned); blank lists all.
    @Option(name: .long, help: "Filter by status: active, paused, needs_input, achieved, abandoned.")
    var status: String?

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints every goal with its finished-versus-planned tally.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let filter = try GoalsCLIHelpers.parseStatusFilter(status)
        // Direct-core read keeps list off the service layer; plans stay small
        // by config bound, so per-row step reads never fan out.
        let store = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        let goals = try await store.list(status: filter)
        guard !goals.isEmpty else {
            let hint = filter.map { " with status '\($0.rawValue)'" } ?? ""
            print(TerminalStyle.dim("No goals\(hint). Add one with 'rune-weaver goals add <title> --statement ...'."))
            return
        }
        print("Goals (\(goals.count)) — \(loaded.url.path)")
        for goal in goals {
            // A missing plan degrades to an empty tally instead of failing the
            // list, matching the service list route.
            let steps = await (try? store.steps(goalID: goal.id)) ?? []
            GoalsCLIHelpers.printGoalRow(goal: goal, steps: steps)
        }
    }
}

/// Creates a goal with a cadence hint and waits for its decomposed plan.
struct GoalsAddCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a goal with a statement of intent."
    )

    /// Short human-readable title stored verbatim.
    @Argument(help: "Short human-readable title.")
    var title: String

    /// Fuller statement of intent shown to the owner and model.
    @Option(name: .long, help: "Fuller statement of intent.")
    var statement: String

    /// Cadence hint in minutes between due advancements.
    @Option(name: .long, help: "Cadence hint in minutes between advancements (5-20160).")
    var intervalMinutes: Int?

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Creates the goal, awaits its background plan, and prints the row.
    mutating func run() async throws {
        let trimmedTitle: String
        do {
            trimmedTitle = try GoalValidation.validatedTitle(title)
        } catch {
            throw ValidationError("Title must not be empty.")
        }
        let trimmedStatement: String
        do {
            trimmedStatement = try GoalValidation.validatedStatement(statement)
        } catch {
            throw ValidationError("--statement must not be empty.")
        }
        // Creation falls back to the configured interval when omitted; a
        // present value outside the steady range fails instead of silently
        // clamping, keeping the CLI and the dashboard in agreement.
        let cadence = try GoalsCLIHelpers.validatedCadence(intervalMinutes)
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        // Creation spends planning calls, so a disabled section fails closed
        // with guidance before any provider work starts.
        guard loaded.config.goals.enabled else {
            print(TerminalStyle.error("Goal pursuit is disabled. Set [goals] enabled = true in \(loaded.url.path) to create goals."))
            throw ExitCode(1)
        }
        let (engine, store) = try await GoalsCLIHelpers.makeEngine(
            loaded: loaded,
            providerName: nil
        )
        let goal: Goal
        do {
            // Origin stays nil: the CLI never links sessions, so the dashboard
            // and agent own the origin story.
            goal = try await engine.create(title: trimmedTitle, statement: trimmedStatement, cadence: cadence)
        } catch let error as GoalEngineError {
            print(TerminalStyle.error(error.localizedDescription))
            throw ExitCode(1)
        }
        // Creation returns before planning lands; awaiting the tracked plan
        // keeps the printed steps honest instead of showing the placeholder.
        await engine.waitForPendingPlan(goalID: goal.id)
        let steps = await (try? store.steps(goalID: goal.id)) ?? []
        print(TerminalStyle.success("Created goal \(goal.id.uuidString)"))
        GoalsCLIHelpers.printGoalRow(goal: goal, steps: steps)
    }
}

/// Shows one goal with its full plan and recent audit trail.
struct GoalsShowCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one goal with its plan and recent events."
    )

    /// Goal identifier.
    @Argument(help: "Goal identifier (UUID).")
    var id: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints the goal detail row.
    mutating func run() async throws {
        let goalID = try GoalsCLIHelpers.parseGoalID(id)
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let store = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        guard let goal = try await store.goal(id: goalID) else {
            print(TerminalStyle.error("Unknown goal \(id)."))
            throw ExitCode(1)
        }
        let steps = await (try? store.steps(goalID: goalID)) ?? []
        let events = await (try? store.events(goalID: goalID, limit: 10)) ?? []
        GoalsCLIHelpers.printGoalRow(goal: goal, steps: steps)
        print(TerminalStyle.dim("  statement: \(goal.statement)"))
        print(TerminalStyle.dim("  cadence: every \(goal.stepIntervalMinutes) min"))
        if let due = goal.nextDueAt {
            print(TerminalStyle.dim("  next due: \(GoalsCLIHelpers.displayDate(due))"))
        }
        print("")
        if steps.isEmpty {
            print(TerminalStyle.dim("No steps yet."))
        } else {
            print("Steps (\(steps.count)):")
            for step in steps.sorted(by: { $0.ordinal < $1.ordinal }) {
                GoalsCLIHelpers.printStepRow(step: step)
            }
        }
        if !events.isEmpty {
            print("")
            print("Recent events (\(events.count)):")
            for event in events {
                print(TerminalStyle.dim("  - \(event.kind.rawValue): \(event.message)"))
            }
        }
    }
}

/// Pauses pursuit of a goal.
struct GoalsPauseCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause pursuit of a goal."
    )

    /// Goal identifier.
    @Argument(help: "Goal identifier (UUID).")
    var id: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Flips the goal to paused.
    mutating func run() async throws {
        try await GoalsCLIHelpers.setStatus(id: id, configPath: config, status: .paused, verb: "Paused")
    }
}

/// Resumes a paused or parked goal back to active.
struct GoalsResumeCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume a paused or parked goal."
    )

    /// Goal identifier.
    @Argument(help: "Goal identifier (UUID).")
    var id: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Flips the goal back to active.
    mutating func run() async throws {
        try await GoalsCLIHelpers.setStatus(id: id, configPath: config, status: .active, verb: "Resumed")
    }
}

/// Abandons a goal, keeping its history joinable.
struct GoalsAbandonCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "abandon",
        abstract: "Abandon a goal."
    )

    /// Goal identifier.
    @Argument(help: "Goal identifier (UUID).")
    var id: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Flips the goal to abandoned.
    mutating func run() async throws {
        try await GoalsCLIHelpers.setStatus(id: id, configPath: config, status: .abandoned, verb: "Abandoned")
    }
}

/// Runs one advancement turn for a goal immediately, bypassing its cadence.
struct GoalsAdvanceCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "advance",
        abstract: "Advance a goal now with one model turn, bypassing its cadence."
    )

    /// Goal identifier.
    @Argument(help: "Goal identifier (UUID).")
    var id: String

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Runs one headless advancement turn through the shared runner.
    mutating func run() async throws {
        let goalID = try GoalsCLIHelpers.parseGoalID(id)
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        // Manual advancement spends a turn, so a disabled section refuses
        // before any provider work starts, even when stale rows linger.
        guard loaded.config.goals.enabled else {
            print(TerminalStyle.error("Goal pursuit is disabled. Set [goals] enabled = true in \(loaded.url.path) to advance goals."))
            throw ExitCode(1)
        }
        let store = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        guard let goal = try await store.goal(id: goalID) else {
            print(TerminalStyle.error("Unknown goal \(id)."))
            throw ExitCode(1)
        }
        // Terminal rows have no next step, and paused rows wait on their
        // owner; both refuse with guidance instead of spending a turn.
        switch goal.status {
        case .achieved, .abandoned:
            print(TerminalStyle.error("Goal '\(goal.title)' is \(goal.status.rawValue); only active goals advance."))
            throw ExitCode(1)
        case .paused:
            print(TerminalStyle.error("Goal '\(goal.title)' is paused; resume it before advancing."))
            throw ExitCode(1)
        case .active, .needsInput:
            break
        }
        let (engine, _) = try await GoalsCLIHelpers.makeEngine(loaded: loaded, providerName: nil)
        guard await engine.isEnabled else {
            print(TerminalStyle.error("Goal pursuit is disabled. Set [goals] enabled = true in \(loaded.url.path) to advance goals."))
            throw ExitCode(1)
        }
        let runtime = try await GoalsCLIHelpers.makeAdvanceRuntime(loaded: loaded, store: store, engine: engine)
        let sessionID = UUID()
        // The per-run session supplies the audit correlation because the CLI
        // keeps no durable run log; the origin session stays nil.
        await runtime.conversations.ensureSession(
            id: sessionID,
            title: goal.title,
            source: "goal",
            overwrite: true,
            goalID: goal.id
        )
        do {
            let turnSessionID = sessionID
            let turnGoalID = goal.id
            let turnTitle = goal.title
            let orchestrator = runtime.orchestrator
            let outcome = try await GoalAdvancementRunner.advance(
                goal: goal,
                store: store,
                engine: engine,
                runID: sessionID,
                turn: { prompt in
                    let response = try await orchestrator.process(input: UserInput(
                        text: prompt,
                        sessionID: turnSessionID,
                        source: "goal",
                        goalID: turnGoalID
                    ))
                    return GoalAdvancementTurn(
                        text: response.text,
                        isParked: response.isParked,
                        toolActions: response.toolActions,
                        totalTokens: response.totalTokens
                    )
                },
                onPostAdvanceFailure: { error in
                    print(TerminalStyle.dim("Goal '\(turnTitle)' post-advance failed: \(error.localizedDescription)"))
                }
            )
            if outcome.isParked {
                print(TerminalStyle.dim("Goal '\(goal.title)' parked awaiting approval."))
            } else {
                print(TerminalStyle.success("Advanced '\(goal.title)': \(ToolInput.inline(outcome.text, limit: 160))"))
            }
            let pending = await runtime.approvalQueue.count()
            if pending > 0 {
                print(TerminalStyle.tool("\(pending) approval(s) pending. Decide via the engine API approvals inbox."))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print(TerminalStyle.error("Goal '\(goal.title)' failed: \(error.localizedDescription)"))
            throw ExitCode(1)
        }
        await runtime.permissionGate.stopPeriodicCleanup()
    }
}

/// Lists a goal's steps, or marks one step done with an optional note.
struct GoalsStepsCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "steps",
        abstract: "List a goal's steps, or mark one step done."
    )

    /// Goal identifier.
    @Argument(help: "Goal identifier (UUID).")
    var id: String

    /// One-based step number to mark done, as printed by the list.
    @Option(name: .long, help: "One-based step number to mark done.")
    var done: Int?

    /// Operator annotation recorded alongside the move.
    @Option(name: .long, help: "Note recorded alongside the move.")
    var note: String?

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Lists steps, or records one manual move.
    mutating func run() async throws {
        let goalID = try GoalsCLIHelpers.parseGoalID(id)
        // A note without a move would have nowhere to land, so it fails
        // instead of silently dropping the annotation.
        if done == nil, note != nil {
            throw ValidationError("--note requires --done.")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        let store = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        guard let goal = try await store.goal(id: goalID) else {
            print(TerminalStyle.error("Unknown goal \(id)."))
            throw ExitCode(1)
        }
        let ordered = await ((try? store.steps(goalID: goalID)) ?? []).sorted { $0.ordinal < $1.ordinal }
        guard let stepNumber = done else {
            guard !ordered.isEmpty else {
                print(TerminalStyle.dim("Goal '\(goal.title)' has no steps yet."))
                return
            }
            print("Steps for '\(goal.title)' (\(ordered.count)):")
            for step in ordered {
                GoalsCLIHelpers.printStepRow(step: step)
            }
            return
        }
        // An empty plan has no valid number, so it fails with a named reason
        // instead of a degenerate range in the message.
        guard !ordered.isEmpty else {
            throw ValidationError("Goal '\(goal.title)' has no steps yet.")
        }
        guard (1 ... ordered.count).contains(stepNumber) else {
            throw ValidationError("--done must be 1...\(ordered.count) (got \(stepNumber)).")
        }
        // Numbers print one-based while storage stays zero-based, so the move
        // resolves through the ordinal instead of trusting the row position.
        guard let step = ordered.first(where: { $0.ordinal == stepNumber - 1 }) else {
            throw ValidationError("--done must be 1...\(ordered.count) (got \(stepNumber)).")
        }
        // A blank note preserves history instead of wiping prior text with
        // whitespace; the store keeps prior notes on nil.
        let trimmedNote: String? = {
            guard let note else { return nil }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        do {
            try await store.setStepStatus(
                goalID: goalID,
                stepID: step.id,
                status: .done,
                notes: trimmedNote,
                lastRunID: nil
            )
        } catch let error as GoalStoreError {
            print(TerminalStyle.error("Failed to move step \(stepNumber): \(GoalsCLIHelpers.storeErrorMessage(error))"))
            throw ExitCode(1)
        }
        print(TerminalStyle.success("Marked step \(stepNumber) done for '\(goal.title)'."))
    }
}

/// Shared loading, parsing, and rendering for the goals subcommands.
enum GoalsCLIHelpers {
    /// Headless collaborators for one manual advancement turn.
    struct AdvanceRuntime {
        /// Orchestrator executing the advancement turn.
        let orchestrator: Orchestrator
        /// Sessions owner for the per-run goal session.
        let conversations: ConversationManager
        /// Queue holding gated writes filed without prompting.
        let approvalQueue: ApprovalQueue
        /// Trust gate owning the periodic cleanup reaper for this run.
        let permissionGate: PermissionGate
    }

    /// Parses a goal identifier, failing on non-UUID input.
    /// - Parameter raw: Raw identifier text.
    /// - Returns: Parsed identifier.
    static func parseGoalID(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ValidationError("Goal id must be a UUID (got '\(raw)').")
        }
        return id
    }

    /// Parses an optional status filter, accepting the camelCase alias for the
    /// parked state so CLI flags and dashboard selects agree.
    ///
    /// Thin CLI wrapper over the shared validator so flags and REST filters
    /// share one exact-plus-alias rule while keeping the `ValidationError`
    /// idiom locally.
    /// - Parameter raw: Raw status value, or nil when unfiltered.
    /// - Returns: Parsed filter, or nil.
    static func parseStatusFilter(_ raw: String?) throws -> GoalStatus? {
        do {
            return try GoalValidation.parseGoalStatusFilter(raw)
        } catch let error as GoalValidationError {
            switch error {
            case let .unknownGoalStatus(value):
                throw ValidationError("Unknown status '\(value)'. Expected active, paused, needs_input, achieved, or abandoned.")
            case .emptyGoalStatus:
                throw ValidationError("Unknown status ''. Expected active, paused, needs_input, achieved, or abandoned.")
            default:
                throw ValidationError("Unknown status. Expected active, paused, needs_input, achieved, or abandoned.")
            }
        }
    }

    /// Validates an optional cadence hint against the steady pursuit bounds.
    ///
    /// Thin CLI wrapper over the config-owned validator so the CLI and the
    /// dashboard share one range while keeping their own error idioms.
    /// - Parameter raw: Raw interval, or nil when omitted.
    /// - Returns: Validated interval, or nil.
    static func validatedCadence(_ raw: Int?) throws -> Int? {
        do {
            return try GoalsConfig.validateCadence(raw)
        } catch let error as GoalValidationError {
            switch error {
            case let .cadenceOutOfRange(value):
                let minCadence = GoalsConfig.minStepIntervalMinutes
                let maxCadence = GoalsConfig.maxStepIntervalMinutes
                throw ValidationError("--interval-minutes must be between \(minCadence) and \(maxCadence) (got \(value)).")
            default:
                throw ValidationError("--interval-minutes is invalid.")
            }
        }
    }

    /// Builds the durable store plus the pursuit engine over the serving provider.
    ///
    /// The engine needs an injected provider for planning even though the store
    /// alone serves reads; the default provider wins because manual management
    /// has no per-call override. A disabled section still builds so reads work,
    /// while creation and advancement refuse through their own honest guards.
    /// - Parameters:
    ///   - loaded: Resolved config plus its source URL.
    ///   - providerName: Provider override, or nil for the configured default.
    /// - Returns: Engine plus its store.
    static func makeEngine(
        loaded: CLIConfigLoader.LoadedConfig,
        providerName: String?
    ) async throws -> (GoalEngine, GoalStore) {
        let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
        guard !providers.isEmpty else {
            print(TerminalStyle.error("No LLM providers are enabled. Check [llm.providers.*] in \(loaded.url.path)."))
            throw ExitCode(1)
        }
        guard let selected = CLIProviderBuilder.selectProvider(
            named: providerName,
            from: providers,
            config: loaded.config.llm
        ) else {
            let names = providers.map(\.name).sorted().joined(separator: ", ")
            print(TerminalStyle.error("Unknown provider '\(providerName ?? "")'. Available: \(names)."))
            throw ExitCode(1)
        }
        let store = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        let engine = GoalEngine(store: store, llm: selected, config: loaded.config.goals)
        return (engine, store)
    }

    /// Wires the headless orchestrator stack for one manual advancement turn.
    ///
    /// Mirrors the scheduler foreground loop: one shared secrets instance, the
    /// same goal stack the service advances, and a headless approval handler
    /// so gated writes file pending approvals instead of prompting.
    /// - Parameters:
    ///   - loaded: Resolved config plus its source URL.
    ///   - store: Durable goal registry.
    ///   - engine: Pursuit engine composing prompts and bumping due dates.
    /// - Returns: Runtime collaborators for the turn.
    static func makeAdvanceRuntime(
        loaded: CLIConfigLoader.LoadedConfig,
        store: GoalStore,
        engine: GoalEngine
    ) async throws -> AdvanceRuntime {
        let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
        guard let selected = CLIProviderBuilder.selectProvider(named: nil, from: providers, config: loaded.config.llm) else {
            let names = providers.map(\.name).sorted().joined(separator: ", ")
            print(TerminalStyle.error("Unknown provider. Available: \(names)."))
            throw ExitCode(1)
        }
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory)
        let conversations = ConversationManager(episodesDBPath: loaded.config.memory.episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            cliPrintError(TerminalStyle.dim("Could not load conversation history; starting fresh."))
        }
        let episodesDB = (loaded.config.memory.episodesDBPath as NSString).expandingTildeInPath
        let trustStore = SQLiteTrustStore(dbPath: episodesDB)
        let permissionGate = await PermissionGate.load(
            store: trustStore,
            pluginsDir: URL(fileURLWithPath: (loaded.config.plugins.pluginsDir as NSString).expandingTildeInPath)
        )
        await permissionGate.updateBashConfig(loaded.config.bash)
        await permissionGate.startPeriodicCleanup()
        let approvalQueue = ApprovalQueue(permissionGate: permissionGate)
        let headlessHandler = await approvalQueue.headlessApprovalHandler()
        let embedder = EmbeddingsBackendFactory.makeBackend(
            memoryEmbeddingBackend: loaded.config.memory.embeddingBackend,
            router: LLMRouter(providers: providers)
        )
        let sharedSecrets = SecretsManager()
        let toolBus = await CLIShared.makeToolBus(
            emailConfig: loaded.config.email,
            filesConfig: loaded.config.files,
            bashConfig: loaded.config.bash,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            approvalHandler: headlessHandler,
            sandboxConfig: loaded.config.sandbox,
            embedder: embedder,
            pluginConfig: loaded.config.plugins,
            episodesDBPath: loaded.config.memory.episodesDBPath,
            browserConfig: loaded.config.browser,
            llmConfig: loaded.config.llm,
            desktopConfig: loaded.config.desktop,
            securityConfig: loaded.config.security,
            secrets: sharedSecrets,
            goalsConfig: loaded.config.goals,
            goalEngine: engine,
            goalStore: store,
            goalConversations: conversations
        )
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: toolBus,
            llm: selected,
            memoryEngine: memoryEngine,
            embedder: embedder,
            compactionThresholdPercent: loaded.config.engine.compactionThresholdPercent,
            securityConfig: loaded.config.security,
            recallBudgets: loaded.config.memory.recallBudgets
        )
        return AdvanceRuntime(
            orchestrator: orchestrator,
            conversations: conversations,
            approvalQueue: approvalQueue,
            permissionGate: permissionGate
        )
    }

    /// Flips one goal's lifecycle state without spending a model turn.
    ///
    /// Status moves need no provider because the store owns the transition and
    /// its event; only creation, planning, and advancement build the engine.
    /// - Parameters:
    ///   - id: Raw goal identifier.
    ///   - configPath: Explicit config path, if any.
    ///   - status: Destination lifecycle state.
    ///   - verb: Past-tense verb for the confirmation line.
    static func setStatus(id: String, configPath: String?, status: GoalStatus, verb: String) async throws {
        let goalID = try parseGoalID(id)
        let loaded = try CLIConfigLoader.loadConfig(path: configPath)
        let store = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        guard try await store.goal(id: goalID) != nil else {
            print(TerminalStyle.error("Unknown goal \(id)."))
            throw ExitCode(1)
        }
        do {
            try await store.setStatus(goalID: goalID, status: status)
        } catch let error as GoalStoreError {
            print(TerminalStyle.error("Failed to update goal \(id): \(GoalsCLIHelpers.storeErrorMessage(error))"))
            throw ExitCode(1)
        }
        print(TerminalStyle.success("\(verb) goal \(goalID.uuidString)."))
    }

    /// Prints one goal row with its finished-versus-planned tally.
    /// - Parameters:
    ///   - goal: Stored goal snapshot.
    ///   - steps: Full plan ordered by ordinal.
    static func printGoalRow(goal: Goal, steps: [GoalStep]) {
        let done = steps.filter { $0.status == .done }.count
        let state: String = switch goal.status {
        case .active:
            TerminalStyle.success("●")
        case .paused, .needsInput:
            TerminalStyle.tool("●")
        case .achieved, .abandoned:
            TerminalStyle.dim("○")
        }
        print("")
        print("  \(state) \(goal.title) \(TerminalStyle.dim("[\(goal.status.rawValue)] \(done)/\(steps.count) \(goal.id.uuidString)"))")
    }

    /// Prints one plan step with its one-based number.
    /// - Parameter step: Stored step snapshot.
    static func printStepRow(step: GoalStep) {
        let marker = step.status == .done ? TerminalStyle.success("✓") : TerminalStyle.dim("·")
        print("  \(marker) \(step.ordinal + 1). [\(step.status.rawValue)] \(step.title)")
        if let notes = step.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print(TerminalStyle.dim("      \(notes)"))
        }
    }

    /// Formats an instant for terminal display in the local zone.
    /// - Parameter date: Instant to format.
    /// - Returns: Short date plus short time.
    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Surfaces the store's own detail instead of the generic NSError line.
    ///
    /// `GoalStoreError` carries its reason as an associated value with no
    /// `LocalizedError` conformance, so interpolating the error would print a
    /// domain code instead of the cause; unwrapping keeps the failure honest.
    /// - Parameter error: Store failure.
    /// - Returns: Human-readable detail.
    static func storeErrorMessage(_ error: GoalStoreError) -> String {
        switch error {
        case let .storeUnavailable(detail),
             let .persistenceFailed(detail),
             let .notFound(detail):
            detail.isEmpty ? String(describing: error) : detail
        }
    }
}
