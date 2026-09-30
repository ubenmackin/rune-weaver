// Rune Weaver CLI — Scheduled job management and foreground runner loop.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Manages scheduled jobs: list config jobs and run the foreground loop.
struct SchedulerCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "scheduler",
        abstract: "List scheduled jobs and run the foreground scheduler loop.",
        subcommands: [SchedulerListCommand.self, SchedulerRunCommand.self]
    )
}

/// Lists every `[[scheduler.jobs]]` entry from the resolved config.
struct SchedulerListCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List scheduled jobs from config.toml."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Prints the configured jobs.
    mutating func run() async throws {
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); showing built-in defaults."))
        }
        // Durable SQLite state is the single source of truth; the config
        // file only seeds an empty database. Direct-core read keeps chat
        // and scheduler paths off the service layer.
        let dbJobs = await SchedulerJobConfig.persistedConfigs(from: loaded.config.memory.episodesDBPath)
        let jobs = dbJobs.isEmpty ? loaded.config.scheduler.jobs : dbJobs
        guard !jobs.isEmpty else {
            print(TerminalStyle.dim("No scheduler jobs configured. Add [[scheduler.jobs]] to \(loaded.url.path)."))
            return
        }
        print("Scheduler jobs (\(jobs.count)) — \(loaded.url.path)")
        for job in jobs {
            let state = job.enabled ? TerminalStyle.success("●") : TerminalStyle.dim("○")
            print("")
            print("  \(state) \(job.name)\(job.enabled ? "" : " (disabled)")")
            if let schedule = job.schedule?.trimmingCharacters(in: .whitespacesAndNewlines), !schedule.isEmpty {
                print(TerminalStyle.dim("    schedule: \(schedule)"))
            }
            if let poll = job.poll {
                let mailbox = poll.trimmedMailbox ?? "(all mailboxes)"
                let pollAccount = "    poll: \(poll.trimmedAccount) '\(poll.query)'"
                let pollDetail = pollAccount + " in \(mailbox) every \(poll.pollIntervalSeconds)s limit \(poll.limit)"
                print(TerminalStyle.dim(pollDetail))
            }
            print(TerminalStyle.dim("    prompt: \(ToolInput.inline(job.prompt, limit: 160))"))
        }
    }
}

