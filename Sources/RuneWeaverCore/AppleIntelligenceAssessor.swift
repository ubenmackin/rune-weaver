// Rune Weaver Core — On-device Apple Intelligence tool safety and impact assessor.

import Foundation
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// On-device safety and impact assessor for tool executions awaiting approval.
public actor AppleIntelligenceAssessor {
    /// Shared singleton instance.
    public static let shared = AppleIntelligenceAssessor()

    /// Budget bounding one model evaluation inside ``assess``.
    ///
    /// Fail-closed bound: the model race never stretches an approval filing.
    /// Filing returns immediately (nil assessment plus background enrichment)
    /// while the model gets at most this long to answer before heuristics win.
    public static let assessmentTimeoutSeconds: Double = 2.5

    /// Minimum spacing between real warm-up model calls.
    ///
    /// Warm-up is advisory: it only makes the next evaluation faster, so it
    /// must never fan out one model call per session creation.
    public static let prewarmDebounceSeconds: Double = 30

    /// Lock-guarded timestamp of the last admitted warm-up.
    ///
    /// Static (not per-instance) so the fire-and-forget entry points can check
    /// the debounce synchronously without an actor hop: the caller never blocks
    /// on isolation just to learn the warm-up was skipped.
    private static let prewarmState = OSAllocatedUnfairLock(initialState: Date?.none)

    /// Creates an assessor.
    public init() {}

    /// Evaluates tool invocation impact and safety.
    ///
    /// Attempts evaluation using macOS 26 Apple Intelligence (`SystemLanguageModel.default`)
    /// with a 2.5-second deadline. Falls back gracefully to rule-based heuristics if the system
    /// model is disabled, warming up, unavailable, refuses, times out, or returns
    /// malformed JSON. Always returns — never throws — so filing always succeeds
    /// even when the model path fails.
    /// - Parameters:
    ///   - toolName: Name of the tool requesting approval.
    ///   - argumentsJSON: Raw invocation arguments.
    ///   - intent: Agent intent or turn narration, if available.
    /// - Returns: Evaluated impact assessment.
    public func assess(
        toolName: String,
        argumentsJSON: String,
        intent: String? = nil
    ) async -> ImpactAssessment {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if SystemLanguageModel.default.isAvailable {
                    do {
                        return try await withTimeout(seconds: Self.assessmentTimeoutSeconds) {
                            try await self.evaluateWithAppleIntelligence(
                                toolName: toolName,
                                argumentsJSON: argumentsJSON,
                                intent: intent
                            )
                        }
                    } catch {
                        // Timeout or model refusal: fall back to heuristics without failing approval.
                        return FallbackHeuristics.evaluate(
                            toolName: toolName,
                            argumentsJSON: argumentsJSON,
                            intent: intent
                        )
                    }
                }
            }
        #endif

        return FallbackHeuristics.evaluate(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            intent: intent
        )
    }

    #if canImport(FoundationModels)
        /// Runs prompt evaluation against on-device Apple Intelligence.
        @available(macOS 26.0, *)
        private func evaluateWithAppleIntelligence(
            toolName: String,
            argumentsJSON: String,
            intent: String?
        ) async throws -> ImpactAssessment {
            let session = LanguageModelSession(
                model: .default,
                instructions: """
                You are a security and safety analyzer for a Mac automation harness.
                Analyze the tool call and output a concise assessment in JSON format.
                Rules:
                - severity: "safe" (read-only inspection, search), "moderate" (benign writes,
                  state changes), or "dangerous" (bulk deletes, credential access, shell risks).
                - outcome: Exactly 1 plain-English sentence describing what will actually happen.
                - warnings: An array of specific risk strings (empty if none).
                Output strictly valid JSON with keys: severity, outcome, warnings.
                """
            )

            let prompt = """
            Tool: \(toolName)
            Arguments: \(argumentsJSON)
            Agent Intent: \(intent ?? "None provided")
            """

            let response = try await session.respond(to: prompt)
            guard let parsed = Self.parseAssessmentJSON(response.content) else {
                return FallbackHeuristics.evaluate(
                    toolName: toolName,
                    argumentsJSON: argumentsJSON,
                    intent: intent
                )
            }
            return parsed
        }

        /// Performs one tiny warm-up round against the on-device model.
        ///
        /// Discards the result: warm-up only faults the model into memory so the
        /// next real evaluation answers faster. Never throws — any failure
        /// (unavailable model, refusal, timeout) is swallowed so session
        /// creation can never fail because warm-up failed.
        private func warmUp() async {
            if #available(macOS 26.0, *) {
                guard SystemLanguageModel.default.isAvailable else { return }
                do {
                    let session = LanguageModelSession(
                        model: .default,
                        instructions: "You are a safety analyzer. Reply briefly."
                    )
                    _ = try await session.respond(to: "ok")
                } catch {
                    // Intentionally discarded: warm-up is best-effort only.
                }
            }
        }
    #else
        /// No-op warm-up on platforms without the on-device model.
        ///
        /// Keeps the debounce and never-throw contract identical where the
        /// model cannot exist, so callers never branch on platform.
        private func warmUp() async {}
    #endif

    /// Requests a debounced, fire-and-forget model warm-up.
    ///
    /// At most one real warm-up runs per 30 seconds no matter how many
    /// sessions are created. Returns immediately without awaiting the model,
    /// discards the result, and never throws, so session creation never blocks
    /// and never fails because of warm-up.
    public nonisolated func prewarm() {
        guard Self.claimPrewarmSlot() else { return }
        Task { [self] in
            await self.warmUp()
        }
    }

    /// Type-level warm-up entry point for callers without an instance handy.
    ///
    /// Delegates to the shared instance so the debounce stays single-sourced
    /// no matter which spelling the caller reaches for.
    public static func prewarm() {
        shared.prewarm()
    }

    /// Claims one warm-up slot when the debounce window has elapsed.
    /// - Parameter now: Reference date. Defaults to now.
    /// - Returns: True when the caller owns a warm-up round.
    private static func claimPrewarmSlot(now: Date = Date()) -> Bool {
        prewarmState.withLock { (last: inout Date?) -> Bool in
            if let last, now.timeIntervalSince(last) < prewarmDebounceSeconds {
                return false
            }
            last = now
            return true
        }
    }

    /// Clears the debounce timestamp so tests can admit a fresh warm-up.
    public static func resetPrewarmForTesting() {
        prewarmState.withLock { (last: inout Date?) in
            last = nil
        }
    }

    /// Returns the last admitted warm-up time, if any.
    /// - Returns: Timestamp of the last admitted warm-up, or nil when none.
    public static func lastPrewarmAtForTesting() -> Date? {
        prewarmState.withLock { (last: inout Date?) in last }
    }

    /// Parses the raw LLM response text into an ImpactAssessment.
    ///
    /// Extracts the outermost `{ ... }` brace range, decodes it with
    /// `JSONDecoder`, trims surrounding whitespace, and normalizes severity:
    /// exactly `safe`, `moderate`, or `dangerous` survive; any other string
    /// maps to `moderate` so novel model wording fails toward the middle
    /// instead of toward trust or alarm.
    /// - Parameter text: Raw model response, possibly wrapped in prose.
    /// - Returns: Parsed assessment, or nil when no JSON object decodes.
    public static func parseAssessmentJSON(_ text: String) -> ImpactAssessment? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }

        let jsonSubstring = String(text[start ... end])
        guard let data = jsonSubstring.data(using: .utf8) else {
            return nil
        }

        struct Payload: Decodable {
            let severity: String
            let outcome: String
            let warnings: [String]?
        }

        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }

        let normalized = decoded.severity.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let severity: ImpactSeverity = switch normalized {
        case "safe":
            .safe
        case "moderate":
            .moderate
        case "dangerous":
            .dangerous
        default:
            .moderate
        }

        return ImpactAssessment(
            severity: severity,
            outcome: decoded.outcome.trimmingCharacters(in: .whitespacesAndNewlines),
            warnings: decoded.warnings ?? []
        )
    }

    /// Races an async operation against a timeout deadline.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

