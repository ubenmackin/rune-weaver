// Rune Weaver Dashboard — Component tests for onboarding brain plus persona steps.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { BrainStep } from "./BrainStep";
import {
  PersonaStep,
  step3CardOrderForGoal,
  validatePersonaStep,
} from "./PersonaStep";
import { clearAuthToken } from "../../api";
import { jsonResponse } from "../../test-utils/http";

describe("BrainStep", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  it("defaults to Local MLX selection", () => {
    render(<BrainStep />);
    const local = screen.getByRole("radio", { name: /local mlx gemma-4-9b/i });
    const cloud = screen.getByRole("radio", { name: /cloud openrouter/i });
    expect((local as HTMLInputElement).checked).toBe(true);
    expect((cloud as HTMLInputElement).checked).toBe(false);
  });

  it("reveals the cloud key field behind the expander", async () => {
    const user = userEvent.setup();
    render(<BrainStep />);
    expect(screen.queryByTestId("brain-api-key-env")).toBeNull();
    await user.click(screen.getByTestId("cloud-expander"));
    expect(screen.getByTestId("brain-api-key-env")).toBeDefined();
    expect(screen.getByText(/keychain/i)).toBeDefined();
  });

  it("shows failed inline when the key is missing and never advances", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (url: string | URL | Request) => {
      if (String(url) === "/settings/secrets/status") {
        return jsonResponse({ status: { OPENROUTER_API_KEY: false } });
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    const onNext = vi.fn();
    render(<BrainStep initialChoice="cloud" onNext={onNext} />);

    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText(/failed/i)).toBeDefined();
    expect(screen.getByTestId("brain-test-status").textContent).toMatch(/failed/i);
    expect(onNext).not.toHaveBeenCalled();
    // Retry stays available instead of auto-advancing past the failure.
    expect(screen.getByTestId("brain-test-connection")).toBeDefined();
  });

  it("shows granted inline when the key is stored", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: { OPENROUTER_API_KEY: true } })),
    );
    render(<BrainStep initialChoice="cloud" />);
    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText("granted")).toBeDefined();
  });

  it("writes default plus fallback providers through the settings save path", async () => {
    const user = userEvent.setup();
    const puts: Array<Record<string, unknown>> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        if (String(url) === "/settings" && init?.method === "PUT") {
          puts.push(JSON.parse(String(init.body ?? "{}")) as Record<string, unknown>);
        }
        return jsonResponse({});
      }),
    );
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => expect(onNext).toHaveBeenCalledTimes(1));
    expect(puts).toHaveLength(1);
    expect(puts[0]).toMatchObject({ defaultProvider: "mlx", fallbackProvider: "openrouter" });
    expect(onNext.mock.calls[0][0]).toMatchObject({
      choice: "local",
      defaultProvider: "mlx",
    });
  });
});

describe("PersonaStep", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  it("blocks Next on empty names with an inline error", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    const onNext = vi.fn();
    render(<PersonaStep onNext={onNext} />);
    await user.click(screen.getByTestId("persona-next"));
    expect(await screen.findByTestId("persona-error")).toBeDefined();
    expect(screen.getByTestId("persona-error").textContent).toMatch(/1 to 64/i);
    expect(onNext).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("requires exactly one goal before advancing", () => {
    expect(validatePersonaStep({ assistantName: "Rune Weaver", userName: "Ada", goal: "" })).toMatch(
      /goal/i,
    );
    expect(
      validatePersonaStep({ assistantName: "Rune Weaver", userName: "Ada", goal: "someday" }),
    ).toMatch(/goal/i);
    expect(
      validatePersonaStep({ assistantName: "  ", userName: "Ada", goal: "inbox" }),
    ).toMatch(/assistant name/i);
    expect(
      validatePersonaStep({ assistantName: "Rune Weaver", userName: "", goal: "inbox" }),
    ).toMatch(/your name/i);
  });

  it("maps inbox plus day plus remember goals to Step 3 order", () => {
    expect(step3CardOrderForGoal("inbox")[0]).toBe("email");
    expect(step3CardOrderForGoal("day")[0]).toBe("calendar");
    expect(step3CardOrderForGoal("remember")[0]).toBe("index");
    for (const goal of ["inbox", "day", "remember"] as const) {
      expect([...step3CardOrderForGoal(goal)].sort()).toEqual(["calendar", "email", "index"]);
    }
  });

  it("saves names through the persona patch and advances with the goal", async () => {
    const user = userEvent.setup();
    const puts: Array<Record<string, unknown>> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        if (String(url) === "/settings" && init?.method === "PUT") {
          puts.push(JSON.parse(String(init.body ?? "{}")) as Record<string, unknown>);
        }
        return jsonResponse({});
      }),
    );
    const onNext = vi.fn();
    render(<PersonaStep onNext={onNext} />);
    await user.type(screen.getByTestId("persona-assistant-name"), "Rune Weaver");
    await user.type(screen.getByTestId("persona-user-name"), "Ada");
    fireEvent.click(screen.getByTestId("persona-goal-day"));
    await user.click(screen.getByTestId("persona-next"));
    await waitFor(() => expect(onNext).toHaveBeenCalledTimes(1));
    expect(onNext.mock.calls[0][0]).toMatchObject({ goal: "day" });
    expect(puts).toHaveLength(1);
    expect(puts[0]).toMatchObject({
      persona: { assistantName: "Rune Weaver", userName: "Ada" },
    });
  });
});
