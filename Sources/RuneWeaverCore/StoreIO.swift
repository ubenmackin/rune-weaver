import Foundation

/// Runs blocking store I/O off the actor executor.
///
/// Nonisolated helper dispatching `work` to a background queue and
/// suspending the caller until it completes, so SQLite/JSON file work
/// never blocks the actor executor. Shared by the conversation,
/// episode, and vector stores so blocking I/O stays single-sourced.
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
