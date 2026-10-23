// Rune Weaver Dashboard — Access per-section Advanced coverage: isolation,
// auto-expand, and single-card containment.
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import AccessPane from "../AccessPane";
import {
  clearAuthToken,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS,
} from "../../api";
import { jsonResponse } from "../../test-utils/http";
import { normalizeWritePathRules } from "../settings/settingsAdvancedCounts";

const storedSettings = {
  configPath: "/tmp/config.toml",
  engineName: "gemma-4-9b",
  logLevel: "info",
  bash: {
    enabled: true,
    defaultAction: "ask",
    rules: [{ pattern: "*", action: "ask" }],
    timeoutSeconds: 30,
    cpuSeconds: 120,
    memoryMb: 1024,
    allowNetwork: false,
    sandboxMode: "strictContainer",
    hostAllowPatterns: [...DEFAULT_BASH_HOST_ALLOW_PATTERNS],
  },
  filesWriteMode: "model",
  filesWritePathRules: [
    { path: "~/Documents", posture: "stage" },
    { path: "~/Secrets", posture: "deny" },
  ],
  filesDenyPatterns: [".env*", ".ssh/*"],
  filesAllowRoots: ["~"],
  filesRequireApprovalOnDeny: true,
};

function stubSettings() {
  const puts: Record<string, unknown>[] = [];
  const fetchMock = vi.fn(
    async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const path = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      if (path === "/approvals/rules" && method === "GET") {
        return jsonResponse({ rules: [], count: 0 });
      }
      if (path === "/settings" && method === "PUT") {
        const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
        puts.push(body);
        const bashBody =
          body.bash && typeof body.bash === "object"
            ? (body.bash as Record<string, unknown>)
            : {};
        return jsonResponse({
          ...storedSettings,
          ...body,
          bash: { ...storedSettings.bash, ...bashBody },
        });
      }
      if (path === "/settings") {
        return jsonResponse(storedSettings);
      }
      return jsonResponse({});
    }
  );
  vi.stubGlobal("fetch", fetchMock);
  return { puts, fetchMock };
}

async function waitForBashLoaded() {
  await waitFor(() => {
    expect(
      (screen.getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement).value
    ).toBe("30");
  });
}

describe("access advanced normalization", () => {
  it("normalizes unknown postures closed", () => {
    expect(
      normalizeWritePathRules([
        { path: "  ~/Documents  ", posture: "widen" },
        { path: 7, posture: "stage" },
      ])
    ).toEqual([{ path: "~/Documents", posture: "ask" }]);
  });
});

