// Rune Weaver Core — Automatic recall formatting, recall execution, and hydration.

import Foundation

// MARK: - MemoryEngine Automatic Recall Formatting

extension MemoryEngine {
    /// Maximum memories injected as system context on one chat turn.
    public static let automaticRecallLimit = 5

    /// Minimum calibrated score for an injected recall hit.
    public static let automaticRecallThreshold = 0.1

    /// Maximum characters for the injected recall block, header included.
    public static let automaticRecallMaxChars = 2000

    /// Header labeling injected recall as system context.
    public static let automaticRecallHeader =
        "Relevant memories (use for context; do not mention unless relevant):"

    /// Whether a recall tier may carry attacker-controlled bytes.
    public static func isUntrustedRecallSource(_ source: MemorySource) -> Bool {
        source == .docIndex
    }

    /// Whether one recall hit must re-enter as labeled data.
    public static func shouldLabelRecallResult(_ result: MemoryResult) -> Bool {
        if isUntrustedRecallSource(result.source) {
            return true
        }
        if result.source == .episodic {
            let trimmed = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("Used ") || trimmed.hasPrefix("Used\n")
        }
        return false
    }

    /// Whether a recall payload already carries the data-only block.
    public static func isAlreadyLabeledRecallPayload(_ compact: String) -> Bool {
        guard let bannerRange = compact.range(of: ContentTrustLabeler.banner),
              let beginRange = compact.range(of: ContentTrustLabeler.beginPrefix),
              let endRange = compact.range(of: ContentTrustLabeler.endDelimiter)
        else {
            return false
        }
        return bannerRange.lowerBound < beginRange.lowerBound && beginRange.lowerBound < endRange.lowerBound
    }

    /// Truncates one recall block to `maxChars`, preserving the `maxChars == 1` edge.
    public static func truncateRecallBlock(_ block: String, maxChars: Int) -> String {
        guard block.count > maxChars else { return block }
        if maxChars == 1 {
            return "…"
        }
        return String(block.prefix(maxChars - 1)) + "…"
    }

    /// Builds source-labeled recall context, token-bounded with truncation.
    public static func automaticRecallContext(
        for results: [MemoryResult],
        threshold: Double = automaticRecallThreshold,
        maxChars: Int = automaticRecallMaxChars,
        labelingEnabled: Bool = true
    ) -> String? {
        guard maxChars > 0 else { return nil }
        let relevant = results.filter { $0.score >= threshold }
        guard !relevant.isEmpty else { return nil }
        let lines = relevant.map { recallLine(for: $0, perHitChars: RecallBudgets().clamped().perHitChars, labelingEnabled: labelingEnabled) }
        let block = ([automaticRecallHeader] + lines).joined(separator: "\n")
        return truncateRecallBlock(block, maxChars: maxChars)
    }

    /// Wraps recall hits as an injectable system message.
    public static func automaticRecallMessage(
        for results: [MemoryResult],
        threshold: Double = automaticRecallThreshold,
        maxChars: Int = automaticRecallMaxChars,
        labelingEnabled: Bool = true
    ) -> Message? {
        guard let text = automaticRecallContext(for: results, threshold: threshold, maxChars: maxChars, labelingEnabled: labelingEnabled) else {
            return nil
        }
        return Message(role: .system, content: text)
    }

    /// Builds source-labeled recall context bounded by recall budgets. Result of packing recall
    /// hits into a bounded context block.
    public struct PackedRecall: Sendable, Equatable {
        /// Candidate memory hits successfully included in the context block.
        public let injectedHits: [MemoryResult]
        /// Assembled system context string, or nil when no hits fit.
        public let contextText: String?
        /// Character count of `contextText` (0 when nil).
        public let injectedChars: Int

        public init(injectedHits: [MemoryResult], contextText: String?, injectedChars: Int) {
            self.injectedHits = injectedHits
            self.contextText = contextText
            self.injectedChars = injectedChars
        }
    }

