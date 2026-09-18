// Rune Weaver Tools — Single-source SSRF guard for API and fetch hops.
//
// The guard refuses metadata hosts, link-local, loopback except configured
// origins, private RFC 1918 ranges, and IPv6 unique-local addresses across
// decimal, hex, octal, and short IPv4 spellings. IPv4 parsing, address
// classification, and origin normalization live in `ApiSSRFParsing` while the
// literal-only verdict plus resolved-range vetting live in `ApiSSRFVerdict` so
// the gate type stays within budget; every caller still enters through
// `ApiSSRFGuard`, so allowlist checks cannot diverge on obfuscated hosts.

import Foundation
import os
import RuneWeaverCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Single width for the bounded DNS pool shared by the queue and the permit gate.
/// One constant keeps the worker count and the pending-vetting bound converged,
/// so a later tune cannot leave the queue wider than the gate that sheds excess
/// fail-closed.
private let ssrfDNSPoolWidth = 4

/// SSRF guard for API URLs.
///
/// Single entry point for decimal, hex, octal, and short IPv4 forms plus IPv6
/// and metadata hosts; parsing, classification, and origin helpers live in
/// `ApiSSRFParsing` so this gate stays within budget without a second range pass.
///
/// Bounded DNS pool for async checks. The resolver blocks its thread with no
/// kernel cancellation, so async verdicts hop here instead of the cooperative
/// pool; only loopback-exempted literals skip this hop, everything else needing
/// DNS must prove its addresses here. The cap keeps a wedged burst from
/// exhausting threads while queued lookups wait without holding one, and
/// abandonment stays fail-closed. The gate bounds total pending (running plus
/// queued) so a burst cannot stack unlimited blocking lookups behind the pool
/// width threads; excess drops fail-closed instead of queueing behind a wedged
/// resolver.
private let ssrfDNSQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.runeweaver.ssrf-dns"
    queue.maxConcurrentOperationCount = ssrfDNSPoolWidth
    queue.qualityOfService = .utility
    return queue
}()

/// Non-blocking permit gate bounding total pending DNS vettings to the pool width.
/// A semaphore cannot be waited from an async context without stalling the
/// cooperative pool, so saturation is probed with a lock-guarded counter
/// instead: acquiring never blocks, and a miss reads as unverified rather
/// than permission to dial. All mutable state stays behind the unfair lock so
/// the gate remains safe to share across awaiting tasks and queue workers; the
/// unfair lock matches the repo-wide checked-Sendable standard and keeps the
/// gate compatible with strict concurrency without bypassing checking.
private final class SSRFPermitGate: Sendable {
    private let permits: OSAllocatedUnfairLock<Int>

    /// Creates a gate holding a fixed number of permits.
    /// - Parameter permits: Total concurrent vettings the pool may hold.
    init(_ permits: Int) {
        self.permits = OSAllocatedUnfairLock(initialState: permits)
    }

    /// Takes one permit when available without waiting.
    /// - Returns: True when the caller owns a permit and must release it.
    func tryAcquire() -> Bool {
        permits.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
    }

    /// Returns a previously acquired permit.
    func release() {
        permits.withLock { $0 += 1 }
    }
}

/// Drop-newest gate bounding total pending DNS vettings to the pool width.
/// Queued lookups hold no thread, but an unbounded queue would still let a
/// burst stack unlimited blocking work behind a wedged resolver while each
/// waiter times out yet its lookup still waits to hold a thread. Trying the
/// gate without waiting keeps the burst fail-closed: saturation reads as
/// unverified rather than permission to dial.
private let ssrfDNSGate = SSRFPermitGate(ssrfDNSPoolWidth)

#if DEBUG
    /// Test-only DNS override keeping stubbed suites hermetic without a production allowlist.
    /// Compiled into debug builds only so release has no stub surface to forge: production
    /// always resolves via the system resolver and fails closed when unverified, while
    /// debug tests publish canned addresses here so hermetic suites never touch the network
    /// or the bounded pool. All state stays behind the unfair lock so the override is safe
    /// to share across tasks under strict concurrency.
    private final class SSRFTestDNSBox: Sendable {
        private let box: OSAllocatedUnfairLock<(@Sendable (String) -> [String])?>

        /// Creates an empty holder restoring system resolution by default.
        init() {
            box = OSAllocatedUnfairLock(initialState: nil)
        }

        /// Returns the published stub, if any.
        func get() -> (@Sendable (String) -> [String])? {
            box.withLock { $0 }
        }

        /// Publishes or clears the stub.
        /// - Parameter newValue: Canned resolver, or nil to restore system resolution.
        func set(_ newValue: (@Sendable (String) -> [String])?) {
            box.withLock { $0 = newValue }
        }
    }

    /// Shared holder for the test-only DNS stub; production paths leave it empty.
    private let ssrfTestDNSBox = SSRFTestDNSBox()
