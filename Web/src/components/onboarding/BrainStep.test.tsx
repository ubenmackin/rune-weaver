// Rune Weaver Dashboard — Component tests for onboarding brain plus persona steps.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { BrainStep, validateBrainProviderForm } from "./BrainStep";
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

  it("renders five-field form with dropdown plus server URL and zero radios", () => {
    render(<BrainStep />);
    expect(screen.queryAllByRole("radio")).toHaveLength(0);
    expect(screen.getByTestId("brain-provider-name")).toBeInTheDocument();
    expect(screen.getByTestId("brain-provider-type")).toBeInTheDocument();
    expect(screen.getByTestId("brain-model")).toBeInTheDocument();
    expect(screen.getByTestId("brain-server-url")).toBeInTheDocument();
    expect(screen.getByTestId("brain-api-key-env")).toBeInTheDocument();
    const options = screen.getAllByRole("option").map((o) => o.textContent ?? "");
    for (const label of [
      "Custom",
      "OpenRouter",
      "OpenAI",
      "Anthropic",
      "Gemini",
      "Ollama",
      "MLX",
      "LM Studio",
      "llama.cpp",
      "Local",
      "Auto",
    ]) {
      expect(options.join(" ")).toMatch(new RegExp(label.replace(".", "\\."), "i"));
    }
    expect(screen.getByText(/keychain/i).textContent).toMatch(/com\.runeweaver\.secrets/i);
  });

  it("blank install shows empty fields with placeholders", () => {
    render(<BrainStep />);
    expect((screen.getByTestId("brain-provider-name") as HTMLInputElement).value).toBe("");
    expect((screen.getByTestId("brain-model") as HTMLInputElement).value).toBe("");
    expect((screen.getByTestId("brain-server-url") as HTMLInputElement).value).toBe("");
    expect((screen.getByTestId("brain-api-key-env") as HTMLInputElement).value).toBe("");
    expect((screen.getByTestId("brain-model") as HTMLInputElement).placeholder).toMatch(
      /gemma-4-9b/i,
    );
    expect((screen.getByTestId("brain-server-url") as HTMLInputElement).placeholder).toMatch(
      /openrouter\.ai\/api\/v1/i,
    );
    expect((screen.getByTestId("brain-api-key-env") as HTMLInputElement).placeholder).toMatch(
      /OPENROUTER_API_KEY/i,
    );
  });

  it("prefills all five fields from the existing default provider", () => {
    render(
      <BrainStep
        initialProviders={{
          mybrain: {
            enabled: true,
            model: "m1",
            serverURL: "https://example.com/v1",
            apiKeyEnv: "MY_KEY",
            providerType: "openai",
          },
        }}
        initialDefaultProvider="mybrain"
      />,
    );
    expect((screen.getByTestId("brain-provider-name") as HTMLInputElement).value).toBe("mybrain");
    expect((screen.getByTestId("brain-provider-type") as HTMLInputElement).value).toBe("openai");
    expect((screen.getByTestId("brain-model") as HTMLInputElement).value).toBe("m1");
    expect((screen.getByTestId("brain-server-url") as HTMLInputElement).value).toBe(
      "https://example.com/v1",
    );
    expect((screen.getByTestId("brain-api-key-env") as HTMLInputElement).value).toBe("MY_KEY");
  });

  it("validates fail-closed bounds without network writes", () => {
    expect(
      validateBrainProviderForm({
        providerName: "  ",
        providerType: "custom",
        model: "m",
        serverURL: "",
        apiKeyEnv: "K",
      }),
    ).toMatch(/1 to 64/i);
    expect(
      validateBrainProviderForm({
        providerName: "n",
        providerType: "custom",
        model: "  ",
        serverURL: "",
        apiKeyEnv: "K",
      }),
    ).toMatch(/1 to 128/i);
    expect(
      validateBrainProviderForm({
        providerName: "n",
        providerType: "custom",
        model: "m",
        serverURL: "not-a-url",
        apiKeyEnv: "K",
      }),
    ).toMatch(/URL/i);
    expect(
      validateBrainProviderForm({
        providerName: "n",
        providerType: "custom",
        model: "m",
        serverURL: "",
        apiKeyEnv: "bad-env!",
      }),
    ).toMatch(/env/i);
  });

  it("blocks Next on blank name without saving", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-next"));
    expect(await screen.findByTestId("brain-error")).toBeInTheDocument();
    expect(screen.getByTestId("brain-error").textContent).toMatch(/1 to 64/i);
    expect(onNext).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("blocks Next on bad URL and bad env", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.type(screen.getByTestId("brain-server-url"), "not-a-url");
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-next"));
    expect(await screen.findByTestId("brain-error")).toHaveTextContent(/Server URL/i);
    expect(onNext).not.toHaveBeenCalled();

    await user.clear(screen.getByTestId("brain-server-url"));
    await user.clear(screen.getByTestId("brain-api-key-env"));
    await user.type(screen.getByTestId("brain-api-key-env"), "bad-env!");
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => {
      expect(screen.getByTestId("brain-error")).toHaveTextContent(/API key env/i);
    });
    expect(onNext).not.toHaveBeenCalled();
  });

  it("creates a single provider set as default with empty fallback", async () => {
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
    render(<BrainStep initialProviders={{ other: { enabled: true } }} onNext={onNext} />);
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.selectOptions(screen.getByTestId("brain-provider-type"), "openai");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.type(screen.getByTestId("brain-server-url"), "https://example.com/v1");
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => expect(onNext).toHaveBeenCalledTimes(1));
    expect(puts).toHaveLength(1);
    expect(puts[0]).toMatchObject({ defaultProvider: "mybrain", fallbackProvider: "" });
    const providers = (puts[0] as { providers: Record<string, Record<string, unknown>> }).providers;
    expect(providers["mybrain"]).toMatchObject({
      enabled: true,
      model: "m1",
      serverURL: "https://example.com/v1",
      apiKeyEnv: "MY_KEY",
      providerType: "openai",
    });
    expect(providers["other"]).toBeDefined();
    expect(onNext.mock.calls[0][0]).toMatchObject({
      providerName: "mybrain",
      defaultProvider: "mybrain",
      model: "m1",
      serverURL: "https://example.com/v1",
      apiKeyEnv: "MY_KEY",
    });
  });

  it("reports missing key inline with Enter env var name first and never advances", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText(/Enter env var name first/i)).toBeInTheDocument();
    expect(screen.getByTestId("brain-test-status").textContent).toMatch(/failed/i);
    expect(onNext).not.toHaveBeenCalled();
  });

  it("shows failed inline when the key is missing and never advances", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (url: string | URL | Request) => {
      if (String(url) === "/settings/secrets/status") {
        return jsonResponse({ status: { MY_KEY: false } });
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText(/failed/i)).toBeInTheDocument();
    expect(screen.getByTestId("brain-test-status").textContent).toMatch(/failed/i);
    expect(onNext).not.toHaveBeenCalled();
    expect(screen.getByTestId("brain-test-connection")).toBeInTheDocument();
  });

  it("shows granted inline when the key is stored", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: { MY_KEY: true } })),
    );
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText("granted")).toBeInTheDocument();
    expect(onNext).not.toHaveBeenCalled();
  });

  it("disables Test plus Next while testing", async () => {
    let resolveFetch!: (value: Response) => void;
    vi.stubGlobal(
      "fetch",
      vi.fn(
        () =>
          new Promise<Response>((resolve) => {
            resolveFetch = resolve;
          }),
      ),
    );
    render(<BrainStep />);
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    fireEvent.click(screen.getByTestId("brain-test-connection"));
    await waitFor(() => {
      expect(screen.getByTestId("brain-test-connection")).toBeDisabled();
      expect(screen.getByTestId("brain-next")).toBeDisabled();
    });
    expect(screen.getByTestId("brain-test-connection").textContent).toMatch(/Testing/i);
    resolveFetch(jsonResponse({ status: { MY_KEY: true } }));
    expect(await screen.findByText("granted")).toBeInTheDocument();
  });

  it("surfaces unauthenticated save inline without advancing", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("Unauthorized", { status: 401, statusText: "Unauthorized" })),
    );
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-next"));
    expect(await screen.findByTestId("brain-error")).toBeInTheDocument();
    expect(screen.getByTestId("brain-error").textContent).toMatch(/401/i);
    expect(onNext).not.toHaveBeenCalled();
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
