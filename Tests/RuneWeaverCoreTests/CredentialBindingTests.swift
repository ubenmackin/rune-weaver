// Rune Weaver Core Tests — Credential binding target-bound verification.
//
// Pins the contract that `rwsecret:<key>` surrogates are bound to authorized
// destinations via policy.toml. A binding mismatch fails closed before the
// Keychain is ever accessed.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("CredentialBinding")
struct CredentialBindingTests {
    // MARK: - Authorized Requests

    @Test
    func `Binding allows exact host match`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET", "POST"],
            allowedPathPrefixes: ["/repos/"]
        )
        let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/repos/owner/repo")
        #expect(result == nil)
    }

    @Test
    func `Binding allows any method when allowedMethods is empty`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.openai.com"],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "OPENAI_KEY", host: "api.openai.com", method: "DELETE", path: "/v1/models")
        #expect(result == nil)
    }

    @Test
    func `Binding allows any path when allowedPathPrefixes is empty`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/anything/goes/here")
        #expect(result == nil)
    }

    // MARK: - Unauthorized Requests (Exfiltration Prevention)

    @Test
    func `Binding denies unauthorized host`() throws {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "GITHUB_PAT", host: "evil-collector.io", method: "GET", path: "/steal")
        #expect(result != nil)
        #expect(try #require(result?.contains("not authorized for host")))
        #expect(try #require(result?.contains("evil-collector.io")))
    }

    @Test
    func `Binding denies unauthorized method`() throws {
        let binding = CredentialBinding(
            allowedHosts: ["api.openai.com"],
            allowedMethods: ["POST"],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "OPENAI_KEY", host: "api.openai.com", method: "DELETE", path: "/v1/models")
        #expect(result != nil)
        #expect(try #require(result?.contains("not authorized for method")))
    }

    @Test
    func `Binding denies unauthorized path prefix`() throws {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: ["/repos/"]
        )
        let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/admin/settings")
        #expect(result != nil)
        #expect(try #require(result?.contains("not authorized for path")))
    }

    @Test
    func `Binding denies when allowedHosts is empty`() throws {
        let binding = CredentialBinding(
            allowedHosts: [],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "ORPHANED_KEY", host: "any.host.com", method: "GET", path: "/")
        #expect(result != nil)
        #expect(try #require(result?.contains("no allowed hosts")))
    }

    @Test
    func `Binding host check is case-insensitive`() {
        let binding = CredentialBinding(
            allowedHosts: ["API.GitHub.COM"],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/")
        #expect(result == nil)
    }

    @Test
    func `Binding method check is case-insensitive`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.openai.com"],
            allowedMethods: ["post"],
            allowedPathPrefixes: []
        )
        let result = binding.denyReason(key: "OPENAI_KEY", host: "api.openai.com", method: "POST", path: "/v1/chat")
        #expect(result == nil)
    }

    // MARK: - Path Prefix Normalization (Traversal Regression)

    @Test
    func `Binding denies literal dot-segment traversal out of the authorized prefix`() throws {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: ["/v1/"]
        )
        let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/v1/../admin/steal")
        #expect(result != nil)
        #expect(try #require(result?.contains("not authorized for path")))
        #expect(try #require(result?.contains("/admin/steal")))
    }

    @Test
    func `Binding denies percent-encoded dot-segment spellings`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: ["/v1/"]
        )
        let spellings = [
            "/v1/%2e%2e/admin/steal",
            "/v1/%2E%2E/admin/steal",
            "/v1/.%2e/admin/steal",
            "/v1/%252e%252e/admin/steal"
        ]
        for spelling in spellings {
            let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: spelling)
            #expect(result != nil, "expected denial for '\(spelling)'")
            #expect(result?.contains("not authorized") == true, "unexpected reason for '\(spelling)': \(result ?? "nil")")
        }
    }

    @Test
    func `Binding denies encoded separator spellings`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: ["/v1/"]
        )
        let spellings = [
            "/v1%2f..%2fadmin/steal",
            "/v1%2F..%2Fadmin/steal",
            "/v1%5c..%5cadmin/steal",
            "/v1%252f..%252fadmin/steal"
        ]
        for spelling in spellings {
            let result = binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: spelling)
            #expect(result != nil, "expected denial for '\(spelling)'")
            #expect(result?.contains("not authorized") == true, "unexpected reason for '\(spelling)': \(result ?? "nil")")
        }
    }

    @Test
    func `Binding refuses an escaped dot segment even when it resolves inside the prefix`() {
        // Fail closed: an escaped dot segment is refused rather than decoded and
        // normalized, because proxy and origin decoders can disagree on the bytes.
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: ["/v1/"]
        )
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/v1/%2e/data") != nil)
    }

    @Test
    func `Binding still allows traversal-free paths inside the authorized prefix`() {
        // No regression: clean and literal-dot paths that route inside the
        // prefix stay authorized after effective-path resolution.
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: ["GET"],
            allowedPathPrefixes: ["/v1/"]
        )
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/v1/data") == nil)
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/v1/") == nil)
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/v1/./data") == nil)
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "api.github.com", method: "GET", path: "/v1/a/../data") == nil)
    }

    @Test
    func `Effective path resolution applies RFC 3986 dot-segment removal`() {
        #expect(EffectiveRequestPath.removeDotSegments("/a/b/c/./../../g") == "/a/g")
        #expect(EffectiveRequestPath.removeDotSegments("mid/content=5/../6") == "mid/6")
        #expect(EffectiveRequestPath.removeDotSegments("/../g") == "/g")
        #expect(EffectiveRequestPath.removeDotSegments("/a/b/./") == "/a/b/")
        #expect(EffectiveRequestPath.removeDotSegments("/a/b/..") == "/a/")
        #expect(EffectiveRequestPath.removeDotSegments("/a/b/../c") == "/a/c")
    }

    @Test
    func `Effective path resolution reports the routed path and refuses ambiguous spellings`() {
        #expect(EffectiveRequestPath.resolve(rawPath: "/v1/data") == .effective("/v1/data"))
        #expect(EffectiveRequestPath.resolve(rawPath: "/v1/../admin/steal") == .effective("/admin/steal"))
        #expect(EffectiveRequestPath.resolve(rawPath: "") == .effective("/"))

        switch EffectiveRequestPath.resolve(rawPath: "/v1/%2e%2e/admin") {
        case let .rejected(reason):
            #expect(reason.contains("dot segment"))
        case .effective:
            Issue.record("expected an encoded dot segment to be refused")
        }
        switch EffectiveRequestPath.resolve(rawPath: "/v1%2f..%2fadmin") {
        case let .rejected(reason):
            #expect(reason.contains("separator"))
        case .effective:
            Issue.record("expected an encoded separator to be refused")
        }
        switch EffectiveRequestPath.resolve(rawPath: "/v1/%zz") {
        case let .rejected(reason):
            #expect(reason.contains("malformed"))
        case .effective:
            Issue.record("expected malformed percent-encoding to be refused")
        }
        switch EffectiveRequestPath.resolve(host: "api%2eexample.com", rawPath: "/v1/data") {
        case let .rejected(reason):
            #expect(reason.contains("host"))
        case .effective:
            Issue.record("expected an encoded host dot to be refused")
        }
    }

    // MARK: - Wildcard Host Authorization

    @Test
    func `Binding wildcard authorizes base domain and subdomains`() {
        let binding = CredentialBinding(
            allowedHosts: ["*.example.com"],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        #expect(binding.denyReason(key: "API_KEY", host: "example.com", method: "GET", path: "/") == nil)
        #expect(binding.denyReason(key: "API_KEY", host: "api.example.com", method: "GET", path: "/") == nil)
        #expect(binding.denyReason(key: "API_KEY", host: "deep.api.example.com", method: "GET", path: "/") == nil)
    }

    @Test
    func `Binding wildcard is case-insensitive and trailing-dot tolerant`() {
        let binding = CredentialBinding(
            allowedHosts: ["*.EXAMPLE.com"],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        #expect(binding.denyReason(key: "API_KEY", host: "API.example.com.", method: "GET", path: "/") == nil)
    }

    @Test
    func `Binding wildcard does not authorize lookalike domains`() {
        let binding = CredentialBinding(
            allowedHosts: ["*.example.com"],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        #expect(binding.denyReason(key: "API_KEY", host: "evil-example.com", method: "GET", path: "/") != nil)
        #expect(binding.denyReason(key: "API_KEY", host: "example.com.evil.com", method: "GET", path: "/") != nil)
        #expect(binding.denyReason(key: "API_KEY", host: "notexample.com", method: "GET", path: "/") != nil)
    }

    @Test
    func `Binding refuses malformed wildcard shapes`() {
        for pattern in ["*", "www.*", "*foo.example.com", "*.example.com:443"] {
            let binding = CredentialBinding(
                allowedHosts: [pattern],
                allowedMethods: [],
                allowedPathPrefixes: []
            )
            let result = binding.denyReason(key: "API_KEY", host: "www.example.com", method: "GET", path: "/")
            #expect(result != nil, "expected denial for wildcard pattern '\(pattern)'")
        }
    }

    @Test
    func `Binding exact host match canonicalizes trailing dot`() {
        let binding = CredentialBinding(
            allowedHosts: ["api.github.com"],
            allowedMethods: [],
            allowedPathPrefixes: []
        )
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "api.github.com.", method: "GET", path: "/") == nil)
        #expect(binding.denyReason(key: "GITHUB_PAT", host: "API.GITHUB.COM.", method: "GET", path: "/") == nil)
    }
}
