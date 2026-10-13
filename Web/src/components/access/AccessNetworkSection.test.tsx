// Rune Weaver Dashboard — Component tests for the access network policy section.
//
// Purpose: Pins the structured network egress editor of the declarative policy
// surface: loading the verified snapshot into the mode select and domain
// editors, persisting the DTO without raw text, and keeping the saved banner
// honest across edits with no restart promise ever shown.
// Scope: Surface fetch and save shapes, the mode select and domain editors,
// the local-exemption display with its Re-check flow, the invariant banner,
// the shared save footer, and the sub-tab chrome that hosts the credentials
// section. Credential rows and the binding modal stay with their owner suite.
// Architectural role: Guards the network half of the single dashboard surface
// whose writes steer the mandatory egress choke-point, so a network edit
// cannot persist unvalidated text or claim a write that never landed.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AccessNetworkSection, canonicalPolicySnapshot, isValidDomainLine } from "./AccessNetworkSection";
import { clearAuthToken, setAuthToken } from "../../api";
import { jsonResponse } from "../../test-utils/http";

// Seed snapshot mirroring the engine GET shape: structured policy plus file
// provenance plus live invariant status, with no raw document on the wire.
const panePolicyPayload = {
  policy: {
    version: 1,
    network: {
      mode: "allowlist_only",
      allowed_domains: ["api.example.com"],
      blocked_domains: ["metadata.google.internal"],
    },
    credentials: {
      GITHUB_TOKEN: {
        allowed_hosts: ["api.github.com"],
        allowed_methods: ["GET"],
        allowed_path_prefixes: ["/repos"],
      },
    },
  },
  path: "/Users/test/.runeweaver/policy.toml",
  loaded_from_disk: true,
  violations: [],
};

