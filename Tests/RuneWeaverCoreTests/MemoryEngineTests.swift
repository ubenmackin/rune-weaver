// Rune Weaver Core Tests — Episodic write boundary: cancellation identity and failure wrapping.

import Foundation
@testable import RuneWeaverCore
import Testing

/// Builds an isolated engine on a fresh temporary directory.
private func makeBoundaryEngine() -> (engine: MemoryEngine, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let engine = MemoryEngine(
        episodesDBPath: base.appendingPathComponent("episodes.db").path,
        vectorDBPath: base.appendingPathComponent("vectors").path,
        profilePath: base.appendingPathComponent("profile.json").path
    )
    return (engine, base)
}

/// One-shot latch holding a store task until the test has cancelled it, so the
/// store call deterministically runs inside an already-cancelled task.
private actor CancelLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Releases every parked waiter; later waiters return immediately.
    func release() {
        released = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    /// Parks until release, or returns at once if release already happened.
    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Memory Engine")
struct MemoryEngineTests {
    @Test
    func `Cancellation during the store keeps its identity`() async throws {
        let (engine, base) = makeBoundaryEngine()
        defer { try? FileManager.default.removeItem(at: base) }
        let latch = CancelLatch()
        let sessionID = UUID()

        let storing = Task {
            await latch.wait()
            try await engine.storeEpisodic(content: "harbor cancellation probe", sessionID: sessionID)
        }
        storing.cancel()
        await latch.release()

        do {
            _ = try await storing.value
            Issue.record("Expected storeEpisodic to throw cancellation")
        } catch is CancellationError {
            // Cancellation reached the boundary without being wrapped.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func `Plain store failure still wraps as episodicFailed`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // A regular file occupying the database's parent directory makes every
        // store open fail with a plain persistence error, never cancellation.
        let blocker = base.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let engine = MemoryEngine(
            episodesDBPath: blocker.appendingPathComponent("nested").appendingPathComponent("episodes.db").path,
            vectorDBPath: base.appendingPathComponent("vectors").path,
            profilePath: base.appendingPathComponent("profile.json").path
        )
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            _ = try await engine.storeEpisodic(content: "harbor persistence probe", sessionID: UUID())
            Issue.record("Expected storeEpisodic to throw")
        } catch let error as MemoryEngineError {
            guard case .episodicFailed = error else {
                Issue.record("Expected episodicFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MemoryEngineError.episodicFailed, got \(error)")
        }
    }
}
