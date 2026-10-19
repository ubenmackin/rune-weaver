// Rune Weaver Dashboard — Component tests for the access credentials policy section.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AccessNetworkSection } from "./AccessNetworkSection";
import { validateBindingHostEntry } from "../PolicyBindingModal";
import { normalizeSecretKey } from "../StoreSecretModal";
import { clearAuthToken } from "../../api";
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

// Two-binding snapshot so one render proves both presence postures: the
// missing key offers Set while the stored key offers Update plus a guarded
// Delete, with no row offering both shapes at once.
const twoKeyPolicyPayload = {
  ...panePolicyPayload,
  policy: {
    ...panePolicyPayload.policy,
    credentials: {
      MISSING_KEY: {
        allowed_hosts: ["api.github.com"],
        allowed_methods: ["GET"],
        allowed_path_prefixes: ["/repos"],
      },
      STORED_KEY: {
        allowed_hosts: ["api.github.com"],
        allowed_methods: ["GET"],
        allowed_path_prefixes: ["/repos"],
      },
    },
  },
};

describe("AccessCredentialsSection", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  // Routes the pane fetch plus the Keychain presence probe so each case overrides only the response
  // it exercises.
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

  it("filters the credentials list by search without touching the draft", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
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
    expect(screen.getByTestId("policy-save-hint").textContent).not.toContain(
      "Unsaved changes"
    );
    expect(screen.queryByTestId("policy-saved")).toBeNull();
  });

  it("opens the binding modal with a Test-committed probe preview of the supervisor verdict", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    await user.click(screen.getByTestId("edit-binding-GITHUB_TOKEN"));

    const modal = await screen.findByTestId("policy-binding-modal");
    // The pairing sentence lives on Review only, so earlier steps show no
    // sentence before the walk reaches Step 4.
    expect(within(modal).queryByTestId("binding-pairing-sentence")).toBeNull();
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("binding-pairing-sentence").textContent).toContain(
      "prefixes apply to every host"
    );
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4"
    );
    expect(within(modal).getByTestId("probe-helper")).toBeDefined();
    // Default probe routes outside the /repos prefix, so it refuses with the
    // path gate named.
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain("No —");
    });
    expect(within(modal).getByTestId("probe-result").textContent).toContain("/repos");

    // Steering the probe inside the prefix flips the verdict only after Test,
    // proving the preview commits instead of following keystrokes.
    const probePath = within(modal).getByLabelText("Probe path") as HTMLInputElement;
    await user.clear(probePath);
    await user.type(probePath, "/repos/owner/repo");
    expect(within(modal).getByTestId("probe-result").textContent).toContain("No —");
    await user.click(within(modal).getByTestId("probe-run"));
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain(
        "Yes — the secret would be sent."
      );
    });

    // A host outside the binding refuses even with method and path matching.
    const probeHost = within(modal).getByLabelText("Probe host") as HTMLInputElement;
    await user.clear(probeHost);
    await user.type(probeHost, "evil-collector.io");
    expect(within(modal).getByTestId("probe-result").textContent).toContain(
      "Yes — the secret would be sent."
    );
    await user.click(within(modal).getByTestId("probe-run"));
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
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    await user.click(screen.getByTestId("credentials-add"));
    const modal = await screen.findByTestId("policy-binding-modal");

    // The fresh modal probes clean: Any method plus Any path on a listed host
    // authorizes, so the Review preview starts affirmative.
    await user.type(within(modal).getByLabelText("Key"), "NEW_KEY");
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4"
    );
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
    expect(screen.getByTestId("policy-save-hint").textContent).toContain(
      "Unsaved changes"
    );
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
    render(<AccessNetworkSection />);

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
    await openCredentialsTab(user);
    await user.click(screen.getByTestId("credentials-add"));
    const modal = await screen.findByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Key"), "NEW_KEY");
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4"
    );
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
        network: {
          ...panePolicyPayload.policy.network,
          allowed_domains: ["2001:db8::1"],
        },
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
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    // Network stays unbracketed while the binding stays bracketed: no field
    // error and Save stays enabled for the loaded file.
    expect(screen.queryByTestId("policy-field-errors")).toBeNull();
    expect((screen.getByTestId("policy-save") as HTMLButtonElement).disabled).toBe(false);

    await openCredentialsTab(user);
    await user.click(screen.getByTestId("edit-binding-IPV6_KEY"));
    const modal = await screen.findByTestId("policy-binding-modal");
    await user.click(within(modal).getByTestId("wizard-next"));
    // The bracket branch is reachable: the host line reads clean and the modal
    // still offers Save changes from Review for the existing binding.
    expect(within(modal).queryByTestId("hosts-errors")).toBeNull();
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4"
    );
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
      policy: {
        network: { allowedDomains: string[] };
        credentials: Record<string, { allowedHosts: string[]; allowedMethods: string[]; allowedPathPrefixes: string[] }>;
      };
    };
    expect(sent.policy.network.allowedDomains).toEqual(["2001:db8::1"]);
    expect(sent.policy.credentials.IPV6_KEY.allowedHosts).toEqual(["[2001:db8::1]"]);
    expect(sent.policy.credentials.IPV6_KEY.allowedMethods).toEqual(["GET"]);
    expect(sent.policy.credentials.IPV6_KEY.allowedPathPrefixes).toEqual(["/v1"]);
    // The wire carries camelCase only with no snake_case spellings.
    const rawSent = JSON.parse((putCalls[0][1] as RequestInit).body as string) as {
      policy: Record<string, unknown>;
    };
    const rawNetwork = (rawSent.policy as { network: Record<string, unknown> }).network;
    expect(rawNetwork).not.toHaveProperty("allowed_domains");
    expect(rawNetwork).not.toHaveProperty("blocked_domains");
    const rawBinding = (
      rawSent.policy as { credentials: Record<string, Record<string, unknown>> }
    ).credentials.IPV6_KEY;
    expect(rawBinding).not.toHaveProperty("allowed_hosts");
    expect(rawBinding).not.toHaveProperty("allowed_methods");
    expect(rawBinding).not.toHaveProperty("allowed_path_prefixes");
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
    render(<AccessNetworkSection />);

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
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);

    // Add path: a key that already owns a binding is refused, because saving
    // it would silently drop the existing binding.
    await user.click(screen.getByTestId("credentials-add"));
    let modal = await screen.findByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Key"), "GITHUB_TOKEN");
    await waitFor(() => {
      expect(within(modal).getByTestId("key-error").textContent).toContain("already exists");
    });
    expect(
      (within(modal).getByTestId("wizard-next") as HTMLButtonElement).disabled
    ).toBe(true);
    // The wizard footer carries no Cancel; dismissal rides the header control.
    await user.click(within(modal).getByRole("button", { name: "Close modal" }));
    await waitFor(() => {
      expect(screen.queryByTestId("policy-binding-modal")).toBeNull();
    });

    // Edit path: the row's own key stays allowed so duplicate blocking never
    // locks an unchanged binding out of editing.
    await user.click(screen.getByTestId("edit-binding-GITHUB_TOKEN"));
    modal = await screen.findByTestId("policy-binding-modal");
    expect(within(modal).queryByTestId("key-error")).toBeNull();
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4"
    );
    expect(
      (within(modal).getByRole("button", { name: "Save changes" }) as HTMLButtonElement).disabled
    ).toBe(false);
  });

  it("confirms binding deletion before removing the row", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
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
    expect(screen.getByTestId("policy-save-hint").textContent).toContain(
      "Unsaved changes"
    );
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

  it("offers Set for a missing secret and Update plus guarded Delete for a stored one", async () => {
    stubPaneFetch(() => jsonResponse(twoKeyPolicyPayload), {
      secretStatus: { MISSING_KEY: false, STORED_KEY: true },
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user, 2);
    // The stored row settles after the presence probe lands; the missing row
    // never leaves the Set posture.
    await waitFor(() => {
      expect(screen.getByTestId("update-secret-STORED_KEY")).toBeDefined();
    });
    expect(screen.getByTestId("delete-secret-STORED_KEY")).toBeDefined();
    expect(screen.queryByTestId("set-secret-STORED_KEY")).toBeNull();
    expect(screen.getByTestId("set-secret-MISSING_KEY")).toBeDefined();
    expect(screen.queryByTestId("update-secret-MISSING_KEY")).toBeNull();
    expect(screen.queryByTestId("delete-secret-MISSING_KEY")).toBeNull();
    expect(screen.getAllByTestId("credential-row")).toHaveLength(2);
  });

  it("stores a missing secret in-pane and flips its badge to Stored", async () => {
    let stored = false;
    const postedKeys: string[] = [];
    const fetchMock = stubPaneFetch(() => jsonResponse(panePolicyPayload), {
      secretStatus: () => ({ GITHUB_TOKEN: stored }),
      onSecretPosted: (body) => {
        if (typeof body.key === "string") postedKeys.push(body.key);
        stored = true;
      },
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    expect(await screen.findByText("Keychain Missing")).toBeDefined();
    expect(screen.getByTestId("set-secret-GITHUB_TOKEN")).toBeDefined();

    await user.click(screen.getByTestId("set-secret-GITHUB_TOKEN"));
    // The store dialog aria-label plus the row Set button both contain
    // "secret", so the input is pinned by test id to target the field only.
    const secretInput = await screen.findByTestId("secret-value-input");
    const storeDialog = secretInput.closest('[role="dialog"]');
    expect(storeDialog).not.toBeNull();
    // The typed value is write-only: only the routed key is ever asserted.
    await user.type(secretInput, "pane-store-value");
    await user.click(
      within(storeDialog as HTMLElement).getByRole("button", { name: /keychain/i })
    );

    await waitFor(() => {
      expect(screen.getByText("Keychain Stored")).toBeDefined();
    });
    expect(postedKeys).toEqual(["GITHUB_TOKEN"]);
    const posts = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url) === "/settings/secrets" && (init as RequestInit | undefined)?.method === "POST"
    );
    expect(posts).toHaveLength(1);
    // The row leaves the Set posture once the secret lands.
    expect(screen.queryByTestId("set-secret-GITHUB_TOKEN")).toBeNull();
    expect(screen.getByTestId("update-secret-GITHUB_TOKEN")).toBeDefined();
    expect(screen.getByTestId("delete-secret-GITHUB_TOKEN")).toBeDefined();
  });

  it("deletes a stored secret only after confirm and keeps the binding", async () => {
    let stored = true;
    const deletedKeys: string[] = [];
    const fetchMock = stubPaneFetch(() => jsonResponse(panePolicyPayload), {
      secretStatus: () => ({ GITHUB_TOKEN: stored }),
      onSecretDeleted: (key) => {
        deletedKeys.push(key);
        stored = false;
      },
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    expect(await screen.findByText("Keychain Stored")).toBeDefined();

    await user.click(screen.getByTestId("delete-secret-GITHUB_TOKEN"));
    const confirmDialog = await screen.findByRole("dialog");
    // Guarded: the row click opens the confirm without firing the DELETE.
    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).startsWith("/settings/secrets/") &&
          (init as RequestInit | undefined)?.method === "DELETE"
      )
    ).toHaveLength(0);
    await user.click(within(confirmDialog).getByRole("button", { name: /delete|remove/i }));

    await waitFor(() => {
      expect(screen.getByText("Keychain Missing")).toBeDefined();
    });
    expect(deletedKeys).toEqual(["GITHUB_TOKEN"]);
    // The secret is gone but the binding survives: row, edit affordance, and
    // the Set offer all remain for the next store.
    expect(screen.getByTestId("credential-row")).toBeDefined();
    expect(screen.getByText("GITHUB_TOKEN")).toBeDefined();
    expect(screen.getByTestId("edit-binding-GITHUB_TOKEN")).toBeDefined();
    expect(screen.getByTestId("set-secret-GITHUB_TOKEN")).toBeDefined();
    expect(screen.queryByTestId("update-secret-GITHUB_TOKEN")).toBeNull();
  });

  it("stacks the Keychain store over the binding modal from its shortcut", async () => {
    let stored = false;
    stubPaneFetch(() => jsonResponse(panePolicyPayload), {
      secretStatus: () => ({ GITHUB_TOKEN: stored }),
      onSecretPosted: () => {
        stored = true;
      },
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    expect(await screen.findByText("Keychain Missing")).toBeDefined();
    await user.click(screen.getByTestId("edit-binding-GITHUB_TOKEN"));
    const bindingModal = await screen.findByTestId("policy-binding-modal");
    // The shortcut only offers while the secret is missing.
    await user.click(within(bindingModal).getByRole("button", { name: "Store in Keychain" }));

    // Stacked: the store dialog opens above the still-mounted binding modal.
    // The binding modal plus the store dialog plus row buttons all contain
    // "secret", so the input is pinned by test id to target the field only.
    const secretInput = await screen.findByTestId("secret-value-input");
    expect(screen.getByTestId("policy-binding-modal")).toBeDefined();
    const storeDialog = secretInput.closest('[role="dialog"]');
    expect(storeDialog).not.toBeNull();
    await user.type(secretInput, "stacked-store-value");
    await user.click(
      within(storeDialog as HTMLElement).getByRole("button", { name: /keychain/i })
    );

    await waitFor(() => {
      expect(screen.getByText("Keychain Stored")).toBeDefined();
    });
    expect(screen.getByTestId("policy-binding-modal")).toBeDefined();
  });

  it("normalizes a pasted rwsecret: prefix to the bare key", async () => {
    // Unit pin on the shared owner: trim, strip exactly one prefix, keep the rest.
    expect(normalizeSecretKey("rwsecret:MY_KEY")).toBe("MY_KEY");
    expect(normalizeSecretKey("  rwsecret:MY_KEY  ")).toBe("MY_KEY");
    expect(normalizeSecretKey("rwsecret:rwsecret:MY_KEY")).toBe("rwsecret:MY_KEY");
    expect(normalizeSecretKey("MY_KEY")).toBe("MY_KEY");

    // Pane flow: pasting the surrogate spelling into the binding Key field
    // lands a binding under the bare key instead of an invalid row.
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    await user.click(screen.getByTestId("credentials-add"));
    const modal = await screen.findByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Key"), "rwsecret:MY_KEY");
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4"
    );
    await user.click(within(modal).getByRole("button", { name: "Save binding" }));
    await waitFor(() => {
      expect(screen.queryByTestId("policy-binding-modal")).toBeNull();
    });
    expect(screen.getByText("MY_KEY")).toBeDefined();
    expect(screen.queryByText("rwsecret:MY_KEY")).toBeNull();
  });

  it("invites in-pane secret setup instead of manual creation when no bindings exist", async () => {
    const emptyPayload = {
      ...panePolicyPayload,
      policy: { ...panePolicyPayload.policy, credentials: {} },
    };
    stubPaneFetch(() => jsonResponse(emptyPayload), { secretStatus: {} });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await user.click(screen.getByTestId("policytab-credentials"));
    await waitFor(() => {
      expect(screen.getByTestId("credentials-empty")).toBeDefined();
    });
    const empty = screen.getByTestId("credentials-empty");
    // Manual creation is gone: the empty state never sends the owner off to
    // create the Keychain entry by hand.
    expect(empty.textContent).not.toContain("Store the secret value in Keychain as");
    // The in-pane path stays offered from the empty state itself.
    expect(within(empty).getByTestId("credentials-empty-add")).toBeDefined();
  });

  it("renders reason lines for rows needing attention", async () => {
    stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    // The fixture host is outside the allowlist, so the row flags coverage.
    await waitFor(() => {
      expect(screen.getByTestId("binding-attention")).toBeDefined();
    });
    expect(screen.getByTestId("binding-attention-reason").textContent).toContain(
      "not in Allowed Domains"
    );
  });

  it("leaves the secret stored when the delete-dialog checkbox stays unchecked", async () => {
    const fetchMock = stubPaneFetch(() => jsonResponse(panePolicyPayload));
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    await user.click(screen.getByTestId("delete-binding-GITHUB_TOKEN"));
    const checkbox = (await screen.findByTestId(
      "delete-binding-also-secret"
    )) as HTMLInputElement;
    expect(checkbox.checked).toBe(false);
    await user.click(screen.getByRole("button", { name: /Confirm delete GITHUB_TOKEN/ }));
    await waitFor(() => {
      expect(screen.queryByTestId("credential-row")).toBeNull();
    });
    const secretDeletes = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url).startsWith("/settings/secrets/") &&
        (init as RequestInit | undefined)?.method === "DELETE"
    );
    expect(secretDeletes).toHaveLength(0);
    expect(screen.getByTestId("policy-save-hint").textContent).toContain(
      "Unsaved changes"
    );
  });

  it("deletes the secret when the delete-dialog checkbox is checked", async () => {
    let stored = true;
    const deletedKeys: string[] = [];
    const fetchMock = stubPaneFetch(() => jsonResponse(panePolicyPayload), {
      secretStatus: () => ({ GITHUB_TOKEN: stored }),
      onSecretDeleted: (key) => {
        deletedKeys.push(key);
        stored = false;
      },
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    await openCredentialsTab(user);
    await user.click(screen.getByTestId("delete-binding-GITHUB_TOKEN"));
    const checkbox = (await screen.findByTestId(
      "delete-binding-also-secret"
    )) as HTMLInputElement;
    expect(checkbox.checked).toBe(false);
    await user.click(checkbox);
    expect(checkbox.checked).toBe(true);
    await user.click(screen.getByRole("button", { name: /Confirm delete GITHUB_TOKEN/ }));
    await waitFor(() => {
      expect(screen.queryByTestId("credential-row")).toBeNull();
    });
    const secretDeletes = fetchMock.mock.calls.filter(
      ([url, init]) =>
        String(url).startsWith("/settings/secrets/") &&
        (init as RequestInit | undefined)?.method === "DELETE"
    );
    expect(secretDeletes).toHaveLength(1);
    expect(deletedKeys).toEqual(["GITHUB_TOKEN"]);
  });

  it("round-trips typed allowed domains through the camelCase write payload", async () => {
    let sentPolicy: Record<string, unknown> | null = null;
    stubPaneFetch((init) => {
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as { policy: Record<string, unknown> };
        sentPolicy = sent.policy;
        return jsonResponse({ ...panePolicyPayload, policy: sent.policy });
      }
      return jsonResponse(panePolicyPayload);
    });
    const user = userEvent.setup();
    render(<AccessNetworkSection />);

    await waitForPaneLoaded();
    const allowed = screen.getByLabelText("Allowed domains") as HTMLTextAreaElement;
    await user.clear(allowed);
    await user.type(allowed, "api.example.com");
    await user.click(screen.getByTestId("policy-save"));

    await waitFor(() => {
      expect(screen.getByTestId("policy-saved")).toBeDefined();
    });
    // The echoed snapshot reloads into the editors, so the typed host persists.
    expect((screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value).toContain(
      "api.example.com"
    );
    // The write carries camelCase only with the typed host and credential bindings.
    expect(sentPolicy).not.toBeNull();
    const sentNetwork = (sentPolicy as unknown as { network: Record<string, unknown> }).network;
    expect(sentNetwork).toHaveProperty("allowedDomains", ["api.example.com"]);
    expect(sentNetwork).not.toHaveProperty("allowed_domains");
    expect(sentNetwork).not.toHaveProperty("blocked_domains");
    expect(sentNetwork).not.toHaveProperty("localExemptions");
    expect(sentNetwork).not.toHaveProperty("local_exemptions");
    const sentCredentials = (sentPolicy as unknown as { credentials: Record<string, Record<string, unknown>> })
      .credentials;
    expect(sentCredentials.GITHUB_TOKEN).toHaveProperty("allowedHosts", ["api.github.com"]);
    expect(sentCredentials.GITHUB_TOKEN).not.toHaveProperty("allowed_hosts");
    expect(sentCredentials.GITHUB_TOKEN).not.toHaveProperty("allowed_methods");
    expect(sentCredentials.GITHUB_TOKEN).not.toHaveProperty("allowed_path_prefixes");
  });
});
