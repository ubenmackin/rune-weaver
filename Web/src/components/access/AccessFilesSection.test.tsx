// Rune Weaver Dashboard — Component tests for the access Files write-posture section.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AccessFilesSection } from "./AccessFilesSection";
import { useAccessFilesAdvanced } from "./useAccessAdvanced";
import { clearAuthToken } from "../../api";
import { jsonResponse } from "../../test-utils/http";

// Single-path harness: the section renders only via simpleOnly plus the
// pane-level Advanced hook, so one card holds Advanced above its footer.
function FilesSectionHarness() {
  const advanced = useAccessFilesAdvanced();
  return <AccessFilesSection simpleOnly advanced={advanced} />;
}

// Seed snapshot mirroring the engine GET shape: the forced posture plus the
// ordered rule list on the camelCase DTO keys. The deeper rule carries deny so
// the lock behavior is exercised by the stored shape.
const storedWriteSettings = {
  filesWriteMode: "staged",
  filesWritePathRules: [
    { path: "~/Documents", posture: "stage" },
    { path: "~/Documents/Secrets", posture: "deny" },
  ],
};

// Builds a rule list at the engine bound by repeating a single path template,
// so the row count is the only variable under test.
function rulesAtBound(count: number): Array<{ path: string; posture: string }> {
  return Array.from({ length: count }, (_, index) => ({
    path: `~/Documents/Rule-${index}`,
    posture: "stage",
  }));
}