#endif

public enum ApiSSRFGuard: Sendable {
    #if DEBUG
        /// Test-only DNS stub keeping hermetic suites off the network without a production bypass.
        /// Debug-only so release builds cannot publish canned proof: production always proves
        /// addresses via the system resolver, while debug tests publish canned addresses and
        /// clear afterwards so one suite cannot leak proof into another. Reads and writes stay
        /// behind the shared unfair-lock box.
        static var testDNSResolver: (@Sendable (String) -> [String])? {
            get { ssrfTestDNSBox.get() }
            set { ssrfTestDNSBox.set(newValue) }
        }
    #endif

    /// Well-known cloud metadata hostnames refused even over public DNS.
    public static let blockedMetadataHosts: Set<String> = [
        "metadata.google.internal",
        "metadata.google",
        "metadata.goog",
        "instance-data.compute.internal",
        "instance-data",
        "metadata.azure.internal",
        "metadata.aws.internal",
        "metadata"
    ]

    /// Whether a host is a well-known metadata hostname.
    /// Intent: exact plus dot-suffix match against the blocked set keeps
    /// subdomains like `sub.metadata.google.internal` refused while
    /// `foo-metadata.google-bar.example.com` passes; substring matching
    /// would overblock the latter. Invariant: comparison uses the cleaned
    /// lowercased base form, and empty hosts never match.
    public static func isMetadataHost(_ host: String) -> Bool {
        let lowered = ApiSSRFOrigin.cleanedHostBase(host)
        guard !lowered.isEmpty else { return false }
        if blockedMetadataHosts.contains(lowered) {
            return true
        }
        // Dot-suffix covers subdomains of a blocked name without substring overblocking.
        return blockedMetadataHosts.contains { lowered.hasSuffix("." + $0) }
    }

    /// Parses one numeric IPv4 part in decimal, octal, or hex.
    public static func parseNumericPart(_ part: String) -> UInt32? {
        ApiIPv4Parsing.parseNumericPart(part)
    }

    /// Parses IPv6 text into eight hextets for loopback and mapped checks.
    public static func ipv6Hextets(_ host: String) -> [UInt16]? {
        ApiIPv4Parsing.ipv6Hextets(host)
    }

    /// Parses any resolver-accepted IPv4 spelling to canonical octets.
    public static func canonicalIPv4Octets(_ host: String) -> IPv4Octets? {
        ApiIPv4Parsing.canonicalIPv4Octets(host)
    }

    /// Whether a host is in `169.254.0.0/16` (link-local, never allowlisted).
    public static func isLinkLocalIPv4(_ host: String) -> Bool {
        ApiSSRFAddresses.isLinkLocalIPv4(host)
    }

    /// Whether a host is IPv6 link-local (`fe80::/10`, never allowlisted).
    public static func isLinkLocalIPv6(_ host: String) -> Bool {
        ApiSSRFAddresses.isLinkLocalIPv6(host)
    }

    /// Whether a host is IPv4 loopback (`127.0.0.0/8`).
    public static func isLoopbackIPv4(_ host: String) -> Bool {
        ApiSSRFAddresses.isLoopbackIPv4(host)
    }

    /// Whether a host is IPv6 loopback or unspecified.
    public static func isLoopbackIPv6(_ host: String) -> Bool {
        ApiSSRFAddresses.isLoopbackIPv6(host)
    }

    /// Whether a host is a loopback equivalent.
    public static func isLoopbackHost(_ host: String) -> Bool {
        ApiSSRFAddresses.isLoopbackHost(host)
    }

    /// Whether a 32-bit IPv4 value dials a sensitive range.
    public static func isSensitiveIPv4Value(_ value: UInt32) -> Bool {
        ApiSSRFAddresses.isSensitiveIPv4Value(value)
    }

    /// Parses a canonical host to its 32-bit IPv4 value for range checks.
    public static func ipv4Value(_ host: String) -> UInt32? {
        ApiSSRFAddresses.ipv4Value(host)
    }

