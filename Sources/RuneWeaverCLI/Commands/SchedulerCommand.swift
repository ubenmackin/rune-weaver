// Rune Weaver CLI — Scheduled job management and foreground runner loop.
//
// Bridges configuration to runtime execution: lists configured jobs from
// `config.toml` and runs the headless scheduler foreground loop. The runner
// evaluates cron expressions and email-arrival triggers, firing due jobs under
// stable session identifiers with run logging and notifications.

import ArgumentParser
import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import RuneWeaverTools

/// Manages scheduled jobs: list config jobs and run the foreground loop.
///
/// The scheduler fires cron schedules (`minute hour day month weekday`
/// plus `@hourly`/`@daily`/`@weekly` shortcuts) and email-arrival poll
/// rules (`poll_account`/`poll_query`/`poll_mailbox`) from
/// `[[scheduler.jobs]]`. `scheduler list` prints the configured jobs;
/// `scheduler run` stays in the foreground, firing due jobs headless
/// under stable job sessions with run logging and macOS notifications.
/// Gated writes file pending approvals instead of prompting.
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
///
/// Loads `[[scheduler.jobs]]`, then polls for due jobs every
/// `--interval` seconds. Each fire runs headless through the
/// orchestrator under the stable job session (`source "scheduler"`) so
/// episodic memory keeps one session per job; `readOnly` and `trusted`
/// tools execute directly while `requiresApproval` tools file pending
/// approvals instead of prompting. Overlapping fires for the same job
/// skip with a log line. Fires append to the terminal log and post a
/// macOS notification. `--once` checks once and exits for scripting.
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
        let memoryEngine = CLIShared.memoryEngine(for: loaded.config.memory)
        let conversations = ConversationManager(episodesDBPath: loaded.config.memory.episodesDBPath)
        do {
            try await conversations.loadAll()
        } catch {
            cliPrintError(TerminalStyle.dim("Could not load conversation history; starting fresh."))
        }
        let permissionGate = PermissionGate()
        let approvalQueue = ApprovalQueue(permissionGate: permissionGate)
        let headlessHandler = await approvalQueue.headlessApprovalHandler()
        let toolBus = await CLIShared.makeToolBus(
            emailConfig: loaded.config.email,
            memoryEngine: memoryEngine,
            permissionGate: permissionGate,
            approvalHandler: headlessHandler,
            sandboxConfig: loaded.config.sandbox
        )
        let orchestrator = Orchestrator(
            conversations: conversations,
            toolBus: toolBus,
            llm: selected,
            memoryEngine: memoryEngine
        )
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
        let engine = SchedulerEngine(
            jobs: schedulerJobs,
            turnRunner: turnRunner,
            pollChecker: pollChecker,
            logger: { message in
                print(TerminalStyle.dim(message))
            },
            notifier: MacOSSchedulerNotifier()
        )
        print(TerminalStyle.dim("Scheduler running \(schedulerJobs.count) job(s) every \(interval)s. Ctrl+C to stop."))
        var lastCheck = Date().addingTimeInterval(TimeInterval(-interval))
        if once {
            let results = await engine.runAllDue(at: Date(), lastCheck: lastCheck)
            await report(results: results, queue: approvalQueue)
            return
        }
        while true {
            let now = Date()
            let results = await engine.runAllDue(at: now, lastCheck: lastCheck)
            lastCheck = now
            await report(results: results, queue: approvalQueue)
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break
            }
        }
        print(TerminalStyle.dim("Scheduler stopped."))
    }

    /// Reports one check batch: per-job outcomes plus pending approvals.
    /// - Parameters:
    ///   - results: Outcomes from the check window.
    ///   - queue: Headless approval queue holding gated writes.
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

    /// Observes current message ids for a poll rule via `email.search`.
    ///
    /// Runs the search through the headless tool bus (read-only, no
    /// approval) and decodes the `EmailSearchEnvelope` ids. Failures and
    /// undecodable output yield an empty check so one unreadable mailbox
    /// never stops the loop and never fires.
    /// - Parameters:
    ///   - rule: Poll rule to check.
    ///   - bus: Headless tool bus serving `email.search`.
    /// - Returns: Currently observed message ids.
    private static func pollCheck(rule: EmailPollRule, bus: ToolBus) async -> SchedulerPollCheck {
        let payload = pollSearchJSON(rule: rule)
        let result = await bus.execute(
            toolCall: ToolInput(toolName: "email.search", argumentsJSON: payload),
            context: ToolContext(conversationID: UUID())
        )
        guard !result.isError else { return .empty }
        guard let data = result.content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(EmailSearchEnvelope.self, from: data)
        else { return .empty }
        return SchedulerPollCheck(ids: envelope.messages.map(\.id))
    }

    /// Encodes `email.search` arguments for a poll rule.
    ///
    /// The payload holds only strings and ints, so `JSONSerialization`
    /// cannot fail in practice. On failure no empty-account search is
    /// emitted (an empty account would widen scope unpredictably);
    /// instead the failure is asserted in debug and a `{}` sentinel is
    /// returned so the poll check decodes to empty (no fire).
    /// - Parameter rule: Poll rule to encode.
    /// - Returns: JSON arguments document.
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
