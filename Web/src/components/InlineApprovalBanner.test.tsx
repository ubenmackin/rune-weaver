// Rune Weaver Dashboard — Tests pinning the inline approval banner's
// duration-only allow chevron, deny split, egress mapping, standing-rules
// link, and keyboard contract to the shared duration tiers.

import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import InlineApprovalBanner, {
  isEgressBlocked,
  resolveEgressHost,
} from "./InlineApprovalBanner";
import { durationOptionsFor } from "../approvalsShared";
import { trustDurationOptions, type PermissionRequest } from "../api";

// Explicit per-test DOM teardown: several suites below query generic controls
// ("Allow", "Expected outcome") shared by every banner, so a lingering render
// from an earlier test would make those queries ambiguous or falsely present.
afterEach(() => {
  cleanup();
});

function toolRequest(
  overrides: Partial<PermissionRequest> = {},
): PermissionRequest {
  return {
    id: "app-tool-1",
    toolName: "files.write",
    description: "Write files on disk",
    input: {
      toolName: "files.write",
      argumentsJSON: '{"path":"/tmp/test.txt"}',
      callID: "call-tool-1",
    },
    suggestedDurations: ["thisTime"],
    ...overrides,
  };
}

function egressRequest(
  overrides: Partial<PermissionRequest> = {},
): PermissionRequest {
  return {
    id: "app-egress-1",
    toolName: "web.fetch",
    description: "Fetch web content",
    egressHost: "api.github.com",
    input: {
      toolName: "web.fetch",
      argumentsJSON: '{"url":"https://api.github.com/repos"}',
      callID: "call-egress-1",
    },
    suggestedDurations: ["thisTime"],
    ...overrides,
  };
}

async function openAllowMenu(
  user: ReturnType<typeof userEvent.setup>,
  toolName = "files.write",
) {
  const chevron = screen.getByRole("button", {
    name: `Allow options for ${toolName}`,
  });
  await user.click(chevron);
  return screen.getByRole("menu");
}

async function openDenyMenu(
  user: ReturnType<typeof userEvent.setup>,
  toolName = "files.write",
) {
  const chevron = screen.getByRole("button", {
    name: `Deny options for ${toolName}`,
  });
  await user.click(chevron);
  return screen.getByRole("menu");
}

describe("InlineApprovalBanner allow options", () => {
  it("lists exactly the 7 shared durations for a plain request", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={toolRequest()}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    await openAllowMenu(user);
    const items = screen.getAllByRole("menuitem");
    expect(items).toHaveLength(7);
    expect(items.map((item) => item.textContent)).toEqual(
      trustDurationOptions.map((option) => option.label),
    );
    expect(
      screen.queryByText(/\(all targets\)/),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("menuitem", { name: "For these targets…" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByTestId("inline-scope-app-tool-1"),
    ).not.toBeInTheDocument();
  });

  it("sends duration-only payloads for every one of the 7 quick options", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={toolRequest()}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const chevron = screen.getByRole("button", {
      name: "Allow options for files.write",
    });
    for (const option of trustDurationOptions) {
      await user.click(chevron);
      await user.click(screen.getByRole("menuitem", { name: option.label }));
      // Quick surfaces send duration only: the server resolves the request's
      // own target, so no scope ever rides a banner decision.
      expect(onDecide).toHaveBeenCalledWith(
        "app-tool-1",
        true,
        option.value,
      );
    }
    for (const call of onDecide.mock.calls) {
      expect(call).toHaveLength(3);
    }
  });

  it("sends a one-shot Allow and Deny with no scope", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={toolRequest()}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    await user.click(screen.getByRole("button", { name: "Allow" }));
    expect(onDecide).toHaveBeenCalledWith("app-tool-1", true, "thisTime");

    await user.click(screen.getByRole("button", { name: "Deny" }));
    expect(onDecide).toHaveBeenCalledWith("app-tool-1", false, "thisTime");
    for (const call of onDecide.mock.calls) {
      expect(call).toHaveLength(3);
    }
  });

  it("offers exactly one Deny chevron item that denies forever", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={toolRequest()}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    await openDenyMenu(user);
    const items = screen.getAllByRole("menuitem");
    expect(items).toHaveLength(1);
    await user.click(
      screen.getByRole("menuitem", { name: "Deny always" }),
    );
    expect(onDecide).toHaveBeenCalledWith("app-tool-1", false, "forever");
    expect(onDecide.mock.calls[0]).toHaveLength(3);
  });

  it("links to the standing rules pane after the Deny group", async () => {
    const onDecide = vi.fn();
    render(
      <InlineApprovalBanner
        request={toolRequest()}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const link = screen.getByRole("link", { name: "Manage standing rules" });
    expect(link).toHaveAttribute("href", "#settings?access=rules");
    expect(link.className).toContain("ghost");
    const denyButton = screen.getByRole("button", { name: "Deny" });
    expect(
      Boolean(
        denyButton.compareDocumentPosition(link) &
          Node.DOCUMENT_POSITION_FOLLOWING,
      ),
    ).toBe(true);
  });
});

