// Rune Weaver Core — Shared serial I/O bridge for SQLite-backed stores.
//
// Every durable store (conversation sessions, episodes, scheduler jobs,
// run logs) funnels blocking file work through this single serial queue
// so disk order matches actor call order and deletes never race earlier
// writes, while the cooperative thread pool never blocks on file I/O. Callers
// choose between cooperative cancellation (throwing `run`, for
// actor-ordered reads and writes that may be abandoned) and
// run-to-completion (non-throwing `runUncancellable`, for audit writes
// that must land even when the surrounding turn was cancelled).

import Foundation

/// Serializes blocking store I/O off the cooperative thread pool.
///
/// Single shared queue plus continuation bridge replacing the per-store
/// serial queues previously duplicated across `ConversationManager`,
/// `EpisodeStore`, `SchedulerStore`, and `RunLogStore`.
public enum SQLiteSerialIO {
    /// Serial queue for all store file I/O.
    ///
    /// One queue for every store: per-store call order is preserved, and
    /// cross-store writes serialize harmlessly since the work is
    /// synchronous and never re-enters the queue. Because all durable stores
    /// (episodes, sessions, run logs, scheduler jobs, tool registry) share
    /// the primary SQLite database (`episodes.db`), funneling all blocking
    /// database handles through a single serial queue completely eliminates
    /// `SQLITE_BUSY` file-level locking collisions across subsystems.
    private static let queue = DispatchQueue(label: "com.runeweaver.stores.serial-io", qos: .utility)

    /// Runs throwing blocking work on the serial queue.
    ///
    /// Suspends the caller until the work completes, keeping SQLite/JSON
    /// file work off the actor executor while preserving call order across
    /// concurrent callers. Already-cancelled tasks throw before dispatch;
    /// in-flight writes run to completion so the file never observes a torn
    /// write, and the continuation resumes exactly once on the single
    /// background completion path.
    /// - Parameter work: Blocking store operation.
    /// - Returns: Operation result.
    /// - Throws: Whatever `work` throws, or `CancellationError` when already cancelled.
    public static func run<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
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

    /// Runs non-throwing blocking work on the serial queue to completion.
    ///
    /// Unlike `run(_:)`, never throws and ignores task cancellation so
    /// audit writes (episode mirrors, run logs, job upserts) land even
    /// when the surrounding turn was cancelled after the in-memory state
    /// already advanced.
    /// - Parameter work: Blocking store operation that cannot fail.
    /// - Returns: Operation result.
    public static func runUncancellable<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = work()
                continuation.resume(returning: result)
            }
        }
    }
}
