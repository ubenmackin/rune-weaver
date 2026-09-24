// Rune Weaver Core — Pooled embeddings backends for bounded parallel indexing.
//
// A single `EmbeddingsBackend` actor (notably the on-device Apple
// NaturalLanguage backend) serializes concurrent `embed` calls through its
// executor, so fanning file workers over one shared instance would collapse
// back to sequential embedding. The pool builds one backend per worker up
// front and vends them through an async counting semaphore, letting each
// worker embed against its own instance while bounding total concurrency to
// the configured worker count.
//
// Throughput gains here are sublinear by design: the underlying Accelerate
// engine behind the on-device backend is already internally threaded, so
// extra workers mainly overlap file I/O, extraction, and store writes rather
// than multiplying vector throughput.

/// Actor vending one embeddings backend per parallel worker.
///
/// The pool holds `count` backend instances built up front and hands them out
/// through an async counting semaphore: `acquire` suspends while every
/// instance is checked out and resumes waiters in FIFO order as instances
/// return via `release`. Embedding itself always runs outside the pool, so
/// concurrent workers never serialize on the pool — only on the backend they
/// hold, which is why each worker gets its own instance.
public actor EmbeddingsBackendPool {
    /// Number of backend instances held by the pool.
    public let count: Int

    /// Idle backend instances available for checkout.
    private var available: [any EmbeddingsBackend]
    /// Waiters suspended in `acquire`, resumed FIFO as instances return.
    private var waiters: [CheckedContinuation<any EmbeddingsBackend, Never>] = []

    /// Creates a pool by building one backend per slot.
    /// - Parameters:
    ///   - count: Backend instances to build; values below one clamp to one.
    ///   - makeBackend: Factory invoked once per slot to build an instance.
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
    ///
    /// Sharing one instance across slots stays correct but reintroduces the
    /// single-actor serialization the factory form avoids, so callers needing
    /// true parallel embedding should prefer the factory form.
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
    ///
    /// Waiters resume in FIFO order as instances return. A worker holds at
    /// most one checkout at a time and always returns it, so checkout never
    /// deadlocks: every waiter is eventually preceded only by holders that
    /// release without needing another slot.
    /// - Returns: An idle backend instance to return via `release`.
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

    /// Runs one embedding operation against a checked-out backend.
    ///
    /// The backend returns to the pool even when `body` throws, so a failing
    /// batch never leaks a slot. Cancellation inside `body` propagates to the
    /// caller instead of degrading.
    /// - Parameter body: Work receiving the checked-out backend.
    /// - Returns: Whatever `body` returns.
    public func withBackend<T: Sendable>(
        _ body: @Sendable (any EmbeddingsBackend) async throws -> T
    ) async throws -> T {
        let backend = await acquire()
        defer { release(backend) }
        return try await body(backend)
    }
}
