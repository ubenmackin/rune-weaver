import Foundation

/// Runs blocking store I/O off the actor executor.
///
/// Nonisolated helper dispatching `work` to a background queue and
/// suspending the caller until it completes, so isolated JSON file work
/// never blocks the actor executor. Reserved for stores that do not share
/// `episodes.db` (such as the vector `facts.json` mirror); every durable
/// SQLite store sharing `episodes.db` funnels through the shared serial
/// queue (`SQLiteSerialIO`) so disk order matches actor order and
/// concurrent writers never race.
///
/// Cancellation is observed cooperatively: already-cancelled tasks throw
/// before dispatch, and in-flight writes run to completion to keep the
/// store consistent. The continuation resumes exactly once on the single
/// background completion path.
/// - Parameter work: Blocking store operation.
/// - Returns: Operation result.
/// - Throws: Whatever `work` throws, or `CancellationError` when already cancelled.
func runStoreIO<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
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

/// Runs blocking store I/O to completion without observing cancellation.
///
/// Shares the run-to-completion contract of
/// `SQLiteSerialIO/runUncancellable(_:)` on its own background queue for
/// isolated files: audit writes issued from an already-cancelled context
/// must still land, while the cancellable helper above would throw before
/// dispatch and drop the write. SQLite stores sharing `episodes.db` use
/// the serial-queue variant instead so ordering stays single-sourced.
/// - Parameter work: Blocking store operation that cannot fail.
/// - Returns: Operation result.
func runStoreIOUncancellable<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: work())
        }
    }
}
