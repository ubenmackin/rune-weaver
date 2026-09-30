// Rune Weaver Core Tests — PolicyStore lifecycle, parsing, and serialization.
//
// Pins the contract that policy.toml is loaded, parsed, validated, serialized,
// and round-tripped correctly. Malformed or invariant-violating policies fall
// back to the safe factory default.

import Foundation
@testable import RuneWeaverCore
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

        #expect(policy.filesystem.allowRoots == ["~/Documents/Projects"])
        #expect(policy.filesystem.denyPaths.contains("~/.ssh"))

        #expect(policy.tools.count == 2)
        #expect(policy.tools["api.request"]?.level == .requiresApproval)
        #expect(policy.tools["api.request"]?.allowGraduatedTrust == true)
        #expect(policy.tools["messages.send"]?.level == .requiresApproval)
        #expect(policy.tools["messages.send"]?.allowGraduatedTrust == false)
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
        #expect(policy.filesystem.allowRoots.isEmpty)
        #expect(policy.tools.isEmpty)
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
            ],
            filesystem: FilesystemPolicy(
                allowRoots: ["~/Documents"],
                denyPaths: ["~/.ssh", "~/.aws"]
            ),
            tools: [
                "api.request": ToolPolicy(level: .requiresApproval, allowGraduatedTrust: true)
            ]
        )

        let toml = PolicyStore.serialize(original)
        let reparsed = try PolicyStore.parse(toml)

        #expect(reparsed.version == original.version)
        #expect(reparsed.network.mode == original.network.mode)
        #expect(reparsed.network.allowedDomains == original.network.allowedDomains)
        #expect(reparsed.network.blockedDomains == original.network.blockedDomains)
        #expect(reparsed.credentials.count == original.credentials.count)
        #expect(reparsed.credentials["GITHUB_PAT"]?.allowedHosts == original.credentials["GITHUB_PAT"]?.allowedHosts)
        #expect(reparsed.filesystem.allowRoots == original.filesystem.allowRoots)
        #expect(reparsed.tools["api.request"]?.level == original.tools["api.request"]?.level)
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
}
