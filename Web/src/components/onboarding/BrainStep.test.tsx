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
    expect(screen.getByText("API Key Name")).toBeInTheDocument();
    expect(screen.getByText(/Local providers leave this blank/i)).toBeInTheDocument();
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
        providerName: "n",
        providerType: "custom",
        model: "m",
        serverURL: "",
        apiKeyEnv: "",
      }),
    ).toBeNull();
    expect(
      validateBrainProviderForm({
        providerName: "n",
        providerType: "custom",
        model: "m",
        serverURL: "",
        apiKeyEnv: "   ",
      }),
    ).toBeNull();
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
    ).toMatch(/API Key Name/i);
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
    expect(
      fetchMock.mock.calls.filter((call) => {
        const [url, init] = call as unknown as [string, RequestInit | undefined];
        return String(url) === "/settings" && init?.method === "PUT";
      }),
    ).toHaveLength(0);
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
      expect(screen.getByTestId("brain-error")).toHaveTextContent(/API Key Name/i);
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

  it("reports granted inline when no key is needed for local providers", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async () => jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);
    const onNext = vi.fn();
    render(<BrainStep onNext={onNext} />);
    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText(/No API key required/i)).toBeInTheDocument();
    expect(screen.getByTestId("brain-test-status").textContent).toMatch(/granted/i);
    expect(screen.getByTestId("brain-test-status")).toHaveClass("granted-pill");
    expect(onNext).not.toHaveBeenCalled();
    expect(
      fetchMock.mock.calls.some((call) => {
        const [url] = call as unknown as [string];
        return String(url).includes("/settings/secrets/status");
      }),
    ).toBe(false);
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
    expect(screen.getByTestId("brain-test-status").textContent).toMatch(
      /Key not found in Keychain/i,
    );
    expect(screen.getByTestId("brain-test-status")).toHaveClass("error-banner");
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

  it("shows Keychain badge plus Store Key when a key name is entered", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url) === "/settings/secrets/status") {
          return jsonResponse({ status: { MY_KEY: false } });
        }
        return jsonResponse({});
      }),
    );
    render(<BrainStep />);
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    expect(await screen.findByText(/Not Set in Keychain/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Store Key/i })).toBeInTheDocument();
  });

  it("shows Stored badge plus Update Key when the key is stored", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: { MY_KEY: true } })),
    );
    render(<BrainStep />);
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    expect(await screen.findByText(/Stored in Keychain/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Update Key/i })).toBeInTheDocument();
  });

  it("opens the store modal and marks stored plus clears Test on success", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        if (String(url) === "/settings/secrets/status") {
          return jsonResponse({ status: { MY_KEY: false } });
        }
        if (String(url) === "/settings/secrets" && init?.method === "POST") {
          return new Response(null, { status: 204 });
        }
        return jsonResponse({});
      }),
    );
    render(<BrainStep />);
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    await user.click(screen.getByTestId("brain-test-connection"));
    expect(await screen.findByText(/Key not found in Keychain/i)).toBeInTheDocument();
    const storeButton = await screen.findByRole("button", { name: /Store Key/i });
    expect(storeButton).toHaveAttribute("title", expect.stringMatching(/Store secret for MY_KEY/));
    await user.click(storeButton);
    expect(await screen.findByTestId("store-secret-modal")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: /API Key for mybrain/i }),
    ).toBeInTheDocument();
    await user.type(screen.getByTestId("secret-value-input"), "s3cr3t-value");
    await user.click(screen.getByTestId("store-secret-submit"));
    await waitFor(() => {
      expect(screen.getByText(/Stored in Keychain/i)).toBeInTheDocument();
    });
    expect(screen.getByRole("button", { name: /Update Key/i })).toBeInTheDocument();
    expect(screen.queryByTestId("brain-test-status")).toBeNull();
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

  it("propagates validation plus save plus test failures via onError", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url) === "/settings/secrets/status") {
          return jsonResponse({ status: { MY_KEY: false } });
        }
        return jsonResponse({});
      }),
    );
    const onError = vi.fn();
    render(<BrainStep onNext={vi.fn()} onError={onError} />);
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.click(screen.getByTestId("brain-next"));
    await screen.findByTestId("brain-error");
    expect(onError).toHaveBeenCalledWith(expect.stringMatching(/1 to 64/i));
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    await user.click(screen.getByTestId("brain-test-connection"));
    await screen.findByText(/Key not found in Keychain/i);
    expect(onError).toHaveBeenCalledWith(expect.stringMatching(/Key not found in Keychain/i));
  });

  it("renders no status when idle and alert when failed", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: { MY_KEY: false } })),
    );
    render(<BrainStep />);
    expect(screen.queryByTestId("brain-test-status")).toBeNull();
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    await user.click(screen.getByTestId("brain-test-connection"));
    const failed = await screen.findByTestId("brain-test-status");
    expect(failed).toHaveAttribute("role", "alert");
    expect(failed).toHaveClass("error-banner");
  });

  it("triggers scrollIntoView plus focus on validation failure", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({})));
    const scrollSpy = vi.fn();
    const focusSpy = vi.fn();
    const originalScrollIntoView = window.HTMLElement.prototype.scrollIntoView;
    const originalFocus = window.HTMLElement.prototype.focus;
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView =
      scrollSpy;
    (window.HTMLElement.prototype as unknown as Record<string, unknown>).focus = focusSpy;
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
      cb(0);
      return 0;
    });
    try {
      render(<BrainStep onNext={vi.fn()} />);
      await user.type(screen.getByTestId("brain-model"), "m1");
      await user.click(screen.getByTestId("brain-next"));
      await screen.findByTestId("brain-error");
      await waitFor(() => {
        expect(scrollSpy).toHaveBeenCalledWith(expect.objectContaining({ block: "nearest" }));
        expect(focusSpy).toHaveBeenCalled();
      });
    } finally {
      window.HTMLElement.prototype.scrollIntoView = originalScrollIntoView;
      window.HTMLElement.prototype.focus = originalFocus;
      vi.unstubAllGlobals();
    }
  });

  it("hides badge until probe resolves and never for invalid shape", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ status: { MY_KEY: false } })),
    );
    render(<BrainStep />);
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    expect(screen.queryByText(/Not Set in Keychain/i)).toBeNull();
    expect(await screen.findByText(/Not Set in Keychain/i)).toBeInTheDocument();
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY!" } });
    await waitFor(() => {
      expect(screen.queryByText(/Stored in Keychain/i)).toBeNull();
    });
    expect(screen.queryByText(/Not Set in Keychain/i)).toBeNull();
  });

  it("normalizes a pasted rwsecret prefix for probe", async () => {
    const fetchMock = vi.fn(async (url: string | URL | Request, _init?: RequestInit) => {
      if (String(url) === "/settings/secrets/status") {
        return jsonResponse({ status: { MY_KEY: false } });
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<BrainStep />);
    fireEvent.change(screen.getByTestId("brain-api-key-env"), {
      target: { value: "rwsecret:MY_KEY" },
    });
    expect(await screen.findByText(/Not Set in Keychain/i)).toBeInTheDocument();
    await waitFor(() => {
      const bodies = fetchMock.mock.calls
        .filter(([url]) => String(url).includes("/settings/secrets/status"))
        .map(([, init]) => String((init as RequestInit)?.body ?? ""));
      expect(bodies.length).toBeGreaterThan(0);
      expect(bodies.join(" ")).toContain("MY_KEY");
      expect(bodies.join(" ")).not.toContain("rwsecret:MY_KEY");
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