describe("InlineApprovalBanner continuation approval", () => {
  it("renders continuation banner with Continue and Stop buttons", async () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-cont-1",
      toolName: "engine.continue",
      description: "The agent has completed 10 tool rounds. Continue?",
      input: { toolName: "engine.continue", argumentsJSON: "{}", callID: "c-cont" },
      suggestedDurations: ["thisTime"],
    };

    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText("Continuation")).toBeInTheDocument();
    expect(
      screen.getByText("The agent has completed 10 tool rounds. Continue?"),
    ).toBeInTheDocument();
    const continueBtn = screen.getByRole("button", { name: "Continue" });
    const stopBtn = screen.getByRole("button", { name: "Stop" });
    expect(continueBtn).toBeInTheDocument();
    expect(stopBtn).toBeInTheDocument();

    await user.click(continueBtn);
    expect(onDecide).toHaveBeenCalledWith("app-cont-1", true, "thisTime");

    await user.click(stopBtn);
    expect(onDecide).toHaveBeenCalledWith("app-cont-1", false, "thisTime");
  });
});

describe("InlineApprovalBanner desktop resume approval", () => {
  it("renders desktop paused banner with Resume Control and Cancel Task buttons", async () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-desk-1",
      toolName: "desktop.resume",
      description: "Desktop automation paused because you moved the mouse. Resume control?",
      input: { toolName: "desktop.resume", argumentsJSON: "{}", callID: "c-desk" },
      suggestedDurations: ["thisTime"],
    };

    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText("Desktop Paused")).toBeInTheDocument();
    expect(
      screen.getByText("Desktop automation paused because you moved the mouse. Resume control?"),
    ).toBeInTheDocument();
    const resumeBtn = screen.getByRole("button", { name: "Resume Control" });
    const cancelBtn = screen.getByRole("button", { name: "Cancel Task" });
    expect(resumeBtn).toBeInTheDocument();
    expect(cancelBtn).toBeInTheDocument();

    await user.click(resumeBtn);
    expect(onDecide).toHaveBeenCalledWith("app-desk-1", true, "thisTime");

    await user.click(cancelBtn);
    expect(onDecide).toHaveBeenCalledWith("app-desk-1", false, "thisTime");
  });
});

describe("InlineApprovalBanner one-shot deny", () => {
  it("renders Deny with no Deny always item for a session-tagged brake request", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    const request: PermissionRequest = {
      id: "app-brake-1",
      toolName: "behavior.brake",
      description:
        "Behavior brake engaged: email.send executed 18 times in the trailing hour (baseline 3).",
      sessionID: "sess-chat",
      input: { toolName: "behavior.brake", argumentsJSON: "{}", callID: "c-brake" },
      suggestedDurations: ["thisTime"],
    };

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    // The one-shot deny stays available while the standing deny stays off the
    // card: its durable tier coerces to thisTime and mints no rule.
    expect(screen.getByRole("button", { name: "Deny" })).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Deny options for behavior.brake" }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("menuitem", { name: "Deny always" }),
    ).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Deny" }));
    expect(onDecide).toHaveBeenCalledWith("app-brake-1", false, "thisTime");
    expect(onDecide.mock.calls[0]).toHaveLength(3);
  });
});