    /// Packs complete recall hits into an injected system context block using "Drop, Don't Chop".
    /// Each candidate's formatted line is added if and only if the ENTIRE line fits within the
    /// remaining `clamped.maxChars` budget.
    public static func packRecallHits(
        from results: [MemoryResult],
        budgets: RecallBudgets,
        labelingEnabled: Bool = true
    ) -> PackedRecall {
        let clamped = budgets.clamped()
        guard clamped.maxChars > 0 else {
            return PackedRecall(injectedHits: [], contextText: nil, injectedChars: 0)
        }
        let relevant = results.filter { $0.score >= clamped.threshold }
        guard !relevant.isEmpty else {
            return PackedRecall(injectedHits: [], contextText: nil, injectedChars: 0)
        }
        let candidates = Array(relevant.prefix(clamped.autoLimit))
        guard !candidates.isEmpty else {
            return PackedRecall(injectedHits: [], contextText: nil, injectedChars: 0)
        }

        let header = automaticRecallHeader
        guard header.count <= clamped.maxChars else {
            return PackedRecall(injectedHits: [], contextText: nil, injectedChars: 0)
        }

        var lines: [String] = []
        var injected: [MemoryResult] = []
        var currentChars = header.count

        for candidate in candidates {
            let line = recallLine(for: candidate, perHitChars: clamped.perHitChars, labelingEnabled: labelingEnabled)
            guard !line.isEmpty else { continue }
            let neededChars = 1 + line.count // \n delimiter + line
            if currentChars + neededChars <= clamped.maxChars {
                lines.append(line)
                injected.append(candidate)
                currentChars += neededChars
            } else {
                // Drop, Don't Chop: candidate does not fit in its entirety.
                // Stop packing to preserve complete memory boundaries.
                break
            }
        }

        guard !lines.isEmpty else {
            return PackedRecall(injectedHits: [], contextText: nil, injectedChars: 0)
        }

        let block = ([header] + lines).joined(separator: "\n")
        return PackedRecall(injectedHits: injected, contextText: block, injectedChars: block.count)
    }

    /// Builds source-labeled recall context bounded by recall budgets using "Drop, Don't Chop".
    public static func automaticRecallContext(
        for results: [MemoryResult],
        budgets: RecallBudgets,
        labelingEnabled: Bool = true
    ) -> String? {
        packRecallHits(from: results, budgets: budgets, labelingEnabled: labelingEnabled).contextText
    }

