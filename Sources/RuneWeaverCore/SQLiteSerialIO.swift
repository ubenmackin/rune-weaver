// Rune Weaver Core — Shared serial I/O bridge for SQLite-backed stores.

import Foundation

/// Serializes blocking store I/O off the cooperative thread pool.
public enum SQLiteSerialIO {
    /// Domain lanes keeping latency-critical interactive store I/O separate
    /// from heavy background document indexing scans.
    public enum Lane: Sendable {
        /// Interactive store lane (conversations, permissions, episodes, tool state).
        case interactive
        /// Heavy background indexing lane (file tree indexing, FTS5 document indexing).
        case indexing
    }

    /// Serial queue for interactive store file I/O.
    private static let interactiveQueue = DispatchQueue(label: "com.runeweaver.stores.interactive", qos: .userInitiated)
    /// Serial queue for heavy background indexing file I/O.
    private static let indexingQueue = DispatchQueue(label: "com.runeweaver.stores.indexing", qos: .utility)

    /// Returns the target queue for a given lane.
    private static func queue(for lane: Lane) -> DispatchQueue {
        switch lane {
        case .interactive:
            interactiveQueue
        case .indexing:
            indexingQueue
        }
    }

    /// Runs throwing blocking work on the designated lane serial queue.
    public static func run<T: Sendable>(
        lane: Lane = .interactive,
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let targetQueue = queue(for: lane)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                targetQueue.async {
                    do {
                        try continuation.resume(returning: work())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Non-cancellable by design: in-flight store writes run to
            // completion so the file never observes a torn write.
            // Cancellation is observed before dispatch and on next suspension.
        }
    }

    /// Runs non-throwing blocking work on the designated lane serial queue to completion.
    public static func runUncancellable<T: Sendable>(
        lane: Lane = .interactive,
        _ work: @Sendable @escaping () -> T
    ) async -> T {
        let targetQueue = queue(for: lane)
        return await withCheckedContinuation { continuation in
            targetQueue.async {
                let result = work()
                continuation.resume(returning: result)
            }
        }
    }
}