describe("AccessPane advanced sections", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.history.replaceState(null, "", "/settings");
  });

  it("keeps each Advanced panel inside its own settings card above the footer", async () => {
    stubSettings();
    render(<AccessPane initialSection="bash" />);

    await waitForBashLoaded();
    const bashDetails = screen.getByTestId("advanced-bash");
    expect(bashDetails.closest("section")).toBe(screen.getByTestId("bash-pane"));
    expect(screen.getByTestId("advanced-bash-trigger").textContent).toBe(
      "Advanced Bash settings"
    );
    expect(screen.queryByTestId("advanced-bash-chip")).toBeNull();

    const user = userEvent.setup();
    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(screen.getByTestId("files-access-pane")).toBeInTheDocument();
    });
    const filesDetails = screen.getByTestId("advanced-files");
    expect(filesDetails.closest("section")).toBe(
      screen.getByTestId("files-access-pane")
    );
    expect(screen.getByTestId("advanced-files-trigger").textContent).toBe(
      "Advanced Files settings"
    );
    expect(screen.queryByTestId("advanced-files-chip")).toBeNull();
  });

  it("saves only Bash keys and keeps a static trigger", async () => {
    const { puts } = stubSettings();
    const user = userEvent.setup();
    render(<AccessPane initialSection="bash" />);

    await waitForBashLoaded();
    const details = screen.getByTestId("advanced-bash");
    const timeout = within(details).getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement;
    await user.clear(timeout);
    await user.type(timeout, "45");

    expect(screen.getByTestId("advanced-bash-trigger").textContent).toBe(
      "Advanced Bash settings"
    );

    await user.click(screen.getByTestId("bash-save"));
    await waitFor(() => {
      expect(puts.length).toBe(1);
    });
    expect(Object.keys(puts[0])).toEqual(["bash"]);
    expect(puts[0]["bash"]).toEqual({ timeoutSeconds: 45 });
    expect(screen.getByTestId("advanced-bash-trigger").textContent).toBe(
      "Advanced Bash settings"
    );
  });

  it("auto-expands the collapsed Bash panel and focuses its validation link", async () => {
    const { puts } = stubSettings();
    const user = userEvent.setup();
    render(<AccessPane initialSection="bash" />);

    await waitForBashLoaded();
    const details = screen.getByTestId("advanced-bash") as HTMLDetailsElement;
    expect(details.open).toBe(false);
    const timeout = within(details).getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement;
    await user.clear(timeout);
    await user.type(timeout, "0");
    await user.click(screen.getByTestId("bash-save"));

    await waitFor(() => {
      expect(details.open).toBe(true);
    });
    expect(screen.getByTestId("advanced-bash-error").textContent).toContain(
      "Invalid bash timeout"
    );
    await waitFor(() => {
      expect(document.activeElement?.id).toBe("advanced-bash-error");
    });
    expect(puts.length).toBe(0);
  });

  it("keeps Bash and Files drafts isolated across tabs and resets only the active section", async () => {
    stubSettings();
    const user = userEvent.setup();
    render(<AccessPane initialSection="bash" />);

    await waitForBashLoaded();
    const bashDetails = screen.getByTestId("advanced-bash");
    const timeout = within(bashDetails).getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement;
    await user.clear(timeout);
    await user.type(timeout, "45");

    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(screen.getByTestId("files-access-pane")).toBeInTheDocument();
    });
    const filesDetails = screen.getByTestId("advanced-files");
    await waitFor(() => {
      expect(
        (
          within(filesDetails).getByLabelText(
            /Deny patterns, one per line/i
          ) as HTMLTextAreaElement
        ).value
      ).toBe(".env*\n.ssh/*");
    });
    const deny = within(filesDetails).getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(deny);
    await user.type(deny, ".env*\n.custom");

    await user.click(screen.getByTestId("access-tab-bash"));
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement).value
      ).toBe("45");
    });
    expect(screen.getByTestId("advanced-bash-trigger").textContent).toBe(
      "Advanced Bash settings"
    );

    await user.click(screen.getByTestId("advanced-bash-trigger"));
    await waitFor(() => {
      expect(
        (screen.getByTestId("advanced-bash") as HTMLDetailsElement).open
      ).toBe(true);
    });
    await user.click(screen.getByTestId("advanced-bash-reset"));
    expect(
      (screen.getByLabelText(/Timeout \(seconds\)/i) as HTMLInputElement).value
    ).toBe("30");
    expect(screen.getByTestId("advanced-bash-trigger").textContent).toBe(
      "Advanced Bash settings"
    );

    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Deny patterns, one per line/i) as HTMLTextAreaElement)
          .value
      ).toBe(".env*\n.custom");
    });
    expect(screen.getByTestId("advanced-files-trigger").textContent).toBe(
      "Advanced Files settings"
    );
  });

  it("saves Files Advanced rules plus deny in one payload without leaking Bash keys", async () => {
    const { puts } = stubSettings();
    const user = userEvent.setup();
    render(<AccessPane initialSection="files" />);

    await waitFor(() => {
      expect(screen.getByTestId("files-access-pane")).toBeInTheDocument();
    });
    const details = screen.getByTestId("advanced-files");
    await waitFor(() => {
      expect(
        (
          within(details).getByLabelText(
            /Deny patterns, one per line/i
          ) as HTMLTextAreaElement
        ).value
      ).toBe(".env*\n.ssh/*");
    });
    const deny = within(details).getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(deny);
    await user.type(deny, ".env*\n.custom");

    await user.click(screen.getByTestId("files-write-save"));
    await waitFor(() => {
      expect(puts.length).toBe(1);
    });
    expect(Object.keys(puts[0])).toEqual(["filesDenyPatterns"]);
    expect(puts[0]["filesDenyPatterns"]).toEqual([".env*", ".custom"]);
    expect(screen.getByTestId("advanced-files-trigger").textContent).toBe(
      "Advanced Files settings"
    );
  });
});
