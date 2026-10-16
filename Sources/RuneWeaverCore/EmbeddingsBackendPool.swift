// Rune Weaver Core — Pooled embeddings backends for bounded parallel indexing.

import Foundation

/// Actor vending one embeddings backend per parallel worker.
public actor EmbeddingsBackendPool {
    /// Number of backend instances held by the pool.
    public let count: Int

    /// Idle backend instances available for checkout.
    private var available: [any EmbeddingsBackend]
    /// Waiters suspended in `acquire`, resumed FIFO as instances return.
    private var waiters: [CheckedContinuation<any EmbeddingsBackend, Never>] = []

    /// Creates a pool by building one backend per slot. count: Backend instances to
    /// build; values below one clamp to one.
    public init(count: Int, makeBackend: @Sendable () -> any EmbeddingsBackend) {
        let size = max(1, count)
        self.count = size
        var built: [any EmbeddingsBackend] = []
        built.reserveCapacity(size)
        for _ in 0 ..< size {
            built.append(makeBackend())
        }
        self.available = built
    }

    /// Creates a pool from prebuilt backend instances.
    /// - Parameter backends: Instances to vend; must not be empty.
    public init(backends: [any EmbeddingsBackend]) {
        precondition(!backends.isEmpty, "EmbeddingsBackendPool needs at least one backend")
        self.count = backends.count
        self.available = backends
    }

    /// Idle backend instances currently available for checkout.
    public var availableCount: Int {
        available.count
    }

    /// Checks out one backend, suspending while every instance is in use.
    public func acquire() async -> any EmbeddingsBackend {
        if let backend = available.popLast() {
            return backend
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Returns a backend to the pool, waking the longest-waiting acquirer first.
    /// - Parameter backend: Instance previously returned by `acquire`.
    public func release(_ backend: any EmbeddingsBackend) {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: backend)
        } else if available.count < count {
            available.append(backend)
        }
        // An unbalanced release beyond the configured size drops its surplus
        // so misuse cannot grow the pool past its bound.
    }

    /// Runs one embedding operation against a checked-out backend. The backend returns to the pool
    /// even when `body` throws, so a failing batch never leaks a slot.
    public func withBackend<T: Sendable>(
        _ body: @Sendable (any EmbeddingsBackend) async throws -> T
    ) async throws -> T {
        let backend = await acquire()
        defer { release(backend) }
        return try await body(backend)
    }

    /// Embeds an image file using an acquired backend from the pool.
    public func embedImage(at imageURL: URL) async throws -> [Float] {
        try await withBackend { backend in
            try await backend.embedImage(at: imageURL)
        }
    }
}
