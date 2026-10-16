// Rune Weaver Tools — Single-source SSRF guard for API and fetch hops.

import Foundation
import os
import RuneWeaverCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Single width for the bounded DNS pool shared by the queue and the permit gate.
private let ssrfDNSPoolWidth = 4

/// SSRF guard for API URLs.
private let ssrfDNSQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.runeweaver.ssrf-dns"
    queue.maxConcurrentOperationCount = ssrfDNSPoolWidth
    queue.qualityOfService = .utility
    return queue
}()

/// Non-blocking permit gate bounding total pending DNS vettings to the pool width.
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
private let ssrfDNSGate = SSRFPermitGate(ssrfDNSPoolWidth)

#if DEBUG
    /// Width for the stub-only DNS queue below.
    private let ssrfStubDNSQueueWidth = 8

    /// Dedicated queue for DEBUG DNS stubs.
    private let ssrfStubDNSQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.runeweaver.ssrf-stub-dns"
        queue.maxConcurrentOperationCount = ssrfStubDNSQueueWidth
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Test-only DNS override keeping stubbed suites hermetic without a production allowlist.
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
        static var testDNSResolver: (@Sendable (String) -> [String])? {
            get { ssrfTestDNSBox.get() }
            set { ssrfTestDNSBox.set(newValue) }
        }

        /// Task-scoped DNS stub for suites that must observe resolver traffic exactly. Debug-only,
        /// matching the global hook.
        @TaskLocal
        static var taskTestDNSResolver: (@Sendable (String) -> [String])?

        /// Effective debug resolver: a task-scoped binding wins over the process-global
        /// holder, keeping lookup-counting suites isolated from concurrent global writers
        /// while preserving the global hook for suites that have not migrated.
        static var activeTestDNSResolver: (@Sendable (String) -> [String])? {
            taskTestDNSResolver ?? testDNSResolver
        }
    #endif

    /// Well-known cloud metadata hostnames plus metadata address literals, refused even over public
    /// DNS and even when an allowlisted name resolves to them.
    public static let blockedMetadataHosts: Set<String> = SensitiveAddressRanges.blockedMetadataHosts

    /// Whether a host is a well-known metadata hostname or metadata literal.
    /// Thin forwarder to the shared Core classifier so Tools callers keep the
    /// established guard name while exactly one metadata set exists.
    public static func isMetadataHost(_ host: String) -> Bool {
        SensitiveAddressRanges.isMetadataHost(host)
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

    /// Whether a 32-bit IPv4 value is in `169.254.0.0/16` (link-local).
    public static func isLinkLocalIPv4Value(_ value: UInt32) -> Bool {
        ApiSSRFAddresses.isLinkLocalIPv4Value(value)
    }

    /// Whether a 32-bit IPv4 value is in private RFC 1918 space.
    public static func isPrivateIPv4Value(_ value: UInt32) -> Bool {
        ApiSSRFAddresses.isPrivateIPv4Value(value)
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
    public static let dnsResolutionTimeoutSeconds: TimeInterval = 5

    /// Allowlisted loopback and homelab origins derived from configuration. Effective exemptions
    /// are the auto service origins (`searxng_url`, enabled media LAN URLs, configured LLM server
    /// URLs) only.
    public static func allowlistedOrigins(
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = []
    ) -> Set<String> {
        var origins = Set<String>()
        var candidates = [browserConfig.searxngURL] + llmServerURLs
        // Disabled services stay out of the exemption set: broadening dialable
        // origins for a service the operator turned off would violate least privilege.
        if let mediaConfig, mediaConfig.sonarr.enabled, let sonarrURL = mediaConfig.sonarr.url {
            candidates.append(sonarrURL)
        }
        if let mediaConfig, mediaConfig.radarr.enabled, let radarrURL = mediaConfig.radarr.url {
            candidates.append(radarrURL)
        }
        for raw in candidates {
            insertOriginVariants(raw, into: &origins)
        }
        return origins
    }

    /// Inserts the dialable host and key variants for one configured origin.
    private static func insertOriginVariants(_ raw: String, into origins: inout Set<String>) {
        guard let trimmed = NormalizedText.value(raw) else { return }
        if trimmed.contains("://") {
            let urlString = trimmed
            if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
                origins.insert(host.lowercased())
                if let key = originKey(for: url) {
                    origins.insert(key)
                }
            }
            return
        }
        origins.insert(trimmed.lowercased())
        let urlString = "http://\(trimmed)"
        if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
            origins.insert(host.lowercased())
            if let key = originKey(for: url) {
                origins.insert(key)
            }
        }
    }

    /// Refusal reason against an explicit exemption set, or nil when dialable.
    public static func denyReason(
        for rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) -> String? {
        denyReasonImpl(for: rawURL, allowlistedOrigins: allowlistedOrigins, hasLLMOrigins: false)
    }

    /// Refusal reason for a URL, or nil when the URL may be dialed.
    public static func denyReason(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = []
    ) -> String? {
        let origins = allowlistedOrigins(browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs)
        let hasLLM = llmServerURLs.contains(where: { NormalizedText.value($0) != nil })
        return denyReasonImpl(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLM)
    }

    /// Async refusal reason against an explicit exemption set, or nil when dialable.
    public static func denyReasonAsync(
        for rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) async -> String? {
        await vetAsync(for: rawURL, allowlistedOrigins: allowlistedOrigins).refusal
    }

    /// Async refusal reason against an explicit exemption set with honest wording, or nil when
    /// dialable.
    public static func denyReasonAsync(
        for rawURL: String,
        allowlistedOrigins: Set<String>,
        hasLLMOrigins: Bool
    ) async -> String? {
        await vet(for: rawURL, origins: allowlistedOrigins, hasLLMOrigins: hasLLMOrigins).refusal
    }

    /// Async refusal reason for a URL, or nil when the URL may be dialed.
    public static func denyReasonAsync(
        for rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = []
    ) async -> String? {
        await vetAsync(
            for: rawURL,
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ).refusal
    }

    /// Whether a URL may be dialed under the SSRF guard. Blocking on the calling thread for DNS;
    /// prefer `isAllowedAsync` off the cooperative pool.
    public static func isAllowed(
        _ rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = []
    ) -> Bool {
        denyReason(for: rawURL, browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs) == nil
    }

    /// Whether a URL may be dialed under the SSRF guard with precomputed origins.
    public static func isAllowed(
        _ rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) -> Bool {
        denyReason(for: rawURL, allowlistedOrigins: allowlistedOrigins) == nil
    }

    /// Async allow check that keeps blocking DNS on the bounded pool.
    /// Unverified hostnames fail closed. Dialing callers use `vetAsync`, which
    /// returns the pinned address the connection must use.
    public static func isAllowedAsync(
        _ rawURL: String,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = []
    ) async -> Bool {
        await denyReasonAsync(for: rawURL, browserConfig: browserConfig, mediaConfig: mediaConfig, llmServerURLs: llmServerURLs) == nil
    }

    /// Async allow check with precomputed origins that keeps blocking DNS on the bounded pool.
    public static func isAllowedAsync(
        _ rawURL: String,
        allowlistedOrigins: Set<String> = []
    ) async -> Bool {
        await denyReasonAsync(for: rawURL, allowlistedOrigins: allowlistedOrigins) == nil
    }
}