describe("InlineApprovalBanner tool approval with intent and assessment", () => {
  it("renders severity badge, intent, outcome, and warnings without tool description", async () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-tool-1",
      toolName: "files.write",
      description: "Write files on disk",
      intent: "Updating deployment config",
      assessment: {
        severity: "moderate",
        outcome: "Writes updated environment variables to .env",
        warnings: ["Overwrites existing .env configuration"],
      },
      input: {
        toolName: "files.write",
        argumentsJSON: '{"path":".env"}',
        callID: "call-1",
      },
      suggestedDurations: ["thisTime"],
    };

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText("files.write")).toBeInTheDocument();
    expect(screen.getByTestId("approval-severity-app-tool-1")).toHaveTextContent("🟡 State Change");
    expect(screen.getByText("Updating deployment config")).toBeInTheDocument();
    expect(
      screen.getByText("Writes updated environment variables to .env"),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/Overwrites existing \.env configuration/),
    ).toBeInTheDocument();
    // Static tool description must NOT be rendered
    expect(screen.queryByText("Write files on disk")).not.toBeInTheDocument();
    // Pending badge must be absent once valued.
    expect(
      screen.queryByTestId("approval-assessment-pending-app-tool-1"),
    ).not.toBeInTheDocument();
  });
});

describe("InlineApprovalBanner pending assessment", () => {
  it("renders pending badge with spinner copy and enabled controls", async () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-pending-1",
      toolName: "email.send",
      description: "Send email to ops",
      intent: "Notifying ops of deploy",
      input: {
        toolName: "email.send",
        argumentsJSON: '{"to":"ops@example.com"}',
        callID: "call-pending-1",
      },
      suggestedDurations: ["thisTime"],
      assessment: null,
    };

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    // Pending badge carries the shared pending testid shape with the request
    // id suffix and the exact pending copy.
    const pending = screen.getByTestId("approval-assessment-pending-app-pending-1");
    expect(pending).toBeInTheDocument();
    expect(pending).toHaveClass("badge");
    expect(pending).toHaveClass("approval-severity-badge");
    expect(pending).toHaveClass("severity-pending");
    expect(pending).toHaveTextContent("Checking safety…");
    // Spinner element shares the stylesheet-owned animation class.
    expect(
      pending.querySelector(
        ".approval-assessment-pending, .approval-assessment-pending-spinner",
      ),
    ).not.toBeNull();
    // Outcome and warnings stay hidden while pending.
    expect(screen.queryByText(/Expected outcome/)).not.toBeInTheDocument();
    expect(screen.queryByText(/⚠️/)).not.toBeInTheDocument();
    // Intent row, arguments disclosure, and live decisions stay available.
    expect(screen.getByText("Notifying ops of deploy")).toBeInTheDocument();
    expect(screen.getByText("View arguments")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeEnabled();
    // Valued badge must be absent while pending.
    expect(
      screen.queryByTestId("approval-severity-app-pending-1"),
    ).not.toBeInTheDocument();
  });

  it("falls back to static description only when nil with description present", async () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-pending-desc",
      toolName: "email.send",
      description: "Send email to ops",
      input: {
        toolName: "email.send",
        argumentsJSON: "{}",
        callID: "call-desc",
      },
      suggestedDurations: ["thisTime"],
      assessment: null,
    };

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    // With no intent and no assessment, the static description is the only
    // narrative available so it renders as the fallback.
    expect(screen.getByText("Send email to ops")).toBeInTheDocument();
    expect(
      screen.getByTestId("approval-assessment-pending-app-pending-desc"),
    ).toBeInTheDocument();
  });

  it("swaps pending for valued assessment on identical id without remounting controls", async () => {
    const onDecide = vi.fn();
    const pendingRequest: PermissionRequest = {
      id: "app-swap-1",
      toolName: "email.send",
      description: "Send email to ops",
      intent: "Notifying ops of deploy",
      input: {
        toolName: "email.send",
        argumentsJSON: '{"to":"ops@example.com"}',
        callID: "call-swap-1",
      },
      suggestedDurations: ["thisTime"],
      assessment: null,
    };
    const valuedRequest: PermissionRequest = {
      ...pendingRequest,
      assessment: {
        severity: "moderate",
        outcome: "Sends deploy notice to ops",
        warnings: ["External recipient"],
      },
    };

    const { rerender } = render(
      <InlineApprovalBanner
        request={pendingRequest}
        deciding={false}
        onDecide={onDecide}
      />,
    );
    expect(
      screen.getByTestId("approval-assessment-pending-app-swap-1"),
    ).toBeInTheDocument();
    const bannerBefore = screen.getByTestId("inline-approval-app-swap-1");
    const allowBefore = screen.getByRole("button", { name: "Allow" });

    // Enrichment for the identical id swaps the copy in place: the banner
    // element and its Allow control persist instead of remounting.
    rerender(
      <InlineApprovalBanner
        request={valuedRequest}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(
      screen.queryByTestId("approval-assessment-pending-app-swap-1"),
    ).not.toBeInTheDocument();
    expect(screen.getByTestId("approval-severity-app-swap-1")).toHaveTextContent(
      "🟡 State Change",
    );
    expect(screen.getByText("Sends deploy notice to ops")).toBeInTheDocument();
    expect(screen.getByText(/External recipient/)).toBeInTheDocument();
    expect(screen.getByTestId("inline-approval-app-swap-1")).toBe(bannerBefore);
    expect(screen.getByRole("button", { name: "Allow" })).toBe(allowBefore);
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Deny" })).toBeEnabled();
    // Static description stays hidden once valued.
    expect(screen.queryByText("Send email to ops")).not.toBeInTheDocument();
  });

  it("renders no badge for unknown severity", async () => {
    const onDecide = vi.fn();
    const request = {
      id: "app-unknown-1",
      toolName: "email.send",
      description: "Send email",
      input: {
        toolName: "email.send",
        argumentsJSON: "{}",
        callID: "call-unknown",
      },
      suggestedDurations: ["thisTime"],
      assessment: {
        severity: "critical",
        outcome: "Does something",
        warnings: [],
      },
    } as unknown as PermissionRequest;

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    // Unknown tiers fail closed with no badge rather than guessing a color,
    // while outcome and decisions stay usable.
    expect(
      screen.queryByTestId("approval-severity-app-unknown-1"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByTestId("approval-assessment-pending-app-unknown-1"),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Does something")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Allow" })).toBeEnabled();
  });
});

