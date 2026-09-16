// Rune Weaver Core — Off-actor blocking I/O helper for sidecar file stores.

import Foundation

/// Runs blocking store I/O off the actor executor.
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
func runStoreIOUncancellable<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: work())
        }
    }
}
