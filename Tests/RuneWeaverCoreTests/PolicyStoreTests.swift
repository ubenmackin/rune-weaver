// Rune Weaver Core Tests — PolicyStore lifecycle, parsing, and serialization.
//
// Pins the contract that policy.toml owns network plus credentials only:
// parsed, validated, serialized, and round-tripped correctly. Legacy
// filesystem and tool tables are tolerated on load and ignored without
// error so older files keep booting. Malformed or invariant-violating
// policies fall back to the safe factory default.

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
}