// MARK: - Internal DNS Vetting Helpers

extension ApiSSRFGuard {
    /// Shared refusal engine over a precomputed exemption set.
    private static func denyReasonImpl(
        for rawURL: String,
        allowlistedOrigins origins: Set<String>,
        hasLLMOrigins: Bool
    ) -> String? {
        // Synchronous callers pay the resolver cost here; the async path
        // moves this same vetting onto the bounded pool instead. The pin the
        // vetting proves is irrelevant to a verdict-only caller.
        switch preDNSOutcome(for: rawURL, allowlistedOrigins: origins, hasLLMOrigins: hasLLMOrigins) {
        case let .denied(reason):
            return reason
        case .allowed:
            return nil
        case let .needsDNS(host):
            guard let url = parsedVettingURL(rawURL) else {
                return unverifiedDenial(for: host)
            }
            return vettedDNSVetting(for: host, origins: origins, url: url).refusal
        }
    }

    /// Vets resolved addresses for one hostname, failing closed when empty and returning the dial
    /// pin when every address clears.
    private static func vettedDNSVetting(for host: String, origins: Set<String> = [], url: URL) -> ApiSSRFVetting {
        vettedIPListVetting(host: host, addresses: resolveHostAddresses(host), origins: origins, url: url)
    }

    /// Bounded async DNS vetting with fail-closed timeout and cancellation.
    static func dnsVettingAsync(host: String, origins: Set<String> = [], url: URL) async -> ApiSSRFVetting {
        if Task.isCancelled {
            return .refused(unverifiedDenial(for: host))
        }
        // Every address proof flows through the shared resolver — hermetic suites observe their
        // canned proof there while production proves via the bounded pool there — so the dial path
        // and the local-access classifier cannot observe different answers for the same host.
        let addresses = await resolveAddressesAsync(host: host)
        return vettedIPListVetting(host: host, addresses: addresses, origins: origins, url: url)
    }

