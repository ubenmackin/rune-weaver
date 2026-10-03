// Rune Weaver Core Tests — PolicyStore lifecycle, parsing, and serialization.
//
// Pins the contract that policy.toml owns network plus credentials only:
// parsed, validated, serialized, and round-tripped correctly. Legacy
// filesystem and tool tables are tolerated on load and ignored without
// error so older files keep booting. Malformed or invariant-violating
// policies fall back to the safe factory default. The retired
// `browser.allowed_origins` list migrates once into
// `[network].local_exemptions`, so a key-present file never reconsults it
// and a failed migration write stays retryable.

import Foundation
@testable import RuneWeaverCore
import RuneWeaverTools
import Testing

@Suite("PolicyStore")
struct PolicyStoreTests {
    // MARK: - TOML Parsing

    @Test
    func `Parses valid policy.toml`() throws {
        let toml = """
        version = 1

        [network]
        mode = "allowlist_only"
        allowed_domains = ["api.github.com", "api.openai.com"]
        blocked_domains = ["169.254.169.254"]

        [credentials.GITHUB_PAT]
        allowed_hosts = ["api.github.com"]
        allowed_methods = ["GET", "POST"]
        allowed_path_prefixes = ["/repos/", "/user"]

        [credentials.OPENAI_KEY]
        allowed_hosts = ["api.openai.com"]
        allowed_methods = ["POST"]

        [filesystem]
        allow_roots = ["~/Documents/Projects"]
        deny_paths = ["~/.ssh", "~/.aws"]

        [tools."api.request"]
        level = "requiresApproval"
        allow_graduated_trust = true

        [tools."messages.send"]
        level = "requiresApproval"
        allow_graduated_trust = false
        """

        let policy = try PolicyStore.parse(toml)

        #expect(policy.version == 1)
        #expect(policy.network.mode == .allowlistOnly)
        #expect(policy.network.allowedDomains.contains("api.github.com"))
        #expect(policy.network.allowedDomains.contains("api.openai.com"))
        #expect(policy.network.blockedDomains.contains("169.254.169.254"))

        #expect(policy.credentials.count == 2)
        let github = try #require(policy.credentials["GITHUB_PAT"])
        #expect(github.allowedHosts.contains("api.github.com"))
        #expect(github.allowedMethods.contains("GET"))
        #expect(github.allowedMethods.contains("POST"))
        #expect(github.allowedPathPrefixes == ["/repos/", "/user"])

        let openai = try #require(policy.credentials["OPENAI_KEY"])
        #expect(openai.allowedHosts.contains("api.openai.com"))
        #expect(openai.allowedMethods.contains("POST"))
        #expect(openai.allowedPathPrefixes.isEmpty)

        // The file owns network plus credentials only: legacy filesystem and
        // tool sections parse without error but never contribute to the held
        // posture, so an older file boots with its egress bindings intact.
    }

