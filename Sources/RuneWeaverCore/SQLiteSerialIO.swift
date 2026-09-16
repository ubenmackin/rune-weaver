// Rune Weaver Core — Shared serial I/O bridge for SQLite-backed stores.

import Foundation

/// Serializes blocking store I/O off the cooperative thread pool.
public enum SQLiteSerialIO {
    /// Serial queue for all store file I/O.
    private static let queue = DispatchQueue(label: "com.runeweaver.stores.serial-io", qos: .utility)

    /// Runs throwing blocking work on the serial queue.
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
    public static func runUncancellable<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = work()
                continuation.resume(returning: result)
            }
        }
    }
}
