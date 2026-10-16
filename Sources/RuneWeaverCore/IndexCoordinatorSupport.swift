// Rune Weaver Core — Index coordinator run totals and reporting helpers.

import Foundation
import os

// MARK: - Run totals

extension IndexCoordinator {
    /// Running totals accumulated across source stages.
    struct Totals: Sendable {
        /// Items examined.
        var scanned = 0
        /// Documents written.
        var indexed = 0
        /// Chunks written with an embedding.
        var vectorChunks = 0
        /// Chunks written without an embedding.
        var keywordChunks = 0
        /// Items deliberately skipped.
        var skipped = 0
        /// Items that could not be processed.
        var errors = 0
        /// Documents retired (deleted as unseen).
        var retired = 0
        /// Documents where the vector cap left tail chunks keyword-only.
        var truncated = 0
        /// Non-fatal problems.
        var warnings: [String] = []
        /// Last relative item reported by a stage.
        var lastItem: String?

        /// Adds one stage report into the running totals.
        /// - Parameter report: Stage contribution to fold in.
        mutating func add(_ report: IndexSourceRunReport) {
            merge(Totals(
                scanned: report.scanned,
                indexed: report.indexed,
                vectorChunks: report.vectorChunks,
                keywordChunks: report.keywordChunks,
                skipped: report.skipped,
                errors: report.errors,
                retired: report.retired,
                truncated: report.truncated,
                warnings: report.warnings,
                lastItem: report.lastItem
            ))
        }

        /// Merges one stage's accumulated totals into the running totals.
        /// - Parameter other: Per-stage totals to fold in.
        mutating func add(_ other: Totals) {
            merge(other)
        }

        /// Folds counted fields shared by reports and accumulated totals.
        private mutating func merge(_ other: Totals) {
            scanned += other.scanned
            indexed += other.indexed
            vectorChunks += other.vectorChunks
            keywordChunks += other.keywordChunks
            skipped += other.skipped
            errors += other.errors
            retired += other.retired
            truncated += other.truncated
            warnings.append(contentsOf: other.warnings)
            if let item = other.lastItem {
                lastItem = item
            }
        }
    }

    /// One overlapped peer's outcome for the task-group join.
    struct OverlapStageOutcome: Sendable {
        /// Overlap-batch position owning the high-water slot.
        let index: Int
        /// Whether the peer contributed work or a counted failure.
        let didRun: Bool
        /// Per-stage totals owned by `executeStage`.
        let stageTotals: Totals
    }

    /// Bundled run identity plus policy for finalizing a pass.
    struct FinishRunContext: Sendable {
        /// What caused the run.
        let trigger: IndexRunTrigger
        /// Per-run session identifier for the log row.
        let sessionID: UUID
        /// Stable event identifier for start and completion events.
        let eventID: UUID
        /// Instant the run began.
        let startedAt: Date
        /// Per-run policy snapshot fixed at run entry.
        let policy: IndexConfig
    }
}

// MARK: - Reporting

extension IndexCoordinator {
    /// Single-line summary for the run event message.
    static func summaryLine(_ summary: IndexRunSummary) -> String {
        "Index run \(summary.status.rawValue): \(summary.documentsIndexed) indexed, "
            + "\(summary.vectorChunks) vectors, \(summary.keywordChunks) keyword-only, "
            + "\(summary.scanned) scanned, \(summary.errors) errors, "
            + "\(summary.retired) retired, \(summary.truncated) truncated"
    }

    /// Detailed outcome text for the completion event response.
    static func detailLine(_ summary: IndexRunSummary) -> String {
        var lines = [summaryLine(summary)]
        lines.append("Trigger: \(summary.trigger.rawValue)")
        lines.append("Retired: \(summary.retired)")
        lines.append("Truncated: \(summary.truncated)")
        if let indexAsOf = summary.indexAsOf {
            lines.append("Index as of: \(ISO8601DateFormatter().string(from: indexAsOf))")
        }
        if let reason = summary.skippedReason {
            lines.append("Skipped: \(reason)")
        }
        for report in summary.sources {
            lines.append(sourceDetailLine(report))
        }
        lines.append(contentsOf: summary.warnings.map { "Warning: \($0)" })
        return lines.joined(separator: "\n")
    }