describe("InlineApprovalBanner network egress approval", () => {
  it("lists exactly the 3 egress durations with no scope row", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();
    const request = egressRequest();
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const chevronBtn = screen.getByRole("button", {
      name: "Allow options for web.fetch to api.github.com",
    });
    await user.click(chevronBtn);

    const expected = durationOptionsFor(request);
    expect(expected).toHaveLength(3);
    const items = screen.getAllByRole("menuitem");
    expect(items).toHaveLength(3);
    expect(items.map((item) => item.textContent)).toEqual(
      expected.map((option) => option.label),
    );
    expect(
      screen.queryByRole("menuitem", { name: "For these targets…" }),
    ).not.toBeInTheDocument();
    expect(screen.queryByText(/\(all targets\)/)).not.toBeInTheDocument();
  });

  it("renders egress badge and the duration chevron for unlisted domain", async () => {
    const onDecide = vi.fn();
    const request = egressRequest();

    const user = userEvent.setup();
    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText("web.fetch")).toBeInTheDocument();
    expect(screen.getByTestId("approval-egress-app-egress-1")).toHaveTextContent("🌐 api.github.com");
    expect(screen.getByText(/is not in allowlist/)).toBeInTheDocument();

    const allowOnceBtn = screen.getByRole("button", { name: "Allow Once" });
    const denyBtn = screen.getByRole("button", { name: "Deny" });
    expect(allowOnceBtn).toBeInTheDocument();
    expect(denyBtn).toBeInTheDocument();

    // Default Allow Once click
    await user.click(allowOnceBtn);
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", true, "thisTime");

    // Deny click denies the call only
    await user.click(denyBtn);
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", false, "thisTime");

    // Open chevron menu: exactly the three egress durations, no scope row.
    const chevronBtn = screen.getByRole("button", {
      name: "Allow options for web.fetch to api.github.com",
    });
    const expected = durationOptionsFor(request);
    for (const option of expected) {
      await user.click(chevronBtn);
      await user.click(screen.getByRole("menuitem", { name: option.label }));
      expect(onDecide).toHaveBeenCalledWith("app-egress-1", true, option.value);
    }

    // Deny always mints the durable deny through the shared contract.
    const denyChevron = screen.getByRole("button", {
      name: "Deny options for web.fetch to api.github.com",
    });
    await user.click(denyChevron);
    await user.click(screen.getByRole("menuitem", { name: "Deny always" }));
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", false, "forever");

    // Every egress path sent the same single payload — no scope, no tier.
    for (const call of onDecide.mock.calls) {
      expect(call).toHaveLength(3);
    }
  });

  it("reads the egressHost spelling for badge and allowlist copy", () => {
    const onDecide = vi.fn();
    const request = egressRequest({
      id: "app-egress-camel",
      egressHost: "api.github.com",
    });

    expect(resolveEgressHost(request)).toBe("api.github.com");

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(
      screen.getByTestId("approval-egress-app-egress-camel"),
    ).toHaveTextContent("🌐 api.github.com");
    expect(screen.getByText(/is not in allowlist/)).toBeInTheDocument();
    expect(screen.queryByText(/is blocked by policy/)).not.toBeInTheDocument();
  });

  it("names an explicit block instead of an allowlist miss", () => {
    const onDecide = vi.fn();
    const request = {
      id: "app-egress-blocked",
      toolName: "web.fetch",
      description: "Fetch web content",
      egressHost: "denied.example.com",
      egressBlocked: true,
      input: {
        toolName: "web.fetch",
        argumentsJSON: '{"url":"https://denied.example.com/secret"}',
        callID: "call-egress-blocked",
      },
      suggestedDurations: ["thisTime"],
    } as unknown as PermissionRequest;

    expect(isEgressBlocked(request)).toBe(true);

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(
      screen.getByTestId("approval-egress-app-egress-blocked"),
    ).toHaveTextContent("🌐 denied.example.com");
    expect(screen.getByText(/is blocked by policy/)).toBeInTheDocument();
    expect(screen.queryByText(/is not in allowlist/)).not.toBeInTheDocument();
  });

  it("treats a block verdict reason as blocked copy", () => {
    const onDecide = vi.fn();
    const request = {
      id: "app-egress-verdict",
      toolName: "api.request",
      description: "Call external api",
      egressHost: "internal.example.com",
      egressReason: "Blocked by policy: explicit deny rule",
      input: {
        toolName: "api.request",
        argumentsJSON: '{"url":"https://internal.example.com/v1"}',
        callID: "call-egress-verdict",
      },
      suggestedDurations: ["thisTime"],
    } as unknown as PermissionRequest;

    expect(isEgressBlocked(request)).toBe(true);

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText(/is blocked by policy/)).toBeInTheDocument();
    expect(screen.queryByText(/is not in allowlist/)).not.toBeInTheDocument();
  });
});

