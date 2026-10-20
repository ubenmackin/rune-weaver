// Rune Weaver Dashboard — Component tests for onboarding brain plus persona steps.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import BrainStep, {
  validateBrainProviderForm,
  type BrainProviderForm,
} from "./BrainStep";
import GettingStartedWizard from "./GettingStartedWizard";
import {
  PersonaStep,
  step3CardOrderForGoal,
  validatePersonaStep,
} from "./PersonaStep";
import { clearAuthToken } from "../../api";
import { jsonResponse } from "../../test-utils/http";

function BrainHarness({
  initial,
  secretStored = false,
  onStoreKey,
  testStatus = "idle" as const,
  testDetail = null,
  fieldError = null,
}: {
  initial?: Partial<BrainProviderForm>;
  secretStored?: boolean;
  onStoreKey?: () => void;
  testStatus?: "idle" | "testing" | "succeeded" | "failed";
  testDetail?: string | null;
  fieldError?: string | null;
}) {
  const [value, setValue] = useState<BrainProviderForm>({
    providerName: "",
    providerType: "",
    model: "",
    serverURL: "",
    apiKeyEnv: "",
    ...initial,
  });
  return (
    <BrainStep
      value={value}
      onChange={(patch) => setValue((prev) => ({ ...prev, ...patch }))}
      secretStored={secretStored}
      onStoreKey={onStoreKey}
      testStatus={testStatus}
      testDetail={testDetail}
      fieldError={fieldError}
    />
  );
}

function stubWizardFetch(handler?: (input: string, init?: RequestInit) => Promise<Response>): void {
  if (handler) {
    vi.stubGlobal("fetch", vi.fn(handler));
    return;
  }
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string | URL | Request) => {
      if (String(url).includes("/settings/secrets/status")) {
        return jsonResponse({ status: {} });
      }
      return jsonResponse({});
    }),
  );
}