/// Runs the foreground scheduler loop with single-flight locking.
struct SchedulerRunCommand: AsyncParsableCommand {
    /// Top-level command configuration.
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the foreground scheduler loop (single-flight, skip-with-log)."
    )

    /// Config file path override.
    @Option(name: .long, help: "Path to config.toml (defaults to ~/.runeweaver/config.toml).")
    var config: String?

    /// Provider name overriding `llm.default_provider`.
    @Option(name: .long, help: "Override the configured LLM provider (e.g. mlx, openrouter, local).")
    var provider: String?

    /// Seconds between due checks.
    @Option(name: .long, help: "Seconds between due checks.")
    var interval: Int = 60

    /// Check due jobs once and exit.
    @Flag(name: .long, help: "Check due jobs once and exit.")
    var once: Bool = false

    /// Loads config, wires headless collaborators, and runs the loop.
    mutating func run() async throws {
        guard (1 ... 86400).contains(interval) else {
            throw ValidationError("--interval must be 1...86400 seconds (got \(interval)).")
        }
        let loaded = try CLIConfigLoader.loadConfig(path: config)
        if loaded.isFallback {
            print(TerminalStyle.dim("No config found at \(loaded.url.path); using built-in defaults."))
        }
        let dbJobs = await SchedulerJobConfig.persistedConfigs(from: loaded.config.memory.episodesDBPath)
        let schedulerJobs = dbJobs.isEmpty ? loaded.config.scheduler.jobs : dbJobs
        guard !schedulerJobs.isEmpty else {
            print(TerminalStyle.dim("No scheduler jobs configured. Add [[scheduler.jobs]] to \(loaded.url.path)."))
            return
        }
        do {
            for job in schedulerJobs {
                try job.validate()
            }
        } catch {
            print(TerminalStyle.error("Invalid scheduler job: \(error)"))
            throw ExitCode(1)
        }
        let providers = await CLIProviderBuilder.buildProviders(from: loaded.config.llm)
        guard !providers.isEmpty else {
            print(TerminalStyle.error("No LLM providers are enabled. Check [llm.providers.*] in \(loaded.url.path)."))
            throw ExitCode(1)
        }
        guard let selected = CLIProviderBuilder.selectProvider(
            named: provider,
            from: providers,
            config: loaded.config.llm
        ) else {
            let names = providers.map(\.name).sorted().joined(separator: ", ")
            print(TerminalStyle.error("Unknown provider '\(provider ?? "")'. Available: \(names)."))
            throw ExitCode(1)
        }
        let runtime = try await Self.makeHeadlessRuntime(
            jobs: schedulerJobs,
            loaded: loaded,
            providers: providers,
            selected: selected
        )
        let engine = runtime.engine
        let approvalQueue = runtime.approvalQueue
        let permissionGate = runtime.permissionGate
        print(TerminalStyle.dim("Scheduler running \(schedulerJobs.count) job(s) every \(interval)s. Ctrl+C to stop."))
        var lastCheck = Date().addingTimeInterval(TimeInterval(-interval))
        if once {
            let now = Date()
            var results = await engine.runAllDue(at: now, lastCheck: lastCheck)
            results += try await advanceDueGoals(now: now, runtime: runtime, goalsConfig: loaded.config.goals)
            await report(results: results, queue: approvalQueue)
            await permissionGate.stopPeriodicCleanup()
            return
        }
        while true {
            let now = Date()
            var results = await engine.runAllDue(at: now, lastCheck: lastCheck)
            lastCheck = now
            results += try await advanceDueGoals(now: now, runtime: runtime, goalsConfig: loaded.config.goals)
            await report(results: results, queue: approvalQueue)
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break
            }
        }
        // Stop the trust reaper explicitly; nothing else owns its lifetime
        // past the foreground loop.
        await permissionGate.stopPeriodicCleanup()
        print(TerminalStyle.dim("Scheduler stopped."))
    }

    /// Headless collaborators for one foreground-loop invocation.
    private struct HeadlessRuntime {
        /// Engine firing due jobs headless.
        let engine: SchedulerEngine
        /// Queue holding gated writes filed without prompting.
        let approvalQueue: ApprovalQueue
        /// Trust gate owning the periodic cleanup reaper for this run.
        let permissionGate: PermissionGate
        /// Durable goal registry backing headless due advancement.
        let goalStore: GoalStore
        /// Pursuit engine composing advancement prompts and bumping due dates.
        let goalEngine: GoalEngine
        /// Sessions owner for per-run goal sessions and chip linkage.
        let conversations: ConversationManager
        /// Headless goal turn runner: prompt plus fresh session plus goal link.
        let goalTurnRunner: GoalHeadlessTurnRunner
    }

    /// Headless goal turn runner shape: prompt, fresh session, goal link.
    /// Returns the full turn outcome so parked approvals skip their due bump
    /// exactly like the service worker instead of mis-recording as finished.
    private typealias GoalHeadlessTurnRunner = @Sendable (String, UUID, UUID) async throws -> GoalAdvancementTurn

    /// Wires headless collaborators for the foreground loop.
    /// - Throws: `ExitCode(1)` when the security policy cannot be verified, so
    ///   the headless loop never runs with an unsupervised `api.request`.
    private static func makeHeadlessRuntime(
        jobs: [SchedulerJobConfig],
        loaded: CLIConfigLoader.LoadedConfig,
        providers: [any LLMProvider],
        selected: any LLMProvider
    ) async throws -> HeadlessRuntime {
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
        // One shared secrets instance per scheduler invocation so the headless
        // bus observes one fallback store instead of per-tool state.
        let sharedSecrets = SecretsManager()
        // The headless bus carries the same goal stack the service advances so
        // headless turns can create, read, and record goal progress instead of
        // answering `invalid_tool`; a disabled `[goals]` section still
        // registers and fails closed inside each tool.
        let goalStore = GoalStore(dbPath: loaded.config.memory.episodesDBPath)
        // Ideas share the goals database and the serving provider, mirroring
        // the service bootstrap: the engine stays nil while `[ideas]` is
        // disabled so a stock install never spends a background review call,
        // and post-advance stays quiet instead of logging suggestions that
        // were never generated.
        let ideasStore = IdeasStore(dbPath: goalStore.dbPath)
        let headlessIdeasEngine = Self.makeHeadlessIdeasEngine(
            store: ideasStore,
            llm: selected,
            config: loaded.config.ideas,
            memoryFacts: { await memoryEngine.getUserProfile().facts.map(\.content) }
        )
        let goalEngine = GoalEngine(store: goalStore, llm: selected, config: loaded.config.goals, ideasEngine: headlessIdeasEngine)
        let toolBus = try await CLIShared.makeToolBus(
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
            goalEngine: goalEngine,
            goalStore: goalStore,
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
        let engine = Self.makeHeadlessSchedulerEngine(jobs: jobs, toolBus: toolBus, orchestrator: orchestrator)
        let goalTurnRunner = Self.makeHeadlessGoalTurnRunner(orchestrator: orchestrator)
        return HeadlessRuntime(
            engine: engine,
            approvalQueue: approvalQueue,
            permissionGate: permissionGate,
            goalStore: goalStore,
            goalEngine: goalEngine,
            conversations: conversations,
            goalTurnRunner: goalTurnRunner
        )
    }

    /// Builds the headless scheduler engine over the shared orchestrator.
    ///
    /// Job prompts run through the same orchestrator as goal turns so headless
    /// execution shares one model posture; polling reads through the headless
    /// bus so arrival checks observe the same tools as the foreground loop.
    /// - Parameters:
    ///   - jobs: Configured jobs the engine fires when due.
    ///   - toolBus: Headless bus backing poll checks.
    ///   - orchestrator: Shared turn runner for job prompts.
    /// - Returns: Engine firing due jobs headless.
    private static func makeHeadlessSchedulerEngine(
        jobs: [SchedulerJobConfig],
        toolBus: ToolBus,
        orchestrator: Orchestrator
    ) -> SchedulerEngine {
        let capturedBus = toolBus
        let pollChecker: SchedulerPollChecker = { rule in
            await SchedulerRunCommand.pollCheck(rule: rule, bus: capturedBus)
        }
        let turnRunner: SchedulerTurnRunner = { prompt, sessionID, source in
            let response = try await orchestrator.process(input: UserInput(
                text: prompt,
                sessionID: sessionID,
                source: source
            ))
            return response.text
        }
        return SchedulerEngine(
            jobs: jobs,
            turnRunner: turnRunner,
            pollChecker: pollChecker,
            logger: { message in
                print(TerminalStyle.dim(message))
            },
            notifier: MacOSSchedulerNotifier()
        )
    }

    /// Builds the headless goal turn runner over the shared orchestrator.
    ///
    /// Goal advancement rides the same orchestrator but tags the goal link so
    /// the turn stamps the session linkage the dashboard chips resolve. The
    /// full outcome travels so a parked turn stays due instead of bumping like
    /// a finished one.
    /// - Parameter orchestrator: Shared turn runner for goal prompts.
    /// - Returns: Goal turn runner mapping prompt plus session plus goal link.
    private static func makeHeadlessGoalTurnRunner(orchestrator: Orchestrator) -> GoalHeadlessTurnRunner {
        { prompt, sessionID, goalID in
            let response = try await orchestrator.process(input: UserInput(
                text: prompt,
                sessionID: sessionID,
                source: "goal",
                goalID: goalID
            ))
            return GoalAdvancementTurn(
                text: response.text,
                isParked: response.isParked,
                toolActions: response.toolActions,
                totalTokens: response.totalTokens
            )
        }
    }

    /// Builds the headless ideas engine when proactive suggestions are enabled.
    ///
    /// Mirrors the service bootstrap's enabled gate so the CLI and service agree
    /// on when a review call may be spent: a disabled install keeps a nil engine
    /// and achievement turns stay quiet instead of spending a model call.
    /// - Parameters:
    ///   - store: Durable idea persistence sharing the goals database.
    ///   - llm: Provider shared with headless turns.
    ///   - config: Suggestion policy.
    ///   - memoryFacts: Memory-facts summary for the review prompt.
    /// - Returns: Wired engine, or nil while `[ideas]` is disabled.
    static func makeHeadlessIdeasEngine(
        store: IdeasStore,
        llm: any LLMProvider,
        config: IdeasConfig,
        memoryFacts: @escaping @Sendable () async -> [String] = { [] }
    ) -> IdeasEngine? {
        guard config.enabled else { return nil }
        return IdeasEngine(store: store, llm: llm, config: config, memoryFacts: memoryFacts)
    }

    /// Advances due goals headless through the shared advancement runner.
    ///
    /// The CLI foreground loop is the second auto-fire runner alongside the
    /// service, so it scans `next_due_at` on every tick just like the worker:
    /// each due goal runs one advancement turn in a fresh goal-linked session,
    /// then bumps its due date so the next firing keeps its rhythm. A disabled
    /// `[goals]` section never spends turns even when stale rows linger. A
    /// parked turn skips its bump until the inbox resume completes, mirroring
    /// the service parked branch; the per-run session supplies the audit
    /// correlation because the headless loop keeps no durable run log.
    /// Achievement-born suggestions persist through the shared runner and are
    /// named on stdout because the headless loop keeps no live hub for the
    /// service's proactive broadcast. There is no nightly suggestion refresh
    /// here: the service worker owns that cadence, so headless surfaces only
    /// the achievement-born batch from each advancement turn.
    /// Cancelled turns stay due and rethrow instead of recording an error
    /// result, so cooperative cancellation always propagates.
    private func advanceDueGoals(now: Date, runtime: HeadlessRuntime, goalsConfig: GoalsConfig) async throws -> [SchedulerRunResult] {
        guard goalsConfig.enabled, await runtime.goalEngine.isEnabled else { return [] }
        let dueGoals: [Goal]
        do {
            dueGoals = try await runtime.goalStore.advanceDue(now: now)
        } catch {
            print(TerminalStyle.dim("Goals due scan failed: \(error.localizedDescription)"))
            return []
        }
        var results: [SchedulerRunResult] = []
        for goal in dueGoals {
            let sessionID = UUID()
            await runtime.conversations.ensureSession(
                id: sessionID,
                title: goal.title,
                source: "goal",
                overwrite: true,
                goalID: goal.id
            )
            let startedAt = Date()
            do {
                let turnRunner = runtime.goalTurnRunner
                let turnSessionID = sessionID
                let turnGoalID = goal.id
                let turnTitle = goal.title
                let outcome = try await GoalAdvancementRunner.advance(
                    goal: goal,
                    store: runtime.goalStore,
                    engine: runtime.goalEngine,
                    runID: sessionID,
                    turn: { prompt in
                        try await turnRunner(prompt, turnSessionID, turnGoalID)
                    },
                    onPostAdvanceFailure: { error in
                        print(TerminalStyle.dim("Goal '\(turnTitle)' post-advance failed: \(error.localizedDescription)"))
                    }
                )
                if outcome.isParked {
                    print(TerminalStyle.dim("Goal '\(goal.title)' parked awaiting approval."))
                }
                // The headless loop keeps no live hub for the service's
                // proactive broadcast, so name the persisted suggestions here
                // instead of dropping the achievement batch silently.
                if let line = Self.achievementIdeasLogLine(goalTitle: goal.title, ideas: outcome.ideas) {
                    print(TerminalStyle.dim(line))
                }
                results.append(SchedulerRunResult(
                    jobName: goal.title,
                    sessionID: sessionID,
                    fired: true,
                    responseText: outcome.text,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    goalID: goal.id
                ))
            } catch is CancellationError {
                // Cancelled turns did not advance, so they stay due for the
                // next tick instead of converting the cancel into an error
                // result.
                throw CancellationError()
            } catch {
                let detail = error.localizedDescription
                cliPrintError(TerminalStyle.error("Goal '\(goal.title)' failed: \(detail)"))
                results.append(SchedulerRunResult(
                    jobName: goal.title,
                    sessionID: sessionID,
                    fired: true,
                    errorMessage: detail,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    goalID: goal.id
                ))
            }
        }
        return results
    }

    /// Formats the headless log line naming achievement-born suggestions.
    ///
    /// The headless loop keeps no live hub for the service's proactive
    /// broadcast, so each finished turn names the suggestions the shared runner
    /// persisted instead of dropping them silently. Titles ride inline-bounded
    /// so one verbose suggestion cannot flood the tick log.
    /// - Parameters:
    ///   - goalTitle: Goal whose turn proposed the suggestions.
    ///   - ideas: Achievement-born suggestions from the turn outcome.
    /// - Returns: Log line, or nil when the turn proposed nothing so quiet
    ///   ticks stay quiet.
    static func achievementIdeasLogLine(goalTitle: String, ideas: [Idea]) -> String? {
        guard !ideas.isEmpty else { return nil }
        let titles = ToolInput.inline(ideas.map(\.title).joined(separator: "; "), limit: 160)
        return "Goal '\(goalTitle)' proposed \(ideas.count) suggestion(s): \(titles)"
    }

    /// Reports one check batch: per-job outcomes plus pending approvals.
    private func report(results: [SchedulerRunResult], queue: ApprovalQueue) async {
        if results.isEmpty {
            print(TerminalStyle.dim("No jobs due."))
        }
        for result in results {
            if result.fired, let text = result.responseText {
                print(TerminalStyle.success("Fired '\(result.jobName)': \(ToolInput.inline(text, limit: 160))"))
            } else if result.fired, let error = result.errorMessage {
                cliPrintError(TerminalStyle.error("Job '\(result.jobName)' failed: \(error)"))
            } else {
                print(TerminalStyle.dim("Skipped '\(result.jobName)': \(result.skippedReason ?? "not due")"))
            }
        }
        let pending = await queue.count()
        if pending > 0 {
            print(TerminalStyle.tool("\(pending) approval(s) pending. Decide via the engine API approvals inbox."))
        }
    }
}

