// Rune Weaver Dashboard — Unit tests for the credential binding preview decision.
//
// Purpose: Pins the client-side mirror of the engine `CredentialBinding`
// gate so the binding modal probe answers honestly without a network round
// trip: one binding pairs one key with hosts, methods, and path prefixes, and
// the secret is sent only when all three match the effective request path.
// Scope: Pure host, method, and effective-path matching only, in both call
// shapes and both DTO spellings. Network allowlist, Keychain state, and TOML
// persistence stay with their owners.
// Architectural role: Keeps the dashboard probe and the egress supervisor on
// one verdict, so a previewed Yes can never disagree with the enforced gate.

import { describe, expect, it } from "vitest";
import { previewBindingDecision } from "./policyBindingPreview";

describe("previewBindingDecision", () => {
  it("sends the secret only when host, method, and effective path all match", () => {
    const binding = {
      allowed_hosts: ["api.github.com"],
      allowed_methods: ["GET"],
      allowed_path_prefixes: ["/repos/"],
    };
    // Exact conjunction authorizes.
    expect(
      previewBindingDecision(binding, "api.github.com", "GET", "/repos/owner/repo")
    ).toBeNull();
    // Each dimension refuses on its own with the failing gate named.
    expect(
      previewBindingDecision(binding, "evil-collector.io", "GET", "/repos/owner/repo")
    ).toContain("not authorized for host");
    expect(
      previewBindingDecision(binding, "api.github.com", "DELETE", "/repos/owner/repo")
    ).toContain("not authorized for method");
    expect(
      previewBindingDecision(binding, "api.github.com", "GET", "/admin/settings")
    ).toContain("not authorized for path");
  });

  it("treats empty methods and empty prefixes as Any while empty hosts stays unusable", () => {
    // Empty methods means Any: every verb authorizes.
    const anyMethod = { allowed_hosts: ["api.openai.com"] };
    expect(previewBindingDecision(anyMethod, "api.openai.com", "DELETE", "/v1/models")).toBeNull();
    // Empty prefixes means Any: every route authorizes.
    const anyPath = { allowed_hosts: ["api.github.com"], allowed_methods: ["GET"] };
    expect(
      previewBindingDecision(anyPath, "api.github.com", "GET", "/anything/goes/here")
    ).toBeNull();
    // Empty hosts authorizes nothing: the orphaned binding fails closed.
    const orphaned = { allowed_hosts: [] as string[] };
    const reason = previewBindingDecision(orphaned, "any.host.com", "GET", "/");
    expect(reason).toContain("no allowed hosts");
  });

  it("applies path prefixes to every host in the same binding", () => {
    // Prefixes scope the whole binding, not one host: the second origin
    // refuses routes outside the prefix exactly like the first.
    const binding = {
      allowed_hosts: ["api.github.com", "uploads.github.com"],
      allowed_methods: ["GET"],
      allowed_path_prefixes: ["/repos/"],
    };
    expect(
      previewBindingDecision(binding, "uploads.github.com", "GET", "/repos/owner/repo")
    ).toBeNull();
    expect(
      previewBindingDecision(binding, "uploads.github.com", "GET", "/admin/settings")
    ).toContain("not authorized for path");
  });

  it("matches a leading wildcard edge against base and subdomains but never lookalikes", () => {
    const binding = { allowed_hosts: ["*.example.com"] };
    expect(previewBindingDecision(binding, "example.com", "GET", "/")).toBeNull();
    expect(previewBindingDecision(binding, "api.example.com", "GET", "/")).toBeNull();
    expect(
      previewBindingDecision(binding, "deep.api.example.com", "GET", "/")
    ).toBeNull();
    expect(previewBindingDecision(binding, "evil-example.com", "GET", "/")).not.toBeNull();
    expect(
      previewBindingDecision(binding, "example.com.evil.com", "GET", "/")
    ).not.toBeNull();
    // Malformed star shapes authorize nothing, so a typo fails closed.
    for (const pattern of ["*", "www.*", "*foo.example.com", "*.example.com:443"]) {
      const malformed = { allowed_hosts: [pattern] };
      expect(
        previewBindingDecision(malformed, "www.example.com", "GET", "/")
      ).not.toBeNull();
    }
  });

  it("matches hosts and methods case-insensitively and tolerates trailing dots", () => {
    const binding = { allowed_hosts: ["API.GitHub.COM"], allowed_methods: ["post"] };
    expect(previewBindingDecision(binding, "api.github.com.", "POST", "/")).toBeNull();
    expect(previewBindingDecision(binding, "api.github.com", "post", "/")).toBeNull();
  });

  it("resolves dot segments before the prefix comparison and refuses ambiguous spellings", () => {
    const binding = {
      allowed_hosts: ["api.github.com"],
      allowed_methods: ["GET"],
      allowed_path_prefixes: ["/v1/"],
    };
    // Literal traversal resolves out of the prefix and refuses with the
    // routed destination named.
    const traversal = previewBindingDecision(
      binding,
      "api.github.com",
      "GET",
      "/v1/../admin/steal"
    );
    expect(traversal).toContain("not authorized");
    expect(traversal).toContain("/admin/steal");
    // Encoded dot segments and separators refuse rather than guessing, and a
    // malformed escape refuses as well.
    for (const spelling of [
      "/v1/%2e%2e/admin/steal",
      "/v1%2f..%2fadmin/steal",
      "/v1/%zz",
    ]) {
      expect(previewBindingDecision(binding, "api.github.com", "GET", spelling)).toContain(
        "not authorized"
      );
    }
    // Clean and literal-dot routes inside the prefix stay authorized.
    expect(previewBindingDecision(binding, "api.github.com", "GET", "/v1/data")).toBeNull();
    expect(previewBindingDecision(binding, "api.github.com", "GET", "/v1/a/../data")).toBeNull();
  });

  it("accepts the probe-object shape and both DTO spellings", () => {
    // The probe object carries host, method, path, and key together for the
    // modal, while positional args mirror the engine ordering.
    const binding = { allowed_hosts: ["api.github.com"] };
    expect(
      previewBindingDecision(binding, { host: "api.github.com", method: "GET", path: "/" })
    ).toBeNull();
    const denied = previewBindingDecision(binding, {
      host: "evil.example.com",
      method: "GET",
      path: "/",
      key: "GITHUB_PAT",
    });
    expect(denied).toContain("GITHUB_PAT");
    // Snake_case and camelCase spellings probe identically so callers never
    // convert before asking.
    const snake = {
      allowed_hosts: ["api.github.com"],
      allowed_methods: ["GET"],
      allowed_path_prefixes: ["/repos"],
    };
    const camel = {
      allowedHosts: ["api.github.com"],
      allowedMethods: ["GET"],
      allowedPathPrefixes: ["/repos"],
    };
    expect(previewBindingDecision(snake, "api.github.com", "GET", "/repos/x")).toBeNull();
    expect(previewBindingDecision(camel, "api.github.com", "GET", "/repos/x")).toBeNull();
  });
});