    @Test
    func `Parses minimal policy.toml with defaults`() throws {
        let toml = """
        version = 1
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.version == 1)
        #expect(policy.network.mode == .allowlistOnly)
        #expect(policy.credentials.isEmpty)
    }

    @Test
    func `Parses unrestricted network mode`() throws {
        let toml = """
        [network]
        mode = "unrestricted"
        allowed_domains = []
        blocked_domains = []
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.network.mode == .unrestricted)
    }

    @Test
    func `Unknown network mode falls back to allowlist_only`() throws {
        let toml = """
        [network]
        mode = "yolo"
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.network.mode == .allowlistOnly)
    }

    @Test
    func `Legacy deny_by_default mode parses as allowlist_only`() throws {
        // Older files stored the fail-closed posture under a retired name;
        // the parse boundary maps it to the surviving spelling so its intent
        // survives the rename instead of falling through to a default.
        let toml = """
        [network]
        mode = "deny_by_default"
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.network.mode == .allowlistOnly)
    }

    @Test
    func `Legacy filesystem and tool tables are ignored on load`() throws {
        // A file carrying only retired sections must still load: the tables
        // are tolerated and dropped, leaving the network-plus-credentials
        // posture at its deny-by-default shape rather than failing the boot.
        let toml = """
        version = 1

        [filesystem]
        allow_roots = ["~/Documents/Projects"]
        deny_paths = ["~/.ssh"]

        [tools."messages.send"]
        level = "trusted"
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.network.mode == .allowlistOnly)
        #expect(policy.credentials.isEmpty)
        #expect(PolicyInvariantVerifier.verify(policy).isEmpty)
    }

    // MARK: - Serialization Round-Trip

    @Test
    func `Serialize and re-parse produces identical policy`() throws {
        let original = SecurityPolicy(
            version: 1,
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com", "api.openai.com"],
                blockedDomains: ["169.254.169.254"]
            ),
            credentials: [
                "GITHUB_PAT": CredentialBinding(
                    allowedHosts: ["api.github.com"],
                    allowedMethods: ["GET", "POST"],
                    allowedPathPrefixes: ["/repos/"]
                )
            ]
        )

        let toml = PolicyStore.serialize(original)
        // The file owns network plus credentials only, so a resaved document
        // never resurrects retired sections even when the input once had them.
        #expect(!toml.contains("[filesystem]"))
        #expect(!toml.contains("[tools."))
        let reparsed = try PolicyStore.parse(toml)

        #expect(reparsed.version == original.version)
        #expect(reparsed.network.mode == original.network.mode)
        #expect(reparsed.network.allowedDomains == original.network.allowedDomains)
        #expect(reparsed.network.blockedDomains == original.network.blockedDomains)
        #expect(reparsed.credentials.count == original.credentials.count)
        #expect(reparsed.credentials["GITHUB_PAT"]?.allowedHosts == original.credentials["GITHUB_PAT"]?.allowedHosts)
    }

    @Test
    func `Safe default serializes and re-parses cleanly`() throws {
        let toml = PolicyStore.serialize(.safeDefault)
        let reparsed = try PolicyStore.parse(toml)
        #expect(reparsed.version == 1)
        #expect(reparsed.network.mode == .allowlistOnly)
        #expect(reparsed.credentials.isEmpty)
    }

    @Test
    func `Serialized policy points editors at the Policy tab`() {
        // The dashboard editor lives on the dedicated Policy tab, so the
        // seeded guidance line must not send operators to the retired tab.
        let toml = PolicyStore.serialize(.safeDefault)
        #expect(toml.contains("Policy tab"))
        #expect(!toml.contains("Security tab"))
    }

    @Test
    func `Store-owned round-trip proof returns bytes that reparse identically`() throws {
        // The settings PUT route serializes through this shared proof, so a
        // clean candidate must come back as bytes the parser reads as the
        // exact accepted policy, while a document that would change meaning on
        // reload must throw instead of reaching disk.
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"],
                blockedDomains: ["169.254.169.254"]
            ),
            credentials: [
                "GITHUB_PAT": CredentialBinding(
                    allowedHosts: ["api.github.com"],
                    allowedMethods: ["GET"],
                    allowedPathPrefixes: ["/repos/"]
                )
            ]
        )

        let toml = try PolicyStore.verifiedTOML(for: policy)
        let reparsed = try PolicyStore.parse(toml)
        #expect(reparsed == policy)

        let hostileKey = "EVIL\"\n[credentials.INJECTED]\nallowed_hosts = [\"*\"]"
        let hostile = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [hostileKey: CredentialBinding(allowedHosts: ["api.example.com"])]
        )
        #expect(throws: PolicyInvariantError.self) {
            _ = try PolicyStore.verifiedTOML(for: hostile)
        }
    }

    @Test
    func `Serialize and re-parse preserves dotted credential key`() throws {
        // Regression: an unquoted `[credentials.MY.KEY]` header parses as
        // nested tables, so the file written by `save()` used to fail
        // Invariant 2 with "no allowed_hosts" when reloaded.
        let original = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "MY.API.KEY": CredentialBinding(allowedHosts: ["api.example.com"])
            ]
        )
        let toml = PolicyStore.serialize(original)
        #expect(toml.contains("[credentials.\"MY.API.KEY\"]"))

        let reparsed = try PolicyStore.parse(toml)
        #expect(reparsed.credentials.count == 1)
        #expect(reparsed.credentials["MY.API.KEY"]?.allowedHosts == Set(["api.example.com"]))
        #expect(PolicyInvariantVerifier.verify(reparsed).isEmpty)
    }

    @Test
    func `PolicyStore save round-trips a dotted credential key`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-dotted-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "MY.API.KEY": CredentialBinding(allowedHosts: ["api.example.com"])
            ]
        )
        let violations = await store.update(policy)
        #expect(violations.isEmpty)
        try await store.save()
        await store.load()
        let reloaded = try await store.snapshot()
        #expect(reloaded.credentials["MY.API.KEY"]?.allowedHosts == Set(["api.example.com"]))
    }

    // MARK: - Network Policy Gate

    @Test
    func `Network policy allows listed domain`() {
        let policy = NetworkEgressPolicy(
            mode: .allowlistOnly,
            allowedDomains: ["api.github.com"]
        )
        #expect(policy.denyReason(for: "api.github.com") == nil)
    }

    @Test
    func `Network policy denies unlisted domain`() throws {
        let policy = NetworkEgressPolicy(
            mode: .allowlistOnly,
            allowedDomains: ["api.github.com"]
        )
        let result = try #require(policy.denyReason(for: "evil.com"))
        #expect(result.contains("not in the allowed domains"))
    }

    @Test
    func `Network policy blocks explicitly blocked domain`() throws {
        let policy = NetworkEgressPolicy(
            mode: .unrestricted,
            allowedDomains: [],
            blockedDomains: ["evil.com"]
        )
        let result = try #require(policy.denyReason(for: "evil.com"))
        #expect(result.contains("explicitly blocked"))
    }

    @Test
    func `Unrestricted mode allows non-blocked domains`() {
        let policy = NetworkEgressPolicy(
            mode: .unrestricted,
            allowedDomains: [],
            blockedDomains: ["evil.com"]
        )
        #expect(policy.denyReason(for: "any.host.com") == nil)
    }

    @Test
    func `Wildcard allowed domain matches subdomain`() {
        let policy = NetworkEgressPolicy(
            mode: .allowlistOnly,
            allowedDomains: ["*.github.com"]
        )
        #expect(policy.denyReason(for: "api.github.com") == nil)
        #expect(policy.denyReason(for: "raw.github.com") == nil)
    }

    @Test
    func `Wildcard blocked domain matches subdomain`() throws {
        let policy = NetworkEgressPolicy(
            mode: .unrestricted,
            blockedDomains: ["*.evil.com"]
        )
        let result = try #require(policy.denyReason(for: "sub.evil.com"))
        #expect(result.contains("blocked pattern"))
    }

    @Test
    func `Blocked domain matches trailing-dot and alternate spellings`() {
        // Regression: `evil.com.` (trailing root dot) and obfuscated numeric
        // spellings previously slipped past an exact-lowercase block entry.
        let policy = NetworkEgressPolicy(
            mode: .unrestricted,
            allowedDomains: [],
            blockedDomains: ["evil.com", "169.254.169.254", "*.malware.net"]
        )
        #expect(policy.denyReason(for: "evil.com.") != nil)
        #expect(policy.denyReason(for: "EVIL.COM.") != nil)
        #expect(policy.denyReason(for: "0xa9fea9fe") != nil)
        #expect(policy.denyReason(for: "sub.malware.net.") != nil)
        #expect(policy.denyReason(for: "safe.example.com.") == nil)
    }

    @Test
    func `Allowed domain matches trailing-dot spelling`() {
        let policy = NetworkEgressPolicy(
            mode: .allowlistOnly,
            allowedDomains: ["api.github.com", "*.example.com"]
        )
        #expect(policy.denyReason(for: "api.github.com.") == nil)
        #expect(policy.denyReason(for: "API.EXAMPLE.COM.") == nil)
    }

    // MARK: - PolicyStore Load Lifecycle

    @Test
    func `PolicyStore update with valid policy succeeds`() async {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-policy-\(UUID().uuidString).toml"))
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                allowedDomains: ["api.github.com"]
            ),
            credentials: [
                "GITHUB_PAT": CredentialBinding(allowedHosts: ["api.github.com"])
            ]
        )
        let violations = await store.update(policy)
        #expect(violations.isEmpty)
        let current = await store.current
        #expect(current.credentials["GITHUB_PAT"] != nil)
    }

    @Test
    func `PolicyStore update with invariant violation is rejected`() async {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-policy-\(UUID().uuidString).toml"))
        let badPolicy = SecurityPolicy(
            credentials: [
                "LEAKED": CredentialBinding(allowedHosts: ["*"])
            ]
        )
        let violations = await store.update(badPolicy)
        #expect(!violations.isEmpty)
        // Current should remain safe default
        let current = await store.current
        #expect(current.credentials.isEmpty)
    }

    @Test
    func `PolicyStore update rejects IPv6 loopback credential target`() async {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-policy-\(UUID().uuidString).toml"))
        let badPolicy = SecurityPolicy(
            credentials: [
                "LOCAL_KEY": CredentialBinding(allowedHosts: ["::1"])
            ]
        )
        let violations = await store.update(badPolicy)
        #expect(!violations.isEmpty)
        let current = await store.current
        #expect(current.credentials.isEmpty)
    }

    @Test
    func `PolicyStore update rejects IPv4-mapped private credential target`() async {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-policy-\(UUID().uuidString).toml"))
        let badPolicy = SecurityPolicy(
            credentials: [
                "MAPPED_KEY": CredentialBinding(allowedHosts: ["::ffff:10.0.0.5"])
            ]
        )
        let violations = await store.update(badPolicy)
        #expect(!violations.isEmpty)
        let current = await store.current
        #expect(current.credentials.isEmpty)
    }

    @Test
    func `PolicyStore load rejects IPv6 credential binding and refuses snapshot`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-ipv6-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[credentials.LOCAL]\nallowed_hosts = [\"fd12:3456::1\"]\n".utf8).write(to: url)
        let store = PolicyStore(fileURL: url)
        await store.load()
        // The invariant-violating file falls back to the displayable safe posture...
        let current = await store.current
        #expect(current == .safeDefault)
        // ...and the security-critical snapshot refuses to bless it.
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await store.snapshot()
        }
    }

    @Test
    func `PolicyStore load accepts public credential hosts`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-public-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let toml = """
        [credentials.GITHUB_PAT]
        allowed_hosts = ["api.github.com", "api.openai.com"]
        """
        try Data(toml.utf8).write(to: url)
        let store = PolicyStore(fileURL: url)
        await store.load()
        let current = await store.current
        #expect(current.credentials["GITHUB_PAT"] != nil)
        let snapshot = try await store.snapshot()
        #expect(snapshot.credentials["GITHUB_PAT"] != nil)
    }

    @Test
    func `PolicyStore loads missing file with safe defaults`() async {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/nonexistent/path/policy.toml"))
        await store.load()
        let current = await store.current
        #expect(current == .safeDefault)
        let loaded = await store.loadedFromDisk
        #expect(!loaded)
    }

    // MARK: - Verified Snapshot

    @Test
    func `Snapshot is unavailable until a load or update is accepted`() async throws {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-policy-\(UUID().uuidString).toml"))
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await store.snapshot()
        }
        let violations = await store.update(.safeDefault)
        #expect(violations.isEmpty)
        let policy = try await store.snapshot()
        #expect(policy == .safeDefault)
    }

    @Test
    func `Corrupt file keeps the fallback displayable but never snapshot-able`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-corrupt-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[credentials.LEAK]\nallowed_hosts = [\"*\"]\n".utf8).write(to: url)
        let store = PolicyStore(fileURL: url)
        await store.load()
        // Display paths keep the safe fallback posture...
        let current = await store.current
        #expect(current == .safeDefault)
        // ...but the security-critical snapshot refuses to launder it.
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await store.snapshot()
        }
    }

    // MARK: - Storage-Boundary Save Guard

    @Test
    func `Save persists a verified policy that reloads clean`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-save-clean-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [
                "SAVE_KEY": CredentialBinding(allowedHosts: ["api.example.com"])
            ]
        )
        // Only an accepted posture reaches the storage boundary, so the
        // persisted file must reload through the same verified path.
        let violations = await store.update(policy)
        #expect(violations.isEmpty)
        try await store.save()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let reloaded = PolicyStore(fileURL: url)
        await reloaded.load()
        let snapshot = try await reloaded.snapshot()
        #expect(snapshot.credentials["SAVE_KEY"]?.allowedHosts == Set(["api.example.com"]))
    }

    @Test
    func `Save never persists a rejected update proposal`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-save-rejected-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        // Seed the file with the verified factory posture first.
        try await store.save()
        let before = try String(contentsOf: url, encoding: .utf8)

        // The violating proposal is refused at the update gate, so the held
        // posture stays clean and a subsequent save must preserve the file
        // rather than persisting the rejected content.
        let violating = SecurityPolicy(
            credentials: [
                "LEAKED": CredentialBinding(allowedHosts: ["*"])
            ]
        )
        #expect(!PolicyInvariantVerifier.verify(violating).isEmpty)
        let updateViolations = await store.update(violating)
        #expect(!updateViolations.isEmpty)
        try await store.save()
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == before)
        let reparsed = try PolicyStore.parse(after)
        #expect(PolicyInvariantVerifier.verify(reparsed).isEmpty)
    }

    @Test
    func `Save refusal carries the invariant violations`() {
        // Pins the error shape the storage boundary throws when the held
        // posture stops satisfying the formal invariants, so callers can
        // surface the failing gate without exposing secret bytes.
        let violating = SecurityPolicy(
            credentials: [
                "LEAKED": CredentialBinding(allowedHosts: ["*"])
            ]
        )
        let violations = PolicyInvariantVerifier.verify(violating)
        #expect(!violations.isEmpty)
        let error = PolicyInvariantError.invariantViolations(violations)
        let description = error.localizedDescription
        #expect(description.contains("formal invariants"))
        for violation in violations {
            #expect(description.contains(violation))
        }
    }

    // MARK: - TOML Injection Guards

    @Test
    func `Append allowed domain rejects quotes and control characters`() async throws {
        // A percent-decoded `URL.host` can carry a quote or newline; writing it
        // raw would close the array element and inject real policy content, so
        // the append must refuse before touching the file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-hostile-allow-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        let before = await store.current

        for hostile in [
            "evil.example\"\n[credentials.INJECTED]",
            "evil\u{01}.example.com",
            "evil\r.example.com",
            "evil\u{7F}.example.com",
            "evil\t.example.com"
        ] {
            await #expect(throws: PolicyInvariantError.self) {
                _ = try await store.appendAllowedDomain(hostile)
            }
        }

        let after = await store.current
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func `Append blocked domain rejects quotes and control characters`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-hostile-block-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)

        await #expect(throws: PolicyInvariantError.self) {
            _ = try await store.appendBlockedDomain("evil.example\"\n[tools.\"api.request\"]")
        }

        let after = await store.current
        #expect(after == .safeDefault)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func `Append allowed domain persists a canonical entry`() async throws {
        // The hostile-input guards must not disturb the ordinary interactive
        // path: a valid host still lands canonically and survives a reload.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-append-clean-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)

        _ = try await store.appendAllowedDomain("API.GitHub.com")

        #expect(FileManager.default.fileExists(atPath: url.path))
        let reloaded = PolicyStore(fileURL: url)
        await reloaded.load()
        let snapshot = try await reloaded.snapshot()
        #expect(snapshot.network.allowedDomains.contains("api.github.com"))
    }

    @Test
    func `Ensure service domains skips hosts that cannot be serialized`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-service-hosts-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)

        _ = await store.ensureServiceDomainsAllowed(
            urlsOrHosts: ["evil.example\"\n[credentials.INJECTED]", "api.github.com"]
        )

        let current = await store.current
        #expect(current.network.allowedDomains.contains("api.github.com"))
        #expect(!current.network.allowedDomains.contains { $0.contains("\"") || $0.contains("\n") })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\n[credentials.INJECTED]"))
    }

    @Test
    func `Ensure service domains never overwrites a present-but-rejected policy file`() async throws {
        // A rejected file leaves the store without an accepted posture;
        // auto-population must refuse instead of writing safe-default plus
        // service hosts over the operator's content and then claiming the
        // result as verified. The snapshot must keep throwing so the egress
        // supervisor factory still refuses boot for the same file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-rejected-ensure-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let rejected = "[credentials.LEAK]\nallowed_hosts = [\"*\"]\n"
        try rejected.write(to: url, atomically: true, encoding: .utf8)
        let store = PolicyStore(fileURL: url)
        await store.load()
        #expect(await store.loadedFromDisk == false)

        _ = await store.ensureServiceDomainsAllowed(urlsOrHosts: ["sonarr.example.net", "smtp.example.net"])

        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == rejected)
        let current = await store.current
        #expect(current == .safeDefault)
        #expect(await store.loadedFromDisk == false)
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await store.snapshot()
        }
        await #expect(throws: PolicyInvariantError.self) {
            _ = try await OutboundEgressSupervisor.make(policyStore: store)
        }
    }

    @Test
    func `Serialize escapes hostile domain strings without policy injection`() throws {
        // Pins the byte-level guard: a hostile entry survives only as escaped
        // text inside its own string element and reparses to the same value.
        let hostile = "evil.example\"\n[credentials.INJECTED]\nallowed_hosts = [\"*\"]"
        let original = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .allowlistOnly, allowedDomains: [hostile], blockedDomains: [])
        )

        let toml = PolicyStore.serialize(original)

        #expect(!toml.contains("\n[credentials.INJECTED]"))
        #expect(toml.contains("evil.example\\\"\\n[credentials.INJECTED]"))

        let reparsed = try PolicyStore.parse(toml)
        #expect(reparsed.network.allowedDomains == [hostile])
        #expect(reparsed.credentials.isEmpty)
    }

    @Test
    func `Serialize escapes hostile credential table keys`() {
        // Table keys interpolate directly into headers, so a hostile key must
        // render as escaped text rather than a second real table.
        let key = "EVIL\"\n[credentials.INJECTED]\nallowed_hosts = [\"*\"]"
        let original = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [key: CredentialBinding(allowedHosts: ["api.example.com"])]
        )

        let toml = PolicyStore.serialize(original)

        #expect(!toml.contains("\n[credentials.INJECTED]"))
        #expect(toml.contains("[credentials.\(RuneWeaverConfig.tomlQuoted(key))]"))
    }

    @Test
    func `Save refuses a policy whose bytes would not reparse identically`() async throws {
        // Escaping alone cannot save a key the parser reads back as different
        // content; the storage boundary must refuse the write rather than
        // persist a document that changes meaning on the next boot.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-roundtrip-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        let hostileKey = "EVIL\"\n[credentials.INJECTED]\nallowed_hosts = [\"*\"]"
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted),
            credentials: [hostileKey: CredentialBinding(allowedHosts: ["api.example.com"])]
        )
        let violations = await store.update(policy)
        #expect(violations.isEmpty)

        await #expect(throws: PolicyInvariantError.self) {
            _ = try await store.save()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Local Exemptions

    @Test
    func `local_exemptions serializes, sorts, and round-trips byte-for-byte`() throws {
        let original = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"],
                blockedDomains: ["169.254.169.254"],
                localExemptions: ["airflow.int.volcrypt.com", "*.corp.example.com", "192.168.1.10"]
            )
        )

        let toml = try PolicyStore.verifiedTOML(for: original)
        let expectedLine = "local_exemptions = ["
            + original.network.localExemptions.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
            + "]"
        #expect(toml.contains(expectedLine))

        let reparsed = try PolicyStore.parse(toml)
        #expect(reparsed == original)
        // Byte-for-byte: re-serializing the reparsed object yields the same document.
        #expect(PolicyStore.serialize(reparsed) == toml)
    }

    @Test
    func `Serialize emits local_exemptions directly after blocked_domains`() {
        let toml = PolicyStore.serialize(.safeDefault)
        #expect(toml.contains("blocked_domains = [\"169.254.169.254\"]\nlocal_exemptions = []"))
    }

    @Test
    func `Missing local_exemptions key parses empty and presence helper reports false`() throws {
        let toml = """
        [network]
        mode = "allowlist_only"
        allowed_domains = ["api.github.com"]
        blocked_domains = ["169.254.169.254"]
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.network.localExemptions.isEmpty)
        #expect(!PolicyStore.containsLocalExemptionsKey(in: toml))
        // A resaved document always carries the key, so a later load can tell
        // an owner-edited empty set from a pre-exemption file that needs seeding.
        #expect(PolicyStore.containsLocalExemptionsKey(in: PolicyStore.serialize(policy)))
    }

    @Test
    func `containsLocalExemptionsKey distinguishes missing, empty, and populated keys`() {
        #expect(!PolicyStore.containsLocalExemptionsKey(in: "[network]\nmode = \"allowlist_only\"\n"))
        #expect(!PolicyStore.containsLocalExemptionsKey(in: "version = 1\n"))
        #expect(PolicyStore.containsLocalExemptionsKey(in: "[network]\nlocal_exemptions = []\n"))
        #expect(PolicyStore.containsLocalExemptionsKey(in: "[network]\nlocal_exemptions = [\"a.example.com\"]\n"))
        // Unparseable text cannot carry a readable key.
        #expect(!PolicyStore.containsLocalExemptionsKey(in: "[network\nbroken"))
    }

    @Test
    func `local_exemptions parse trims and drops blanks`() throws {
        let toml = """
        [network]
        local_exemptions = ["  airflow.int.volcrypt.com  ", "   ", "192.168.1.10"]
        """

        let policy = try PolicyStore.parse(toml)
        #expect(policy.network.localExemptions == ["airflow.int.volcrypt.com", "192.168.1.10"])
    }

    @Test
    func `Safe default carries no local exemptions`() {
        #expect(NetworkEgressPolicy.safeDefault.localExemptions.isEmpty)
        #expect(SecurityPolicy.safeDefault.network.localExemptions.isEmpty)
        #expect(PolicyStore.serialize(.safeDefault).contains("local_exemptions = []"))
    }

    @Test
    func `isValidExemptionEntry enforces the local exemption shape`() {
        #expect(AllowedOriginPattern.isValidExemptionEntry("airflow.int.volcrypt.com"))
        #expect(AllowedOriginPattern.isValidExemptionEntry("127.0.0.1"))
        #expect(AllowedOriginPattern.isValidExemptionEntry("fd12:3456::1"))
        #expect(AllowedOriginPattern.isValidExemptionEntry("*.corp.example.com"))
        #expect(AllowedOriginPattern.isValidExemptionEntry("prefix.*"))
        #expect(AllowedOriginPattern.isValidExemptionEntry("*"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry(""))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("   "))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("example.com:8080"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("*.example.com:8080"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("http://example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("user@example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo?bar.example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo[bar].example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo\\bar.example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo,bar.example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo#bar.example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo..example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("*.*"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("**"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("foo.*.example.com"))
        #expect(!AllowedOriginPattern.isValidExemptionEntry("*."))
        #expect(!AllowedOriginPattern.isValidExemptionEntry(".*"))
    }

    @Test
    func `Shared metadata host classifier keeps exact and dot-suffix semantics`() {
        #expect(SensitiveAddressRanges.isMetadataHost("metadata.google.internal"))
        #expect(SensitiveAddressRanges.isMetadataHost("sub.metadata.google.internal"))
        #expect(SensitiveAddressRanges.isMetadataHost("METADATA.GOOGLE.INTERNAL."))
        #expect(SensitiveAddressRanges.isMetadataHost("100.100.100.200"))
        #expect(!SensitiveAddressRanges.isMetadataHost("foo-metadata.google-bar.example.com"))
        #expect(!SensitiveAddressRanges.isMetadataHost("metadata.example.com"))
        #expect(!SensitiveAddressRanges.isMetadataHost(""))
        // The Tools façade forwards to the same single Core verdict.
        #expect(ApiSSRFGuard.isMetadataHost("sub.metadata.google.internal"))
        #expect(!ApiSSRFGuard.isMetadataHost("example.com"))
        #expect(ApiSSRFGuard.blockedMetadataHosts == SensitiveAddressRanges.blockedMetadataHosts)
    }

    @Test
    func `local exemptions verifier rejects never-dialable and malformed entries`() {
        let rejected = [
            "", // blank
            "   ", // whitespace only
            "metadata.google.internal", // metadata hostname
            "sub.metadata.aws.internal", // metadata subdomain
            "100.100.100.200", // Alibaba metadata literal
            "*.metadata.google.internal", // wildcard over a metadata base
            "metadata.google.*", // wildcard over a metadata stem
            "169.254.169.254", // link-local literal
            "*.169.254.169.254", // wildcard over a link-local base
            "fe80::1", // IPv6 link-local
            "64:ff9b::a9fe:a9fe", // NAT64 embedding 169.254.169.254
            "2002:a9fe:a9fe::", // 6to4 embedding 169.254.169.254
            "::ffff:100.100.100.200", // mapped metadata literal
            "http://example.com", // URL, not a host
            "user@example.com", // userinfo
            "example.com:8080", // port suffix
            "*.example.com:8080", // port-qualified wildcard
            "foo?bar.example.com", // glob syntax
            "foo[bar].example.com", // glob syntax
            "foo\\bar.example.com", // path separator
            "foo,bar.example.com", // comma
            "foo#bar.example.com", // fragment
            "foo..example.com", // empty DNS label
            "*.*", // universal star-dot shape
            "**", // double star
            "foo.*.example.com" // misplaced star
        ]
        for entry in rejected {
            let policy = SecurityPolicy(
                network: NetworkEgressPolicy(mode: .unrestricted, localExemptions: [entry])
            )
            #expect(!PolicyInvariantVerifier.verify(policy).isEmpty, "expected rejection for '\(entry)'")
        }
    }

    @Test
    func `local exemptions verifier rejects TOML-breaking scalars`() {
        for entry in ["evil.example\"", "evil\u{01}.example.com", "evil\r.example.com", "evil\u{7F}.example.com"] {
            let policy = SecurityPolicy(
                network: NetworkEgressPolicy(mode: .unrestricted, localExemptions: [entry])
            )
            let violations = PolicyInvariantVerifier.verify(policy)
            #expect(!violations.isEmpty, "expected rejection for '\(entry)'")
            #expect(violations.contains(where: { $0.contains("quote or control") }))
        }
    }

    @Test
    func `local exemptions verifier accepts local hosts and legacy wildcard shapes`() {
        let accepted = [
            "airflow.int.volcrypt.com",
            "localhost",
            "127.0.0.1",
            "10.0.0.5",
            "192.168.1.10",
            "100.64.0.1",
            "fd12:3456::1",
            "::1",
            "*.corp.example.com",
            "prefix.*",
            "*"
        ]
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(mode: .unrestricted, localExemptions: Set(accepted))
        )
        #expect(PolicyInvariantVerifier.verifyLocalExemptions(policy).isEmpty)
        #expect(PolicyInvariantVerifier.verify(policy).isEmpty)
    }

    @Test
    func `PolicyStore update rejects a policy carrying a never-dialable exemption`() async {
        let store = PolicyStore(fileURL: URL(fileURLWithPath: "/tmp/test-policy-\(UUID().uuidString).toml"))
        let badPolicy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .unrestricted,
                localExemptions: ["metadata.google.internal"]
            )
        )
        let violations = await store.update(badPolicy)
        #expect(!violations.isEmpty)
        let current = await store.current
        #expect(current == .safeDefault)
    }

    @Test
    func `Save and reload preserves local exemptions`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-exemptions-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        let policy = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"],
                blockedDomains: ["169.254.169.254"],
                localExemptions: ["airflow.int.volcrypt.com", "*.corp.example.com"]
            )
        )
        let violations = await store.update(policy)
        #expect(violations.isEmpty)
        try await store.save()

        let reloaded = PolicyStore(fileURL: url)
        await reloaded.load()
        let snapshot = try await reloaded.snapshot()
        #expect(snapshot == policy)
    }

    @Test
    func `Domain appenders preserve local exemptions untouched`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-exemption-append-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PolicyStore(fileURL: url)
        let seed = SecurityPolicy(
            network: NetworkEgressPolicy(
                mode: .allowlistOnly,
                allowedDomains: ["api.github.com"],
                blockedDomains: [],
                localExemptions: ["airflow.int.volcrypt.com", "*.corp.example.com"]
            )
        )
        let seedViolations = await store.update(seed)
        #expect(seedViolations.isEmpty)
        try await store.save()

        _ = try await store.appendAllowedDomain("api.openai.com")
        _ = try await store.appendBlockedDomain("evil.example.com")
        _ = await store.ensureServiceDomainsAllowed(urlsOrHosts: ["sonarr.example.net"])

        let current = await store.current
        #expect(current.network.localExemptions == seed.network.localExemptions)

        // The file round-trips the grants and the appended lists together.
        let reloaded = PolicyStore(fileURL: url)
        await reloaded.load()
        let snapshot = try await reloaded.snapshot()
        #expect(snapshot.network.localExemptions == seed.network.localExemptions)
        #expect(snapshot.network.allowedDomains.contains("api.openai.com"))
        #expect(snapshot.network.allowedDomains.contains("sonarr.example.net"))
        #expect(snapshot.network.blockedDomains.contains("evil.example.com"))
    }

    // MARK: - Legacy Origin Migration

    @Test
    func `First load imports legacy allowed origins and persists local_exemptions`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-migrate-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacyToml = """
        [network]
        mode = "allowlist_only"
        allowed_domains = ["api.github.com"]
        blocked_domains = ["169.254.169.254"]
        """
        try legacyToml.write(to: url, atomically: true, encoding: .utf8)

        let store = PolicyStore(fileURL: url)
        await store.load(legacyLocalOrigins: [
            "airflow.int.volcrypt.com",
            "*.Corp.Example.com",
            "192.168.1.10"
        ])

        // Accepted entries land canonicalized in memory and stay snapshot-able.
        let current = await store.current
        #expect(current.network.localExemptions == ["airflow.int.volcrypt.com", "*.corp.example.com", "192.168.1.10"])
        #expect(await store.loadedFromDisk == true)
        let snapshot = try await store.snapshot()
        #expect(snapshot == current)

        // The rewrite carries the key plus the imported grants while leaving
        // the rest of the network posture untouched.
        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(PolicyStore.containsLocalExemptionsKey(in: persisted))
        let reparsed = try PolicyStore.parse(persisted)
        #expect(reparsed.network.localExemptions == current.network.localExemptions)
        #expect(reparsed.network.allowedDomains == ["api.github.com"])
        #expect(reparsed.network.blockedDomains == ["169.254.169.254"])
    }

    @Test
    func `A file that already carries local_exemptions ignores legacy origins`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-keyed-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let keyedToml = """
        [network]
        mode = "allowlist_only"
        local_exemptions = ["kept.example.com"]
        """
        try keyedToml.write(to: url, atomically: true, encoding: .utf8)

        let store = PolicyStore(fileURL: url)
        await store.load(legacyLocalOrigins: ["ignored.example.com", "metadata.google.internal"])

        // Key present means no import and no legacy diagnostics at all, and
        // the file is left byte-for-byte untouched.
        let current = await store.current
        #expect(current.network.localExemptions == ["kept.example.com"])
        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(persisted == keyedToml)
        let diagnostics = await store.lastLoadDiagnostics
        #expect(!diagnostics.contains { $0.localizedCaseInsensitiveContains("legacy") })
    }

    @Test
    func `Invalid legacy origins are skipped with diagnostics`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-migrate-invalid-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[network]\nmode = \"allowlist_only\"\n".write(to: url, atomically: true, encoding: .utf8)

        let store = PolicyStore(fileURL: url)
        await store.load(legacyLocalOrigins: [
            "airflow.int.volcrypt.com",
            "metadata.google.internal",
            "169.254.169.254",
            "example.com:8080",
            "http://example.com",
            ""
        ])

        // Only the entry that passes the exemption gates survives.
        let current = await store.current
        #expect(current.network.localExemptions == ["airflow.int.volcrypt.com"])

        let diagnostics = await store.lastLoadDiagnostics
        for rejected in ["metadata.google.internal", "169.254.169.254", "example.com:8080", "http://example.com"] {
            #expect(
                diagnostics.contains { $0.contains("Skipped legacy browser.allowed_origins entry '\(rejected)'") },
                "expected a diagnostic for '\(rejected)'"
            )
        }
        #expect(diagnostics.contains { $0.contains("Skipped legacy browser.allowed_origins entry ''") })

        // The persisted file carries only the accepted entry, so a later load
        // never re-imports a rejected value.
        let persisted = try String(contentsOf: url, encoding: .utf8)
        let reparsed = try PolicyStore.parse(persisted)
        #expect(reparsed.network.localExemptions == ["airflow.int.volcrypt.com"])
    }

    @Test
    func `Failed migration write keeps merged posture and retries next load`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-migrate-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("policy.toml")
        try "[network]\nmode = \"allowlist_only\"\n".write(to: url, atomically: true, encoding: .utf8)
        // A read-only parent keeps the existing file readable while making the
        // atomic rewrite throw, standing in for a full disk or denied write.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let store = PolicyStore(fileURL: url)
        await store.load(legacyLocalOrigins: ["airflow.int.volcrypt.com"])

        // Runtime keeps the imported grant even though the file could not be
        // rewritten...
        let current = await store.current
        #expect(current.network.localExemptions == ["airflow.int.volcrypt.com"])
        let snapshot = try await store.snapshot()
        #expect(snapshot.network.localExemptions == ["airflow.int.volcrypt.com"])
        let failedDiagnostics = await store.lastLoadDiagnostics
        #expect(failedDiagnostics.contains { $0.contains("will retry next load") })
        // ...and the on-disk file still lacks the key, so a later load retries.
        let beforeRetry = try String(contentsOf: url, encoding: .utf8)
        #expect(!PolicyStore.containsLocalExemptionsKey(in: beforeRetry))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        await store.load(legacyLocalOrigins: ["airflow.int.volcrypt.com"])

        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(PolicyStore.containsLocalExemptionsKey(in: persisted))
        let reparsed = try PolicyStore.parse(persisted)
        #expect(reparsed.network.localExemptions == ["airflow.int.volcrypt.com"])
        let retriedDiagnostics = await store.lastLoadDiagnostics
        #expect(!retriedDiagnostics.contains { $0.contains("will retry next load") })
        #expect(retriedDiagnostics.contains { $0.contains("Policy loaded successfully") })
    }

    @Test
    func `Missing file seeds the default policy with legacy origins`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-migrate-seed-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("policy.toml")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PolicyStore(fileURL: url)
        await store.load(legacyLocalOrigins: ["airflow.int.volcrypt.com", "metadata.google.internal"])

        // The in-memory posture is the factory default plus the accepted
        // grant, and a missing file still counts as a deny-by-default load.
        let current = await store.current
        #expect(current.network.mode == .allowlistOnly)
        #expect(current.network.allowedDomains == NetworkEgressPolicy.safeDefault.allowedDomains)
        #expect(current.network.localExemptions == ["airflow.int.volcrypt.com"])
        #expect(await store.loadedFromDisk == false)

        // The seeded file carries the same grant under the new key.
        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(PolicyStore.containsLocalExemptionsKey(in: persisted))
        let reparsed = try PolicyStore.parse(persisted)
        #expect(reparsed.network.localExemptions == ["airflow.int.volcrypt.com"])
        let diagnostics = await store.lastLoadDiagnostics
        #expect(diagnostics.contains { $0.contains("Created default policy file") })
        #expect(diagnostics.contains { $0.contains("Skipped legacy browser.allowed_origins entry 'metadata.google.internal'") })
    }

    @Test
    func `makeLoaded migrates a fresh store and returns an injected one untouched`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-policy-make-loaded-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "[network]\nmode = \"allowlist_only\"\n".write(to: url, atomically: true, encoding: .utf8)

        // A nil injection constructs and loads with the legacy list, so the
        // one-time migration runs exactly there.
        let created = await PolicyStore.makeLoaded(injected: nil, legacyLocalOrigins: ["airflow.int.volcrypt.com"])
        let createdCurrent = await created.current
        #expect(createdCurrent.network.localExemptions == ["airflow.int.volcrypt.com"])

        // An injected instance stays authoritative: resolving again returns the
        // same store without reloading or re-migrating it.
        let resolved = await PolicyStore.makeLoaded(injected: created, legacyLocalOrigins: ["ignored.example.com"])
        #expect(resolved === created)
        let resolvedCurrent = await resolved.current
        #expect(resolvedCurrent.network.localExemptions == ["airflow.int.volcrypt.com"])
    }

    @Test
    func `Resaved config omits allowed_origins while legacy decoding stays available`() throws {
        var config = RuneWeaverConfig.default
        config.browser.allowedOrigins = ["airflow.int.volcrypt.com"]
        // The retired key no longer round-trips out of config.toml...
        #expect(!config.renderTOML().contains("allowed_origins"))

        // ...but decoding keeps accepting it so an older file can feed the
        // one-time migration into [network].local_exemptions.
        let legacy = """
        [browser]
        allowed_origins = ["airflow.int.volcrypt.com"]
        """
        let decoded = try RuneWeaverConfig(decoding: TOMLParser.parse(legacy))
        #expect(decoded.browser.allowedOrigins == ["airflow.int.volcrypt.com"])
    }
}