/// Headless email-poll helpers live in an extension so the main command body
/// stays within the type-length bound while keeping the same call sites.
extension SchedulerRunCommand {
    /// Observes current message ids for a poll rule via `email.search`.
    fileprivate static func pollCheck(rule: EmailPollRule, bus: ToolBus) async -> SchedulerPollCheck {
        let payload = pollSearchJSON(rule: rule)
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "email.search", argumentsJSON: payload),
            context: ToolContext(conversationID: UUID())
        )
        guard !result.isError else { return .empty }
        guard let data = result.content.data(using: .utf8) else { return .empty }
        let envelope: EmailSearchEnvelope
        do {
            envelope = try JSONDecoder().decode(EmailSearchEnvelope.self, from: data)
        } catch {
            RuneWeaverLog.scheduler.warning("SchedulerCommand.pollCheck: failed to decode EmailSearchEnvelope: \(error.localizedDescription)")
            return .empty
        }
        return SchedulerPollCheck(ids: envelope.messages.map(\.id))
    }

    /// Encodes `email.search` arguments for a poll rule.
    private static func pollSearchJSON(rule: EmailPollRule) -> String {
        var object: [String: Any] = [
            "account": rule.trimmedAccount,
            "query": rule.query,
            "limit": rule.limit
        ]
        if let mailbox = rule.trimmedMailbox {
            object["mailbox"] = mailbox
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            assertionFailure("pollSearchJSON serialization failed for account '\(rule.trimmedAccount)'")
            return "{}"
        }
        return text
    }
}
