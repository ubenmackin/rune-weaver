// Rune Weaver Core — Proactive Wayfinder engine that proposes next moves.

import Foundation
import os

/// One parsed suggestion before dedup and persistence.
struct ParsedIdea: Sendable, Equatable {
    /// Suggestion family emitted by the model.
    let kind: IdeaKind
    /// Bounded title, already trimmed to the documented cap.
    let title: String
    /// Explanation text, possibly empty. For a plan adjustment carrying structured steps this holds
    /// those steps newline-separated so the replacement plan survives the existing body column
    /// without a schema change.
    let body: String
    /// Goal a plan adjustment targets, copied by the model from the goal id
    /// quoted beside each recent outcome. Nil for every other kind and for a
    /// model that omits the link.
    let goalID: UUID?
}

/// Resumes a checked continuation exactly once across the review race.
private final class ReviewResumption: Sendable {
    /// Continuation captured at the start of the race, cleared on first resume.
    private let state: OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>

    /// Creates a resumption owning the awaiting continuation.
    /// - Parameter continuation: Continuation to resume once.
    init(continuation: CheckedContinuation<String?, Never>) {
        self.state = OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>(initialState: continuation)
    }

    /// Resumes the awaiting caller once; later calls are no-ops.
    /// - Parameter value: Review text, or nil when the timeout won.
    func resume(_ value: String?) {
        let pending = state.withLock { state -> CheckedContinuation<String?, Never>? in
            let continuation = state
            state = nil
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Proactive suggestion engine over a durable idea store.
public actor IdeasEngine {
    /// Longest title accepted from the model; longer titles truncate rather than drop.
    public static let maxTitleLength = 80
    /// How far back recent goal outcomes are considered.
    public static let outcomeLookback: TimeInterval = 7 * 24 * 60 * 60
    /// Upper bound on recent goal outcomes quoted in the review prompt.
    public static let maxOutcomeEvents = 20
    /// Upper bound on structured replacement steps parsed from one suggestion.
    public static let maxAdjustmentSteps = 12
    /// Longest single replacement step accepted from the model; longer text truncates.
    public static let maxAdjustmentStepLength = 200

    /// Durable idea persistence and dedup.
    private let store: IdeasStore
    /// Injected language provider shared with chat turns; never self-built so
    /// suggestions observe the same model, routing, and fallback posture.
    private var llm: any LLMProvider
    /// Suggestion policy clamped at init so hand-built configs degrade to the
    /// nearest sane bound instead of refusing to run.
    private let config: IdeasConfig
    /// Goal events read over the same shared database as the idea store.
    private let goalStore: GoalStore
    /// Optional provider of a short memory-facts summary appended to the prompt.
    private let memoryFacts: @Sendable () async -> [String]

    /// Creates an ideas engine over shared collaborators. store: Durable idea
    /// persistence and dedup.
    public init(
        store: IdeasStore,
        llm: any LLMProvider,
        config: IdeasConfig,
        memoryFacts: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.store = store
        self.llm = llm
        self.config = config.clamped()
        self.goalStore = GoalStore(dbPath: store.dbPath)
        self.memoryFacts = memoryFacts
    }

    /// Dynamically updates the serving LLM provider without a restart.
    public func updateLLM(_ provider: any LLMProvider) {
        self.llm = provider
    }

    /// Whether proactive idea generation is enabled by configuration.
    /// Triggers consult this before spending a review call so a disabled
    /// install stays silent even when a stale caller invokes generation.
    public var isEnabled: Bool {
        config.enabled
    }

    /// Runs one review cycle and persists any fresh suggestions.
    @discardableResult
    public func generate() async -> [Idea] {
        guard config.enabled else { return [] }
        let maxPerCycle = config.maxPerCycle
        guard maxPerCycle > 0 else { return [] }
        let outcomes = await recentOutcomes()
        let facts = await memoryFacts()
        let prompt = Self.reviewPrompt(outcomes: outcomes, facts: facts, maxPerCycle: maxPerCycle)
        guard let raw = await collectReviewText(prompt: prompt),
              let parsed = Self.parseIdeas(from: raw, maxCount: maxPerCycle)
        else { return [] }
        // Dedup is owned solely by the store's batch append, which skips titles that duplicate an
        // existing non-dismissed idea.
        let now = Date()
        let ideas = parsed.map { candidate in
            Idea(
                kind: candidate.kind,
                title: candidate.title,
                body: candidate.body,
                goalID: candidate.goalID,
                status: .proposed,
                createdAt: now,
                updatedAt: now
            )
        }
        do {
            return try await store.append(ideas: ideas)
        } catch {
            RuneWeaverLog.scheduler.warning("IdeasEngine: failed to persist generated ideas: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Prompt assembly

    /// Builds the single-shot review instruction. Only the bounded outcome tail and the supplied
    /// facts travel, so long goal histories never crowd the review call.
    static func reviewPrompt(outcomes: [String], facts: [String], maxPerCycle: Int) -> String {
        var lines: [String] = []
        lines.append("You are the Wayfinder for Rune Weaver, a personal assistant harness.")
        lines.append("Propose at most \(maxPerCycle) proactive next moves the owner would likely value, based on recent goal outcomes and known facts.")
        lines.append("")
        lines.append("Recent goal outcomes:")
        if outcomes.isEmpty {
            lines.append("- None yet.")
        } else {
            lines.append(contentsOf: outcomes)
        }
        lines.append("")
        lines.append("Memory facts:")
        if facts.isEmpty {
            lines.append("- None yet.")
        } else {
            lines.append(contentsOf: facts.map { "- \($0)" })
        }
        lines.append("")
        lines.append(
            "Reply with ONLY a JSON array of objects like "
                + "[{\"kind\":\"tip\",\"title\":\"Short title\",\"body\":\"One or two sentences.\"},"
                + "{\"kind\":\"plan_adjustment\",\"title\":\"Short title\","
                + "\"steps\":[\"First concrete step\",\"Second concrete step\"],\"goalId\":\"<goal id>\"}]."
        )
        lines.append("\"kind\" must be one of: \(IdeaKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        lines.append(
            "For \"plan_adjustment\" supply a \"steps\" array of at most "
                + "\(Self.maxAdjustmentSteps) short concrete replacement steps, one action per entry, "
                + "and omit \"body\"; every other kind supplies a \"body\" sentence and omits \"steps\"."
        )
        lines.append(
            "For \"plan_adjustment\", copy the \"goal_id\" of the goal the adjustment targets from the "
                + "recent outcomes above into a \"goalId\" field so the suggestion can be linked back; "
                + "omit \"goalId\" for every other kind."
        )
        lines.append("Keep each \"title\" at most \(Self.maxTitleLength) characters. No prose outside the array.")
        return lines.joined(separator: "\n")
    }

    /// Extracts bounded suggestions from chatty model output. A plan adjustment keeps the model's
    /// `goalId` link so it can be accepted against its goal; other kinds never carry one.
    static func parseIdeas(from raw: String, maxCount: Int) -> [ParsedIdea]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("```") {
            // Fence-tolerant: drop markers rather than trying to pair them, so
            // unclosed or language-tagged fences still expose the array.
            text = text.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            text = text.replacingOccurrences(of: "```", with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let open = text.firstIndex(of: "["),
              let close = text.lastIndex(of: "]"),
              open < close
        else { return nil }
        let candidate = String(text[open ... close])
        guard let data = candidate.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [Any]
        else { return nil }
        var ideas: [ParsedIdea] = []
        for element in array {
            guard let object = element as? [String: Any] else { continue }
            let rawTitle = (object["title"] as? String) ?? ""
            let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }
            let title = String(trimmedTitle.prefix(Self.maxTitleLength))
            var body = ((object["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawKind = (object["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = rawKind.flatMap(IdeaKind.init(rawValue:)) ?? .tip
            // A plan adjustment carries its replacement plan as a structured `steps` array; encode
            // it newline-separated into `body` so the accept route reads a contract-backed plan
            // instead of re-splitting free-form prose, and the existing body column needs no.
            let goalID = kind == .planAdjustment ? Self.parseGoalID(from: object) : nil
            if kind == .planAdjustment {
                let steps = Self.normalizedSteps(from: (object["steps"] as? [Any]) ?? [])
                if !steps.isEmpty {
                    body = steps.joined(separator: "\n")
                }
            }
            ideas.append(ParsedIdea(kind: kind, title: title, body: body, goalID: goalID))
        }
        guard !ideas.isEmpty else { return nil }
        return Array(ideas.prefix(max(0, maxCount)))
    }

    /// Normalizes one model-supplied step list into bounded, non-empty entries.
    static func normalizedSteps(from raw: [Any]) -> [String] {
        raw.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxAdjustmentSteps)
            .map { String($0.prefix(Self.maxAdjustmentStepLength)) }
    }

    /// Extracts an optional goal link from one model-supplied object. A blank or malformed value
    /// degrades to nil rather than dropping the suggestion.
    static func parseGoalID(from object: [String: Any]) -> UUID? {
        let raw = (object["goalId"] as? String)
            ?? (object["goalID"] as? String)
            ?? (object["goal_id"] as? String)
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)
    }

    // MARK: - Review internals

    /// Reads recent goal outcomes worth reviewing. Only terminal completions and blocked steps
    /// travel: those are the events that reveal what worked and what stalled, which is what a
    /// suggestion should build on.
    private func recentOutcomes() async -> [String] {
        let since = Date().addingTimeInterval(-Self.outcomeLookback)
        let events: [GoalObservedEvent]
        do {
            events = try await goalStore.observedEvents(since: since, limit: Self.maxOutcomeEvents)
        } catch is CancellationError {
            return []
        } catch {
            RuneWeaverLog.stores.error("IdeasEngine: failed to load recent outcome events: \(error.localizedDescription)")
            return []
        }
        return events
            .filter {
                $0.kind == GoalEventKind.completed.rawValue || $0.kind == GoalEventKind.stepBlocked.rawValue
            }
            .map { event in
                // The goal id leads the line so the model can copy it verbatim
                // into the adjustment's `goalId` field; an event without a link
                // (never expected for goal audit rows) still quotes its outcome.
                if let goalID = event.goalID {
                    return "- goal_id=\(goalID.uuidString) \(event.kind): \(event.message)"
                }
                return "- \(event.kind): \(event.message)"
            }
    }

    /// Collects one review reply under a wall-clock timeout. Every failure degrades to nil, which
    /// the caller turns into an empty array.
    private func collectReviewText(prompt: String) async -> String? {
        let timeoutSeconds = max(1, config.timeoutSeconds)
        let timeoutNS = UInt64(timeoutSeconds) * 1_000_000_000
        let provider = Task { await self.collectOnce(prompt: prompt) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumption = ReviewResumption(continuation: continuation)
                Task {
                    let text = await provider.value
                    resumption.resume(text)
                }
                Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNS)
                        provider.cancel()
                        resumption.resume(nil)
                    } catch {
                        return
                    }
                }
            }
        } onCancel: {
            // Caller cancellation still reaches the provider so a cooperative
            // stream ends promptly; a non-cooperative one stays bounded by the
            // timeout side of the race instead of by the losing task.
            provider.cancel()
        }
    }

    /// Runs the single review chat call and folds its stream to text.
    private func collectOnce(prompt: String) async -> String? {
        let messages = [Message(role: .user, content: prompt)]
        let stream = llm.chat(messages: messages, tools: [])
        var text = ""
        for await chunk in stream {
            if Task.isCancelled {
                return nil
            }
            if chunk.errorMessage != nil {
                return nil
            }
            text += chunk.delta
            if chunk.isFinished {
                break
            }
        }
        if Task.isCancelled {
            return nil
        }
        return text
    }
}
