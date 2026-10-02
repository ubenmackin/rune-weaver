// Rune Weaver Dashboard — Tests pinning the inline approval banner's allow
// options to the shared trust-duration tiers.

import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import InlineApprovalBanner, {
  isEgressBlocked,
  resolveEgressHost,
  splitAllowOptions,
} from "./InlineApprovalBanner";
import { trustDurationOptions, type PermissionRequest } from "../api";

// Explicit per-test DOM teardown: several suites below query generic controls
// ("Allow", "Expected outcome") shared by every banner, so a lingering render
// from an earlier test would make those queries ambiguous or falsely present.
afterEach(() => {
  cleanup();
});

describe("InlineApprovalBanner allow options", () => {
  it("mirrors every shared trust duration in the base option set", () => {
    const base = splitAllowOptions.filter((option) => !option.widen);
    // Base values and labels must come from trustDurationOptions verbatim so a
    // new or renamed tier can never be omitted from the inline banner while
    // the inbox and engine still offer it.
    expect(base.map((option) => option.value)).toEqual(
      trustDurationOptions.map((option) => option.value),
    );
    for (const tier of trustDurationOptions) {
      expect(base.find((option) => option.value === tier.value)?.label).toBe(
        tier.label,
      );
    }
  });

  it("offers an all-targets variant for every non-one-shot tier", () => {
    const widen = splitAllowOptions.filter((option) => option.widen);
    // The one-shot `thisTime` grant persists nothing, so it must never appear
    // as a widenable option; every other tier gets exactly one widen variant.
    const expected = trustDurationOptions.filter(
      (option) => option.value !== "thisTime",
    );
    expect(widen.map((option) => option.value)).toEqual(
      expected.map((option) => option.value),
    );
    for (const tier of expected) {
      expect(widen.find((option) => option.value === tier.value)?.label).toBe(
        `${tier.label} (all targets)`,
      );
    }
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
    expect(onDecide).toHaveBeenCalledWith("app-cont-1", true, "thisTime", false);

    await user.click(stopBtn);
    expect(onDecide).toHaveBeenCalledWith("app-cont-1", false, "thisTime", false);
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
  it("renders egress badge and 5-tier split combo for unlisted domain", async () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
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
    };

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
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", true, "thisTime", false, "allowOnce");

    // Deny click
    await user.click(denyBtn);
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", false, "thisTime", false, "deny");

    // Open chevron menu
    const chevronBtn = screen.getByRole("button", {
      name: "Allow options for web.fetch to api.github.com",
    });
    await user.click(chevronBtn);

    expect(screen.getByRole("menuitem", { name: "Allow Once" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Allow During Session" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Always Allow" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Deny Always" })).toBeInTheDocument();

    // Each pick closes the menu, so the remaining tiers reopen the chevron.
    // Session picks must keep the thisTime duration while carrying their tier.
    await user.click(screen.getByRole("menuitem", { name: "Allow During Session" }));
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", true, "thisTime", false, "allowSession");

    // Reopen and pick Always Allow
    await user.click(chevronBtn);
    await user.click(screen.getByRole("menuitem", { name: "Always Allow" }));
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", true, "forever", false, "alwaysAllow");

    // Reopen and pick Deny Always
    await user.click(chevronBtn);
    await user.click(screen.getByRole("menuitem", { name: "Deny Always" }));
    expect(onDecide).toHaveBeenCalledWith("app-egress-1", false, "forever", false, "denyAlways");
  });

  it("reads the snake_case egress_host spelling for badge and allowlist copy", () => {
    const onDecide = vi.fn();
    const request: PermissionRequest = {
      id: "app-egress-snake",
      toolName: "web.fetch",
      description: "Fetch web content",
      egress_host: "api.github.com",
      input: {
        toolName: "web.fetch",
        argumentsJSON: '{"url":"https://api.github.com/repos"}',
        callID: "call-egress-snake",
      },
      suggestedDurations: ["thisTime"],
    };

    expect(resolveEgressHost(request)).toBe("api.github.com");

    render(
      <InlineApprovalBanner
        request={request}
        deciding={false}
        onDecide={onDecide}
      />,
    );

    expect(
      screen.getByTestId("approval-egress-app-egress-snake"),
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