describe("BrainStep", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  it("shares a single-row layout for Provider Name plus Provider Type", () => {
    render(<BrainHarness />);
    const name = screen.getByTestId("brain-provider-name");
    const type = screen.getByTestId("brain-provider-type");
    const nameRow = name.closest(".form-row");
    const typeRow = type.closest(".form-row");
    expect(nameRow).not.toBeNull();
    expect(nameRow).toBe(typeRow);
    expect(name.closest(".form-group")?.classList.contains("flex-1")).toBe(true);
    expect(type.closest(".form-group")?.classList.contains("flex-1")).toBe(true);
    expect(screen.getByTestId("brain-model")).toBeInTheDocument();
    expect(screen.getByTestId("brain-server-url")).toBeInTheDocument();
    expect(screen.getByTestId("brain-api-key-env")).toBeInTheDocument();
  });

  it("labels the key field API Key Name - Optional with zero helper prose", () => {
    render(<BrainHarness />);
    expect(screen.getByText("API Key Name - Optional")).toBeInTheDocument();
    const label = screen.getByText("API Key Name - Optional");
    expect(label.getAttribute("for")).toBe("brain-api-key-env");
    expect((screen.getByTestId("brain-api-key-env") as HTMLInputElement).placeholder).toMatch(
      /OPENROUTER_API_KEY/i,
    );
    expect(screen.queryByText(/Local providers leave this blank/i)).toBeNull();
    expect(screen.queryByText(/never in the config/i)).toBeNull();
    expect(screen.queryByText(/com\.runeweaver\.secrets/i)).toBeNull();
  });

  it("shows no pill when the key name is blank", () => {
    render(<BrainHarness initial={{ apiKeyEnv: "" }} />);
    expect(screen.queryByText(/Not Set in Keychain/i)).toBeNull();
    expect(screen.queryByText(/Stored in Keychain/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /Store Key/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /Update Key/i })).toBeNull();
  });

  it("immediately shows Not Set pill plus Store Key on typing", async () => {
    const user = userEvent.setup();
    render(<BrainHarness />);
    expect(screen.queryByText(/Not Set in Keychain/i)).toBeNull();
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    expect(await screen.findByText(/Not Set in Keychain/i)).toBeInTheDocument();
    const storeButton = screen.getByRole("button", { name: /Store Key/i });
    expect(storeButton).toBeInTheDocument();
    expect(storeButton).toHaveClass("keychain-action-btn");
    expect(storeButton.getAttribute("title")).toMatch(/Store secret for MY_KEY in Keychain/);
    expect(screen.getByText(/Not Set in Keychain/i)).toHaveClass("keychain-status-badge", "missing");
  });

  it("shows Stored pill plus Update Key when secretStored is true", () => {
    const onStoreKey = vi.fn();
    render(<BrainHarness initial={{ apiKeyEnv: "MY_KEY" }} secretStored onStoreKey={onStoreKey} />);
    expect(screen.getByText(/Stored in Keychain/i)).toBeInTheDocument();
    expect(screen.getByText(/Stored in Keychain/i)).toHaveClass("keychain-status-badge", "stored");
    const updateButton = screen.getByRole("button", { name: /Update Key/i });
    expect(updateButton).toHaveClass("keychain-action-btn");
    expect(updateButton.getAttribute("title")).toBe("Update secret for MY_KEY");
    fireEvent.click(updateButton);
    expect(onStoreKey).toHaveBeenCalledTimes(1);
  });

  it("renders zero inline action buttons in the presentational step", () => {
    render(<BrainHarness initial={{ apiKeyEnv: "MY_KEY" }} />);
    expect(screen.queryByTestId("brain-next")).toBeNull();
    expect(screen.queryByTestId("brain-test-connection")).toBeNull();
    expect(screen.queryByTestId("brain-back")).toBeNull();
    expect(document.querySelector(".onboarding-actions")).toBeNull();
  });

  it("validates fail-closed bounds with empty key valid", () => {
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

  it("renders inline field plus test states without owning actions", () => {
    const { rerender } = render(
      <BrainStep
        value={{ providerName: "", providerType: "", model: "", serverURL: "", apiKeyEnv: "" }}
        onChange={() => {}}
      />,
    );
    expect(screen.queryByTestId("brain-test-status")).toBeNull();
    expect(screen.queryByTestId("brain-error")).toBeNull();
    rerender(
      <BrainStep
        value={{ providerName: "", providerType: "", model: "", serverURL: "", apiKeyEnv: "MY_KEY" }}
        onChange={() => {}}
        testStatus="failed"
        testDetail="Key not stored"
        fieldError="Model must be 1 to 128 characters."
      />,
    );
    expect(screen.getByTestId("brain-test-status")).toHaveTextContent(/Failed to connect/i);
    expect(screen.getByTestId("brain-test-status")).toHaveAttribute("role", "alert");
    expect(screen.getByTestId("brain-error")).toHaveTextContent(/1 to 128/i);
  });

  it("opens the store modal from the wizard footer and marks stored on success", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        if (String(url) === "/settings") {
          if (init?.method === "PUT") return jsonResponse({});
          return jsonResponse({ providers: {}, defaultProvider: "" });
        }
        if (String(url) === "/settings/secrets/status") {
          return jsonResponse({ status: { MY_KEY: false } });
        }
        if (String(url) === "/settings/secrets" && init?.method === "POST") {
          return new Response(null, { status: 204 });
        }
        return jsonResponse({});
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
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

  it("owns Back plus Test plus Next in the wizard footer with zero step actions", async () => {
    const user = userEvent.setup();
    stubWizardFetch(async (url: string) => {
      if (url === "/settings") return jsonResponse({ providers: {}, defaultProvider: "" });
      return jsonResponse({});
    });
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.getByTestId("brain-test-connection")).toBeInTheDocument();
    });
    expect(screen.getByTestId("brain-next")).toBeInTheDocument();
    expect(screen.getByTestId("brain-next")).toHaveClass("primary");
    expect(screen.getByTestId("brain-test-connection")).toHaveClass("ghost");
    const step = screen.getByTestId("brain-step");
    expect(step.querySelector(".onboarding-actions")).toBeNull();
    expect(step.querySelector('[data-testid="brain-next"]')).toBeNull();
    expect(step.querySelector('[data-testid="brain-test-connection"]')).toBeNull();
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 2 of 4");
    });
  });

  it("disables footer Test plus Next while testing plus saving plus loading", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        (url: string | URL | Request) =>
          new Promise<Response>((resolve) => {
            if (String(url) === "/settings/secrets/status") {
              return;
            }
            resolve(jsonResponse({ providers: {}, defaultProvider: "" }));
          }),
      ),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    fireEvent.click(screen.getByTestId("brain-test-connection"));
    await waitFor(() => {
      expect(screen.getByTestId("brain-test-connection")).toBeDisabled();
      expect(screen.getByTestId("brain-next")).toBeDisabled();
    });
  });

  it("blocks Next on blank name plus blank model with inline plus footer errors", async () => {
    const user = userEvent.setup();
    stubWizardFetch(async (url: string) => {
      if (url === "/settings") return jsonResponse({ providers: {}, defaultProvider: "" });
      return jsonResponse({});
    });
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    await user.click(screen.getByTestId("brain-next"));
    const inline = await screen.findByTestId("brain-error");
    expect(inline).toHaveTextContent(/1 to 64/i);
    expect(inline).toHaveAttribute("role", "alert");
    const footer = screen.getByTestId("wizard-footer-error");
    expect(footer).toHaveAttribute("role", "alert");
    expect(footer.textContent).not.toBe("");
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 1 of 4");
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.click(screen.getByTestId("brain-next"));
    expect(await screen.findByTestId("brain-error")).toHaveTextContent(/1 to 128/i);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 1 of 4");
  });

  it("blocks Next on bad URL plus bad key shape", async () => {
    const user = userEvent.setup();
    stubWizardFetch(async (url: string) => {
      if (url === "/settings") return jsonResponse({ providers: {}, defaultProvider: "" });
      return jsonResponse({});
    });
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    fireEvent.change(screen.getByTestId("brain-server-url"), { target: { value: "not-a-url" } });
    await user.click(screen.getByTestId("brain-next"));
    expect(await screen.findByTestId("brain-error")).toHaveTextContent(/URL/i);
    expect(screen.getByTestId("wizard-footer-error").textContent).toMatch(/URL/i);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 1 of 4");
    fireEvent.change(screen.getByTestId("brain-server-url"), { target: { value: "" } });
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "bad-env!" } });
    await user.click(screen.getByTestId("brain-next"));
    expect(await screen.findByTestId("brain-error")).toHaveTextContent(/API Key Name/i);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 1 of 4");
  });

  it("saves a single provider payload preserving existing entries", async () => {
    const user = userEvent.setup();
    const puts: Array<{ url: string; body: Record<string, unknown> }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        const target = String(url);
        if (target === "/settings" && init?.method === "PUT") {
          puts.push({ url: target, body: JSON.parse(String(init.body ?? "{}")) });
          return jsonResponse({ ok: true });
        }
        if (target === "/settings") {
          return jsonResponse({
            providers: {
              other: { model: "other-model", serverURL: "", apiKeyEnv: "", providerType: "" },
            },
            defaultProvider: "other",
          });
        }
        if (target === "/settings/secrets/status") return jsonResponse({ status: {} });
        return jsonResponse({});
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    // Prefilled default entry must be cleared before typing a new provider.
    await user.clear(screen.getByTestId("brain-provider-name"));
    await user.clear(screen.getByTestId("brain-model"));
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.click(screen.getByTestId("brain-next"));
    await waitFor(() => {
      expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 2 of 4");
    });
    expect(puts).toHaveLength(1);
    const payload = puts[0].body as {
      defaultProvider: string;
      fallbackProvider: string;
      providers: Record<string, Record<string, unknown>>;
    };
    expect(payload.defaultProvider).toBe("mybrain");
    expect(payload.fallbackProvider).toBe("");
    expect(payload.providers["other"]).toBeDefined();
    expect(payload.providers["mybrain"]).toMatchObject({ model: "m1" });
  });

  it("surfaces 401 unauthenticated save inline with status code", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        const target = String(url);
        if (target === "/settings" && init?.method === "PUT") {
          return new Response("unauthenticated", { status: 401, statusText: "Unauthorized" });
        }
        if (target === "/settings") {
          return jsonResponse({ providers: {}, defaultProvider: "" });
        }
        if (target === "/settings/secrets/status") return jsonResponse({ status: {} });
        return jsonResponse({});
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    await user.type(screen.getByTestId("brain-provider-name"), "mybrain");
    await user.type(screen.getByTestId("brain-model"), "m1");
    await user.click(screen.getByTestId("brain-next"));
    const inline = await screen.findByTestId("brain-error");
    expect(inline).toHaveTextContent(/401/i);
    expect(screen.getByTestId("wizard-footer-error").textContent).toMatch(/401/i);
    expect(screen.getByTestId("wizard-progress")).toHaveTextContent("Step 1 of 4");
  });

  it("renders role alert on failed test status through the wizard footer", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url).includes("/settings/secrets/status")) {
          return jsonResponse({ status: { MY_KEY: false } });
        }
        return jsonResponse({ providers: {}, defaultProvider: "" });
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    await user.type(screen.getByTestId("brain-api-key-env"), "MY_KEY");
    await user.click(screen.getByTestId("brain-test-connection"));
    const status = await screen.findByTestId("brain-test-status");
    expect(status).toHaveTextContent(/Failed to connect/i);
    expect(status).toHaveAttribute("role", "alert");
  });
});

