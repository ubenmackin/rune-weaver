// Rune Weaver Dashboard — Component tests for the declarative policy pane.
//
// Purpose: Pins the structured network-plus-credentials editor that owns
// policy.toml outside the shared config form: loading the verified snapshot
// into inline editors, persisting the DTO without raw text, and keeping the
// saved banner honest across edits with no restart promise ever shown.
// Scope: Pane fetch and save shapes, network editors, the searchable
// credentials list, the add/edit modal with its live probe preview, and
// delete confirmation. Engine invariant math and TOML serialization stay with
// their owner suites.
// Architectural role: Guards the single dashboard surface whose writes steer
// the mandatory egress choke-point, so a pane edit cannot persist unvalidated
// text or claim a write that never landed.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PolicyPane, canonicalPolicySnapshot, isValidDomainLine } from "./PolicyPane";
import { validateBindingHostEntry } from "./PolicyBindingModal";
import { clearAuthToken, setAuthToken } from "../api";
import { jsonResponse } from "../test-utils/http";

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

describe("PolicyPane", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  // Routes the pane fetch plus the Keychain presence probe so each case
  // overrides only the response it exercises.
  function stubPaneFetch(
    policyResponse: (init?: RequestInit) => Response | Promise<Response>
  ) {
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        if (urlStr === "/settings/policy") {
          return policyResponse(init);
        }
        if (urlStr.includes("/settings/secrets/status")) {
          return jsonResponse({ status: { GITHUB_TOKEN: true } });
        }
        return jsonResponse({});
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  // Waits for the snapshot to land in the editors: the mode select proves the
  // DTO arrived and the credential row proves the bindings rendered.
  async function waitForPaneLoaded() {
    await waitFor(() => {
      expect((screen.getByLabelText("Mode") as HTMLSelectElement).value).toBe(
        "allowlist_only"
      );
      expect(screen.getByTestId("credential-row")).toBeDefined();
    });
  }

  it("loads the structured snapshot into network editors and the credentials list", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    render(<PolicyPane />);

    await waitForPaneLoaded();
    expect(
      (screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value
    ).toContain("api.example.com");
    expect(
      (screen.getByLabelText("Blocked domains") as HTMLTextAreaElement).value
    ).toContain("metadata.google.internal");
    expect(screen.getByText("GITHUB_TOKEN")).toBeDefined();
    // Keychain presence resolves beside the policy load, so the row badges
    // Stored instead of blocking the render on secrets.
    expect(await screen.findByText("Keychain Stored")).toBeDefined();
    expect(screen.getByText(/All 3 Formal Security Invariants Verified/)).toBeDefined();
    expect(screen.getByTestId("policy-location").textContent).toContain("Customized");
    // The egress editors own their vertical rhythm, so the section carries the
    // scoped spacing class that separates each hint from the next label.
    expect(screen.getByTestId("network-egress-editors").className).toContain(
      "policy-network-section"
    );

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    expect(screen.getByText("Unsaved changes.")).toBeDefined();
  });

  it("surfaces invalid domain shapes inline and gates Save", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<PolicyPane />);

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

  it("filters the credentials list by search without touching the draft", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();
    const search = screen.getByLabelText("Search bindings");
    await user.type(search, "zzz-no-such-key");
    await waitFor(() => {
      expect(screen.getByTestId("credentials-no-match")).toBeDefined();
    });
    expect(screen.queryByTestId("credential-row")).toBeNull();

    // Clearing the filter restores the row with no save in flight: search is
    // a view concern, so the draft stays clean and no banner appears.
    await user.clear(search);
    await waitFor(() => {
      expect(screen.getByTestId("credential-row")).toBeDefined();
    });
    expect(screen.queryByText("Unsaved changes.")).toBeNull();
    expect(screen.queryByTestId("policy-saved")).toBeNull();
  });

  it("opens the binding modal with a live probe preview of the supervisor verdict", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("edit-binding-GITHUB_TOKEN"));

    const modal = await screen.findByTestId("policy-binding-modal");
    // The pairing sentence states the conjunction under edit.
    expect(within(modal).getByTestId("binding-pairing-sentence").textContent).toContain(
      "prefixes apply to every host"
    );
    // Default probe routes outside the /repos prefix, so it refuses with the
    // path gate named.
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain("No —");
    });
    expect(within(modal).getByTestId("probe-result").textContent).toContain("/repos");

    // Steering the probe inside the prefix flips the verdict without a
    // network round trip, proving the preview mirrors the binding gate.
    const probePath = within(modal).getByLabelText("Probe path") as HTMLInputElement;
    await user.clear(probePath);
    await user.type(probePath, "/repos/owner/repo");
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain(
        "Yes — the secret would be sent."
      );
    });

    // A host outside the binding refuses even with method and path matching.
    const probeHost = within(modal).getByLabelText("Probe host") as HTMLInputElement;
    await user.clear(probeHost);
    await user.type(probeHost, "evil-collector.io");
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain("No —");
    });
    expect(within(modal).getByTestId("probe-result").textContent).toContain(
      "evil-collector.io"
    );
  });

  it("adds a binding through the modal into the draft without persisting", async () => {
    let putCount = 0;
    const fetchMock = stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        putCount += 1;
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("credentials-add"));
    const modal = await screen.findByTestId("policy-binding-modal");

    // The fresh modal probes clean: Any method plus Any path on a listed host
    // authorizes, so the preview starts affirmative.
    await user.type(within(modal).getByLabelText("Key"), "NEW_KEY");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain(
        "Yes — the secret would be sent."
      );
    });

    // Modal save writes into the live draft only; the pane Save owns
    // persistence, so no PUT fires here.
    await user.click(within(modal).getByRole("button", { name: "Save binding" }));
    await waitFor(() => {
      expect(screen.queryByTestId("policy-binding-modal")).toBeNull();
    });
    expect(screen.getByText("NEW_KEY")).toBeDefined();
    expect(screen.getByText("Unsaved changes.")).toBeDefined();
    expect(putCount).toBe(0);
    const policyPuts = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url) === "/settings/policy" && (init as RequestInit | undefined)?.method === "PUT"
    );
    expect(policyPuts).toHaveLength(0);
  });

  it("probes Keychain presence only when the binding set changes", async () => {
    const fetchMock = stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const secretProbes = () =>
      fetchMock.mock.calls.filter(([url]) =>
        String(url).includes("/settings/secrets/status")
      ).length;
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();
    await waitFor(() => {
      expect(secretProbes()).toBe(1);
    });

    // Network keystrokes reshape the draft on every character without adding or
    // removing a binding, so the presence probe must not refire per keystroke.
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com\napi.other.com");
    expect(secretProbes()).toBe(1);

    // Adding a binding changes the key set, so the probe refires for the new key.
    await user.click(screen.getByTestId("credentials-add"));
    const modal = await screen.findByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Key"), "NEW_KEY");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByRole("button", { name: "Save binding" }));
    await waitFor(() => {
      expect(secretProbes()).toBe(2);
    });
  });

  it("keeps a loaded bracketed IPv6 binding editable instead of reading brackets as glob syntax", async () => {
    const ipv6Payload = {
      ...panePolicyPayload,
      policy: {
        ...panePolicyPayload.policy,
        credentials: {
          IPV6_KEY: {
            allowed_hosts: ["[2001:db8::1]"],
            allowed_methods: ["GET"],
            allowed_path_prefixes: ["/v1"],
          },
        },
      },
    };
    const fetchMock = stubPaneFetch(() => jsonResponse(ipv6Payload));
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();
    // The server accepts this binding, so the pane gate must too: no field
    // error and Save stays enabled for the loaded file.
    expect(screen.queryByTestId("policy-field-errors")).toBeNull();
    expect((screen.getByTestId("policy-save") as HTMLButtonElement).disabled).toBe(false);

    await user.click(screen.getByTestId("edit-binding-IPV6_KEY"));
    const modal = await screen.findByTestId("policy-binding-modal");
    // The bracket branch is reachable: the host line reads clean and the modal
    // still offers Save changes for the existing binding.
    expect(within(modal).queryByTestId("hosts-errors")).toBeNull();
    expect(
      (within(modal).getByRole("button", { name: "Save changes" }) as HTMLButtonElement).disabled
    ).toBe(false);

    // Saving through the modal keeps the literal intact and the pane persists
    // it, proving a server-accepted bracketed binding stays fully editable.
    await user.click(within(modal).getByRole("button", { name: "Save changes" }));
    await waitFor(() => {
      expect(screen.queryByTestId("policy-binding-modal")).toBeNull();
    });
    await user.click(screen.getByTestId("policy-save"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    const putCalls = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url) === "/settings/policy" && (init as RequestInit | undefined)?.method === "PUT"
    );
    expect(putCalls).toHaveLength(1);
    const sent = JSON.parse((putCalls[0][1] as RequestInit).body as string) as {
      policy: { credentials: Record<string, { allowed_hosts: string[] }> };
    };
    expect(sent.policy.credentials.IPV6_KEY.allowed_hosts).toEqual(["[2001:db8::1]"]);
  });

  it("refuses a loaded binding host the supervisor confines", async () => {
    const confinedPayload = {
      ...panePolicyPayload,
      policy: {
        ...panePolicyPayload.policy,
        credentials: {
          GITHUB_TOKEN: {
            allowed_hosts: ["evil host"],
            allowed_methods: ["GET"],
            allowed_path_prefixes: ["/repos"],
          },
        },
      },
    };
    stubPaneFetch(() => jsonResponse(confinedPayload));
    render(<PolicyPane />);

    await waitForPaneLoaded();
    // A whitespace host never matches at runtime, so the pane field gate
    // refuses the loaded draft instead of offering a save the server 400s.
    await waitFor(() => {
      expect(screen.getByTestId("policy-field-errors").textContent).toContain("invalid host");
    });
    expect((screen.getByTestId("policy-save") as HTMLButtonElement).disabled).toBe(true);
  });

  it("blocks saving a binding onto an existing key", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();

    // Add path: a key that already owns a binding is refused, because saving
    // it would silently drop the existing binding.
    await user.click(screen.getByTestId("credentials-add"));
    let modal = await screen.findByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Key"), "GITHUB_TOKEN");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await waitFor(() => {
      expect(within(modal).getByTestId("key-error").textContent).toContain("already exists");
    });
    expect(
      (within(modal).getByRole("button", { name: "Save binding" }) as HTMLButtonElement).disabled
    ).toBe(true);
    await user.click(within(modal).getByRole("button", { name: "Cancel" }));
    await waitFor(() => {
      expect(screen.queryByTestId("policy-binding-modal")).toBeNull();
    });

    // Edit path: the row's own key stays allowed so duplicate blocking never
    // locks an unchanged binding out of editing.
    await user.click(screen.getByTestId("edit-binding-GITHUB_TOKEN"));
    modal = await screen.findByTestId("policy-binding-modal");
    expect(within(modal).queryByTestId("key-error")).toBeNull();
    expect(
      (within(modal).getByRole("button", { name: "Save changes" }) as HTMLButtonElement).disabled
    ).toBe(false);
  });

  it("confirms binding deletion before removing the row", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<PolicyPane />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("delete-binding-GITHUB_TOKEN"));
    await waitFor(() => {
      expect(screen.getByText("Delete binding?")).toBeDefined();
    });

    // Cancelling keeps the row; only an explicit confirm removes it, and the
    // removal marks the draft dirty for the pane Save to persist.
    await user.click(screen.getByRole("button", { name: "Keep" }));
    await waitFor(() => {
      expect(screen.queryByText("Delete binding?")).toBeNull();
    });
    expect(screen.getByTestId("credential-row")).toBeDefined();

    await user.click(screen.getByTestId("delete-binding-GITHUB_TOKEN"));
    await waitFor(() => {
      expect(screen.getByText("Delete binding?")).toBeDefined();
    });
    await user.click(screen.getByRole("button", { name: /Confirm delete GITHUB_TOKEN/ }));
    await waitFor(() => {
      expect(screen.queryByTestId("credential-row")).toBeNull();
    });
    expect(screen.getByText("Unsaved changes.")).toBeDefined();
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
      render(<PolicyPane />);

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

  it("accepts bracketed IPv6 binding hosts while refusing ports and confined literals", () => {
    // The server accepts `[2001:db8::1]` as a binding host, so the shared
    // helper must keep its bracket branch reachable for that shape.
    expect(validateBindingHostEntry("[2001:db8::1]")).toBeNull();
    // Brackets delimit an IPv6 literal only: a port tail, a non-literal inner
    // value, and confined literals all still refuse.
    expect(validateBindingHostEntry("[2001:db8::1]:443")).not.toBeNull();
    expect(validateBindingHostEntry("[not-a-literal]")).not.toBeNull();
    expect(validateBindingHostEntry("[::1]")).not.toBeNull();
    expect(validateBindingHostEntry("[fe80::1]")).not.toBeNull();
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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
    render(<PolicyPane />);

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
});