describe("InlineApprovalBanner split menu keyboard and positioning", () => {
  const positionRequest: PermissionRequest = {
    id: "app-pos-1",
    toolName: "files.write",
    description: "Write files on disk",
    input: { toolName: "files.write", argumentsJSON: '{"path":"/tmp/test.txt"}', callID: "call-pos-1" },
    suggestedDurations: ["thisTime"],
  };

  it("moves focus through every row with arrows, Home, End, and Escape", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();

    render(
      <InlineApprovalBanner
        request={positionRequest}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const chevronBtn = screen.getByRole("button", {
      name: "Allow options for files.write",
    });
    await user.click(chevronBtn);

    // Focus lands on the first choice without an extra tab stop.
    const items = screen.getAllByRole("menuitem");
    expect(items).toHaveLength(7);
    expect(items[0]).toHaveFocus();

    await user.keyboard("{ArrowDown}");
    expect(items[1]).toHaveFocus();

    await user.keyboard("{ArrowUp}");
    expect(items[0]).toHaveFocus();

    // Arrow up from the first row wraps to the last duration row.
    await user.keyboard("{ArrowUp}");
    expect(items[items.length - 1]).toHaveFocus();

    await user.keyboard("{ArrowDown}");
    expect(items[0]).toHaveFocus();

    await user.keyboard("{End}");
    expect(items[items.length - 1]).toHaveFocus();
    expect(items[items.length - 1]).toHaveTextContent("Forever");

    await user.keyboard("{Home}");
    expect(items[0]).toHaveFocus();

    // Escape closes and returns focus to the chevron.
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(chevronBtn).toHaveFocus();
    expect(onDecide).not.toHaveBeenCalled();
  });

  it("closes the deny menu on Escape and returns focus to its chevron", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();

    render(
      <InlineApprovalBanner
        request={positionRequest}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    const denyChevron = screen.getByRole("button", {
      name: "Deny options for files.write",
    });
    await user.click(denyChevron);
    expect(screen.getAllByRole("menuitem")).toHaveLength(1);

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(denyChevron).toHaveFocus();
    expect(onDecide).not.toHaveBeenCalled();
  });

  it("renders upward with split-allow-menu-up class when menuPlacement='up'", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();

    render(
      <InlineApprovalBanner
        request={positionRequest}
        deciding={false}
        onDecide={onDecide}
        menuPlacement="up"
      />,
    );

    const chevronBtn = screen.getByRole("button", {
      name: "Allow options for files.write",
    });
    await user.click(chevronBtn);

    const menu = screen.getByRole("menu");
    expect(menu).toHaveClass("split-allow-menu-up");
    expect(menu).toHaveAttribute("data-placement", "top");

    // Option clicking works as expected
    const optionBtn = screen.getByRole("menuitem", { name: "Next hour" });
    await user.click(optionBtn);
    expect(onDecide).toHaveBeenCalledWith("app-pos-1", true, "oneHour");
    expect(onDecide.mock.calls[0]).toHaveLength(3);
  });

  it("renders downward with data-placement='bottom' when menuPlacement='down'", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();

    render(
      <InlineApprovalBanner
        request={positionRequest}
        deciding={false}
        onDecide={onDecide}
        menuPlacement="down"
      />,
    );

    const chevronBtn = screen.getByRole("button", {
      name: "Allow options for files.write",
    });
    await user.click(chevronBtn);

    const menu = screen.getByRole("menu");
    expect(menu).not.toHaveClass("split-allow-menu-up");
    expect(menu).toHaveAttribute("data-placement", "bottom");
  });

  it("dynamically flips upward when space below is constrained", async () => {
    const onDecide = vi.fn();
    const user = userEvent.setup();

    // Mock getBoundingClientRect so anchor is near bottom of viewport
    vi.spyOn(Element.prototype, "getBoundingClientRect").mockReturnValue({
      top: 600,
      bottom: 640,
      left: 100,
      right: 300,
      width: 200,
      height: 40,
      x: 100,
      y: 600,
      toJSON: () => {},
    });

    // Window height 700 -> spaceBelow = 700 - 640 = 60 (< 320), spaceAbove = 600 (> 60)
    const originalInnerHeight = window.innerHeight;
    Object.defineProperty(window, "innerHeight", {
      writable: true,
      configurable: true,
      value: 700,
    });

    try {
      render(
        <InlineApprovalBanner
          request={positionRequest}
          deciding={false}
          onDecide={onDecide}
          menuPlacement="auto"
        />,
      );

      const chevronBtn = screen.getByRole("button", {
        name: "Allow options for files.write",
      });
      await user.click(chevronBtn);

      const menu = screen.getByRole("menu");
      expect(menu).toHaveClass("split-allow-menu-up");
      expect(menu).toHaveAttribute("data-placement", "top");
    } finally {
      Object.defineProperty(window, "innerHeight", {
        writable: true,
        configurable: true,
        value: originalInnerHeight,
      });
      vi.restoreAllMocks();
    }
  });
});