    /// Whether a canonical host is a sensitive IPv6 literal.
    public static func isSensitiveIPv6Host(_ canonical: String) -> Bool {
        ApiSSRFAddresses.isSensitiveIPv6Host(canonical)
    }

    /// Normalizes a URL host for origin comparison.
    public static func normalizedHost(_ host: String) -> String {
        ApiSSRFOrigin.normalizedHost(host)
    }

    /// Effective port for origin comparison, filling the scheme default.
    public static func effectivePort(for url: URL) -> Int {
        ApiSSRFOrigin.effectivePort(for: url)
    }

    /// Origin key (`host:port`) for allowlist comparison.
    /// - Parameter url: Parsed URL with a host.
    /// - Returns: Lowercased origin, or nil when hostless.
    public static func originKey(for url: URL) -> String? {
        ApiSSRFOrigin.originKey(for: url)
    }

    /// Bounded wait for the async DNS probe so a wedged resolver fails closed
    /// quickly instead of stalling the gate; literal refusals never wait on DNS.
    private static let dnsResolutionTimeoutSeconds: TimeInterval = 2

    /// Allowlisted loopback origins derived from configuration.
    public static func allowlistedOrigins(browserConfig: BrowserConfig, llmServerURLs: [String]) -> Set<String> {
        var origins = Set<String>()
        let candidates = [browserConfig.searxngURL] + llmServerURLs
        for raw in candidates {
            guard let trimmed = NormalizedText.value(raw),
                  let url = URL(string: trimmed),
                  let key = originKey(for: url)
            else { continue }
            origins.insert(key)
        }
        return origins
    }

    /// Refusal reason against an explicit exemption set, or nil when dialable.
    /// Browser flows pass an empty set because they never dial local origins,
    /// so every loopback and LAN spelling fails closed with no config to forge.
    /// Blocking on the calling thread for DNS and point-in-time: prefer
    /// `denyReasonAsync` off the cooperative pool, and pin the resolved
    /// address at dial time because a hostname can rebind between this check
    /// and the connection. Hostnames that cannot be resolved fail closed.
    /// The synchronous shape stays for callers that cannot suspend, such as
    /// browser bridge input checks; suspendable web and API paths use the
    /// bounded-pool variant so a wedged resolver cannot stall shared tasks.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - allowlistedOrigins: Precomputed `host:port` exemptions that may be dialed.
    /// - Returns: Refusal reason, or nil when allowed.
    public static func denyReason(
        for rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) -> String? {
        denyReasonImpl(for: rawURL, allowlistedOrigins: allowlistedOrigins, hasLLMOrigins: false)
    }

    /// Refusal reason for a URL, or nil when the URL may be dialed.
    /// Denies metadata, link-local, loopback (except the configured
    /// `searxng_url` plus LLM origins), private RFC 1918 ranges, `0.0.0.0/8`,
    /// and IPv6 unique-local addresses across decimal/hex/octal/short forms.
    /// Blocking on the calling thread for DNS and point-in-time: prefer
    /// `denyReasonAsync` off the cooperative pool, and pin the resolved
    /// address at dial time because a hostname can rebind between this check
    /// and the connection. Hostnames that cannot be resolved fail closed.
    public static func denyReason(
        for rawURL: String,
        browserConfig: BrowserConfig,
        llmServerURLs: [String] = []
    ) -> String? {
        let origins = allowlistedOrigins(browserConfig: browserConfig, llmServerURLs: llmServerURLs)
        let hasLLM = llmServerURLs.contains(where: { NormalizedText.value($0) != nil })
        return denyReasonImpl(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLM)
    }

    /// Async refusal reason against an explicit exemption set, or nil when dialable.
    /// Literal checks run inline on the calling task while DNS hops to the
    /// bounded pool with a fail-closed timeout, so the cooperative pool never
    /// stalls on a wedged resolver. Cancellation abandons the lookup without
    /// waiting: the resolver has no kernel cancellation, so its slot stays
    /// held until return while the waiter fails closed. The verdict stays
    /// point-in-time: pin the resolved address at dial time because a hostname
    /// can rebind between this check and the connection.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - allowlistedOrigins: Precomputed `host:port` exemptions that may be dialed.
    /// - Returns: Refusal reason, or nil when allowed.
    public static func denyReasonAsync(
        for rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) async -> String? {
        switch preDNSOutcome(for: rawURL, allowlistedOrigins: allowlistedOrigins, hasLLMOrigins: false) {
        case let .denied(reason):
            reason
        case .allowed:
            nil as String?
        case let .needsDNS(host):
            await dnsVerdictAsync(host: host)
        }
    }