describe("Brain connection test fail-closed", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
  });

  it("fails blank URL with Enter server URL first", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url).includes("/settings/secrets/status")) {
          return jsonResponse({ status: {} });
        }
        return jsonResponse({ providers: {}, defaultProvider: "" });
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    await user.click(screen.getByTestId("brain-test-connection"));
    const status = await screen.findByTestId("brain-test-status");
    expect(status).toHaveTextContent(/Failed to connect/i);
    expect(status).toHaveTextContent(/Enter server URL first/i);
  });

  it("fails invalid URL with shape error", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url).includes("/settings/secrets/status")) {
          return jsonResponse({ status: {} });
        }
        return jsonResponse({ providers: {}, defaultProvider: "" });
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    fireEvent.change(screen.getByTestId("brain-server-url"), { target: { value: "not-a-url" } });
    await user.click(screen.getByTestId("brain-test-connection"));
    const status = await screen.findByTestId("brain-test-status");
    expect(status).toHaveTextContent(/Failed to connect/i);
    expect(status).toHaveTextContent(/absolute http\(s\) URL up to 253/i);
  });

  it("succeeds reachable plus stored with empty detail", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url).includes("/settings/secrets/status")) {
          return jsonResponse({ status: { MY_KEY: true } });
        }
        if (String(url).startsWith("https://")) {
          return jsonResponse({ ok: true });
        }
        return jsonResponse({ providers: {}, defaultProvider: "" });
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    fireEvent.change(screen.getByTestId("brain-server-url"), {
      target: { value: "https://brain.example.com" },
    });
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    await user.click(screen.getByTestId("brain-test-connection"));
    const status = await screen.findByTestId("brain-test-status");
    expect(status).toHaveTextContent(/Succeeded/i);
    expect(status.textContent).not.toMatch(/—/);
    expect(status.textContent).not.toMatch(/No server URL/i);
  });

  it("fails unreachable server", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url).includes("/settings/secrets/status")) {
          return jsonResponse({ status: {} });
        }
        if (String(url).startsWith("https://")) {
          throw new Error("unreachable");
        }
        return jsonResponse({ providers: {}, defaultProvider: "" });
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    fireEvent.change(screen.getByTestId("brain-server-url"), {
      target: { value: "https://brain.example.com" },
    });
    await user.click(screen.getByTestId("brain-test-connection"));
    const status = await screen.findByTestId("brain-test-status");
    expect(status).toHaveTextContent(/Failed to connect/i);
    expect(status).toHaveTextContent(/Server unreachable/i);
  });

  it("fails missing stored key", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        if (String(url).includes("/settings/secrets/status")) {
          return jsonResponse({ status: { MY_KEY: false } });
        }
        if (String(url).startsWith("https://")) {
          return jsonResponse({ ok: true });
        }
        return jsonResponse({ providers: {}, defaultProvider: "" });
      }),
    );
    render(<GettingStartedWizard initialSkippedSteps={[]} />);
    await waitFor(() => {
      expect(screen.queryByTestId("brain-loading")).toBeNull();
    });
    fireEvent.change(screen.getByTestId("brain-server-url"), {
      target: { value: "https://brain.example.com" },
    });
    fireEvent.change(screen.getByTestId("brain-api-key-env"), { target: { value: "MY_KEY" } });
    await user.click(screen.getByTestId("brain-test-connection"));
    const status = await screen.findByTestId("brain-test-status");
    expect(status).toHaveTextContent(/Failed to connect/i);
    expect(status).toHaveTextContent(/Key not stored/i);
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
