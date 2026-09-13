// Rune Weaver Dashboard — Component tests for SettingsManager.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager from "./SettingsManager";

const mockSettings = {
  engineName: "Test Engine",
  logLevel: "info",
  defaultProvider: "mlx",
  fallbackProvider: "openrouter",
  providers: {
    mlx: {
      enabled: true,
      model: "gemma-4-9b",
      server_url: "http://localhost:8080",
      api_style: "openai",
      context_length: 32000,
    },
    openrouter: {
      enabled: true,
      model: "anthropic/claude-3.5-sonnet",
      server_url: "https://openrouter.ai/api/v1",
      api_key_env: "OPENROUTER_API_KEY",
      api_style: "openai",
      context_length: 128000,
    },
  },
  memoryVectorDBPath: "memory/vectors",
  memoryEpisodesDBPath: "memory/episodes.db",
  memoryEmbeddingModel: "bge-small-en-v1.5",
  voiceSTTProvider: "whisper",
  voiceWhisperModel: "base.en",
  voiceTTSProvider: "system",
  sandboxStagingPath: "sandbox/staging",
  sandboxAutoApproveAfter: 5,
  emailAccounts: [
    {
      name: "icloud",
      type: "imap",
      host: "imap.mail.me.com",
      port: 993,
      username: "test@icloud.com",
    },
  ],
  configPath: "/Users/test/.runeweaver/config.toml",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("SettingsManager", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders loaded providers and switches to other tabs", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => json(mockSettings))
    );

    render(<SettingsManager />);

    // Initial tab: LLM Providers
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
      expect(screen.getByDisplayValue("http://localhost:8080")).toBeDefined();
      expect(screen.getByText("/Users/test/.runeweaver/config.toml")).toBeDefined();
    });

    // Switch to Engine & Logs tab
    const engineTabBtn = screen.getByRole("button", { name: /Engine & Logs/i });
    await user.click(engineTabBtn);
    expect(screen.getByDisplayValue("Test Engine")).toBeDefined();

    // Switch to Sandbox tab
    const sandboxTabBtn = screen.getByRole("button", { name: /Sandbox & Trust/i });
    await user.click(sandboxTabBtn);
    expect(screen.getByDisplayValue("sandbox/staging")).toBeDefined();
    expect(screen.getByText(/Auto-Approve After \(Executions\)/i)).toBeDefined();

    // Switch to Email Accounts tab
    const emailTabBtn = screen.getByRole("button", { name: /Email Accounts/i });
    await user.click(emailTabBtn);
    expect(screen.getByDisplayValue("imap.mail.me.com")).toBeDefined();
    expect(screen.getByText("EMAIL_ICLOUD_PASSWORD")).toBeDefined();
  });

  it("allows adding a new provider and saving changes", async () => {
    const user = userEvent.setup();
    let sentPayload: any = null;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string);
        return json({
          ...mockSettings,
          ...sentPayload,
        });
      }
      return json(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Add a provider
    const addProviderBtn = screen.getByRole("button", { name: /Add Provider/i });
    await user.click(addProviderBtn);

    expect(screen.getByDisplayValue("provider_3")).toBeDefined();

    // Save settings
    const saveButton = screen.getByRole("button", { name: /Save Settings/i });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
    });

    expect(sentPayload).toBeDefined();
    expect(sentPayload.providers.provider_3).toBeDefined();
  });

  it("allows adding an email account", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => json(mockSettings))
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Switch to Email Accounts tab
    const emailTabBtn = screen.getByRole("button", { name: /Email Accounts/i });
    await user.click(emailTabBtn);

    // Add an email account
    const addAccountBtn = screen.getByRole("button", { name: /Add Account/i });
    await user.click(addAccountBtn);

    expect(screen.getByDisplayValue("mail_2")).toBeDefined();
    expect(screen.getByText("EMAIL_MAIL_2_PASSWORD")).toBeDefined();
  });
});