describe("InlineApprovalBanner sandbox tier line", () => {
  it("renders the verbatim tier line beneath Expected outcome", () => {
    const onDecide = vi.fn();
    const summary =
      "Runs in a temporary container with no internet access. Nothing is kept after the run.";
    const outcome = "Lists files in /tmp without changing anything";
    const request: PermissionRequest = {
      id: "app-tier-1",
      toolName: "bash.exec",
      description: "Run shell command",
      intent: "Listing temp files",
      assessment: {
        severity: "moderate",
        outcome,
        warnings: [],
      },
      sandboxSummary: summary,
      input: {
        toolName: "bash.exec",
        argumentsJSON: '{"command":"ls /tmp"}',
        callID: "call-tier-1",
      },
      suggestedDurations: ["thisTime"],
    };

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText(outcome)).toBeInTheDocument();
    const tier = screen.getByTestId("bash-tier-line");
    expect(tier.textContent).toBe(summary);
    const outcomeLabel = screen.getByText(/Expected outcome:/);
    expect(
      Boolean(
        outcomeLabel.compareDocumentPosition(tier) &
          Node.DOCUMENT_POSITION_FOLLOWING,
      ),
    ).toBe(true);
  });

  it("renders nothing when the sandbox summary is absent", () => {
    const onDecide = vi.fn();
    const outcome = "Writes updated environment variables to .env";
    const request: PermissionRequest = {
      id: "app-tier-2",
      toolName: "files.write",
      description: "Write files on disk",
      intent: "Updating deployment config",
      assessment: {
        severity: "moderate",
        outcome,
        warnings: [],
      },
      input: {
        toolName: "files.write",
        argumentsJSON: '{"path":".env"}',
        callID: "call-tier-2",
      },
      suggestedDurations: ["thisTime"],
    };

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(screen.getByText(outcome)).toBeInTheDocument();
    expect(screen.queryByTestId("bash-tier-line")).not.toBeInTheDocument();
  });
});