    /// Async refusal reason for a URL, or nil when the URL may be dialed.
    /// Literal checks run inline on the calling task while DNS hops to the
    /// bounded pool with a fail-closed timeout, so the cooperative pool never
    /// stalls on a wedged resolver. Cancellation abandons the lookup without
    /// waiting: the resolver has no kernel cancellation, so its slot stays
    /// held until return while the waiter fails closed. The verdict stays
    /// point-in-time: pin the resolved address at dial time because a hostname
    /// can rebind between this check and the connection.
    public static func denyReasonAsync(
        for rawURL: String,
        browserConfig: BrowserConfig,
        llmServerURLs: [String] = []
    ) async -> String? {
        let origins = allowlistedOrigins(browserConfig: browserConfig, llmServerURLs: llmServerURLs)
        let hasLLM = llmServerURLs.contains(where: { NormalizedText.value($0) != nil })
        return switch preDNSOutcome(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLM) {
        case let .denied(reason):
            reason
        case .allowed:
            nil as String?
        case let .needsDNS(host):
            await dnsVerdictAsync(host: host)
        }
    }

    /// Shared refusal engine over a precomputed exemption set.
    /// Blocking on the calling thread for DNS: kept for existing callers while
    /// new paths prefer `denyReasonAsync`, which reuses the same literal stage
    /// inline and isolates only DNS on the bounded pool. Hostnames without a
    /// verified address fail closed.
    /// - Parameters:
    ///   - rawURL: Candidate URL.
    ///   - origins: Precomputed `host:port` exemptions that may be dialed.
    ///   - hasLLMOrigins: Whether LLM endpoints contribute exemptions, for honest wording.
    /// - Returns: Refusal reason, or nil when allowed.
    private static func denyReasonImpl(
        for rawURL: String,
        allowlistedOrigins origins: Set<String>,
        hasLLMOrigins: Bool
    ) -> String? {
        // Synchronous callers pay the resolver cost here; the async path
        // moves this same vetting onto the bounded pool instead.
        switch preDNSOutcome(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLMOrigins) {
        case let .denied(reason):
            reason
        case .allowed:
            nil as String?
        case let .needsDNS(host):
            vettedDNSDenial(for: host)
        }
    }

    /// Literal-only refusal plus resolved-range vetting live in `ApiSSRFVerdict`
    /// so this gate stays within budget; the sync engine and the async inline
    /// stage share that verdict.
    /// Vets resolved addresses for one hostname, failing closed when empty.
    /// Single-sourced by the sync engine, the bounded async worker, and the
    /// debug stub fast path so every path enforces the same resolved-range table.
    /// - Parameter host: Hostname whose addresses were resolved.
    /// - Returns: Refusal reason, or nil when every address is dialable.
    private static func vettedDNSDenial(for host: String) -> String? {
        vettedIPListDenial(host: host, addresses: resolveHostAddresses(host))
    }