describe("AccessFilesSection", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  // Routes the settings GET plus the files PUT so each case overrides only the response it
  // exercises.
  function stubSettings(
    files: Record<string, unknown>,
    onPut?: (body: Record<string, unknown>) => Response
  ) {
    const settings = { ...files };
    const puts: Record<string, unknown>[] = [];
    const fetchMock = vi.fn(
      async (
        url: string | URL | Request,
        init?: RequestInit
      ): Promise<Response> => {
        const urlStr = String(url);
        if (
          urlStr === "/settings" &&
          (init?.method ?? "GET").toUpperCase() === "PUT"
        ) {
          const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
          puts.push(body);
          if (onPut) return onPut(body);
          return jsonResponse({ ...settings, ...body });
        }
        return jsonResponse(settings);
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    return { puts, getPutCount: () => puts.length };
  }

  // Waits for the snapshot to land: the first row proves the [files] section
  // arrived instead of the fresh-form defaults.
  async function waitForSectionLoaded() {
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Rule 1 path/i) as HTMLInputElement).value
      ).toBe("~/Documents");
    });
  }

  it("loads the [files] write snapshot into both editors", async () => {
    stubSettings(storedWriteSettings);
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    expect(
      (screen.getByLabelText(/Always stage for review/i) as HTMLInputElement)
        .checked
    ).toBe(true);
    expect(
      (screen.getByLabelText(/Rule 2 posture/i) as HTMLSelectElement).value
    ).toBe("deny");
    expect(screen.getByLabelText(/Rule 2 path/i)).toBeDefined();
    // Bounds ride the form so the owner reads the engine limit before typing.
    expect(screen.getByTestId("adv-files-write-rules-bounds").textContent).toContain(
      "Up to 50 rules, each path up to 1024 characters"
    );
    expect(screen.getByTestId("files-write-save-hint").textContent).toContain(
      "Only the edited keys travel"
    );
    // Editing one field flips the hint without touching the stored patch.
    const user = userEvent.setup();
    await user.clear(screen.getByLabelText(/Rule 1 path/i));
    await user.type(screen.getByLabelText(/Rule 1 path/i), "~/Documents/Work");
    expect(screen.getByTestId("files-write-save-hint").textContent).toContain(
      "Unsaved changes"
    );
  });

  it("saves the mode and the rule list in one payload", async () => {
    const { puts, getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    await user.click(screen.getByLabelText(/Always write live/i));
    await user.clear(screen.getByLabelText(/Rule 1 path/i));
    await user.type(screen.getByLabelText(/Rule 1 path/i), "~/Documents/Work");
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    // The posture and the rules travel together on one flat [files] payload,
    // with the untouched deny row carried as loaded.
    expect(Object.keys(puts[0]).sort()).toEqual([
      "filesWriteMode",
      "filesWritePathRules",
    ]);
    expect(puts[0]["filesWriteMode"]).toBe("live");
    expect(puts[0]["filesWritePathRules"]).toEqual([
      { path: "~/Documents/Work", posture: "stage" },
      { path: "~/Documents/Secrets", posture: "deny" },
    ]);
  });

  it("saves an unedited form as an empty changed-only payload", async () => {
    const { puts, getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    // A form the owner never touched sends nothing, so every stored [files]
    // value survives, including the access keys this section never owns.
    expect(Object.keys(puts[0])).toEqual([]);
  });

  it("sends the trimmed rule path with the closed posture", async () => {
    const { puts, getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    // Surrounding whitespace never reaches the file, and the posture rides the
    // closed token the engine validates.
    await user.clear(screen.getByLabelText(/Rule 1 path/i));
    await user.type(screen.getByLabelText(/Rule 1 path/i), "  ~/Documents/Work  ");
    await user.selectOptions(screen.getByLabelText(/Rule 1 posture/i), "ask");
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    expect(puts[0]["filesWritePathRules"]).toEqual([
      { path: "~/Documents/Work", posture: "ask" },
      { path: "~/Documents/Secrets", posture: "deny" },
    ]);
    expect(puts[0]["filesWriteMode"]).toBeUndefined();
  });

  it("adds and removes rows while keeping the declared order", async () => {
    const { puts, getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    await user.click(screen.getByRole("button", { name: /Add Rule/i }));
    const addedPath = screen.getByLabelText(/Rule 3 path/i) as HTMLInputElement;
    await user.type(addedPath, "~/Documents/Work");
    // A fresh row starts at the approval posture so a half-typed path never
    // widens write authority while the owner is still entering it.
    expect(
      (screen.getByLabelText(/Rule 3 posture/i) as HTMLSelectElement).value
    ).toBe("ask");
    await user.click(screen.getByLabelText(/Remove rule 2/i));
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    expect(puts[0]["filesWritePathRules"]).toEqual([
      { path: "~/Documents", posture: "stage" },
      { path: "~/Documents/Work", posture: "ask" },
    ]);
  });

  it("locks a deny row against a softer posture", async () => {
    const { puts, getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    const denyPosture = screen.getByLabelText(
      /Rule 2 posture/i
    ) as HTMLSelectElement;
    // The select is inert, so the UI offers no click that softens the refusal.
    expect(denyPosture.disabled).toBe(true);
    expect(denyPosture.value).toBe("deny");
    expect(screen.getByTestId("adv-files-write-rule-1-lock").textContent).toContain(
      "Deny is locked"
    );

    // Editing a sibling row still carries the refusal as loaded, so no UI path
    // can smuggle a softened posture onto the deny row.
    await user.selectOptions(screen.getByLabelText(/Rule 1 posture/i), "ask");
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    const savedRules = puts[0]["filesWritePathRules"] as Array<{
      path: string;
      posture: string;
    }>;
    expect(savedRules[0]).toEqual({ path: "~/Documents", posture: "ask" });
    expect(savedRules[1]).toEqual({
      path: "~/Documents/Secrets",
      posture: "deny",
    });
  });

  it("renders the posture consequence per row and follows the select", async () => {
    stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    expect(
      screen.getByTestId("adv-files-write-rule-0-consequence").textContent
    ).toBe("Writes wait in Staged Changes for your decision; nothing lands without review.");
    expect(
      screen.getByTestId("adv-files-write-rule-1-consequence").textContent
    ).toContain(
      "Writes are refused outright, whatever the rest of the policy would allow."
    );

    await user.selectOptions(screen.getByLabelText(/Rule 1 posture/i), "ask");
    expect(
      screen.getByTestId("adv-files-write-rule-0-consequence").textContent
    ).toBe("Writes park an approval request before anything is written to disk.");
  });

  it("locks Add Rule once the table sits at the engine bound", async () => {
    const files = { ...storedWriteSettings, filesWritePathRules: rulesAtBound(50) };
    stubSettings(files);
    render(<FilesSectionHarness />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Rule 50 path/i)).toBeDefined();
    });
    // Add locks at the bound so the UI cannot grow the list past the engine
    // limit in the first place.
    expect(screen.getByRole("button", { name: /Add Rule/i })).toHaveProperty(
      "disabled",
      true
    );
  });

  it("refuses a rule list past the engine bound before any network write", async () => {
    // A list that drifted past the bound (a hand-edited config) still fails
    // closed in the form instead of surfacing a server 400.
    const files = {
      ...storedWriteSettings,
      filesWritePathRules: rulesAtBound(51),
    };
    const { getPutCount } = stubSettings(files);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitFor(() => {
      expect(screen.getByLabelText(/Rule 51 path/i)).toBeDefined();
    });
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(
        screen.getByText(/at most 50 entries \(got 51\)/i)
      ).toBeDefined();
    });
    expect(getPutCount()).toBe(0);
  });

  it("enforces the rule path length before any network write", async () => {
    const { getPutCount } = stubSettings(storedWriteSettings);
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    // Fire the change directly: typing a 1025-character path one keystroke at a
    // time proves nothing about the bound that a paste cannot.
    const overlong = `~/${"x".repeat(1100)}`;
    fireEvent.change(screen.getByLabelText(/Rule 1 path/i), {
      target: { value: overlong },
    });
    fireEvent.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(
        screen.getByText(/Rule 1 path must be at most 1024 characters/i)
      ).toBeDefined();
    });
    expect(getPutCount()).toBe(0);
  });

  it("rejects a blank or relative rule path in the form", async () => {
    const { getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    // A blank row is not a rule, so clearing a path fails closed rather than
    // saving a path that matches nothing.
    await user.clear(screen.getByLabelText(/Rule 1 path/i));
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(
        screen.getByText(/Rule 1 path must not be blank/i)
      ).toBeDefined();
    });
    expect(getPutCount()).toBe(0);

    // A bare relative path refuses because the engine cannot bound it against
    // the directory the process happened to stand in.
    await user.type(screen.getByLabelText(/Rule 1 path/i), "Documents/Work");
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(
        screen.getByText(/must be ~, start with ~\/, or be an absolute path/i)
      ).toBeDefined();
    });
    expect(getPutCount()).toBe(0);
  });

  it("signals live apply with no restart after a save", async () => {
    const { getPutCount } = stubSettings(storedWriteSettings);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    await user.click(screen.getByLabelText(/Always write live/i));
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(screen.getByTestId("files-write-saved")).toBeDefined();
    });
    expect(screen.getByTestId("files-write-saved").textContent).toBe(
      "File write settings saved. Changes apply immediately with no restart."
    );
    expect(screen.queryByText(/Restart required/i)).toBeNull();
    expect(screen.queryByText(/requires a restart/i)).toBeNull();
    // The footer reads clean again because the accepted snapshot re-seeded the
    // dirty comparison, so a second untouched save sends only the echo.
    expect(screen.getByTestId("files-write-save-hint").textContent).toContain(
      "Only the edited keys travel"
    );
    await user.click(screen.getByTestId("files-write-save"));
    await waitFor(() => {
      expect(getPutCount()).toBe(2);
    });
  });

  it("maps a server 400 to the inline error path without discarding the draft", async () => {
    const serverReason =
      "files.write_paths.posture must be live, stage, ask, or deny";
    const { getPutCount } = stubSettings(storedWriteSettings, () =>
      jsonResponse({ reason: serverReason }, 400)
    );
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitForSectionLoaded();
    await user.clear(screen.getByLabelText(/Rule 1 path/i));
    await user.type(screen.getByLabelText(/Rule 1 path/i), "~/Documents/Work");
    await user.click(screen.getByTestId("files-write-save"));

    // The honest server message surfaces inline while the editor stays open
    // for repair instead of closing on a generic failure.
    await waitFor(() => {
      expect(screen.getByText(serverReason)).toBeDefined();
    });
    expect(getPutCount()).toBe(1);
    expect(screen.queryByTestId("files-write-saved")).toBeNull();
    expect(screen.getByTestId("files-access-pane")).toBeDefined();
    // The edited path survives the refused save.
    expect((screen.getByLabelText(/Rule 1 path/i) as HTMLInputElement).value).toBe(
      "~/Documents/Work"
    );
  });

  it("keeps the documented rule defaults when the engine omits the list", async () => {
    stubSettings({ filesWriteMode: "model" });
    render(<FilesSectionHarness />);

    await waitFor(() => {
      expect(screen.queryByTestId("files-write-loading")).toBeNull();
    });
    // An absent list seeds the documented per-path defaults so an older engine
    // never blanks the editor into an unsaveable shape, and the posture falls
    // back to the model posture rather than an unknown radio selection.
    expect(
      (screen.getByLabelText(/Let the model decide/i) as HTMLInputElement).checked
    ).toBe(true);
    expect((screen.getByLabelText(/Rule 1 path/i) as HTMLInputElement).value).toBe(
      "~/Library"
    );
    expect(
      (screen.getByLabelText(/Rule 5 path/i) as HTMLInputElement).value
    ).toBe("~/Downloads");
    expect(screen.queryByTestId("files-write-load-error")).toBeNull();
  });

  it("ignores a snake_case rule spelling and uses defaults", async () => {
    const files = {
      filesWriteMode: "live",
      files_write_path_rules: [{ path: "~/Notes", posture: "live" }],
    };
    const { puts, getPutCount } = stubSettings(files);
    const user = userEvent.setup();
    render(<FilesSectionHarness />);

    await waitFor(() => {
      expect((screen.getByLabelText(/Rule 1 path/i) as HTMLInputElement).value).toBe(
        "~/Library"
      );
    });
    expect(
      (screen.getByLabelText(/Rule 1 posture/i) as HTMLSelectElement).value
    ).toBe("ask");

    // Whatever spelling arrived, the save always encodes the camelCase DTO key.
    await user.clear(screen.getByLabelText(/Rule 1 path/i));
    await user.type(screen.getByLabelText(/Rule 1 path/i), "~/Notes/Live");
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(getPutCount()).toBe(1);
    });
    expect(puts[0]["filesWritePathRules"]).toEqual([
      { path: "~/Notes/Live", posture: "ask" },
      { path: "~/Photos", posture: "ask" },
      { path: "~/Documents", posture: "stage" },
      { path: "~/Desktop", posture: "stage" },
      { path: "~/Downloads", posture: "stage" },
    ]);
    expect(puts[0]["files_write_path_rules"]).toBeUndefined();
  });
});