    /// Formats one per-source outcome as a durable detail line.
    /// - Parameter report: Stage contribution to describe.
    /// - Returns: A single `Source:` line carrying did-run plus counts.
    static func sourceDetailLine(_ report: IndexSourceRunReport) -> String {
        var line = "Source \(report.kind.rawValue): \(report.scanned) scanned, \(report.indexed) indexed, didRun \(report.didRun ? "true" : "false")"
        if let reason = report.skippedReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            line += ", skipped \(reason)"
        }
        return line
    }

    /// Orders collected reports canonically, filling gaps from the live policy.
    static func orderedSourceReports(_ reports: [IndexSourceRunReport], cancelled: Bool, policy: IndexConfig) -> [IndexSourceRunReport] {
        var ordered = reports.sorted { lhs, rhs in
            let left = IndexSourceKind.runOrder.firstIndex(of: lhs.kind) ?? Int.max
            let right = IndexSourceKind.runOrder.firstIndex(of: rhs.kind) ?? Int.max
            return left < right
        }
        if cancelled {
            return ordered
        }
        let present = Set(reports.map(\.kind))
        for kind in IndexSourceKind.runOrder {
            if present.contains(kind) {
                continue
            }
            if kind == .files || kind == .mail || kind == .messages || kind == .calendars || kind == .reminders {
                if kind.isEnabled(in: policy) {
                    ordered.append(IndexSourceRunReport(kind: kind, didRun: false, skippedReason: unavailableReason(for: kind)))
                } else {
                    ordered.append(IndexSourceRunReport(kind: kind, didRun: false, skippedReason: disabledReason(for: kind)))
                }
            }
        }
        ordered.sort { lhs, rhs in
            let left = IndexSourceKind.runOrder.firstIndex(of: lhs.kind) ?? Int.max
            let right = IndexSourceKind.runOrder.firstIndex(of: rhs.kind) ?? Int.max
            return left < right
        }
        return ordered
    }

    /// Orders collected reports canonically, filling disabled gaps.
    static func orderedSourceReports(_ reports: [IndexSourceRunReport], cancelled: Bool) -> [IndexSourceRunReport] {
        orderedSourceReports(reports, cancelled: cancelled, policy: IndexConfig(enabled: false))
    }

    /// Enabled-but-unrun reason for a kind the live policy selects yet that contributed no report.
    /// - Parameter kind: Source that did not run despite being enabled.
    static func unavailableReason(for kind: IndexSourceKind) -> String {
        switch kind {
        case .files:
            "File indexing is enabled but did not run in this pass."
        case .mail:
            "Mail indexing is enabled but did not run in this pass."
        case .messages:
            "Messages indexing is enabled but did not run in this pass."
        case .calendars:
            "Calendar indexing is enabled but did not run in this pass."
        case .reminders:
            "Reminders indexing is enabled but did not run in this pass."
        }
    }

    /// Disabled reason matching each stage's policy guard.
    /// - Parameter kind: Source that did not run.
    /// - Returns: Reason the stage reports when its toggle is off.
    static func disabledReason(for kind: IndexSourceKind) -> String {
        switch kind {
        case .files:
            "File indexing is disabled in [index]."
        case .mail:
            "Mail indexing is disabled in [index]."
        case .messages:
            "Messages indexing is disabled in [index]."
        case .calendars:
            "Calendar indexing is disabled in [index]."
        case .reminders:
            "Reminders indexing is disabled in [index]."
        }
    }
}

// MARK: - Cancellation flag

/// Lock-guarded cancellation flag shared with non-isolated stage closures.
final class IndexCancellationFlag: Sendable {
    /// Thread-safe flag state.
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Whether cancellation has been requested.
    var isSet: Bool {
        state.withLock { $0 }
    }

    /// Requests cancellation.
    func set() {
        state.withLock { $0 = true }
    }

    /// Clears the flag for a fresh run.
    func reset() {
        state.withLock { $0 = false }
    }
}