    /// Bounded async DNS vetting with fail-closed timeout and cancellation.
    /// Runs the blocking resolver on the capped pool; a wedged lookup keeps
    /// its slot until return while the waiter fails closed, and queued
    /// lookups wait without holding threads. Saturation drops fail-closed
    /// without queueing, and a queued lookup that lost the race to timeout or
    /// cancellation skips the resolver instead of holding a thread for a
    /// verdict nobody waits on.
    /// - Parameter host: Hostname needing DNS vetting.
    /// - Returns: Refusal reason, or nil when every address is dialable.
    private static func dnsVerdictAsync(host: String) async -> String? {
        if Task.isCancelled {
            return unverifiedDenial(for: host)
        }
        #if DEBUG
            // Hermetic suites publish canned proof here so stubbed hosts never
            // touch the network or consume a bounded-pool slot; the holder is
            // debug-only so release keeps no stub surface and always vets via
            // the system resolver fail-closed. Serialized suites publish and
            // clear per test because the holder is process-global.
            if let stub = ssrfTestDNSBox.get() {
                return vettedIPListDenial(host: host, addresses: stub(host))
            }
        #endif
        // Drop-newest when the pool is saturated so a burst cannot stack
        // unlimited blocking lookups behind a wedged resolver; saturation
        // reads as unverified rather than permission to dial. The probe never
        // blocks, so awaiting tasks keep the cooperative pool moving.
        guard ssrfDNSGate.tryAcquire() else {
            return unverifiedDenial(for: host)
        }
        // Single one-shot verdict shared by DNS, timeout, and cancellation so a slow
        // resolver arriving after a timeout cannot resume twice; late arrivals observe
        // the stored outcome instead of racing. The sleeper holder stays apart from the
        // verdict lock and is re-checked after storing, so a resume racing registration
        // still drops the late sleeper instead of leaking sleeps under bursts.
        let once = CheckedOnce<String?>()
        let sleeper = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        return await withTaskCancellationHandler {
            // The shared once gate never resumes with failure, so the throwing
            // shape only bridges the shared gate into this Never-style waiter;
            // any unexpected throw still fails closed rather than dialing.
            do {
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                    once.set(continuation)
                    // Register the fail-closed sleeper before queueing DNS so an early
                    // DNS answer always finds a handle to drop; the winner cancels the
                    // loser on settle, keeping burst lookups from stacking lingering sleeps.
                    let timeoutTask = Task {
                        let nanos = UInt64((dnsResolutionTimeoutSeconds * 1_000_000_000).rounded(.down))
                        try? await Task.sleep(nanoseconds: nanos)
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: unverifiedDenial(for: host))
                    }
                    if once.isSettled {
                        timeoutTask.cancel()
                    } else {
                        sleeper.withLock { $0 = timeoutTask }
                        if once.isSettled {
                            let late = sleeper.withLock { current -> Task<Void, Never>? in
                                let task = current
                                current = nil
                                return task
                            }
                            late?.cancel()
                        }
                    }
                    ssrfDNSQueue.addOperation {
                        // Cooperative removal: when timeout or cancellation already
                        // won, skip the blocking resolver so a queued burst never
                        // holds a pool thread for an abandoned verdict.
                        if once.isSettled {
                            ssrfDNSGate.release()
                            return
                        }
                        defer { ssrfDNSGate.release() }
                        let verdict = vettedDNSDenial(for: host)
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: verdict)
                    }
                    if Task.isCancelled {
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: unverifiedDenial(for: host))
                    }
                }
            } catch {
                return unverifiedDenial(for: host)
            }
        } onCancel: {
            let held = sleeper.withLock { current -> Task<Void, Never>? in
                let task = current
                current = nil
                return task
            }
            held?.cancel()
            once.resume(returning: unverifiedDenial(for: host))
        }
    }

    /// Resolves a hostname to its IP addresses.
    /// Blocking by design with no kernel cancellation: callers on the
    /// cooperative pool must use `denyReasonAsync`, which hops this work to
    /// the bounded pool with a fail-closed timeout. The result stays
    /// point-in-time; pin the address at dial time because a hostname can
    /// rebind between this check and the connection.
    private static func resolveHostAddresses(_ host: String) -> [String] {
        #if DEBUG
            // Hermetic debug suites publish canned proof here so they never touch the network;
            // the stub exists in debug builds only, so release always vets via the system resolver.
            if let stub = ssrfTestDNSBox.get() {
                return stub(host)
            }
        #endif
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM)

        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &res)
        guard status == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }

        var addresses = [String]()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let ptr = current {
            let addr = ptr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ai_addr, addr.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let resolved = hostname.withUnsafeBufferPointer { buf in
                    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    return String(bytes: bytes, encoding: .utf8) ?? ""
                }
                addresses.append(resolved)
            }
            current = addr.ai_next
        }
        return addresses
    }

    /// Whether a URL may be dialed under the SSRF guard.
    /// Blocking on the calling thread for DNS; prefer `isAllowedAsync` off
    /// the cooperative pool. Unverified hostnames fail closed. The synchronous
    /// shape stays for callers that cannot suspend, such as browser bridge
    /// input checks.
    public static func isAllowed(
        _ rawURL: String,
        browserConfig: BrowserConfig,
        llmServerURLs: [String] = []
    ) -> Bool {
        denyReason(for: rawURL, browserConfig: browserConfig, llmServerURLs: llmServerURLs) == nil
    }

    /// Async allow check that keeps blocking DNS on the bounded pool.
    /// Unverified hostnames fail closed. The verdict stays point-in-time;
    /// pin the resolved address at dial time.
    public static func isAllowedAsync(
        _ rawURL: String,
        browserConfig: BrowserConfig,
        llmServerURLs: [String] = []
    ) async -> Bool {
        await denyReasonAsync(for: rawURL, browserConfig: browserConfig, llmServerURLs: llmServerURLs) == nil
    }
}