    /// Formats recall content, collapsing excessive blank runs and bounding to `perHitChars`.
    public static func formattedHitContent(_ content: String, perHitChars: Int, isDocument: Bool = false) -> String {
        let text: String
        if isDocument {
            var collapsed = content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            while collapsed.contains("\n\n\n") {
                collapsed = collapsed.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            text = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = singleLineSquashed(content)
        }
        guard text.count > perHitChars else { return text }
        guard perHitChars > 1 else { return "…" }
        return String(text.prefix(perHitChars)) + "…"
    }

    /// One recall line with per-hit truncation plus a preserved citation suffix.
    public static func recallLine(for result: MemoryResult, perHitChars: Int, labelingEnabled: Bool) -> String {
        let compact = formattedHitContent(result.content, perHitChars: perHitChars, isDocument: result.source == .docIndex)
        let citation = citationSuffix(for: result)
        if labelingEnabled, shouldLabelRecallResult(result) {
            if isUntrustedRecallSource(result.source) {
                let labeled = ContentTrustLabeler.label(toolName: recallSourceTag(for: result), content: compact)
                if let citation {
                    return "[\(result.source.rawValue)] \(labeled) \(citation)"
                }
                return "[\(result.source.rawValue)] \(labeled)"
            }
            // Check the emitted truncated payload, not the pre-truncation line: a stored
            // tool-mirror block truncated to `perHitChars` can lose its closing delimiter, so a
            // full-content check would skip re-labeling and emit an unclosed block.
            if !isAlreadyLabeledRecallPayload(compact) {
                let labeled = ContentTrustLabeler.label(toolName: "recall:\(result.source.rawValue)", content: compact)
                if let citation {
                    return "[\(result.source.rawValue)] \(labeled) \(citation)"
                }
                return "[\(result.source.rawValue)] \(labeled)"
            }
        }
        if let citation {
            if compact.isEmpty {
                return "[\(result.source.rawValue)] \(citation)"
            }
            return "[\(result.source.rawValue)] \(compact) \(citation)"
        }
        return "[\(result.source.rawValue)] \(compact)"
    }

    /// Squashes recall content to a single trimmed line.
    public static func singleLineSquashed(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Engine-authored attribution for the untrusted data-only block.
    public static func recallSourceTag(for result: MemoryResult) -> String {
        if let name = result.metadata["display_name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedName = singleLineSquashed(name)
            if let path = result.metadata["path"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "recall:\(result.source.rawValue):\(trimmedName) (\(singleLineSquashed(path)))"
            }
            return "recall:\(result.source.rawValue):\(trimmedName)"
        }
        return "recall:\(result.source.rawValue)"
    }

    /// One trailing citation suffix from hit metadata, never truncated away.
    public static func citationSuffix(for result: MemoryResult) -> String? {
        var parts: [String] = []
        if let date = result.metadata["date"]?.trimmingCharacters(in: .whitespacesAndNewlines), !date.isEmpty {
            let squashed = singleLineSquashed(date)
            if !squashed.isEmpty {
                parts.append(squashed)
            }
        }
        if let path = result.metadata["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let squashed = singleLineSquashed(path)
            if !squashed.isEmpty {
                parts.append(squashed)
            }
        }
        if let displayName = result.metadata["display_name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            let squashed = singleLineSquashed(displayName)
            if !squashed.isEmpty {
                parts.append(squashed)
            }
        }
        if parts.isEmpty {
            guard result.source == .docIndex else { return nil }
            if let documentID = result.metadata["document_id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !documentID.isEmpty {
                return "[\(singleLineSquashed(documentID))]"
            }
            return "[indexed document]"
        }
        return "[\(parts.joined(separator: "|"))]"
    }

    /// Wraps recall hits as an injectable system message bounded by recall budgets.
    public static func automaticRecallMessage(
        for results: [MemoryResult],
        budgets: RecallBudgets,
        labelingEnabled: Bool = true
    ) -> Message? {
        guard let text = automaticRecallContext(for: results, budgets: budgets, labelingEnabled: labelingEnabled) else {
            return nil
        }
        return Message(role: .system, content: text)
    }

    /// Injected subset of retrieved hits in rank order matching the packed context block.
    public static func injectedRecallHits(from results: [MemoryResult], budgets: RecallBudgets) -> [MemoryResult] {
        packRecallHits(from: results, budgets: budgets).injectedHits
    }
}

// MARK: - MemoryEngine Automatic Recall

extension MemoryEngine {
    /// Drops the just-mirrored self-echo from recall hits.
    public static func filteredRecallResults(
        _ results: [MemoryResult],
        query: String,
        sessionID: UUID
    ) -> [MemoryResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return results.filter { result in
            guard result.source == .episodic else { return true }
            guard result.metadata["session_id"] == sessionID.uuidString else { return true }
            return result.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != trimmedQuery
        }
    }

    /// Inserts injected recall at a stable slot keeping the prefix identical across rounds.
    public static func historyWithRecall(_ history: [Message], recall: Message?) -> [Message] {
        guard let recall else { return history }
        guard !history.isEmpty else { return [recall] }
        if let lastUserIndex = history.lastIndex(where: { $0.role == .user }) {
            var spliced = history
            spliced.insert(recall, at: lastUserIndex)
            return spliced
        }
        var insertAt = 0
        while insertAt < history.count, history[insertAt].role == .system {
            insertAt += 1
        }
        var spliced = history
        spliced.insert(recall, at: insertAt)
        return spliced
    }

    /// Resolves automatic recall for one user turn, failure-isolated except cancellation.
    public func recallMessage(
        for query: String,
        sessionID: UUID,
        embedder: (any EmbeddingsBackend)? = nil,
        labelingEnabled: Bool = true,
        budgets: RecallBudgets = RecallBudgets(),
        plan: RecallPlan? = nil
    ) async throws -> Message? {
        let (message, _) = try await recallMessageWithDiagnostics(
            for: query,
            sessionID: sessionID,
            embedder: embedder,
            labelingEnabled: labelingEnabled,
            budgets: budgets,
            plan: plan
        )
        return message
    }

    /// Resolves automatic recall while reporting observability alongside the message. Diagnostics
    /// carry hit identifiers plus sources plus scores plus the injected char count plus the
    /// doc-index skip flag, never content.
    public func recallMessageWithDiagnostics(
        for query: String,
        sessionID: UUID,
        embedder: (any EmbeddingsBackend)? = nil,
        labelingEnabled: Bool = true,
        budgets: RecallBudgets = RecallBudgets(),
        plan: RecallPlan? = nil
    ) async throws -> (Message?, RecallDiagnostics) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let skipped = (plan?.skipDocIndex ?? false) || docIndexStore == nil
            return (nil, RecallDiagnostics.zero(skippedDocIndex: skipped))
        }
        let effectiveBudgets = budgets.clamped()
        // Thread the caller's budgets into the default plan so `perTier`
        // and `expandedQuery` derive from the same clamped value the turn
        // fans out with instead of the default budgets.
        let effectivePlan = plan ?? MemoryQueryRouter.plan(for: query, currentDate: Date(), budgets: effectiveBudgets)
        let skipped = effectivePlan.skipDocIndex || docIndexStore == nil
        let recallQuery = effectivePlan.expandedQuery.isEmpty ? query : effectivePlan.expandedQuery
        var embedding: [Float]?
        do {
            if let embedder {
                embedding = try await embedder.embedQuery(recallQuery)
            } else {
                embedding = nil
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            embedding = nil
        }
        do {
            // `plan.perTier` is the single source for fan-out; budgets still
            // govern threshold, caps, and weights downstream.
            let results = try await recall(
                query: recallQuery,
                embedding: embedding,
                limit: effectivePlan.perTier,
                since: effectivePlan.since,
                until: effectivePlan.until,
                budgets: effectiveBudgets,
                skipDocIndex: effectivePlan.skipDocIndex
            )
            let windowed: [MemoryResult] = if effectivePlan.skipDocIndex {
                results.filter { $0.source != .docIndex }
            } else if await LiveSearchOverride.shared.shouldUseLiveSearch(for: query) {
                // In this branch the plan did not request a skip, so a live verdict here can only
                // come from the forced override.
                results.filter { $0.source != .docIndex }
            } else {
                results
            }
            let filtered = Self.filteredRecallResults(windowed, query: query, sessionID: sessionID)
            let packed = Self.packRecallHits(from: filtered, budgets: effectiveBudgets, labelingEnabled: labelingEnabled)
            let message = packed.contextText.map { Message(role: .system, content: $0) }
            let reported: [MemoryResult] = message == nil ? [] : packed.injectedHits
            let diagnostics = Self.recallDiagnostics(for: reported, injectedChars: packed.injectedChars, skippedDocIndex: skipped)
            return (message, diagnostics)
        } catch let error as CancellationError {
            throw error
        } catch {
            return (nil, RecallDiagnostics.zero(skippedDocIndex: skipped))
        }
    }
}

// MARK: - Episode Message Conversion

extension Episode {
    /// Converts an episodic turn back to working-memory history.
    public func asMessage() -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            toolCallID: metadata["tool_call_id"],
            createdAt: timestamp
        )
    }

    /// Converts an episode for session-resume hydration, if replayable.
    public func hydrationMessage() -> Message? {
        guard role == .tool else { return asMessage() }
        if let callID = metadata["tool_call_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callID.isEmpty
        {
            return asMessage()
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Message(id: id, role: .assistant, content: trimmed, createdAt: timestamp)
    }
}

extension MemoryEngine {
    /// Converts episodes to replay-safe working history for resume.
    public static func hydrationMessages(from episodes: [Episode]) -> [Message] {
        episodes.compactMap { $0.hydrationMessage() }
    }
}
