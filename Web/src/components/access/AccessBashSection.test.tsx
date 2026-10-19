// Rune Weaver Dashboard — Component tests for the access Bash & Shell section.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AccessBashSection } from "./AccessBashSection";
import { clearAuthToken } from "../../api";
import { jsonResponse } from "../../test-utils/http";

// Seed snapshot mirroring the engine GET shape: the ordered [bash] section
// plus the confinement knobs on camelCase keys.
const storedBash = {
  enabled: true,
  defaultAction: "ask",
  rules: [{ pattern: "*", action: "ask" }],
  timeoutSeconds: 30,
  cpuSeconds: 60,
  memoryMb: 512,
  allowNetwork: false,
  sandboxMode: "strictContainer",
  hostAllowPatterns: ["xcodebuild*", "codesign*"],
};

describe("AccessBashSection", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  // Routes the settings GET plus the bash PATCH so each case overrides only the response it
  // exercises.
  function stubSettings(
    bash: Record<string, unknown>,
    onPut?: (body: Record<string, unknown>) => Response
  ) {
    const settings = { bash };
    const puts: Record<string, unknown>[] = [];
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        if (urlStr === "/settings" && (init?.method ?? "GET").toUpperCase() === "PUT") {
          const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
          puts.push(body);
          if (onPut) return onPut(body);
          return jsonResponse({ ...settings, ...body });
        }
        return jsonResponse(settings);
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    return { puts, getPutCount: () => puts.length, fetchMock };
  }

  // Waits for the snapshot to land: the rules textarea proves the [bash]
  // section arrived instead of the fresh-form defaults.
  async function waitForSectionLoaded(expectedSubstring = "* = ask") {
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Rules, one per line/i) as HTMLTextAreaElement).value
      ).toContain(expectedSubstring);
    });
  }

  it("loads the [bash] snapshot into every editor", async () => {
    stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();
    expect((screen.getByLabelText(/Default action/i) as HTMLSelectElement).value).toBe(
      "ask"
    );
    expect((screen.getByLabelText(/Execution tier/i) as HTMLSelectElement).value).toBe(
      "strictContainer"
    );
    expect(
      (screen.getByLabelText(/Host allow patterns/i) as HTMLTextAreaElement).value
    ).toContain("xcodebuild*");
    expect((screen.getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement).value).toBe(
      "30"
    );
    expect((screen.getByLabelText(/CPU seconds/i) as HTMLInputElement).value).toBe("60");
    expect((screen.getByLabelText(/Memory \(MB\)/i) as HTMLInputElement).value).toBe("512");
    expect((screen.getByLabelText(/Allow network access/i) as HTMLInputElement).checked).toBe(
      false
    );
    expect(screen.queryByLabelText(/^Enabled$/i)).toBeNull();
    expect(screen.queryByTestId("bash-loading")).toBeNull();
    // Unedited draft reads clean so the footer never claims a pending write.
    expect(screen.getByTestId("bash-save-hint").textContent).toContain(
      "Only the edited keys travel"
    );
    // Editing one knob flips the hint without touching the stored patch.
    await user.clear(screen.getByLabelText(/Timeout \(seconds\)/i));
    await user.type(screen.getByLabelText(/Timeout \(seconds\)/i), "45");
    expect(screen.getByTestId("bash-save-hint").textContent).toContain(
      "Unsaved changes"
    );
  });

  it("saves an unedited form as an empty changed-only bash patch", async () => {
    const { puts, getPutCount } = stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    // The save travels alone: only the bash section rides the PUT, and a form
    // the owner never touched sends the empty patch so stored values survive.
    expect(Object.keys(puts[0])).toEqual(["bash"]);
    expect(puts[0]["bash"]).toEqual({});
  });

  it("pins the rules textarea contract with ordered last-match rules", async () => {
    const settings = {
      ...storedBash,
      defaultAction: "deny",
      rules: [
        { pattern: "*", action: "deny" },
        { pattern: "swiftformat *", action: "allow" },
      ],
    };
    const { puts, getPutCount } = stubSettings(settings);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded("* = deny");

    // Pinned by accessible label as a single textarea with the stored fixture
    // rendered in order: catch-all first, specifics after.
    const rulesTextarea = screen.getByLabelText(
      /Rules, one per line/i
    ) as HTMLTextAreaElement;
    expect(rulesTextarea.tagName).toBe("TEXTAREA");
    expect(rulesTextarea.placeholder).toContain("* = deny");
    expect(rulesTextarea.value).toContain("* = deny");
    expect(rulesTextarea.value).toContain("swiftformat * = allow");
    // Format hint pins the `pattern = action` line shape with the closed
    // allow/ask/deny set and the top-to-bottom last-match-wins order.
    expect(screen.getByText(/pattern = action/i)).toBeDefined();
    expect(screen.getByText(/last matching rule wins/i)).toBeDefined();
    expect(screen.getByText(/Put the catch-all first and specifics after/i)).toBeDefined();
    // Live count follows the parsed textarea rows.
    expect(screen.getByText(/2 rules/i)).toBeDefined();

    // No row model exists: there are no per-rule inputs or remove buttons,
    // only the one textarea.
    expect(screen.queryByLabelText(/Rule 1/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /Remove.*rule/i })).toBeNull();
    expect(screen.getAllByLabelText(/Rules, one per line/i).length).toBe(1);

    // Add Rule focuses the editor for keyboard flow without altering the
    // parsed count by itself.
    await user.click(screen.getByRole("button", { name: /Add Rule/i }));
    await waitFor(() => {
      expect(document.activeElement).toBe(rulesTextarea);
    });
    expect(rulesTextarea.value.endsWith("\n")).toBe(true);
    expect(screen.getByText(/2 rules/i)).toBeDefined();

    // Blank lines and surrounding whitespace collapse on save with order preserved top-to-bottom;
    // the wire shape is an ordered rule array.
    const editedTextarea = screen.getByLabelText(
      /Rules, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "* = deny\nnot a rule");
    await user.click(screen.getByTestId("bash-save"));
    await waitFor(() => {
      expect(screen.getByText(/Line 2/i)).toBeDefined();
    });
    expect(getPutCount()).toBe(0);

    // An unknown action on the right also rejects with its line number. The
    // Line 2 matcher disambiguates the validation error from the format hint,
    // which also mentions the allow/ask/deny set.
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "* = deny\nswiftformat * = maybe");
    await user.click(screen.getByTestId("bash-save"));
    await waitFor(() => {
      expect(screen.getByText(/Line 2/i)).toBeDefined();
    });
    expect(
      screen.getByText(/Line 2: action must be allow, ask, or deny/i)
    ).toBeDefined();
    expect(getPutCount()).toBe(0);

    // Ordered save runs last: blanks collapse and order is preserved
    // top-to-bottom as a changed-only patch carrying only the edited rules.
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "  * = allow  \n\nswiftformat * = allow\n   \n");
    expect(screen.getByText(/2 rules/i)).toBeDefined();
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    const bash = puts[0]["bash"] as Record<string, unknown>;
    expect(bash["rules"]).toEqual([
      { pattern: "*", action: "allow" },
      { pattern: "swiftformat *", action: "allow" },
    ]);
    expect(bash["sandbox_mode"]).toBeUndefined();
    expect(bash["host_allow_patterns"]).toBeUndefined();
  });

  it("rejects an empty rule list before any network write", async () => {
    const { getPutCount } = stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();
    // Clearing the textarea leaves an empty list, which must fail closed
    // instead of falling through to the default action.
    const rulesTextarea = screen.getByLabelText(
      /Rules, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(rulesTextarea);
    expect(screen.getByText(/0 rules/i)).toBeDefined();

    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(screen.getByText(/Invalid bash rules/i)).toBeDefined();
    });
    expect(screen.getByText(/At least one rule is required/i)).toBeDefined();
    expect(getPutCount()).toBe(0);
  });

  it("reads camelCase bash settings while sending camelCase keys", async () => {
    const camelBash = {
      enabled: true,
      defaultAction: "deny",
      rules: [{ pattern: "git *", action: "allow" }],
      timeoutSeconds: 45,
      allowNetwork: true,
      sandboxMode: "machineScoped",
      hostAllowPatterns: ["xcodebuild*"],
    };
    const { puts } = stubSettings(camelBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded("git * = allow");

    // Camel aliases populate the fields, with rules serialized as `pattern = action` lines preserving order.
    expect((screen.getByLabelText(/Default action/i) as HTMLSelectElement).value).toBe(
      "deny"
    );
    expect(screen.getByDisplayValue("45")).toBeDefined();
    expect(screen.getByDisplayValue("git * = allow")).toBeDefined();
    expect((screen.getByLabelText(/Execution tier/i) as HTMLSelectElement).value).toBe(
      "machineScoped"
    );
    expect(
      (screen.getByLabelText(/Host allow patterns/i) as HTMLTextAreaElement).value
    ).toContain("xcodebuild*");

    // Editing one knob sends a changed-only camelCase patch: only the edited
    // timeout travels while untouched values stay omitted.
    const timeoutInput = screen.getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement;
    await user.clear(timeoutInput);
    await user.type(timeoutInput, "46");
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(screen.getByTestId("bash-saved")).toBeDefined();
    });
    const bash = puts[0]["bash"] as Record<string, unknown>;
    expect(bash).toBeDefined();
    expect(bash["timeoutSeconds"]).toBe(46);
    expect(bash["timeout_seconds"]).toBeUndefined();
    expect(bash["defaultAction"]).toBeUndefined();
    expect(bash["allowNetwork"]).toBeUndefined();
    expect(bash["rules"]).toBeUndefined();
    expect(bash["sandboxMode"]).toBeUndefined();
    expect(bash["hostAllowPatterns"]).toBeUndefined();
  });

  it("renders current cpu and memory values with server-clamped inputs", async () => {
    stubSettings(storedBash);
    render(<AccessBashSection />);

    await waitForSectionLoaded();

    // Stored bounds round-trip into the form directly under the timeout.
    const cpuInput = screen.getByLabelText(/CPU seconds/i) as HTMLInputElement;
    const memoryInput = screen.getByLabelText(/Memory \(MB\)/i) as HTMLInputElement;
    expect(cpuInput.value).toBe("60");
    expect(memoryInput.value).toBe("512");
    // Inputs clamp to the engine bounds so the form agrees with the server 400.
    expect(cpuInput.min).toBe("1");
    expect(cpuInput.max).toBe("3600");
    expect(cpuInput.step).toBe("1");
    expect(memoryInput.min).toBe("64");
    expect(memoryInput.max).toBe("8192");
    expect(memoryInput.step).toBe("1");
    // One-line hints name the non-obvious bound semantics.
    expect(screen.getByText(/wall-clock may exceed CPU time for sleeping processes/i)).toBeDefined();
    expect(screen.getByText(/best-effort ulimit bound/i)).toBeDefined();
  });

  it("saves edited bounds through one PATCH carrying only the bash delta", async () => {
    const { puts, getPutCount } = stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();

    // Editing only the resource budgets keeps the save to one request.
    const cpuInput = screen.getByLabelText(/CPU seconds/i) as HTMLInputElement;
    await user.clear(cpuInput);
    await user.type(cpuInput, "90");
    const memoryInput = screen.getByLabelText(/Memory \(MB\)/i) as HTMLInputElement;
    await user.clear(memoryInput);
    await user.type(memoryInput, "2048");
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    // The save travels alone: only the bash section rides the PUT, and the
    // edited budgets arrive on camelCase keys as a changed-only patch with untouched values omitted.
    expect(Object.keys(puts[0])).toEqual(["bash"]);
    const bash = puts[0]["bash"] as Record<string, unknown>;
    expect(bash["cpuSeconds"]).toBe(90);
    expect(bash["memoryMb"]).toBe(2048);
    expect(bash["timeoutSeconds"]).toBeUndefined();
    expect(bash["sandboxMode"]).toBeUndefined();
    expect(bash["hostAllowPatterns"]).toBeUndefined();
  });

  it("maps a server 400 to the inline error path without discarding the draft", async () => {
    const serverReason = "bash.cpu_seconds must be between 1 and 3600 (got 9999)";
    const { getPutCount } = stubSettings(storedBash, () =>
      jsonResponse({ reason: serverReason }, 400)
    );
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();
    const cpuInput = screen.getByLabelText(/CPU seconds/i) as HTMLInputElement;
    await user.clear(cpuInput);
    await user.type(cpuInput, "3600");
    await user.click(screen.getByTestId("bash-save"));

    // The honest server message surfaces inline while the editor stays open
    // for repair instead of closing on a generic failure.
    await waitFor(() => {
      expect(screen.getByText(serverReason)).toBeDefined();
    });
    expect(getPutCount()).toBe(1);
    expect(screen.queryByTestId("bash-saved")).toBeNull();
    expect(screen.getByTestId("bash-pane")).toBeDefined();
  });

  it("rejects an out-of-range cpu budget before any network write", async () => {
    const { getPutCount } = stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();

    // A zero CPU budget would kill every command instantly, so the form fails
    // closed with the bound instead of returning a server 400.
    const cpuInput = screen.getByLabelText(/CPU seconds/i) as HTMLInputElement;
    await user.clear(cpuInput);
    await user.type(cpuInput, "0");
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(screen.getByText(/Invalid bash CPU budget/i)).toBeDefined();
    });
    expect(getPutCount()).toBe(0);
  });

  it("renders human-readable tier labels with raw values preserved", async () => {
    stubSettings(storedBash);
    render(<AccessBashSection />);

    await waitForSectionLoaded();

    const tierSelect = screen.getByLabelText(/Execution tier/i) as HTMLSelectElement;
    const options = Array.from(tierSelect.querySelectorAll("option"));
    expect(options.map((option) => option.textContent)).toEqual([
      "Temporary container",
      "Workspace machine",
      "On this Mac",
    ]);
    expect(options.map((option) => option.value)).toEqual([
      "strictContainer",
      "machineScoped",
      "hostSeatbelt",
    ]);
    expect(tierSelect.value).toBe("strictContainer");
  });

  it("shows per-tier help plus scope and keeps the blob absent", async () => {
    stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();

    const tierSelect = screen.getByLabelText(/Execution tier/i) as HTMLSelectElement;
    expect(screen.getByTestId("bash-sandbox-help").textContent).toBe(
      "Runs in a temporary container with no internet access. Nothing is kept after the run.",
    );
    expect(screen.getByTestId("bash-sandbox-scope").textContent).toBe(
      "Scope: fresh workspace scratch, deleted at turn end.",
    );
    expect(screen.queryByText(/Tiers:/)).toBeNull();
    expect(document.body.textContent).not.toContain("stay isolated");

    await user.selectOptions(tierSelect, "machineScoped");
    expect(screen.getByTestId("bash-sandbox-help").textContent).toBe(
      "Runs in a persistent workspace machine with no internet access. Workspace files persist across runs.",
    );
    expect(screen.getByTestId("bash-sandbox-scope").textContent).toBe(
      "Scope: full workspace, kept across runs.",
    );

    await user.selectOptions(tierSelect, "hostSeatbelt");
    expect(screen.getByTestId("bash-sandbox-help").textContent).toBe(
      "Runs on your Mac as you with full access to your files.",
    );
    expect(screen.getByTestId("bash-sandbox-scope").textContent).toBe(
      "Scope: your entire Mac, running as you.",
    );
    expect(screen.queryByText(/Tiers:/)).toBeNull();
  });

  it("keeps numeric limits collapsed in Advanced with policy visible", async () => {
    stubSettings(storedBash);
    render(<AccessBashSection />);

    await waitForSectionLoaded();

    const advanced = screen.getByTestId("bash-advanced-details");
    expect(advanced).not.toBeNull();
    expect((advanced as HTMLDetailsElement).open).toBe(false);
    expect(within(advanced as HTMLElement).getByText("Advanced")).toBeDefined();
    expect((advanced as HTMLElement).textContent).toContain("Advanced");
    const advancedScope = advanced as HTMLElement;
    expect(within(advancedScope).getByLabelText(/Timeout \(seconds\)/i)).toBeDefined();
    expect(within(advancedScope).getByLabelText(/CPU seconds/i)).toBeDefined();
    expect(within(advancedScope).getByLabelText(/Memory \(MB\)/i)).toBeDefined();
    // The confinement editors stay outside the disclosure so the tier and
    // allowlist read without opening Advanced.
    expect(screen.getByLabelText(/Execution tier/i)).toBeDefined();
    expect(screen.getByLabelText(/Host allow patterns/i)).toBeDefined();
    expect(screen.getByLabelText(/Allow network access/i)).toBeDefined();
    expect(screen.getByLabelText(/Default action/i)).toBeDefined();
    expect(screen.getByLabelText(/Rules, one per line/i)).toBeDefined();
  });

  it("signals live apply with no restart after a save", async () => {
    const { getPutCount } = stubSettings(storedBash);
    const user = userEvent.setup();
    render(<AccessBashSection />);

    await waitForSectionLoaded();
    await user.clear(screen.getByLabelText(/Timeout \(seconds\)/i));
    await user.type(screen.getByLabelText(/Timeout \(seconds\)/i), "45");
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(screen.getByTestId("bash-saved")).toBeDefined();
    });
    expect(screen.getByTestId("bash-saved").textContent).toBe(
      "Bash settings saved. Changes apply immediately with no restart."
    );
    expect(screen.queryByText(/Restart required/i)).toBeNull();
    expect(screen.queryByText(/requires a restart/i)).toBeNull();
    // The footer reads clean again because the accepted snapshot re-seeded the
    // dirty comparison, so a second untouched save sends nothing new.
    expect(screen.getByTestId("bash-save-hint").textContent).toContain(
      "Only the edited keys travel"
    );
    await user.click(screen.getByTestId("bash-save"));
    await waitFor(() => {
      expect(getPutCount()).toBe(2);
    });
  });

  it("keeps the fresh defaults when the engine omits [bash]", async () => {
    stubSettings({});
    render(<AccessBashSection />);

    await waitFor(() => {
      expect(screen.queryByTestId("bash-loading")).toBeNull();
    });
    // An absent section leaves the form defaults untouched, so an older
    // engine never blanks the editor into an unsaveable shape.
    expect((screen.getByLabelText(/Default action/i) as HTMLSelectElement).value).toBe(
      "ask"
    );
    expect((screen.getByLabelText(/Execution tier/i) as HTMLSelectElement).value).toBe(
      "strictContainer"
    );
    expect(
      (screen.getByLabelText(/Rules, one per line/i) as HTMLTextAreaElement).value
    ).toContain("* = ask");
    expect(screen.queryByTestId("bash-load-error")).toBeNull();
  });
});