/// Fast rule-based heuristics providing immediate risk classification.
public enum FallbackHeuristics {
    /// Evaluates tool impact using static rules and pattern matching.
    public static func evaluate(
        toolName: String,
        argumentsJSON: String,
        intent _: String? = nil
    ) -> ImpactAssessment {
        let name = toolName.lowercased()

        // 1. Continuation special-case
        if name == "engine.continue" {
            return ImpactAssessment(
                severity: .moderate,
                outcome: "Allows the agent to proceed with additional tool execution rounds.",
                warnings: []
            )
        }

        // 2. Read-only tools
        if isKnownReadOnly(name) {
            return ImpactAssessment(
                severity: .safe,
                outcome: "Performs read-only inspection with no side effects.",
                warnings: []
            )
        }

        // 3. Known high-risk patterns
        let lowerArgs = argumentsJSON.lowercased()
        if isDangerous(name: name, args: lowerArgs) {
            var warnings: [String] = []
            if lowerArgs.contains("rm -rf") || lowerArgs.contains("rm -r") || lowerArgs.contains("rmdir") {
                warnings.append("Permanently deletes files or directories without trash recovery.")
            }
            if lowerArgs.contains(".ssh") || lowerArgs.contains(".aws") || lowerArgs.contains("keychain") {
                warnings.append("Accesses or modifies sensitive credential paths.")
            }
            if name.contains("desktop") {
                warnings.append("Simulates mouse and keyboard hardware events.")
            }
            return ImpactAssessment(
                severity: .dangerous,
                outcome: "Performs a potentially destructive or elevated system action.",
                warnings: warnings.isEmpty ? ["Action carries risk of state loss or external effect."] : warnings
            )
        }

        // 4. Moderate state-change defaults
        var outcome = "Modifies workspace state or communicates with an external endpoint."
        var warnings: [String] = []
        if name.contains("email.send") {
            outcome = "Sends an outgoing email to specified recipients."
            warnings.append("Reaches external network recipients.")
        } else if name.contains("file") || name.contains("files.write") {
            outcome = "Writes or updates file contents on disk."
        }

        return ImpactAssessment(
            severity: .moderate,
            outcome: outcome,
            warnings: warnings
        )
    }

    private static func isKnownReadOnly(_ toolName: String) -> Bool {
        let readTools: Set = [
            "files.read", "files.glob", "files.grep", "files.list",
            "web.fetch", "memory.search", "memory.recall", "index",
            "email.search", "email.read", "browser.screenshot"
        ]
        return readTools.contains(toolName)
    }

    private static func isDangerous(name: String, args: String) -> Bool {
        if name == "desktop.action" {
            return true
        }
        if args.contains("rm -rf") || args.contains("rm -r ") || args.contains("rmdir") {
            return true
        }
        if args.contains("drop table") || args.contains("drop database") {
            return true
        }
        if args.contains("kill -9") || args.contains("pkill") {
            return true
        }
        if args.contains("/etc/") || args.contains("sudo ") {
            return true
        }
        if args.contains(".ssh/") || args.contains(".aws/") {
            return true
        }
        return false
    }
}
