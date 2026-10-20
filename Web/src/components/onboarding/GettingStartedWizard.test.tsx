// Rune Weaver Dashboard — Onboarding wizard step order, skip, and resume tests.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import GettingStartedWizard from "./GettingStartedWizard";
import { WIZARD_STEPS, isSkipped, nextStep } from "./wizardState";
import { jsonResponse } from "../../test-utils/http";

function stubFetch(handler: (input: string, init?: RequestInit) => Promise<Response>): void {
  vi.stubGlobal("fetch", vi.fn(handler));
}

beforeEach(() => {
  vi.unstubAllGlobals();
  window.history.pushState({}, "", "/");
});

describe("wizardState step order", () => {
  it("keeps the canonical four-step order", () => {
    expect(WIZARD_STEPS).toEqual(["brain", "persona", "connect", "protect"]);
  });

  it("advances through unskipped steps and ends after protect", () => {
    expect(nextStep("brain", [])).toBe("persona");
    expect(nextStep("persona", [])).toBe("connect");
    expect(nextStep("connect", [])).toBe("protect");
    expect(nextStep("protect", [])).toBeNull();
  });

  it("jumps over skipped steps", () => {
    expect(nextStep("brain", ["persona"])).toBe("connect");
    expect(nextStep("brain", ["persona", "connect"])).toBe("protect");
    expect(nextStep("connect", ["protect"])).toBeNull();
  });

  it("reports skipped membership", () => {
    expect(isSkipped("brain", ["brain"])).toBe(true);
    expect(isSkipped("persona", ["brain"])).toBe(false);
  });
});

describe("GettingStartedWizard progress", () => {
  it("labels every step Step N of 4 with no hidden fifth step", async () => {
    const user = userEvent.setup();
    stubFetch(async () => jsonResponse({ ok: true }));
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 1 of 4");
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 2 of 4");
    });
    await user.type(screen.getByTestId("persona-assistant-name"), "Rune Weaver");
    await user.type(screen.getByTestId("persona-user-name"), "Ada");
    await user.click(screen.getByTestId("persona-goal-inbox"));
    await user.click(screen.getByTestId("persona-next"));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 3 of 4");
    });
    await user.click(screen.getByRole("button", { name: "Next" }));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 4 of 4");
    });
    expect(screen.queryByText(/Step 5 of/)).toBeNull();
  });

  it("shows Back on steps 2 through 4 and preserves entered values", async () => {
    const user = userEvent.setup();
    stubFetch(async () => jsonResponse({ ok: true }));
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    expect(screen.queryByRole("button", { name: "Back" })).toBeNull();
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 2 of 4");
    });
    expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument();
    await user.type(screen.getByTestId("persona-assistant-name"), "Test Assistant");
    await user.type(screen.getByTestId("persona-user-name"), "Ada");
    await user.click(screen.getByTestId("persona-goal-inbox"));
    await user.click(screen.getByTestId("persona-next"));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 3 of 4");
    });
    await user.click(screen.getByRole("button", { name: "Back" }));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 2 of 4");
    });
    expect(screen.getByTestId("persona-assistant-name")).toHaveValue("Test Assistant");
  });
});

describe("GettingStartedWizard skip and resume", () => {
  it("persists Skip for now and advances to the next step", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (input: string) => {
      if (typeof input === "string" && input.includes("/onboarding/skip")) {
        return jsonResponse({ skipped_steps: ["brain"] });
      }
      return jsonResponse({ ok: true });
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await user.click(screen.getByRole("button", { name: "Skip for now" }));
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining("/onboarding/skip"),
        expect.objectContaining({ method: "POST" }),
      );
    });
    const [, init] = fetchMock.mock.calls.find(([url]) =>
      String(url).includes("/onboarding/skip"),
    ) as unknown as [string, RequestInit];
    expect(String(init.body)).toContain("brain");
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 2 of 4");
    });
  });

  it("resumes at the first incomplete step from server skipped steps", () => {
    stubFetch(async () => jsonResponse({ ok: true }));
    render(<GettingStartedWizard initialSkippedSteps={["brain", "persona"]} />);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 3 of 4");
    expect(screen.getByText(/Link the sources/i)).toBeInTheDocument();
  });

  it("finishes on the last step via completeOnboarding", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async () => jsonResponse({ completed_at: "2026-10-19T00:00:00Z" }));
    vi.stubGlobal("fetch", fetchMock);
    const onFinished = vi.fn();
    render(<GettingStartedWizard initialSkippedSteps={["brain", "persona", "connect"]} onFinished={onFinished} />);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 4 of 4");
    await user.click(screen.getByRole("button", { name: "Finish" }));
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining("/onboarding/complete"),
        expect.objectContaining({ method: "POST" }),
      );
    });
    await waitFor(() => expect(onFinished).toHaveBeenCalledTimes(1));
  });
});

describe("GettingStartedWizard standalone suppression", () => {
  it("renders nothing when standalone is forced", () => {
    stubFetch(async () => jsonResponse({ ok: true }));
    const { container } = render(<GettingStartedWizard initialSkippedSteps={[]} isStandalone />);
    expect(screen.queryByTestId("getting-started-wizard")).toBeNull();
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing when the URL carries standalone mode", () => {
    stubFetch(async () => jsonResponse({ ok: true }));
    window.history.pushState({}, "", "/?standalone=true#settings");
    const { container } = render(<GettingStartedWizard initialSkippedSteps={[]} />);
    expect(screen.queryByTestId("getting-started-wizard")).toBeNull();
    expect(container).toBeEmptyDOMElement();
    window.history.pushState({}, "", "/");
  });
});