describe("AccessNetworkSection", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  // Routes the pane fetch plus the Keychain presence probe so each case
  // overrides only the response it exercises.
  // Secrets side of the stub: store and delete answer the bodyless 204 from
  // the engine contract while status answers only the existence map. Status
  // accepts a fixed map or a probe function so store and delete flows can
  // flip presence mid-test; posted bodies and deleted keys ride out through
  // callbacks instead of globals.
  interface PaneSecretsStub {
    secretStatus?: Record<string, boolean> | ((keys: string[]) => Record<string, boolean>);
    onSecretPosted?: (body: Record<string, unknown>) => void;
    onSecretDeleted?: (key: string) => void;
    listedKeys?: string[];
  }

  function stubPaneFetch(
    policyResponse: (init?: RequestInit) => Response | Promise<Response>,
    secrets?: PaneSecretsStub
  ) {
    const configuredStatus = secrets?.secretStatus ?? { GITHUB_TOKEN: true };
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        const method = (init?.method ?? "GET").toUpperCase();
        if (urlStr === "/settings/secrets" && method === "POST") {
          let body: Record<string, unknown> = {};
          try {
            body = JSON.parse(init?.body as string) as Record<string, unknown>;
          } catch {
            body = {};
          }
          secrets?.onSecretPosted?.(body);
          return new Response(null, { status: 204 });
        }
        if (urlStr.startsWith("/settings/secrets/") && method === "DELETE") {
          secrets?.onSecretDeleted?.(
            decodeURIComponent(urlStr.slice("/settings/secrets/".length))
          );
          return new Response(null, { status: 204 });
        }
        // Keychain enumeration for the unlinked section. Defaults to empty so
        // the empty line reads clean without evidence of orphans.
        if (urlStr === "/settings/secrets" && method === "GET") {
          return jsonResponse({ keys: secrets?.listedKeys ?? [] });
        }
        if (urlStr === "/settings/policy") {
          return policyResponse(init);
        }
        if (urlStr.includes("/settings/secrets/status")) {
          if (typeof configuredStatus === "function") {
            let keys: string[] = [];
            try {
              const parsed = JSON.parse(init?.body as string) as { keys?: unknown };
              if (Array.isArray(parsed.keys)) {
                keys = parsed.keys.filter(
                  (entry): entry is string => typeof entry === "string"
                );
              }
            } catch {
              keys = [];
            }
            return jsonResponse({ status: configuredStatus(keys) });
          }
          return jsonResponse({ status: configuredStatus });
        }
        return jsonResponse({});
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  // Waits for the snapshot to land in the Network editors: the mode select
  // proves the DTO arrived. Credentials live behind their sub-tab, so this
  // gate stays Network-only and credential cases open the tab explicitly.
  async function waitForPaneLoaded() {
    await waitFor(() => {
      expect((screen.getByLabelText("Mode") as HTMLSelectElement).value).toBe(
        "allowlist_only"
      );
    });
  }

  // Opens the Credentials sub-tab and waits for the bindings list to render.
  async function openCredentialsTab(
    user: ReturnType<typeof userEvent.setup>,
    expectedRows = 1
  ) {
    await user.click(screen.getByTestId("policytab-credentials"));
    await waitFor(() => {
      expect(screen.getAllByTestId("credential-row").length).toBe(expectedRows);
    });
  }

  it("loads the structured snapshot into network editors and the credentials list", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    expect(
      (screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value
    ).toContain("api.example.com");
    expect(
      (screen.getByLabelText("Blocked domains") as HTMLTextAreaElement).value
    ).toContain("metadata.google.internal");
    // Credentials stay behind their sub-tab: Network is default and the
    // binding row is hidden until the tab opens.
    expect(screen.getByTestId("policytab-network")).toBeDefined();
    // The egress editors own their vertical rhythm, so the section carries the
    // scoped spacing class that separates each hint from the next label.
    expect(screen.getByTestId("network-egress-editors").className).toContain(
      "policy-network-section"
    );
    expect(screen.getByTestId("policy-network-section")).toBeDefined();
    expect(screen.queryByTestId("policy-credentials-section")).toBeNull();
    expect(screen.queryByTestId("credentials-list")).toBeNull();
    expect(screen.queryByTestId("credential-row")).toBeNull();
    expect(screen.queryByTestId("unlinked-secrets")).toBeNull();
    await openCredentialsTab(user);
    expect(screen.getByTestId("policy-credentials-section")).toBeDefined();
    expect(screen.getByTestId("credentials-list")).toBeDefined();
    expect(screen.getByTestId("unlinked-secrets")).toBeDefined();
    expect(screen.queryByTestId("policy-network-section")).toBeNull();
    expect(screen.queryByTestId("network-egress-editors")).toBeNull();
    expect(screen.getByText("GITHUB_TOKEN")).toBeDefined();
    // Keychain presence resolves beside the policy load, so the row badges
    // Stored instead of blocking the render on secrets.
    expect(await screen.findByText("Keychain Stored")).toBeDefined();
    expect(screen.getByText(/All 3 Formal Security Invariants Verified/)).toBeDefined();
    expect(screen.getByTestId("policy-location").textContent).toContain("Customized");

    // The retired contract is gone: no raw editor and no Verify button.
    expect(screen.queryByText(/Raw TOML/i)).toBeNull();
    expect(screen.queryByLabelText(/Edit policy\.toml directly/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /^Verify$/i })).toBeNull();
  });

  it("saves the structured draft, reflects the returned snapshot, and never promises a restart", async () => {
    let sentBody: Record<string, unknown> | null = null;
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        sentBody = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...panePolicyPayload,
          policy: (sentBody as unknown as { policy: unknown }).policy,
        });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policy-save"));

    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    // The write carries the DTO only; the retired text field never rides along.
    expect(sentBody).not.toBeNull();
    expect(sentBody).toHaveProperty("policy");
    expect(sentBody).not.toHaveProperty("raw_toml");
    expect(sentBody).not.toHaveProperty("rawToml");
    // Policy writes apply live, so the banner promises no restart and no
    // restart banner ever appears for policy.
    expect(screen.getByTestId("policy-saved").textContent).toContain("no restart");
    expect(screen.queryByText(/needs a restart/i)).toBeNull();
    expect(screen.queryByText(/restart to apply/i)).toBeNull();
  });

  it("clears the saved banner on the next edit while tracking unsaved changes", async () => {
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as { policy: unknown };
        return jsonResponse({ ...panePolicyPayload, policy: sent.policy });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policy-save"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });

    // Any edit retires the stale success: the banner clears and the dirty
    // marker appears, so success never reads as covering the current draft.
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com\napi.other.com");
    await waitFor(() => {
      expect(screen.queryByTestId("policy-saved")).toBeNull();
    });
    expect(screen.getByTestId("policy-save-hint").textContent).toContain(
      "Unsaved changes"
    );
  });

  it("surfaces invalid domain shapes inline and gates Save", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    // A trailing-star shape never matches at runtime yet would read as
    // allowed, so it refuses inline before any write reaches the server.
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com\nfoo.*");

    await waitFor(() => {
      expect(screen.getByTestId("allowed-domains-error")).toBeDefined();
    });
    expect(screen.getByTestId("policy-field-errors")).toBeDefined();
    expect((screen.getByTestId("policy-save") as HTMLButtonElement).disabled).toBe(true);
  });

  it("carries the owner bearer on policy load and save", async () => {
    // Token mode is exactly where a bare fetch 401s, so the pane must send
    // the configured bearer alongside same-origin credentials on both calls.
    setAuthToken("policy-owner-token");
    try {
      const fetchMock = stubPaneFetch((init) => {
        if (init?.method === "PUT") {
          const sent = JSON.parse(init.body as string) as { policy: unknown };
          return jsonResponse({ ...panePolicyPayload, policy: sent.policy });
        }
        return jsonResponse(panePolicyPayload);
      });
      const user = userEvent.setup();
      render(<AccessNetworkSection />);

      await waitForPaneLoaded();
      await user.click(screen.getByTestId("policy-save"));
      await waitFor(() => {
        expect(screen.getByTestId("policy-saved")).toBeDefined();
      });

      const policyCalls = fetchMock.mock.calls.filter(([url]) =>
        String(url).startsWith("/settings/policy")
      );
      expect(policyCalls.length).toBeGreaterThanOrEqual(2);
      for (const [, init] of policyCalls) {
        expect(init?.credentials).toBe("same-origin");
        expect((init?.headers as Record<string, string>).Authorization).toBe(
          "Bearer policy-owner-token"
        );
      }
    } finally {
      clearAuthToken();
    }
  });

  it("rejects non-leading wildcard shapes and blank-adjacent domain entries", () => {
    // Mirrors the server fail-closed bounds: only an exact host or a single
    // leading star-dot edge authorizes.
    for (const entry of ["*foo", "foo*", "***", "*.*", "foo bar", "a,b", "a?b", "foo.*"]) {
      expect(isValidDomainLine(entry)).toBe(false);
    }
    expect(isValidDomainLine("api.example.com")).toBe(true);
    expect(isValidDomainLine("*.example.com")).toBe(true);
  });

  it("refuses network hosts no canonicalized URL host could equal", () => {
    // Separators, userinfo, fragments, and port suffixes never match at
    // runtime, so the editor and the server boundary refuse the same shapes.
    for (const entry of [
      "api.example.com/path",
      "api.example.com\\path",
      "user@example.com",
      "api.example.com#frag",
      "api.example.com:443",
      "*.example.com:443",
    ]) {
      expect(isValidDomainLine(entry)).toBe(false);
    }
    // Colons stay allowed for unbracketed IPv6 literals: a valid literal
    // always carries at least two colons and never reads as a port suffix.
    expect(isValidDomainLine("::1")).toBe(true);
    expect(isValidDomainLine("2001:db8::1")).toBe(true);
    // Brackets stay binding-only: network lines refuse them while the binding
    // modal accepts the same literal bracketed.
    expect(isValidDomainLine("[2001:db8::1]")).toBe(false);
    expect(isValidDomainLine("[::1]")).toBe(false);
  });

  it("maintains domain validation parity with server SettingsRouteTests", () => {
    const valid = [
      "api.example.com",
      "*.example.com",
      "127.0.0.1",
      "::1",
      "2001:db8::1",
      "sub.domain.co.uk",
    ];
    for (const host of valid) {
      expect(isValidDomainLine(host)).toBe(true);
    }

    const rejected = [
      "*",
      "*.",
      "*example.com",
      "api.*",
      "api.*.com",
      "http://api.example.com",
      "api.example.com:8080",
      "api.example.com/path",
      "foo@bar",
      "foo#bar",
      "foo bar",
      "foo,bar",
      "[2001:db8::1]",
      "[::1]",
    ];
    for (const host of rejected) {
      expect(isValidDomainLine(host)).toBe(false);
    }
  });

  it("treats reordered sets as clean through the canonical snapshot", () => {
    // Domain lists and binding arrays behave as sets while credential keys
    // behave as a map, so ordering alone must not read dirty.
    const base = {
      version: 1,
      network: { mode: "allowlist_only", allowed_domains: ["b.example.com", "a.example.com"], blocked_domains: [] },
      credentials: {
        B_KEY: { allowed_hosts: ["b.example.com", "a.example.com"], allowed_methods: ["POST", "GET"], allowed_path_prefixes: ["/v2", "/v1"] },
        A_KEY: { allowed_hosts: ["api.example.com"], allowed_methods: [], allowed_path_prefixes: [] },
      },
    };
    const reordered = {
      version: 1,
      network: { mode: "allowlist_only", allowed_domains: ["a.example.com", "b.example.com"], blocked_domains: [] },
      credentials: {
        A_KEY: { allowed_hosts: ["api.example.com"], allowed_methods: [], allowed_path_prefixes: [] },
        B_KEY: { allowed_hosts: ["a.example.com", "b.example.com"], allowed_methods: ["GET", "POST"], allowed_path_prefixes: ["/v1", "/v2"] },
      },
    };
    expect(canonicalPolicySnapshot(base)).toBe(canonicalPolicySnapshot(reordered));
  });

  it("ignores server-owned local exemptions in the dirty comparison", () => {
    // localExemptions is display-only: a server-derived grant must never read
    // dirty, so the canonical snapshot excludes it.
    const without = {
      version: 1,
      network: { mode: "allowlist_only", allowed_domains: ["a.example.com"], blocked_domains: [] },
      credentials: {},
    };
    const withGrant = {
      version: 1,
      network: {
        mode: "allowlist_only",
        allowed_domains: ["a.example.com"],
        blocked_domains: [],
        localExemptions: ["airflow.int.volcrypt.com"],
      },
      credentials: {},
    };
    expect(canonicalPolicySnapshot(without)).toBe(canonicalPolicySnapshot(withGrant));
  });

  it("renders stored local exemptions read-only with hint copy", async () => {
    const payload = {
      ...panePolicyPayload,
      policy: {
        ...panePolicyPayload.policy,
        network: {
          ...(panePolicyPayload.policy.network as Record<string, unknown>),
          localExemptions: ["airflow.int.volcrypt.com"],
        },
      },
    };
    stubPaneFetch(() => jsonResponse(payload));
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    const area = screen.getByTestId("policy-local-exemptions") as HTMLTextAreaElement;
    expect(area.value).toContain("airflow.int.volcrypt.com");
    expect(area.readOnly).toBe(true);
    // The local display matches the editable editors in height so the section
    // keeps one vertical rhythm even though the field itself never edits.
    expect(area.rows).toBe(5);
    expect(screen.getByTestId("local-exemptions-count").textContent).toContain("1");
    const hint = screen.getByTestId("local-exemptions-hint").textContent ?? "";
    expect(hint).toContain("Not editable here");
    expect(hint).toContain("Re-check local access");
    expect(hint).toContain("private addresses");
    expect(hint).toContain("Wildcards never");
    expect(hint).toContain("Metadata");
    expect(hint).toContain("link-local");
  });

  it("tolerates snake_case local_exemptions on decode", async () => {
    const payload = {
      ...panePolicyPayload,
      policy: {
        version: 1,
        network: {
          mode: "allowlist_only",
          allowed_domains: ["api.example.com"],
          blocked_domains: ["metadata.google.internal"],
          local_exemptions: ["airflow.int.volcrypt.com"],
        },
        credentials: panePolicyPayload.policy.credentials,
      },
    };
    stubPaneFetch(() => jsonResponse(payload));
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    expect(
      (screen.getByTestId("policy-local-exemptions") as HTMLTextAreaElement).value
    ).toContain("airflow.int.volcrypt.com");
  });

  it("discloses local grants on save and never sends exemptions", async () => {
    let sentPolicy: Record<string, unknown> | null = null;
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as { policy: Record<string, unknown> };
        sentPolicy = sent.policy;
        return jsonResponse({
          ...panePolicyPayload,
          policy: {
            ...(panePolicyPayload.policy as Record<string, unknown>),
            network: {
              ...((panePolicyPayload.policy as Record<string, unknown>).network as Record<string, unknown>),
              localExemptions: ["office-printer.local"],
            },
          },
          localAccess: {
            granted: ["office-printer.local"],
            removed: [],
            neverDialable: [],
          },
        });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policy-save"));

    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    expect(screen.getByTestId("policy-saved").textContent).toContain(
      "Local network access granted for: office-printer.local"
    );
    expect(
      (screen.getByTestId("policy-local-exemptions") as HTMLTextAreaElement).value
    ).toContain("office-printer.local");
    // Display-only: the write never carries the server-owned field.
    expect(sentPolicy).not.toBeNull();
    const sentNetwork = (sentPolicy as unknown as { network: Record<string, unknown> }).network;
    expect(sentNetwork).not.toHaveProperty("localExemptions");
    expect(sentNetwork).not.toHaveProperty("local_exemptions");
  });

  it("warns on never-dialable hosts after save", async () => {
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as { policy: unknown };
        return jsonResponse({
          ...panePolicyPayload,
          policy: sent.policy,
          localAccess: {
            granted: [],
            removed: [],
            neverDialable: ["169.254.169.254"],
          },
        });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policy-save"));

    await waitFor(() => {
      expect(screen.getByTestId("policy-local-never-dialable")).toBeDefined();
    });
    expect(screen.getByTestId("policy-local-never-dialable").textContent).toContain(
      "169.254.169.254"
    );
  });

  it("discloses removed local access on save", async () => {
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as { policy: unknown };
        return jsonResponse({
          ...panePolicyPayload,
          policy: sent.policy,
          localAccess: {
            granted: [],
            removed: ["old-device.local"],
            neverDialable: [],
          },
        });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policy-save"));

    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    expect(screen.getByTestId("policy-local-removed")).toBeDefined();
    expect(screen.getByTestId("policy-local-removed").textContent).toContain(
      "Local network access removed for: old-device.local"
    );
  });

  it("shows the unresolved 400 reason and keeps the draft", async () => {
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        return jsonResponse(
          {
            reason:
              "Local access classification failed for: mystery.local (unresolved DNS). Nothing was saved. Gate: classification, field: network.allowed_domains.",
          },
          400
        );
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com\nmystery.local");
    await user.click(screen.getByTestId("policy-save"));

    await waitFor(() => {
      expect(screen.getByTestId("policy-error")).toBeDefined();
    });
    expect(screen.getByTestId("policy-error").textContent).toContain("mystery.local");
    // The 400 never persists: the draft stays for repair.
    expect((screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value).toContain(
      "mystery.local"
    );
    expect(screen.queryByTestId("policy-saved")).toBeNull();
  });

  it("previews a local re-check diff and applies it", async () => {
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        const method = init?.method ?? "GET";
        if (urlStr === "/settings/policy" && method !== "PUT") {
          return jsonResponse({
            ...panePolicyPayload,
            policy: {
              ...panePolicyPayload.policy,
              network: {
                ...(panePolicyPayload.policy.network as Record<string, unknown>),
                localExemptions: ["office-printer.local"],
              },
            },
          });
        }
        if (urlStr === "/settings/policy" && method === "PUT") {
          const sent = JSON.parse(init?.body as string) as { policy: unknown };
          return jsonResponse({ ...panePolicyPayload, policy: sent.policy });
        }
        if (urlStr === "/settings/policy/recheck-local" && method === "POST") {
          const sent = JSON.parse(init?.body as string) as { policy: Record<string, unknown> };
          const sentNetwork = (sent.policy as { network: Record<string, unknown> }).network;
          expect(sentNetwork).not.toHaveProperty("localExemptions");
          return jsonResponse({
            added: ["new-printer.local"],
            removed: [],
            unchanged: ["office-printer.local"],
            unresolved: [],
          });
        }
        if (urlStr === "/settings/policy/recheck-local/apply" && method === "POST") {
          return jsonResponse({
            ...panePolicyPayload,
            policy: {
              ...panePolicyPayload.policy,
              network: {
                ...(panePolicyPayload.policy.network as Record<string, unknown>),
                localExemptions: ["new-printer.local", "office-printer.local"],
              },
            },
            localAccess: { granted: ["new-printer.local"], removed: [], neverDialable: [] },
          });
        }
        if (urlStr.includes("/settings/secrets/status")) {
          return jsonResponse({ status: { GITHUB_TOKEN: true } });
        }
        return jsonResponse({});
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(
      within(screen.getByTestId("network-egress-editors")).getByTestId("policy-recheck")
    );

    const modal = await screen.findByTestId("policy-recheck-modal");
    expect(within(modal).getByTestId("policy-recheck-added").textContent).toContain(
      "new-printer.local"
    );
    expect(within(modal).getByTestId("policy-recheck-unchanged").textContent).toContain(
      "office-printer.local"
    );
    const confirm = within(modal).getByTestId(
      "policy-recheck-confirm"
    ) as HTMLButtonElement;
    // The persist action reads as Apply grants so its write consequence is
    // explicit beside the discarding Cancel; Cancel closes without writing.
    expect(confirm.textContent).toBe("Apply grants");
    expect(confirm.disabled).toBe(false);

    await user.click(confirm);
    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    expect(screen.getByTestId("policy-saved").textContent).toContain(
      "Local network access granted for: new-printer.local"
    );
    expect(
      (screen.getByTestId("policy-local-exemptions") as HTMLTextAreaElement).value
    ).toContain("new-printer.local");
    expect(screen.queryByTestId("policy-recheck-modal")).toBeNull();
  });

  it("disables confirm while unresolved hosts remain", async () => {
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        const method = init?.method ?? "GET";
        if (urlStr === "/settings/policy") return jsonResponse(panePolicyPayload);
        if (urlStr === "/settings/policy/recheck-local" && method === "POST") {
          return jsonResponse({
            added: [],
            removed: [],
            unchanged: [],
            unresolved: ["ghost.local"],
          });
        }
        if (urlStr.includes("/settings/secrets/status")) {
          return jsonResponse({ status: { GITHUB_TOKEN: true } });
        }
        return jsonResponse({});
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(
      within(screen.getByTestId("network-egress-editors")).getByTestId("policy-recheck")
    );

    const modal = await screen.findByTestId("policy-recheck-modal");
    expect(within(modal).getByTestId("policy-recheck-unresolved").textContent).toContain(
      "ghost.local"
    );
    expect(within(modal).getByTestId("policy-recheck-unresolved").textContent).toContain(
      "Cannot apply"
    );
    expect(
      (within(modal).getByTestId("policy-recheck-confirm") as HTMLButtonElement).disabled
    ).toBe(true);
  });

  it("renders the save control inside the shared settings footer", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    // The save control matches every other Settings tab: a shared
    // settings-footer wrapping a primary-button save-button.
    const saveButton = screen.getByTestId("policy-save");
    expect(saveButton).toHaveClass("primary-button");
    expect(saveButton).toHaveClass("save-button");
    expect(saveButton.closest(".settings-footer")).not.toBeNull();
  });

  it("keeps a trailing space visible while the draft records the trimmed host", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    // A trailing space is display-only: the textarea keeps it while the draft
    // parses the trimmed host, so the count still names the host with no error.
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com ");
    await waitFor(() => {
      expect((screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value).toBe(
        "api.example.com "
      );
    });
    expect(screen.getByTestId("allowed-domains-count").textContent).toContain("1 host");
    expect(screen.queryByTestId("allowed-domains-error")).toBeNull();
  });

  it("keeps an internal-space line visible and names it in the inline error", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    // An internal space never matches at runtime, so the text stays visible
    // and the inline error names the line instead of eating the space.
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "foo bar");
    await waitFor(() => {
      expect((screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value).toBe(
        "foo bar"
      );
    });
    await waitFor(() => {
      expect(screen.getByTestId("allowed-domains-error")).toBeDefined();
    });
    expect(screen.getByTestId("allowed-domains-error").textContent).toContain("foo bar");
  });

  it("defaults to the Network sub-tab with Credentials hidden", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    expect(screen.getByTestId("policy-subtabs")).toBeDefined();
    expect(screen.getByTestId("policy-subtabs")).toHaveClass("policy-tabs");
    expect(screen.getByRole("tablist", { name: "Policy sections" })).toBeDefined();
    const networkTab = screen.getByTestId("policytab-network");
    const credentialsTab = screen.getByTestId("policytab-credentials");
    expect(screen.getByRole("tab", { name: "Network" })).toBeDefined();
    expect(screen.getByRole("tab", { name: "Credentials" })).toBeDefined();
    for (const tab of [networkTab, credentialsTab]) {
      expect(tab).toHaveClass("policy-tab");
      expect(tab).not.toHaveClass("settings-tab-btn");
    }
    expect(networkTab).toHaveClass("active");
    expect(credentialsTab).not.toHaveClass("active");
    expect(
      (screen.getByTestId("policytab-network") as HTMLButtonElement).getAttribute(
        "aria-selected"
      )
    ).toBe("true");
    expect((credentialsTab as HTMLButtonElement).getAttribute("aria-selected")).toBe(
      "false"
    );
    const networkControls = networkTab.getAttribute("aria-controls");
    expect(networkControls).toBeTruthy();
    const networkPanel = document.getElementById(networkControls as string);
    expect(networkPanel).not.toBeNull();
    expect(networkPanel?.getAttribute("role")).toBe("tabpanel");
    const credentialsControls = credentialsTab.getAttribute("aria-controls");
    expect(credentialsControls).toBeTruthy();
    expect(screen.getByTestId("policy-network-section")).toBeDefined();
    expect(screen.queryByTestId("policy-credentials-section")).toBeNull();
    expect(screen.queryByTestId("credential-row")).toBeNull();
  });

  it("switches to Credentials to show bindings plus unlinked while keeping the draft", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload), {
      listedKeys: ["ORPHAN_KEY"],
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    const networkTab = screen.getByTestId("policytab-network");
    const credentialsTab = screen.getByTestId("policytab-credentials");
    expect(screen.getByTestId("policy-subtabs")).toHaveClass("policy-tabs");
    for (const tab of [networkTab, credentialsTab]) {
      expect(tab).toHaveClass("policy-tab");
      expect(tab).not.toHaveClass("settings-tab-btn");
    }
    expect(networkTab).toHaveClass("active");
    expect(credentialsTab).not.toHaveClass("active");
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com\napi.other.com");

    await user.click(screen.getByTestId("policytab-credentials"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-credentials-section")).toBeDefined();
    });
    expect(credentialsTab).toHaveClass("active");
    expect(networkTab).not.toHaveClass("active");
    expect((credentialsTab as HTMLButtonElement).getAttribute("aria-selected")).toBe(
      "true"
    );
    expect((networkTab as HTMLButtonElement).getAttribute("aria-selected")).toBe(
      "false"
    );
    const credentialsControls = credentialsTab.getAttribute("aria-controls");
    expect(credentialsControls).toBeTruthy();
    const credentialsPanel = document.getElementById(credentialsControls as string);
    expect(credentialsPanel).not.toBeNull();
    expect(credentialsPanel?.getAttribute("role")).toBe("tabpanel");
    expect(screen.getByText("GITHUB_TOKEN")).toBeDefined();
    expect(screen.getByTestId("unlinked-secrets")).toBeDefined();
    expect(screen.getByTestId("unlinked-secret-row")).toBeDefined();
    expect(screen.getByText("ORPHAN_KEY")).toBeDefined();

    // The Network edit survives the tab switch: the draft stays dirty and the
    // Network section restores the typed value on return.
    expect(screen.getByTestId("policy-save-hint").textContent).toContain(
      "Unsaved changes"
    );
    expect((screen.getByTestId("policy-save") as HTMLButtonElement).disabled).toBe(
      false
    );
    await user.click(screen.getByTestId("policytab-network"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-network-section")).toBeDefined();
    });
    expect(networkTab).toHaveClass("active");
    expect(credentialsTab).not.toHaveClass("active");
    const networkControls = networkTab.getAttribute("aria-controls");
    expect(networkControls).toBeTruthy();
    const networkPanel = document.getElementById(networkControls as string);
    expect(networkPanel).not.toBeNull();
    expect(networkPanel?.getAttribute("role")).toBe("tabpanel");
    expect(
      (screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value
    ).toContain("api.other.com");
    expect(screen.queryByTestId("policy-credentials-section")).toBeNull();
  });

  it("pins the underline tab bar with wired panels and clean draft", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    const subtabs = screen.getByTestId("policy-subtabs");
    expect(subtabs).toHaveClass("policy-tabs");
    const tabButtons = within(subtabs).getAllByRole("tab");
    expect(tabButtons).toHaveLength(2);
    for (const tab of tabButtons) {
      expect(tab).toHaveClass("policy-tab");
      expect(tab).not.toHaveClass("settings-tab-btn");
    }
    expect(subtabs.querySelector(".settings-tab-btn")).toBeNull();
    const networkTab = screen.getByTestId("policytab-network");
    const credentialsTab = screen.getByTestId("policytab-credentials");
    // Default selection owns the underline while the draft stays clean.
    expect(networkTab).toHaveClass("active");
    expect(credentialsTab).not.toHaveClass("active");
    expect(screen.getByTestId("policy-save-hint").textContent).not.toContain(
      "Unsaved changes"
    );
    expect((screen.getByTestId("policy-save") as HTMLButtonElement).disabled).toBe(
      false
    );
    const networkControls = networkTab.getAttribute("aria-controls");
    expect(networkControls).toBeTruthy();
    expect(document.getElementById(networkControls as string)?.getAttribute("role")).toBe(
      "tabpanel"
    );

    await user.click(credentialsTab);
    await waitFor(() => {
      expect(screen.getByTestId("policy-credentials-section")).toBeDefined();
    });
    expect(credentialsTab).toHaveClass("active");
    expect(networkTab).not.toHaveClass("active");
    const credentialsControls = credentialsTab.getAttribute("aria-controls");
    expect(credentialsControls).toBeTruthy();
    expect(
      document.getElementById(credentialsControls as string)?.getAttribute("role")
    ).toBe("tabpanel");
    // Tab chrome alone never dirties the draft.
    expect(screen.getByTestId("policy-save-hint").textContent).not.toContain(
      "Unsaved changes"
    );
  });

  it("shows a success toast on save", async () => {
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as { policy: unknown };
        return jsonResponse({ ...panePolicyPayload, policy: sent.policy });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    expect(screen.queryByTestId("toast")).toBeNull();
    await user.click(screen.getByTestId("policy-save"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    expect(screen.getByTestId("toast").textContent).toContain("Policy saved");
  });

  it("shows zero toasts on save failure", async () => {
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        return jsonResponse({ reason: "classification failed for mystery.local" }, 400);
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policy-save"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-error")).toBeDefined();
    });
    expect(screen.queryByTestId("toast")).toBeNull();
    expect(screen.queryByTestId("toast-error")).toBeNull();
    expect(screen.queryByTestId("policy-saved")).toBeNull();
  });
});