    /// Resolves a hostname to addresses on the bounded SSRF DNS pool.
    static func resolveAddressesAsync(host: String) async -> [String] {
        if Task.isCancelled {
            return []
        }
        #if DEBUG
            // Debug-only stub surface, matching `dnsVettingAsync`: a task-scoped binding wins over
            // the process-global holder, so a lookup-counting suite stays isolated from concurrent
            // suites that publish globally.
            if let stub = activeTestDNSResolver {
                return await stubResultWithTimeoutAsync(failure: []) {
                    stub(host)
                }
            }
        #endif
        return await boundedPoolResultAsync(failure: []) {
            resolveHostAddresses(host)
        }
    }

    #if DEBUG
        /// Runs a test stub under the fail-closed timeout on the dedicated stub
        /// queue without consuming production ssrfDNSGate permits.
        private static func stubResultWithTimeoutAsync<T: Sendable>(
            failure: T,
            operation: @escaping @Sendable () -> T
        ) async -> T {
            if Task.isCancelled {
                return failure
            }
            let once = CheckedOnce<T>()
            let sleeper = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            do {
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                    once.set(continuation)
                    let timeoutTask = Task {
                        let nanos = UInt64((dnsResolutionTimeoutSeconds * 1_000_000_000).rounded(.down))
                        do {
                            try await Task.sleep(nanoseconds: nanos)
                        } catch {
                            return
                        }
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: failure)
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
                    // Hermetic stubs run on the dedicated stub queue — never the shared global
                    // queue — so an instant canned lookup cannot stall behind parallel-suite work
                    // into a false fail-closed timeout; the fail-closed timeout still bounds a wedged stub without consuming pool permits.
                    ssrfStubDNSQueue.addOperation {
                        let result = operation()
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: result)
                    }
                }
            } catch {
                return failure
            }
        }
    #endif

    /// Runs one blocking resolver operation on the capped pool under the shared fail-closed timeout
    /// and cancellation contract.
    private static func boundedPoolResultAsync<T: Sendable>(
        failure: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        if Task.isCancelled {
            return failure
        }
        // Drop-newest when the pool is saturated so a burst cannot stack
        // unlimited blocking lookups behind a wedged resolver; saturation
        // reads as unverified rather than permission to dial.
        guard ssrfDNSGate.tryAcquire() else {
            return failure
        }
        // Single one-shot verdict shared by the operation, timeout, and cancellation so a slow
        // resolver arriving after a timeout cannot resume twice; late arrivals observe the stored
        // outcome instead of racing.
        let once = CheckedOnce<T>()
        let sleeper = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        return await withTaskCancellationHandler {
            // The shared once gate never resumes with failure, so the throwing
            // shape only bridges the shared gate into this Never-style waiter;
            // any unexpected throw still fails closed rather than dialing.
            do {
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                    once.set(continuation)
                    // Register the fail-closed sleeper before queueing the operation so an early
                    // answer always finds a handle to drop; the winner cancels the loser on settle,
                    // keeping burst lookups from stacking lingering sleeps.
                    let timeoutTask = Task {
                        let nanos = UInt64((dnsResolutionTimeoutSeconds * 1_000_000_000).rounded(.down))
                        do {
                            try await Task.sleep(nanoseconds: nanos)
                        } catch {
                            return
                        }
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: failure)
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
                        // Cooperative removal: when timeout or cancellation
                        // already won, skip the blocking work so a queued burst
                        // never holds a pool thread for an abandoned verdict.
                        if once.isSettled {
                            ssrfDNSGate.release()
                            return
                        }
                        defer { ssrfDNSGate.release() }
                        let result = operation()
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: result)
                    }
                    if Task.isCancelled {
                        let held = sleeper.withLock { current -> Task<Void, Never>? in
                            let task = current
                            current = nil
                            return task
                        }
                        held?.cancel()
                        once.resume(returning: failure)
                    }
                }
            } catch {
                return failure
            }
        } onCancel: {
            let held = sleeper.withLock { current -> Task<Void, Never>? in
                let task = current
                current = nil
                return task
            }
            held?.cancel()
            once.resume(returning: failure)
        }
    }

    /// Resolves a hostname to its IP addresses.
    private static func resolveHostAddresses(_ host: String) -> [String] {
        #if DEBUG
            // Hermetic debug suites publish canned proof here so they never touch the network; the
            // hook exists in debug builds only, so release always vets via the system resolver.
            if let stub = activeTestDNSResolver {
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
}

// MARK: - Internal Classification Helpers

extension ApiSSRFGuard {
    /// Classifies whether saving `host` should grant local-network access.
    public static func classifyLocalAccess(forHost host: String) async -> LocalAccessVerdict {
        let cleaned = SensitiveAddressNormalization.cleanedHostBase(host)
        guard !cleaned.isEmpty else {
            return .unresolved(reason: "SSRF denied: refusing empty host.")
        }
        if let reason = neverExemptLiteralDenial(for: cleaned) {
            return .neverDialable(reason: reason)
        }
        if isLoopbackHost(cleaned) {
            return .localNetwork
        }
        let canonical = normalizedHost(cleaned)
        if let value = ipv4Value(canonical), isSensitiveIPv4Value(value) {
            return .localNetwork
        }
        // Classify the literal's own prefix as well as the normalized form: normalization collapses
        // a dotted tail onto its dotted IPv4, which would drop the link-local, unique-local, or
        // embedded-translation verdict the literal's prefix carries.
        if isSensitiveIPv6Host(cleaned) || isSensitiveIPv6Host(canonical) {
            return .localNetwork
        }
        if isIPAddressLiteral(cleaned) {
            // Literals settle without DNS; sensitive ranges already returned
            // above, so what remains is a public address.
            return .publicDestination
        }
        // Prove hostnames through the single bounded resolver the dial path uses, so the save-time
        // verdict and the dial-time pin cannot observe different answers for the same host.
        let addresses = await resolveAddressesAsync(host: cleaned)
        guard !addresses.isEmpty else {
            return .unresolved(reason: unverifiedDenial(for: cleaned))
        }
        if addresses.contains(where: { isNeverExemptAddress($0) }) {
            // The refusal reuses the guard's resolved-range wording so the save-time verdict and
            // the dial-time refusal stay identical by construction; the helper must refuse while a
            // never-exempt address is present, and the fallback keeps the same fail-closed refusal.
            let reason = vettedIPListDenial(host: cleaned, addresses: addresses)
                ?? "SSRF denied: hostname '\(cleaned)' resolves to blocked address"
            return .neverDialable(reason: reason)
        }
        if addresses.contains(where: { isExemptableSensitiveAddress($0) }) {
            return .localNetwork
        }
        return .publicDestination
    }

    /// Never-exempt refusal for a cleaned literal or metadata hostname.
    private static func neverExemptLiteralDenial(for host: String) -> String? {
        if isMetadataHost(host) {
            return "SSRF denied: refusing metadata host '\(host)'."
        }
        if isLinkLocalIPv4(host) {
            return "SSRF denied: refusing link-local address '\(host)' (169.254.0.0/16)."
        }
        if isLinkLocalIPv6(host) {
            return "SSRF denied: refusing link-local address '\(host)' (fe80::/10)."
        }
        return embeddedNeverExemptDenial(for: host)
    }

    /// Whether a resolved address is never exempt from refusal.
    private static func isNeverExemptAddress(_ address: String) -> Bool {
        if isLinkLocalIPv4(address) || isLinkLocalIPv6(address) || isMetadataHost(address) {
            return true
        }
        return embeddedNeverExemptDenial(for: address) != nil
    }

    /// Whether a resolved address is sensitive but exemption-eligible.
    private static func isExemptableSensitiveAddress(_ address: String) -> Bool {
        if isLoopbackHost(address) {
            return true
        }
        let canonical = normalizedHost(address)
        if let value = ipv4Value(canonical), isSensitiveIPv4Value(value) {
            return true
        }
        return isSensitiveIPv6Host(address) || isSensitiveIPv6Host(canonical)
    }
}
