// Rune Weaver Dashboard — Component tests for SettingsManager.

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager, { SECRET_STATUS_CHUNK_SIZE, getToolCategory } from "./SettingsManager";
import {
  BASH_PERMISSION_ACTIONS,
  BASH_TIMEOUT_MAX_SECONDS,
  BASH_TIMEOUT_MIN_SECONDS,
  clearAuthToken,
  DEFAULT_BASH_ALLOW_NETWORK,
  DEFAULT_BASH_CONFIG,
  DEFAULT_BASH_DEFAULT_ACTION,
  DEFAULT_BASH_ENABLED,
  DEFAULT_BASH_RULES,
  DEFAULT_BASH_TIMEOUT_SECONDS,
  setAuthToken,
} from "../api";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";
import { jsonResponse } from "../test-utils/http";

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
  memoryEmbeddingBackend: "apple",
  voiceSTTProvider: "whisper",
  voiceWhisperModel: "base.en",
  voiceTTSProvider: "system",
  sandboxContainerBaseImage: "alpine:latest",
  sandboxArchiveSessionTTLMinutes: 10,
  sandboxMaxConcurrentMachines: 3,
  emailAccounts: [
    {
      name: "icloud",
      type: "imap",
      host: "imap.mail.me.com",
      port: 993,
      username: "test@icloud.com",
    },
  ],
  pluginsDir: "~/.runeweaver/plugins",
  pluginsMarketplaceIndexURL: "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json",
  pluginsAutoRescan: true,
  configPath: "/Users/test/.runeweaver/config.toml",
};

describe("SettingsManager", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedRunsForTesting();
  });

  it("renders loaded providers and switches to other tabs", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(mockSettings))
    );

    render(<SettingsManager />);

    // Initial tab: LLM Providers
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
      expect(screen.getByDisplayValue("http://localhost:8080")).toBeDefined();
      expect(screen.getByText("/Users/test/.runeweaver/config.toml")).toBeDefined();
    });

    // Switch to Engine and Logs tab via the vertical sidenav
    const engineTabBtn = screen.getByRole("tab", { name: /Engine and Logs/i });
    await user.click(engineTabBtn);
    expect(screen.getByDisplayValue("Test Engine")).toBeDefined();

    // Switch to Security tab (sandbox plus file guard share one pane)
    const sandboxTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(sandboxTabBtn);
    // Tier-3-only contract: no host-staging editors remain and the
    // detonation runtime renders as fixed text rather than an input.
    expect(screen.queryByLabelText(/Staging Path/i)).toBeNull();
    expect(screen.queryByLabelText(/Retention/i)).toBeNull();
    expect(screen.queryByLabelText(/Max Total Size/i)).toBeNull();
    expect(screen.queryByLabelText(/Cleanup Interval/i)).toBeNull();
    expect(screen.queryByDisplayValue("sandbox/staging")).toBeNull();
    expect(screen.queryByLabelText(/Container Runtime/i)).toBeNull();
    expect(screen.getByTestId("sandbox-container-runtime").textContent).toContain(
      "container"
    );
    expect(screen.getByText(/Apple Container CLI \(fixed\)/i)).toBeDefined();
    expect(screen.getByDisplayValue("alpine:latest")).toBeDefined();

    // Switch to Email Accounts tab via the vertical sidenav
    const emailTabBtn = screen.getByRole("tab", { name: /Email Accounts/i });
    await user.click(emailTabBtn);
    expect(screen.getByDisplayValue("imap.mail.me.com")).toBeDefined();
    expect(screen.getByText("EMAIL_ICLOUD_PASSWORD")).toBeDefined();
  });

  it("renames the search tab to Web with Web Search and Browser automation subsections", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string) => {
        const url = String(input);
        if (url.includes("/search/health")) {
          return jsonResponse({ reachable: false, url: "http://127.0.0.1:8888" });
        }
        if (url.includes("/browser/health")) {
          return jsonResponse({ ready: false });
        }
        if (url.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (url.includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // The internal tab id stays "search" so the search* API aliases and the
    // /search/* health routes keep working; only the visible label moves to Web.
    const webTab = screen.getByRole("tab", { name: /Web/i });
    expect(screen.queryByRole("tab", { name: /^Search$/i })).toBeNull();
    await user.click(webTab);

    // One Web card groups the two [browser]-backed surfaces as subsections.
    expect(screen.getByText("Web Search (SearXNG)")).toBeDefined();
    expect(screen.getByText("Browser automation")).toBeDefined();
    expect(screen.getByLabelText(/SearXNG URL/i)).toBeDefined();
  });

  it("allows adding a new provider and saving changes", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      return jsonResponse(mockSettings);
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
    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    expect(sentPayload).toBeDefined();
    const providers = (sentPayload as unknown as Record<string, unknown>)["providers"] as Record<
      string,
      unknown
    >;
    expect(providers["provider_3"]).toBeDefined();
  });

  it("allows adding an email account", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(mockSettings))
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Switch to Email Accounts tab via the vertical sidenav
    const emailTabBtn = screen.getByRole("tab", { name: /Email Accounts/i });
    await user.click(emailTabBtn);

    // Add an email account
    const addAccountBtn = screen.getByRole("button", { name: /Add Account/i });
    await user.click(addAccountBtn);

    expect(screen.getByDisplayValue("mail_2")).toBeDefined();
    expect(screen.getByText("EMAIL_MAIL_2_PASSWORD")).toBeDefined();
  });

  it("exposes the embedding backend select and saves it", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Switch to Memory and Storage tab via the vertical sidenav
    const memoryTabBtn = screen.getByRole("tab", { name: /Memory and Storage/i });
    await user.click(memoryTabBtn);

    // Backend select reflects the loaded value.
    const backendSelect = screen.getByLabelText(/Embedding Backend/i) as HTMLSelectElement;
    expect(backendSelect.value).toBe("apple");

    // No editable model input: provider follows the chat model and apple is
    // fixed on-device, so the prior value stays hidden but persisted.
    expect(screen.queryByLabelText(/Embedding Model/i)).toBeNull();
    expect(screen.queryByDisplayValue("bge-small-en-v1.5")).toBeNull();

    // Backend leads the section because it decides whether any model applies.
    const vectorInput = screen.getByLabelText(/Vector Storage Path/i);
    const episodesInput = screen.getByLabelText(/Episodes SQLite Database Path/i);
    expect(
      Boolean(
        backendSelect.compareDocumentPosition(vectorInput) &
          Node.DOCUMENT_POSITION_FOLLOWING
      )
    ).toBe(true);
    expect(
      Boolean(
        backendSelect.compareDocumentPosition(episodesInput) &
          Node.DOCUMENT_POSITION_FOLLOWING
      )
    ).toBe(true);

    // Help text explains each backend without an editable model field.
    expect(screen.getByText(/no model config/i)).toBeDefined();
    expect(screen.getByText(/active chat model/i)).toBeDefined();
    expect(screen.getByText(/keyword-only/i)).toBeDefined();
    expect(screen.getByText(/vector reset/i)).toBeDefined();

    await user.selectOptions(backendSelect, "provider");
    expect(backendSelect.value).toBe("provider");

    // Save settings
    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    expect(sentPayload).toBeDefined();
    expect((sentPayload as unknown as Record<string, unknown>)["memoryEmbeddingBackend"]).toBe(
      "provider"
    );
    // Prior model value persists untouched for forward compatibility.
    expect((sentPayload as unknown as Record<string, unknown>)["memoryEmbeddingModel"]).toBe(
      "bge-small-en-v1.5"
    );
  });

  it("renders Tools and Runes tab with disabled-by-default warning and enables discovered rune", async () => {
    const user = userEvent.setup();
    const mockPlugins = [
      {
        id: "community.weather",
        name: "Weather Reporter",
        version: "1.0.0",
        description: "Fetches current weather.",
        runtime: "python",
        source: "local_disk",
        status: "discovered",
        isEnabled: false,
        integrityHash: null,
        tools: [
          {
            name: "weather.get",
            description: "Get weather",
            permissionLevel: "readOnly",
            inputSchema: "{}",
            isEnabled: false,
            isBuiltIn: false,
            pluginID: "community.weather",
            source: "plugin",
            integrityStatus: "valid",
          },
        ],
        permissionOverrides: {},
        discoveredAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ];

    const mockTools = [
      {
        name: "remember_fact",
        description: "Store persistent fact",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
      {
        name: "weather.get",
        description: "Get weather",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: false,
        pluginID: "community.weather",
        source: "plugin",
        integrityStatus: "valid",
      },
    ];

    let enableCalled = false;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (urlStr.includes("/plugins/community.weather/state") && init?.method === "POST") {
        enableCalled = true;
        return jsonResponse({
          ...mockPlugins[0],
          status: "enabled",
          isEnabled: true,
          integrityHash: "abcdef1234567890",
        });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: mockPlugins });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    // Wait for initial load
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Switch to Tools and Runes tab via the vertical sidenav
    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Verify warning banner for disabled-by-default discovered runes
    await waitFor(() => {
      expect(screen.getByText(/awaiting review/i)).toBeDefined();
      expect(screen.getByText("Weather Reporter")).toBeDefined();
      expect(screen.getAllByText(/PENDING REVIEW/i).length).toBeGreaterThan(0);
    });

    // Verify enable button is present
    const enableBtn = screen.getByRole("button", { name: /Approve & Enable/i });
    expect(enableBtn).toBeDefined();

    // Click enable
    await user.click(enableBtn);

    await waitFor(() => {
      expect(enableCalled).toBe(true);
      expect(screen.getByText(/Enabled rune 'Weather Reporter'/i)).toBeDefined();
    });
  });

  it("hides marketplace entry points while keeping plugin rescan functional", async () => {
    const user = userEvent.setup();
    const discoveredRune = {
      id: "community.weather",
      name: "Weather Reporter",
      version: "1.0.0",
      description: "Fetches current weather.",
      runtime: "python",
      source: "local_disk",
      status: "discovered",
      isEnabled: false,
      integrityHash: null,
      tools: [
        {
          name: "weather.get",
          description: "Get weather",
          permissionLevel: "readOnly",
          inputSchema: "{}",
          isEnabled: false,
          isBuiltIn: false,
          pluginID: "community.weather",
          source: "plugin",
          integrityStatus: "valid",
        },
      ],
      permissionOverrides: {},
      discoveredAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    const mockTools = [
      {
        name: "remember_fact",
        description: "Store persistent fact",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];

    // Empty initial registry proves the empty state; rescan returning a rune proves local discovery
    // still works without any marketplace interaction. The second fetch parameter stays unused here
    // because this path only serves GET fixtures and never inspects request bodies.
    const fetchMock = vi.fn(async (url: string | URL | Request) => {
      const urlStr = String(url);
      if (urlStr.includes("/plugins/rescan")) {
        return jsonResponse({ plugins: [discoveredRune] });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Empty state guides toward local discovery instead of a remote catalog.
    await waitFor(() => {
      expect(
        screen.getByText(/No external runes discovered in plugins directory/i)
      ).toBeDefined();
    });
    expect(screen.getByText(/Rescan Plugins to discover them/i)).toBeDefined();

    // Neither the header action nor the empty-state action exposes the catalog.
    expect(
      screen.queryByRole("button", { name: /Browse Marketplace/i })
    ).toBeNull();

    // Plugin Configuration stays editable so local paths keep working.
    expect(screen.getByLabelText(/^Plugins Directory$/i)).toBeDefined();
    expect(screen.getByLabelText(/Marketplace Index URL/i)).toBeDefined();

    const rescanBtn = screen.getByRole("button", { name: /Rescan Plugins/i });
    await user.click(rescanBtn);

    // Rescan populates the list, confirming local discovery is unaffected.
    await waitFor(() => {
      expect(screen.getByText("Weather Reporter")).toBeDefined();
    });
    expect(
      screen.queryByRole("button", { name: /Browse Marketplace/i })
    ).toBeNull();
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/plugins/rescan"))).toBe(
      true
    );
  });

  it("disables an enabled builtin tool via the tool state endpoint with per-row pending", async () => {
    const user = userEvent.setup();
    // Two sibling email tools prove per-tool granularity: toggling one must
    // leave the other untouched in both the request payload and the UI.
    let builtinTools = [
      {
        name: "email.read",
        description: "Read email messages",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
      {
        name: "email.attachment",
        description: "Download email attachments",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];
    const calls: Array<{ url: string; method?: string; body?: string }> = [];
    // Hold the state POST open so the test can observe the pending row before the refreshed list
    // resolves. A mutable holder keeps the resolver visible across the fetch closure without
    // narrowing the local to null at the release site.
    const gate: { release: (() => void) | null } = { release: null };
    const stateGate = new Promise<void>((resolve) => {
      gate.release = resolve;
    });
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      const method = init?.method;
      calls.push({ url: urlStr, method, body: init?.body as string | undefined });
      if (urlStr.includes("/tools/") && urlStr.includes("/state") && method === "POST") {
        await stateGate;
        const payload = JSON.parse(init?.body as string) as { enabled: boolean };
        const name = decodeURIComponent(urlStr.split("/tools/")[1].split("/state")[0]);
        builtinTools = builtinTools.map((tool) =>
          tool.name === name ? { ...tool, isEnabled: payload.enabled } : tool
        );
        return jsonResponse(builtinTools.find((tool) => tool.name === name));
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: builtinTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText("email.read")).toBeDefined();
      expect(screen.getByText("email.attachment")).toBeDefined();
    });

    // Both rows render their own permission badge and a state switch whose
    // checked value mirrors the persisted bus flag (not the next action).
    expect(screen.getByText("readOnly")).toBeDefined();
    expect(screen.getByText("requiresApproval")).toBeDefined();
    const readToggle = screen.getByRole("switch", { name: "email.read Enabled" });
    const attachmentToggle = screen.getByRole("switch", {
      name: "email.attachment Enabled",
    });
    expect((readToggle as HTMLInputElement).checked).toBe(true);
    expect((attachmentToggle as HTMLInputElement).checked).toBe(true);
    expect(readToggle.getAttribute("aria-checked")).toBe("true");
    expect(attachmentToggle.getAttribute("aria-checked")).toBe("true");
    // State text reports the current value; action phrasing must be gone.
    expect(screen.getAllByText("Enabled").length).toBeGreaterThan(0);
    expect(
      screen.queryByRole("switch", { name: "Disable email.read" })
    ).toBeNull();
    expect(
      screen.queryByRole("switch", { name: "Enable email.read" })
    ).toBeNull();
    // Visual switch affordance renders a track/knob per row driven by the
    // persisted state so on/off is visible without reading the text.
    const tracks = document.querySelectorAll(".tool-switch-track");
    expect(tracks.length).toBe(2);
    tracks.forEach((track) => {
      expect(track.getAttribute("data-on")).toBe("true");
      expect(track.querySelector(".tool-switch-thumb")).not.toBeNull();
    });

    const clickPromise = user.click(readToggle);

    // The pending gate stays closed until the test releases it, so only the
    // acted-on row may disable while its sibling stays interactive. The
    // acted-on row announces the in-flight request with Updating… text.
    await waitFor(() => {
      expect(gate.release).not.toBeNull();
      expect(screen.getByText("Updating…")).toBeDefined();
      expect(
        (screen.getByRole("switch", { name: /email\.read/i }) as HTMLInputElement).disabled
      ).toBe(true);
    });
    expect(
      (screen.getByRole("switch", { name: /email\.attachment/i }) as HTMLInputElement).disabled
    ).toBe(false);
    expect(
      (screen.getByRole("switch", { name: /email\.attachment/i }) as HTMLInputElement).checked
    ).toBe(true);
    const release = gate.release;
    if (release) release();
    await clickPromise;

    await waitFor(() => {
      expect(screen.getByText(/Disabled tool 'email\.read'/i)).toBeDefined();
    });

    const stateCall = calls.find((call) => call.url.includes("/tools/email.read/state"));
    expect(stateCall).toBeDefined();
    expect(stateCall?.method).toBe("POST");
    expect(JSON.parse(stateCall?.body ?? "{}")).toEqual({ enabled: false });

    // Refreshed list flips only the toggled switch; the sibling stays on.
    // Checked, accessible name, and visible state text all follow the
    // refreshed bus value together.
    await waitFor(() => {
      expect(screen.getByRole("switch", { name: "email.read Disabled" })).toBeDefined();
    });
    const refreshedRead = screen.getByRole("switch", { name: "email.read Disabled" });
    const refreshedAttachment = screen.getByRole("switch", {
      name: "email.attachment Enabled",
    });
    expect((refreshedRead as HTMLInputElement).checked).toBe(false);
    expect(refreshedRead.getAttribute("aria-checked")).toBe("false");
    expect((refreshedAttachment as HTMLInputElement).checked).toBe(true);
    expect(screen.getAllByText("Disabled").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Enabled").length).toBeGreaterThan(0);
    const refreshedTracks = document.querySelectorAll(".tool-switch-track");
    const readRow = refreshedRead.closest("label");
    expect(readRow?.querySelector(".tool-switch-track")?.getAttribute("data-on")).toBe(
      "false"
    );
    expect(refreshedTracks.length).toBe(2);
  });

  it("enables a disabled builtin tool via the tool state endpoint", async () => {
    const user = userEvent.setup();
    let builtinTools = [
      {
        name: "email.read",
        description: "Read email messages",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
      {
        name: "email.attachment",
        description: "Download email attachments",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];
    const calls: Array<{ url: string; method?: string; body?: string }> = [];
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      const method = init?.method;
      calls.push({ url: urlStr, method, body: init?.body as string | undefined });
      if (urlStr.includes("/tools/") && urlStr.includes("/state") && method === "POST") {
        const payload = JSON.parse(init?.body as string) as { enabled: boolean };
        const name = decodeURIComponent(urlStr.split("/tools/")[1].split("/state")[0]);
        builtinTools = builtinTools.map((tool) =>
          tool.name === name ? { ...tool, isEnabled: payload.enabled } : tool
        );
        return jsonResponse(builtinTools.find((tool) => tool.name === name));
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: builtinTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByRole("switch", { name: "email.attachment Disabled" })).toBeDefined();
    });

    // Disabled rows report state text with an unchecked switch; the checked
    // flag and aria-checked stay in sync with the persisted bus value.
    const attachmentToggle = screen.getByRole("switch", {
      name: "email.attachment Disabled",
    });
    const readToggle = screen.getByRole("switch", { name: "email.read Disabled" });
    expect((attachmentToggle as HTMLInputElement).checked).toBe(false);
    expect(attachmentToggle.getAttribute("aria-checked")).toBe("false");
    expect((readToggle as HTMLInputElement).checked).toBe(false);
    expect(screen.getAllByText("Disabled").length).toBeGreaterThan(0);
    expect(
      screen.queryByRole("switch", { name: "Enable email.attachment" })
    ).toBeNull();

    await user.click(attachmentToggle);

    await waitFor(() => {
      expect(screen.getByText(/Enabled tool 'email\.attachment'/i)).toBeDefined();
    });

    const stateCall = calls.find((call) =>
      call.url.includes("/tools/email.attachment/state")
    );
    expect(stateCall).toBeDefined();
    expect(stateCall?.method).toBe("POST");
    expect(JSON.parse(stateCall?.body ?? "{}")).toEqual({ enabled: true });

    // Refreshed list flips only the toggled switch; the untouched sibling
    // proves the endpoint never bulk-enables related tools.
    await waitFor(() => {
      expect(
        screen.getByRole("switch", { name: "email.attachment Enabled" })
      ).toBeDefined();
    });
    const refreshedAttachment = screen.getByRole("switch", {
      name: "email.attachment Enabled",
    });
    const refreshedRead = screen.getByRole("switch", { name: "email.read Disabled" });
    expect((refreshedAttachment as HTMLInputElement).checked).toBe(true);
    expect(refreshedAttachment.getAttribute("aria-checked")).toBe("true");
    expect((refreshedRead as HTMLInputElement).checked).toBe(false);
    expect(
      refreshedAttachment
        .closest("label")
        ?.querySelector(".tool-switch-track")
        ?.getAttribute("data-on")
    ).toBe("true");
    expect(
      refreshedRead
        .closest("label")
        ?.querySelector(".tool-switch-track")
        ?.getAttribute("data-on")
    ).toBe("false");
  });

  it("allows configuring container sandboxing settings and saving", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const sandboxTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(sandboxTabBtn);

    // Tier-3-only contract: the detonation runtime is fixed text with no
    // editor, and no host-staging inputs remain to suggest a choice.
    expect(screen.queryByLabelText(/Container Runtime/i)).toBeNull();
    expect(screen.getByTestId("sandbox-container-runtime").textContent).toContain(
      "container"
    );
    expect(screen.getByText(/Apple Container CLI \(fixed\)/i)).toBeDefined();
    expect(screen.queryByLabelText(/Staging Path/i)).toBeNull();
    expect(screen.queryByLabelText(/Retention/i)).toBeNull();
    expect(screen.queryByLabelText(/Max Total Size/i)).toBeNull();
    expect(screen.queryByLabelText(/Cleanup Interval/i)).toBeNull();

    const baseImageInput = screen.getByLabelText(/Base Image/i);
    await user.clear(baseImageInput);
    await user.type(baseImageInput, "debian:slim");

    const ttlInput = screen.getByLabelText(/Archive Session TTL/i);
    await user.clear(ttlInput);
    await user.type(ttlInput, "25");

    const maxMachinesInput = screen.getByLabelText(/Max Concurrent Machines/i);
    await user.clear(maxMachinesInput);
    await user.type(maxMachinesInput, "7");

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    expect(sentPayload).toBeDefined();
    expect(sentPayload?.["sandboxContainerBaseImage"]).toBe("debian:slim");
    expect(sentPayload?.["sandboxArchiveSessionTTLMinutes"]).toBe(25);
    expect(sentPayload?.["sandboxMaxConcurrentMachines"]).toBe(7);
    // Deleted host-staging and free-text runtime keys must never reach the
    // engine; the decoder drops them so sending them would look saved
    // without persisting.
    expect(sentPayload).not.toHaveProperty("sandboxStagingPath");
    expect(sentPayload).not.toHaveProperty("sandboxRetentionDays");
    expect(sentPayload).not.toHaveProperty("sandboxMaxTotalBytes");
    expect(sentPayload).not.toHaveProperty("sandboxCleanupIntervalSeconds");
    expect(sentPayload).not.toHaveProperty("sandboxContainerRuntime");
  });

  it("edits blocked paths via textarea with live count and trims blanks on save", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    let putCount = 0;
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*", "*.pem"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    const mockTools = [
      {
        name: "files.read",
        description: "Read a file",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithFiles,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFiles);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Files guard lives in the Security Files & Access section, so
    // open it through the Security tab inline editor.
    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // Multiline editor surfaces the guard boundary with example globs so a
    // first-time reader knows the one-per-line shape without opening docs.
    const denyTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    expect(denyTextarea.placeholder).toContain(".env*");
    expect(denyTextarea.placeholder).toContain("*.pem");
    expect(denyTextarea.placeholder).toContain(".ssh/*");
    expect(denyTextarea.value).toContain(".env*");
    expect(screen.getByText(/2 patterns/i)).toBeDefined();

    // Blank lines and surrounding whitespace collapse on save; an emptied
    // editor stays a valid allow-all instead of failing the form.
    await user.clear(denyTextarea);
    await user.type(denyTextarea, "  .env*  \n\n*.pem\n   \n.ssh/*  ");
    expect(screen.getByText(/3 patterns/i)).toBeDefined();

    // Single page Save owns the Files & Access persist: no section-level
    // Save Configuration remains in Security, so the page save payload
    // carries the files keys.
    expect(
      screen.queryByRole("button", { name: /Save Configuration/i })
    ).toBeNull();
    await user.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([".env*", "*.pem", ".ssh/*"]);
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    // Security editor stays mounted after the page save, so the follow-up
    // steps run against the same textarea without reopening a modal.
    const reopenedTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;

    // Traversal escapes fail closed with their editor line number so the
    // author can jump straight to the offending glob.
    const putsBeforeTraversal = putCount;
    await user.clear(reopenedTextarea);
    await user.type(reopenedTextarea, ".env*\n../escape\n*.pem");
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(screen.getByText(/Line 2.*\.\./i)).toBeDefined();
    });
    expect(putCount).toBe(putsBeforeTraversal);

    // Empty means allow all in scope: clearing the editor saves an empty
    // array and surfaces the allow-all hint instead of an error.
    await user.clear(reopenedTextarea);
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(sentPayload?.["filesDenyPatterns"]).toEqual([]);
    });
    expect(
      screen.getByText(/allow all in-scope paths/i)
    ).toBeDefined();
  });

  it("confirms deny and roots resets via modal without persisting until save", async () => {
    const user = userEvent.setup();
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: ["custom*"],
      filesAllowRoots: ["~/custom"],
      filesRequireApprovalOnDeny: true,
    };
    const mockTools = [
      {
        name: "files.read",
        description: "Read a file",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const fetchMock = vi.fn(async (url: string | URL | Request) => {
      const urlStr = String(url);
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFiles);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Reset confirmations live in the Security Files & Access section;
    // Security owns both sandbox isolation and the file editors.
    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    const denyTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    expect(denyTextarea.value).toContain("custom*");

    // Reset opens a shared confirmation stating counts and the form-local
    // nature; cancelling leaves the in-progress text untouched. The Cancel is
    // scoped to the confirmation dialog because the Security pane behind it
    // renders its own inline save.
    const resetDenyBtn = screen.getByRole("button", { name: /Reset to Defaults/i });
    await user.click(resetDenyBtn);
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom pattern/i)).toBeDefined();
    });
    expect(screen.getByText(/nothing is saved until you choose Save/i)).toBeDefined();
    const denyConfirmDialog = document.querySelector(".session-delete-modal") as HTMLElement;
    expect(denyConfirmDialog).not.toBeNull();
    await user.click(within(denyConfirmDialog).getByRole("button", { name: /Cancel/i }));
    expect((screen.getByLabelText(/Deny patterns, one per line/i) as HTMLTextAreaElement).value).toContain(
      "custom*"
    );

    // Confirming rewrites only the form text; the guard defaults reappear in
    // the editor without any network persistence yet.
    await user.click(screen.getByRole("button", { name: /Reset to Defaults/i }));
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom pattern/i)).toBeDefined();
    });
    await user.click(
      screen.getByRole("button", { name: /Confirm reset deny patterns/i })
    );
    await waitFor(() => {
      expect(
        (screen.getByLabelText(/Deny patterns, one per line/i) as HTMLTextAreaElement).value
      ).toContain(".env*");
    });

    // Roots follow the same form-local pattern with their own counts.
    const resetRootsBtn = screen.getByRole("button", { name: /Reset Roots/i });
    await user.click(resetRootsBtn);
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom root/i)).toBeDefined();
    });
    expect(screen.getByText(/nothing is saved until you choose Save/i)).toBeDefined();
    await user.click(
      screen.getByRole("button", { name: /Confirm reset allowed roots/i })
    );
    // Confirming swaps the custom root for the home default; the old value
    // leaves the form so only the default remains visible.
    await waitFor(() => {
      expect(screen.queryByDisplayValue("~/custom")).toBeNull();
    });
    expect(screen.getAllByDisplayValue("~").length).toBeGreaterThan(0);
  });

  it("uses ghost icon buttons for files and roots resets with no Add actions", async () => {
    const user = userEvent.setup();
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    const mockTools = [
      {
        name: "files.read",
        description: "Read a file",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        return jsonResponse(settingsWithFiles);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Files header actions live in the Security Files & Access section;
    // sandbox isolation (Apple Container Machine) shares the same pane.
    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // Ghost treatment carries the hover and alignment tokens; secondary
    // buttons have no stylesheet entry and render misaligned, so every
    // header action must use the shared ghost icon style. No Add actions
    // remain: both subsections edit through the single textarea, so Reset
    // is the only header action per subsection.
    expect(
      screen.queryByRole("button", { name: /Add Pattern/i })
    ).toBeNull();
    expect(screen.queryByRole("button", { name: /Add Root/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /Add Roots/i })).toBeNull();
    const resetDefaultsBtn = screen.getByRole("button", { name: /Reset to Defaults/i });
    expect(resetDefaultsBtn.className).toContain("ghost");
    expect(resetDefaultsBtn.className).toContain("icon-text-btn");

    const resetRootsBtn = screen.getByRole("button", { name: /Reset Roots/i });
    expect(resetRootsBtn.className).toContain("ghost");
    expect(resetRootsBtn.className).toContain("icon-text-btn");

    // Subsection headings keep each policy surface discoverable in the section.
    expect(screen.getByText("Blocked Paths")).toBeDefined();
    expect(screen.getByText("Allowed Roots")).toBeDefined();
    // Sandbox isolation shares the Security pane beside the Files section.
    expect(screen.getByText("Apple Container Machine")).toBeDefined();

    // Approval escalation toggle stays with its explanatory hint.
    expect(screen.getByLabelText(/Require approval on deny/i)).toBeDefined();
    expect(screen.getByText(/approvals inbox instead of failing silently/i)).toBeDefined();
  });

  it("edits max tool rounds per turn in engine tab and saves", async () => {
    const user = userEvent.setup();
    let savedBody: Record<string, any> | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init?: RequestInit) => {
        if (typeof url === "string" && url.endsWith("/settings") && init?.method === "PUT") {
          savedBody = JSON.parse(String(init.body)) as Record<string, unknown>;
          return jsonResponse({ ...mockSettings, ...savedBody, configPath: "/path/config.toml" });
        }
        if (typeof url === "string" && url.endsWith("/settings")) {
          return jsonResponse({
            ...mockSettings,
            maxToolIterations: 12,
          });
        }
        return jsonResponse({});
      }),
    );

    render(<SettingsManager />);

    // Wait for initial load
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Switch to Engine tab
    const engineTabBtn = screen.getByRole("tab", { name: /Engine and Logs/i });
    await user.click(engineTabBtn);

    // Verify loaded value
    const input = await screen.findByLabelText(/Max Tool Rounds per Turn/i);
    expect(input).toHaveValue(12);

    // Edit value
    await user.clear(input);
    await user.type(input, "15");
    expect(input).toHaveValue(15);

    // Save
    await user.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(savedBody).not.toBeNull();
    });
    expect((savedBody as unknown as Record<string, unknown>)?.maxToolIterations).toBe(15);
  });

  it("opens browser and web configuration modal from the combined Browser & Web header without fallback error", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (typeof url === "string" && url.includes("/tools")) {
          return jsonResponse({
            tools: [
              {
                name: "browser.act",
                description: "Perform an action",
                isEnabled: true,
                isBuiltIn: true,
                hasConfig: true,
              },
              {
                name: "web.fetch",
                description: "Fetch a URL",
                isEnabled: true,
                isBuiltIn: true,
                hasConfig: true,
              },
            ],
          });
        }
        if (typeof url === "string" && url.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        return jsonResponse(mockSettings);
      }),
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Switch to Tools tab
    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Browser and web prefixes share one section, so both tools render under a
    // single Browser & Web heading with no leftover split sections. The split
    // would strand web.fetch away from the allowlist editor its calls need.
    await waitFor(() => {
      expect(screen.getByText("Browser & Web")).toBeDefined();
    });
    expect(screen.queryByText("Browser Automation")).toBeNull();
    expect(document.querySelectorAll(".tool-category-section").length).toBe(1);
    // Pills mirror sections: All plus one Browser pill, never a second Web pill.
    // Scoped to the pills bar because the sidenav Web tab also renders /^Web$/.
    expect(document.querySelectorAll(".tools-category-pill").length).toBe(2);
    const pillsBar = document.querySelector(".tools-category-pills");
    expect(pillsBar).not.toBeNull();
    expect(within(pillsBar as HTMLElement).getByText("Browser")).toBeDefined();
    expect(within(pillsBar as HTMLElement).queryByText(/^Web$/)).toBeNull();
    expect(screen.getByText("browser.act")).toBeDefined();
    expect(screen.getByText("web.fetch")).toBeDefined();

    // Single header Configure owns the whole surface: it sits beside Enable
    // All in the category actions, never inside a tool card, so one editor
    // covers both prefixes without duplicated buttons.
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    const configureButton = configureButtons[0];
    expect(configureButton.closest(".tool-category-actions")).not.toBeNull();
    expect(configureButton.closest(".builtin-tool-card")).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
    await user.click(configureButton);

    // Should open "Configure Browser & Web Automation" modal
    expect(screen.getByRole("heading", { name: /Configure Browser & Web Automation/i })).toBeDefined();
    // Must NOT show the fallback error message
    expect(screen.queryByText(/No configuration UI is available/i)).toBeNull();
  });

  it("drops count-only badges while keeping pending and tampered attention badges", async () => {
    const user = userEvent.setup();
    const settingsWithCounts = {
      ...mockSettings,
      filesDenyPatterns: [".env*", "*.pem"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    const mockPlugins = [
      {
        id: "community.weather",
        name: "Weather Reporter",
        version: "1.0.0",
        description: "Fetches current weather.",
        runtime: "python",
        source: "local_disk",
        status: "discovered",
        isEnabled: false,
        integrityHash: null,
        tools: [
          {
            name: "weather.get",
            description: "Get weather",
            permissionLevel: "readOnly",
            inputSchema: "{}",
            isEnabled: false,
            isBuiltIn: false,
            pluginID: "community.weather",
            source: "plugin",
            integrityStatus: "valid",
          },
        ],
        permissionOverrides: {},
        discoveredAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
      {
        id: "community.notes",
        name: "Notes Keeper",
        version: "1.0.0",
        description: "Keeps notes.",
        runtime: "python",
        source: "local_disk",
        status: "tampered",
        isEnabled: false,
        integrityHash: "abcdef1234567890",
        tools: [
          {
            name: "notes.save",
            description: "Save note",
            permissionLevel: "readOnly",
            inputSchema: "{}",
            isEnabled: false,
            isBuiltIn: false,
            pluginID: "community.notes",
            source: "plugin",
            integrityStatus: "tampered",
          },
        ],
        permissionOverrides: {},
        discoveredAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ];
    const mockTools = [
      {
        name: "remember_fact",
        description: "Store persistent fact",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
      {
        name: "email.read",
        description: "Read email messages",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: mockPlugins });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        return jsonResponse(settingsWithCounts);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Count-only sidenav badges are gone even though backing counts are non-zero:
    // two providers, two deny patterns, and one email account.
    const providersTab = screen.getByRole("tab", { name: /LLM Providers/i });
    expect(providersTab.querySelector(".settings-tab-badge")).toBeNull();
    const securityTab = screen.getByRole("tab", { name: /Security/i });
    expect(securityTab.querySelector(".settings-tab-badge")).toBeNull();
    const emailTab = screen.getByRole("tab", { name: /Email Accounts/i });
    expect(emailTab.querySelector(".settings-tab-badge")).toBeNull();

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText(/awaiting review/i)).toBeDefined();
    });

    // Attention-only nav badges remain: one orange pending-review and one red tampered.
    const toolsTab = screen.getByRole("tab", { name: /Tools and Runes/i });
    const navBadges = toolsTab.querySelectorAll(".settings-tab-badge");
    expect(navBadges.length).toBe(2);
    expect(toolsTab.querySelector('[title="1 runes pending human review"]')).not.toBeNull();
    expect(toolsTab.querySelector('[title="1 runes modified since approval"]')).not.toBeNull();

    // Attention metric cards and banners remain visible.
    expect(screen.getByText("Pending Review")).toBeDefined();
    expect(screen.getByText("Tampered")).toBeDefined();
    expect(screen.getByText(/modified on disk since approval/i)).toBeDefined();

    // Count-only section headers render without badge shells.
    const installedHeader = screen.getByText("Installed Runes & Plugins").closest("h4");
    expect(installedHeader?.querySelector(".settings-tab-badge")).toBeNull();
    const builtinHeader = screen.getByText("Built-in Engine Tools").closest("h4");
    expect(builtinHeader?.querySelector(".settings-tab-badge")).toBeNull();
  });

  it("renders no badge shells when nothing needs attention", async () => {
    const user = userEvent.setup();
    const settingsWithCounts = {
      ...mockSettings,
      filesDenyPatterns: [".env*", "*.pem"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    const mockTools = [
      {
        name: "remember_fact",
        description: "Store persistent fact",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        return jsonResponse(settingsWithCounts);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // No attention items means the Tools nav renders without any badge element.
    const toolsTabBefore = screen.getByRole("tab", { name: /Tools and Runes/i });
    expect(toolsTabBefore.querySelector(".settings-tab-badge")).toBeNull();

    await user.click(toolsTabBefore);

    await waitFor(() => {
      expect(screen.getByText("Installed Runes & Plugins")).toBeDefined();
    });

    // With counts removed and zero attention items, no badge shell remains anywhere.
    expect(document.querySelectorAll(".settings-tab-badge").length).toBe(0);
    expect(screen.queryByText(/awaiting review/i)).toBeNull();
    expect(screen.queryByText(/modified on disk since approval/i)).toBeNull();
  });

  it("shows exactly Settings saved in a status toast without the config path", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(_url);
      if (urlStr.includes("/runs")) {
        return jsonResponse({ runs: [], count: 0 });
      }
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    // Toast uses role=status so assistive technology announces it.
    const toast = screen.getByRole("status");
    expect(toast.textContent).toContain("Settings saved.");
    // Dropped configPath from copy; the badge keeps the path separately.
    expect(toast.textContent).not.toContain("/Users/test/.runeweaver/config.toml");
    expect(toast.textContent).not.toMatch(/Restart/i);
    expect(screen.getByText("/Users/test/.runeweaver/config.toml")).toBeDefined();
    expect(sentPayload).toBeDefined();
  });

  it("clears the success toast on tab switch so it never follows navigation", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(_url);
      if (urlStr.includes("/runs")) {
        return jsonResponse({ runs: [], count: 0 });
      }
      if (init?.method === "PUT") {
        const sent = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sent,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    const engineTabBtn = screen.getByRole("tab", { name: /Engine and Logs/i });
    await user.click(engineTabBtn);

    await waitFor(() => {
      expect(screen.queryByText("Settings saved.")).toBeNull();
    });
    expect(screen.queryByRole("status")).toBeNull();
  });

  it("guards saves while work is running with Cancel aborting the PUT", async () => {
    const user = userEvent.setup();
    const putCalls: Array<{ url: string; body: string }> = [];
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(_url);
      if (urlStr.includes("/runs")) {
        return jsonResponse({
          runs: [
            {
              id: "run-1",
              kind: "chat",
              status: "running",
              message: "thinking",
              timestamp: Date.now() / 1000,
            },
          ],
          count: 1,
        });
      }
      if (init?.method === "PUT") {
        putCalls.push({ url: urlStr, body: init.body as string });
        const sent = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sent,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(
        screen.getByText(
          "If you continue, in progress chats will be cancelled. Do you want to continue?"
        )
      ).toBeDefined();
    });

    // Cancel aborts the PUT so nothing persists and no toast appears.
    await user.click(screen.getByRole("button", { name: "Cancel" }));

    await waitFor(() => {
      expect(
        screen.queryByText(
          "If you continue, in progress chats will be cancelled. Do you want to continue?"
        )
      ).toBeNull();
    });
    expect(putCalls.length).toBe(0);
    expect(screen.queryByText("Settings saved.")).toBeNull();
  });

  it("guards saves while work is running with Continue saving and hot-reloading", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(_url);
      if (urlStr.includes("/runs")) {
        return jsonResponse({
          runs: [
            {
              id: "run-2",
              kind: "scheduler",
              status: "running",
              message: "running job",
              timestamp: Date.now() / 1000,
            },
          ],
          count: 1,
        });
      }
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(
        screen.getByText(
          "If you continue, in progress chats will be cancelled. Do you want to continue?"
        )
      ).toBeDefined();
    });

    await user.click(screen.getByRole("button", { name: "Continue" }));

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
    expect(sentPayload).toBeDefined();
  });

  it("renders a unified Desktop Configure modal that saves capture knobs and blocklist without enable keys", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "desktop.screenshot",
        description: "Capture a display or app window",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "desktop.action",
        description: "Perform approved desktop actions",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // One header Configure owns the whole Desktop surface: both tools share the
    // same editor, so a second per-card button would duplicate the modal and
    // drift from the server hasConfig authority.
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    expect(configureButtons[0].closest(".tool-category-actions")).not.toBeNull();
    expect(configureButtons[0].closest(".builtin-tool-card")).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
    expect(screen.getByText("Desktop & Automation")).toBeDefined();
    await user.click(configureButtons[0]);

    // The unified modal carries both capture knobs and blocklist.
    expect(screen.getByRole("heading", { name: /Configure Desktop Integration/i })).toBeDefined();
    expect(screen.getByLabelText(/Max Image Dimension/i)).toBeDefined();
    expect(screen.getByLabelText(/JPEG Quality/i)).toBeDefined();
    expect(screen.getByLabelText(/Blocked Apps/i)).toBeDefined();
    // No in-modal Enabled toggle: the modal holds no checkboxes at all.
    const modal = document.querySelector(".modal-container");
    expect(modal).not.toBeNull();
    expect(modal?.querySelectorAll('input[type="checkbox"]').length).toBe(0);

    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const desktop = (sentPayload as unknown as Record<string, unknown>)["desktop"] as Record<
      string,
      unknown
    >;
    expect(desktop).toBeDefined();
    expect(desktop).toHaveProperty("max_image_dimension");
    expect(desktop).toHaveProperty("jpeg_quality");
    expect(desktop).toHaveProperty("blocked_apps");
    expect(desktop).not.toHaveProperty("screen_capture_enabled");
    expect(desktop).not.toHaveProperty("control_enabled");
  });

  it("renders the unified Desktop Configure modal from the category header and saves edited blocklist without enable keys", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "desktop.screenshot",
        description: "Capture a display or app window",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "desktop.action",
        description: "Perform approved desktop actions",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Header placement covers both desktop tools at once: the category holds
    // two cards but exposes one Configure, so editing the blocklist here proves
    // the shared editor path without a per-tool entry point.
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    expect(configureButtons[0].closest(".tool-category-actions")).not.toBeNull();
    expect(configureButtons[0].closest(".builtin-tool-card")).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
    await user.click(configureButtons[0]);

    // The unified modal opens from the header as well.
    expect(screen.getByRole("heading", { name: /Configure Desktop Integration/i })).toBeDefined();
    const blockedTextarea = screen.getByLabelText(/Blocked Apps/i) as HTMLTextAreaElement;
    expect(blockedTextarea.value).toContain("Terminal");
    expect(screen.getByText(/7 apps/i)).toBeDefined();
    expect(screen.getByLabelText(/Max Image Dimension/i)).toBeDefined();
    expect(screen.getByLabelText(/JPEG Quality/i)).toBeDefined();
    // No in-modal Enabled toggle: the modal holds no checkboxes at all.
    const modal = document.querySelector(".modal-container");
    expect(modal).not.toBeNull();
    expect(modal?.querySelectorAll('input[type="checkbox"]').length).toBe(0);

    await user.clear(blockedTextarea);
    await user.type(blockedTextarea, "Terminal\n1Password");
    expect(screen.getByText(/2 apps/i)).toBeDefined();

    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const desktop = (sentPayload as unknown as Record<string, unknown>)["desktop"] as Record<
      string,
      unknown
    >;
    expect(desktop.blocked_apps).toEqual(["Terminal", "1Password"]);
    expect(desktop).toHaveProperty("max_image_dimension");
    expect(desktop).toHaveProperty("jpeg_quality");
    expect(desktop).not.toHaveProperty("screen_capture_enabled");
    expect(desktop).not.toHaveProperty("control_enabled");
  });

  it("does not guard parked approvals awaiting human review", async () => {
    const user = userEvent.setup();
    let putCalled = false;
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(_url);
      if (urlStr.includes("/runs")) {
        return jsonResponse({
          runs: [
            {
              id: "run-parked",
              kind: "chat",
              status: "awaiting_approval",
              message: "waiting",
              timestamp: Date.now() / 1000,
            },
          ],
          count: 1,
        });
      }
      if (init?.method === "PUT") {
        putCalled = true;
        const sent = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...mockSettings,
          ...sent,
        });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    // Parked work saves directly with no confirm modal.
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
    expect(
      screen.queryByText(
        "If you continue, in progress chats will be cancelled. Do you want to continue?"
      )
    ).toBeNull();
    expect(putCalled).toBe(true);
  });

  it("styles every category Configure button with accent-ghost", async () => {
    const user = userEvent.setup();
    const configurableTools = [
      "media.arr",
      "media.arr.read",
      "browser.navigate",
      "browser.act",
      "web.fetch",
      "desktop.screenshot",
      "desktop.action",
    ].map((name) => ({
      name,
      description: `${name} tool`,
      permissionLevel: "readOnly",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: true,
      pluginID: null,
      source: "builtin",
      integrityStatus: "valid",
      hasConfig: true,
    }));
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: configurableTools });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Seven configurable tools collapse to three header buttons (media,
    // Browser & Web, desktop), so the count follows categories rather than
    // tools. The combined section proves browser.* and web.* stay together.
    await waitFor(() => {
      expect(screen.getByText("Browser & Web")).toBeDefined();
    });
    expect(screen.getByText("Desktop & Automation")).toBeDefined();
    expect(screen.getByText("Media & Streaming")).toBeDefined();
    expect(screen.queryByText("Browser Automation")).toBeNull();
    expect(document.querySelectorAll(".tool-category-section").length).toBe(3);
    expect(document.querySelectorAll(".tools-category-pill").length).toBe(4);
    const configureButtons = await screen.findAllByRole("button", {
      name: /^Configure$/,
    });
    expect(configureButtons.length).toBe(3);
    for (const btn of configureButtons) {
      expect(btn.classList.contains("accent-ghost")).toBe(true);
      expect(btn.classList.contains("icon-text-btn")).toBe(true);
      expect(btn.classList.contains("tool-category-action-btn")).toBe(true);
      expect(btn.classList.contains("configure")).toBe(true);
      expect(btn.classList.contains("ghost")).toBe(false);
      // Header ownership, never a card child, keeps one editor per surface.
      expect(btn.closest(".tool-category-actions")).not.toBeNull();
      expect(btn.closest(".builtin-tool-card")).toBeNull();
    }
    // No per-card Configure remains anywhere in the grid.
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
  });

  it("opens the media category Configure and hides Configure on unconfigurable categories", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "media.arr",
        description: "Search and manage media",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "email.read",
        description: "Read email messages",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: false,
      },
      {
        name: "files.read",
        description: "Read a file",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Only the media row earns a header button: the server hasConfig flag is
    // the sole authority, so email and files rows without a flagged tool stay
    // clean even though their sections still render with bulk toggles.
    await waitFor(() => {
      expect(screen.getByText("Media & Streaming")).toBeDefined();
    });
    expect(screen.getByText("Email & Mailboxes")).toBeDefined();
    expect(screen.getByText("Files & Workspace")).toBeDefined();
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    expect(configureButtons[0].closest(".tool-category-actions")).not.toBeNull();
    expect(configureButtons[0].closest(".builtin-tool-card")).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
    // Bulk toggles stay beside the single Configure without interference.
    expect(screen.getAllByRole("button", { name: /Enable All|Disable All/ }).length).toBe(3);
    await user.click(configureButtons[0]);

    // Media header opens the existing Sonarr & Radarr editor, never fallback.
    expect(screen.getByRole("heading", { name: /Configure Media Automation/i })).toBeDefined();
    expect(screen.queryByText(/No configuration UI is available/i)).toBeNull();
  });

  it("keeps search, pills, empty-state, and bulk toggles intact for the combined category", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "browser.navigate",
        description: "Open a page",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "web.search",
        description: "Search the web",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: false,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "email.read",
        description: "Read email messages",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Combined pill and section stay singular: one Browser pill covers both
    // prefixes, and the grid holds one Browser & Web section plus email.
    await waitFor(() => {
      expect(screen.getByText("Browser & Web")).toBeDefined();
    });
    expect(document.querySelectorAll(".tool-category-section").length).toBe(2);
    expect(screen.getByText("browser.navigate")).toBeDefined();
    expect(screen.getByText("web.search")).toBeDefined();
    // Pills stay singular too: All plus one per visible category, with a single
    // Browser pill and no standalone Web pill left behind. Scoped to the pills
    // bar because the sidenav Web tab also renders /^Web$/.
    expect(document.querySelectorAll(".tools-category-pill").length).toBe(3);
    const pillsBar = document.querySelector(".tools-category-pills");
    expect(pillsBar).not.toBeNull();
    expect(within(pillsBar as HTMLElement).getByText("Browser")).toBeDefined();
    expect(within(pillsBar as HTMLElement).queryByText(/^Web$/)).toBeNull();
    // Search input keeps its accessible shape; pills keep counts.
    const searchInput = document.querySelector("input.tools-search-input") as HTMLInputElement | null;
    expect(searchInput).not.toBeNull();
    expect(searchInput?.getAttribute("type")).toBe("search");
    expect(screen.getAllByRole("button", { name: /All/i }).length).toBeGreaterThan(0);
    // Bulk toggles render per visible category and stay interactive.
    const bulkButtons = screen.getAllByRole("button", { name: /Enable All|Disable All/ });
    expect(bulkButtons.length).toBe(2);
    // One header Configure for the combined surface, none for email.
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    expect(configureButtons[0].closest(".tool-category-actions")).not.toBeNull();

    // Unmatched filter renders the empty state with a reset that restores the
    // grid, proving search and pill filtering never strand the pane.
    const searchBox = screen.getByPlaceholderText(/Search tools by name or description/i);
    await user.clear(searchBox);
    await user.type(searchBox, "zzz-no-such-tool");
    await waitFor(() => {
      expect(screen.getByText(/No tools match your filter criteria/i)).toBeDefined();
    });
    await user.click(screen.getByRole("button", { name: /Reset filters/i }));
    await waitFor(() => {
      expect(screen.getByText("Browser & Web")).toBeDefined();
    });
    expect(screen.getByText("browser.navigate")).toBeDefined();
  });

  it("routes bash.exec to the Bash & Shell category with its own pill and Configure", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "bash.exec",
        description: "Run shell commands",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "email.read",
        description: "Read email messages",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: false,
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Bash groups under its own section rather than falling through to
    // Other Tools, with a dedicated pill beside the email pill.
    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    expect(screen.getByText("Email & Mailboxes")).toBeDefined();
    expect(screen.queryByText("Other Tools")).toBeNull();
    expect(document.querySelectorAll(".tool-category-section").length).toBe(2);
    expect(screen.getByText("bash.exec")).toBeDefined();
    expect(document.querySelectorAll(".tools-category-pill").length).toBe(3);
    const pillsBar = document.querySelector(".tools-category-pills");
    expect(pillsBar).not.toBeNull();
    expect(within(pillsBar as HTMLElement).getByText("Bash")).toBeDefined();
    expect(within(pillsBar as HTMLElement).getByText("Email")).toBeDefined();
    // Only the bash row earns a header button: the server hasConfig flag is
    // the sole authority, so the email section stays clean.
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    expect(configureButtons[0].closest(".tool-category-actions")).not.toBeNull();
    expect(configureButtons[0].closest(".builtin-tool-card")).toBeNull();
    await user.click(configureButtons[0]);

    // Header Configure opens the Bash editor, never the fallback.
    expect(screen.getByRole("heading", { name: /Configure Bash & Shell/i })).toBeDefined();
    expect(screen.queryByText(/No configuration UI is available/i)).toBeNull();
  });

  it("saves the Security Files & Access section through the shared files payload", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "files.read",
        description: "Read a file",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "files.grep",
        description: "Search files",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithFiles,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFiles);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);

    // Security owns the single Files & Access editor through the shared
    // files payload helper; Tools owns no files editor.
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // The Security section mirrors the guard form through the shared payload helper.
    expect(screen.getByLabelText(/Deny patterns, one per line/i)).toBeDefined();
    expect(screen.getByLabelText(/Allowed roots, one per line/i)).toBeDefined();
    expect(screen.getByLabelText(/Require approval on deny/i)).toBeDefined();

    // Single page Save owns the persist with no section Save Configuration;
    // the header scope note states the sharing boundary once and no
    // consumer note remains.
    expect(
      screen.queryByRole("button", { name: /Save Configuration/i })
    ).toBeNull();
    expect(screen.getByText(/Allow roots bound/i)).toBeDefined();
    expect(screen.queryByTestId("files-consumer-note")).toBeNull();

    await user.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([".env*"]);
    expect(sentPayload?.["filesAllowRoots"]).toEqual(["~"]);
    expect(sentPayload?.["filesRequireApprovalOnDeny"]).toBe(true);
  });

  it("saves the Bash & Shell modal with the ordered bash payload", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "bash.exec",
        description: "Run shell commands",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const settingsWithBash = {
      ...mockSettings,
      bash: {
        enabled: true,
        default_action: "ask",
        rules: [{ pattern: "*", action: "ask" }],
        timeout_seconds: 30,
        allow_network: false,
      },
    };
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithBash,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithBash);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    await user.click(configureButtons[0]);

    // The Bash modal carries the full shell policy: enable, default action,
    // ordered rules, timeout, and network isolation.
    expect(screen.getByRole("heading", { name: /Configure Bash & Shell/i })).toBeDefined();
    expect(screen.getByLabelText(/Default action/i)).toBeDefined();
    expect(screen.getByLabelText(/Timeout \(seconds\)/i)).toBeDefined();
    expect(screen.queryByText(/No configuration UI is available/i)).toBeNull();

    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const bash = (sentPayload as unknown as Record<string, unknown>)["bash"] as Record<
      string,
      unknown
    >;
    expect(bash).toBeDefined();
    expect(bash["enabled"]).toBe(true);
    expect(bash["default_action"]).toBe("ask");
    expect(bash["rules"]).toEqual([{ pattern: "*", action: "ask" }]);
    expect(bash["timeout_seconds"]).toBe(30);
    expect(bash["allow_network"]).toBe(false);
  });

  it("pins the bash textarea contract with ordered last-match rules", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "bash.exec",
        description: "Run shell commands",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const settingsWithBash = {
      ...mockSettings,
      bash: {
        enabled: true,
        default_action: "deny",
        rules: [
          { pattern: "*", action: "deny" },
          { pattern: "swiftformat *", action: "allow" },
        ],
        timeout_seconds: 30,
        allow_network: false,
      },
    };
    let sentPayload: Record<string, unknown> | null = null;
    let putCount = 0;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithBash,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithBash);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    await user.click(configureButtons[0]);
    expect(screen.getByRole("heading", { name: /Configure Bash & Shell/i })).toBeDefined();

    // Pinned by accessible label as a single textarea with the opencode
    // fixture rendered in order: catch-all first, specifics after.
    const rulesTextarea = screen.getByLabelText(
      /Rules, one per line/i
    ) as HTMLTextAreaElement;
    expect(rulesTextarea.tagName).toBe("TEXTAREA");
    expect(rulesTextarea.placeholder).toContain("* = deny");
    expect(rulesTextarea.value).toContain("* = deny");
    expect(rulesTextarea.value).toContain("swiftformat * = allow");
    // Format hint pins the `pattern = action` line shape with the closed
    // allow/ask/deny set and the top-to-bottom last-match-wins order.
    expect(screen.getByText(/pattern = action/i)).toBeDefined();
    expect(screen.getByText(/last matching rule wins/i)).toBeDefined();
    // Live count follows the parsed textarea rows.
    expect(screen.getByText(/2 rules/i)).toBeDefined();

    // No row model exists for bash rules: there are no per-rule inputs or
    // remove buttons, only the one textarea.
    expect(screen.queryByLabelText(/Rule 1/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /Remove.*rule/i })).toBeNull();
    expect(screen.getAllByLabelText(/Rules, one per line/i).length).toBe(1);

    // Add Rule focuses the editor for keyboard flow without altering the
    // parsed count by itself.
    await user.click(screen.getByRole("button", { name: /Add Rule/i }));
    await waitFor(() => {
      expect(document.activeElement).toBe(rulesTextarea);
    });
    expect(rulesTextarea.value.endsWith("\n")).toBe(true);
    expect(screen.getByText(/2 rules/i)).toBeDefined();

    // Blank lines and surrounding whitespace collapse on save with order
    // preserved top-to-bottom; the wire shape is an ordered rule array.
    // Malformed lines reject first with their editor line number and never
    // reach the network, so the ordered save below runs from a clean form.
    const editedTextarea = screen.getByLabelText(
      /Rules, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "* = deny\nnot a rule");
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));
    await waitFor(() => {
      expect(screen.getByText(/Line 2/i)).toBeDefined();
    });
    expect(putCount).toBe(0);

    // An unknown action on the right also rejects with its line number.
    // The Line 2 matcher disambiguates the validation error from the
    // format hint, which also mentions the allow/ask/deny set.
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "* = deny\nswiftformat * = maybe");
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));
    await waitFor(() => {
      expect(screen.getByText(/Line 2/i)).toBeDefined();
    });
    expect(
      screen.getByText(/Line 2: action must be allow, ask, or deny/i)
    ).toBeDefined();
    expect(putCount).toBe(0);

    // Ordered save runs last so the modal auto-close timer never strands a
    // follow-up step: blanks collapse and order is preserved top-to-bottom.
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "  * = deny  \n\nswiftformat * = allow\n   \n");
    expect(screen.getByText(/2 rules/i)).toBeDefined();
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const bash = (sentPayload as unknown as Record<string, unknown>)["bash"] as Record<
      string,
      unknown
    >;
    expect(bash["rules"]).toEqual([
      { pattern: "*", action: "deny" },
      { pattern: "swiftformat *", action: "allow" },
    ]);
  });

  it("keeps Files & Access in the Security pane", async () => {
    const user = userEvent.setup();
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*", "*.pem"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(settingsWithFiles))
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);

    // Security owns sandbox isolation plus Files & Access plus access
    // management; the file guard lives in Security as its own section.
    await waitFor(() => {
      expect(screen.getByText("Sandbox & Security Policy")).toBeDefined();
    });
    expect(screen.getByText("Files & Access")).toBeDefined();
    expect(screen.getByText("Blocked Paths")).toBeDefined();
    expect(screen.getByText("Allowed Roots")).toBeDefined();
    expect(screen.getByLabelText(/Deny patterns, one per line/i)).toBeDefined();
    expect(screen.getByLabelText(/Allowed roots, one per line/i)).toBeDefined();
    expect(screen.getByText("Apple Container Machine")).toBeDefined();
  });

  it("keeps bash.exec out of Other Tools", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "bash.exec",
        description: "Run shell commands",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "custom.widget",
        description: "Custom utility",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: false,
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Bash lands in its own section while the unknown prefix falls through
    // to Other Tools; neither section borrows the other's tool.
    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    expect(screen.getByText("Other Tools")).toBeDefined();
    expect(document.querySelectorAll(".tool-category-section").length).toBe(2);
    const pillsBar = document.querySelector(".tools-category-pills");
    expect(pillsBar).not.toBeNull();
    expect(within(pillsBar as HTMLElement).getByText("Bash")).toBeDefined();
    expect(within(pillsBar as HTMLElement).getByText("Other")).toBeDefined();
    const sections = Array.from(document.querySelectorAll(".tool-category-section"));
    const bashSection = sections.find((section) =>
      section.textContent?.includes("Bash & Shell")
    );
    const otherSection = sections.find((section) =>
      section.textContent?.includes("Other Tools")
    );
    expect(bashSection?.textContent).toContain("bash.exec");
    expect(bashSection?.textContent).not.toContain("custom.widget");
    expect(otherSection?.textContent).toContain("custom.widget");
    expect(otherSection?.textContent).not.toContain("bash.exec");
  });

  it("routes colliding external names to Other while keeping builtin bash.exec in Bash", () => {
    const builtinBash = {
      name: "bash.exec",
      description: "Run shell commands",
      permissionLevel: "requiresApproval",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: true,
      pluginID: null,
      source: "builtin",
      integrityStatus: "valid",
      hasConfig: true,
    };
    const pluginBashEvil = {
      name: "bash.evil",
      description: "External colliding name",
      permissionLevel: "readOnly",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: false,
      pluginID: "external.plugin",
      source: "plugin",
      integrityStatus: "valid",
    };
    const pluginFilesEvil = {
      name: "files.evil",
      description: "External colliding name",
      permissionLevel: "readOnly",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: false,
      pluginID: "external.plugin",
      source: "plugin",
      integrityStatus: "valid",
    };
    // Builtin shell entry stays in its section even with the provenance gate.
    expect(getToolCategory(builtinBash)).toBe("bash");
    // External names never join builtin sections regardless of prefix.
    expect(getToolCategory(pluginBashEvil)).toBe("other");
    expect(getToolCategory(pluginFilesEvil)).toBe("other");
    // String fallback has no provenance, so only exact known builtin names
    // resolve; colliding or unknown names fall through to Other.
    expect(getToolCategory("bash.exec")).toBe("bash");
    expect(getToolCategory("files.read")).toBe("files");
    expect(getToolCategory("bash.evil")).toBe("other");
    expect(getToolCategory("files.evil")).toBe("other");
    expect(getToolCategory("custom.widget")).toBe("other");
  });

  it("rejects an empty bash rule list before any network write", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "bash.exec",
        description: "Run shell commands",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const settingsWithBash = {
      ...mockSettings,
      bash: {
        enabled: true,
        default_action: "ask",
        rules: [{ pattern: "*", action: "ask" }],
        timeout_seconds: 30,
        allow_network: false,
      },
    };
    let putCount = 0;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        const sent = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithBash,
          ...sent,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithBash);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    await user.click(configureButtons[0]);
    expect(screen.getByRole("heading", { name: /Configure Bash & Shell/i })).toBeDefined();

    // Clearing the textarea leaves an empty list, which must fail closed
    // instead of falling through to the default action.
    const bashTextarea = screen.getByLabelText(
      /Rules, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(bashTextarea);
    expect(screen.getByText(/0 rules/i)).toBeDefined();

    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(screen.getByText(/Invalid bash rules/i)).toBeDefined();
    });
    expect(screen.getByText(/At least one rule is required/i)).toBeDefined();
    expect(putCount).toBe(0);
  });

  it("reads camelCase bash aliases while sending snake_case keys", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "bash.exec",
        description: "Run shell commands",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const settingsWithCamelBash = {
      ...mockSettings,
      bash: {
        enabled: true,
        defaultAction: "deny",
        rules: [{ pattern: "git *", action: "allow" }],
        timeoutSeconds: 45,
        allowNetwork: true,
      },
    };
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithCamelBash,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithCamelBash);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    await user.click(configureButtons[0]);
    expect(screen.getByRole("heading", { name: /Configure Bash & Shell/i })).toBeDefined();

    // Camel aliases populate the same fields as the snake keys, with rules
    // serialized as `pattern = action` lines preserving order.
    const defaultSelect = screen.getByLabelText(/Default action/i) as HTMLSelectElement;
    expect(defaultSelect.value).toBe("deny");
    expect(screen.getByDisplayValue("45")).toBeDefined();
    expect(screen.getByDisplayValue("git * = allow")).toBeDefined();

    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const bash = (sentPayload as unknown as Record<string, unknown>)["bash"] as Record<
      string,
      unknown
    >;
    expect(bash).toBeDefined();
    expect(bash["default_action"]).toBe("deny");
    expect(bash["timeout_seconds"]).toBe(45);
    expect(bash["allow_network"]).toBe(true);
    expect(bash["rules"]).toEqual([{ pattern: "git *", action: "allow" }]);
  });

  it("edits allowed roots via the Security textarea with live count, reset, and array payload", async () => {
    const user = userEvent.setup();
    let sentPayload: Record<string, unknown> | null = null;
    let putCount = 0;
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*"],
      filesAllowRoots: ["~/custom"],
      filesRequireApprovalOnDeny: true,
    };
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithFiles,
          ...sentPayload,
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: [] });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFiles);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // Roots textarea is pinned by its accessible label and stays a single
    // multiline editor through the shared roots codec.
    const rootsTextarea = screen.getByLabelText(
      /Allowed roots, one per line/i
    ) as HTMLTextAreaElement;
    expect(rootsTextarea.tagName).toBe("TEXTAREA");
    expect(rootsTextarea.placeholder).toContain("~");
    expect(rootsTextarea.value).toContain("~/custom");
    expect(screen.getByText(/1 root/i)).toBeDefined();
    expect(screen.getByText(/Order is display-only/i)).toBeDefined();

    // No row model exists for roots: there are no per-root inputs or remove
    // buttons, only the one textarea. The single editor keeps small screens
    // and copy-paste of root sets working.
    expect(screen.queryByLabelText(/Root 1/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /Remove.*root/i })).toBeNull();
    expect(screen.getAllByLabelText(/Allowed roots, one per line/i).length).toBe(1);

    // Header scope note states the sharing boundary once directly under
    // Files & Access: allow roots bound live access while denied paths skip
    // everywhere including the index, and no consumer note remains.
    expect(screen.getByText(/Allow roots bound/i)).toBeDefined();
    expect(screen.getByText(/do not affect index coverage/i)).toBeDefined();
    expect(screen.queryByTestId("files-consumer-note")).toBeNull();

    // No Add Roots action remains: the single textarea is the only editor.
    expect(screen.queryByRole("button", { name: /Add Roots/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /Add Pattern/i })).toBeNull();

    // Reset rewrites only the form text after an explicit confirm and never
    // persists until Save. Cancelling leaves the in-progress text untouched.
    const resetRootsBtn = screen.getByRole("button", { name: /^Reset Roots$/i });
    await user.click(resetRootsBtn);
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom root/i)).toBeDefined();
    });
    expect(screen.getByText(/nothing is saved until you choose Save/i)).toBeDefined();
    const resetDialog = document.querySelector(".session-delete-modal") as HTMLElement;
    expect(resetDialog).not.toBeNull();
    await user.click(within(resetDialog).getByRole("button", { name: /Cancel/i }));
    expect(
      (screen.getByLabelText(/Allowed roots, one per line/i) as HTMLTextAreaElement).value
    ).toContain("~/custom");
    expect(putCount).toBe(0);

    // Confirming swaps the custom root for the home default; the old value
    // leaves the form so only the default remains visible.
    await user.click(screen.getByRole("button", { name: /^Reset Roots$/i }));
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom root/i)).toBeDefined();
    });
    await user.click(
      screen.getByRole("button", { name: /Confirm reset allowed roots/i })
    );
    await waitFor(() => {
      expect(screen.queryByDisplayValue("~/custom")).toBeNull();
    });
    expect(
      (screen.getByLabelText(/Allowed roots, one per line/i) as HTMLTextAreaElement).value
    ).toContain("~");
    expect(putCount).toBe(0);

    // Blank lines and surrounding whitespace collapse on save with order
    // preserved for display; the wire shape is a trimmed string array.
    // Single page Save owns the persist with no section Save Configuration.
    expect(
      screen.queryByRole("button", { name: /Save Configuration/i })
    ).toBeNull();
    const editedTextarea = screen.getByLabelText(
      /Allowed roots, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "  ~/a  \n\n~/b\n   \n");
    expect(screen.getByText(/2 roots/i)).toBeDefined();
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(sentPayload?.["filesAllowRoots"]).toEqual(["~/a", "~/b"]);
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([".env*"]);
    expect(sentPayload?.["filesRequireApprovalOnDeny"]).toBe(true);
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
    const putsAfterSave = putCount;

    // Traversal escapes fail closed with their editor line number.
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "~/a\n../escape");
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(screen.getByText(/Line 2.*\.\./i)).toBeDefined();
    });
    expect(putCount).toBe(putsAfterSave);

    // Empty means no roots: clearing the editor rejects with an error and
    // never reaches the network.
    await user.clear(editedTextarea);
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(screen.getByText(/Allowed roots cannot be empty/i)).toBeDefined();
    });
    expect(putCount).toBe(putsAfterSave);
  });

  it("points Tools Files to Security with no Configure button", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "files.read",
        description: "Read a file",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
      {
        name: "files.grep",
        description: "Search files",
        permissionLevel: "readOnly",
        inputSchema: "{}",
        isEnabled: true,
        isBuiltIn: true,
        pluginID: null,
        source: "builtin",
        integrityStatus: "valid",
        hasConfig: true,
      },
    ];
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        return jsonResponse(settingsWithFiles);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Tools owns the Files & Workspace category for toggles only: both file
    // tools share one section with bulk actions but no header Configure, even
    // though the server flags them with hasConfig. Security owns the editor,
    // so the Tools section points there instead of opening a modal.
    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Workspace")).toBeDefined();
    });
    expect(screen.getByText("files.read")).toBeDefined();
    expect(screen.getByText("files.grep")).toBeDefined();
    expect(
      screen.queryAllByRole("button", { name: /^Configure$/ }).length
    ).toBe(0);
    expect(screen.queryByRole("button", { name: /^Configure$/ })).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
    expect(
      screen.getAllByRole("button", { name: /Enable All|Disable All/ }).length
    ).toBeGreaterThan(0);
    // No inline file editors live in Tools: the roots textarea stays in Security.
    expect(screen.queryByLabelText(/Allowed roots, one per line/i)).toBeNull();
    expect(screen.queryByLabelText(/Deny patterns, one per line/i)).toBeNull();

    // The pointer target renders in Security as the single Files & Access editor.
    // The header scope note states the sharing boundary once directly under
    // the heading with no consumer note.
    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });
    expect(screen.getByLabelText(/Allowed roots, one per line/i)).toBeDefined();
    expect(screen.getByText(/Allow roots bound/i)).toBeDefined();
    expect(screen.getByText(/do not affect index coverage/i)).toBeDefined();
    expect(screen.queryByTestId("files-consumer-note")).toBeNull();
  });
});

// Declarative security policy (policy.toml) editor: load, save, and verify all
// sit behind the owner gate, so coverage pins honest server-truth rendering
// plus the dashboard's shared same-origin auth convention on every call.
const policyPayload = {
  policy: {
    version: 1,
    network: {
      mode: "allowlist_only",
      allowed_domains: ["api.example.com"],
      blocked_domains: ["metadata.google.internal"],
    },
    credentials: {
      GITHUB_TOKEN: {
        allowed_hosts: ["api.github.com"],
        allowed_methods: ["GET"],
        allowed_path_prefixes: ["/repos"],
      },
    },
  },
  raw_toml: 'version = 1\n[network]\nmode = "allowlist_only"\n',
  path: "/Users/test/.runeweaver/policy.toml",
  loaded_from_disk: true,
  violations: [],
};

const policyCandidateToml = 'version = 1\n[network]\nmode = "deny_by_default"\n';

describe("SettingsManager declarative policy editor", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    resetSharedRunsForTesting();
  });

  // Routes the settings shell plus both policy routes so each case overrides
  // only the response it exercises; unrelated boot probes stay benign.
  function stubPolicyFetch(
    policyResponse: (init?: RequestInit) => Response | Promise<Response>
  ) {
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        if (urlStr === "/settings/policy" || urlStr === "/settings/policy/verify") {
          return policyResponse(init);
        }
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        return jsonResponse(mockSettings);
      }
    );
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  async function openPolicySection() {
    const user = userEvent.setup();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Security/i }));
    await waitFor(() => {
      expect(screen.getByTestId("security-policy-section")).toBeDefined();
    });
    return user;
  }

  // Waits for the policy fetch to settle: the mode badge proves the DTO landed
  // and the enabled Save proves the loading guard released, so a disabled
  // button never swallows the next click.
  async function waitForPolicyLoaded() {
    await waitFor(() => {
      expect(screen.getByText(/Mode: allowlist_only/)).toBeDefined();
      expect(
        (screen.getByRole("button", { name: /Save Policy/i }) as HTMLButtonElement).disabled
      ).toBe(false);
    });
  }

  it("loads the policy into the visual overview and the raw editor", async () => {
    const fetchMock = stubPolicyFetch(() => jsonResponse(policyPayload));
    const user = await openPolicySection();

    await waitForPolicyLoaded();
    // The header names the real file state instead of claiming defaults, and
    // the overview reads the file's allow/deny sets and credential bindings.
    expect(screen.getByText(/Customized/)).toBeDefined();
    expect(screen.getByText("api.example.com")).toBeDefined();
    expect(screen.getByText("metadata.google.internal")).toBeDefined();
    expect(screen.getByText("GITHUB_TOKEN")).toBeDefined();
    expect(screen.getByText(/All 4 Formal Security Invariants Verified/)).toBeDefined();

    // The raw editor starts from the exact server TOML so edits are applied
    // to file truth rather than a locally reconstructed approximation.
    await user.click(screen.getByRole("button", { name: /Raw TOML Editor/i }));
    expect(
      (screen.getByLabelText(/Edit policy\.toml directly/i) as HTMLTextAreaElement).value
    ).toBe(policyPayload.raw_toml);

    const loadCall = fetchMock.mock.calls.find(
      ([url]) => String(url) === "/settings/policy"
    );
    expect(loadCall?.[1]).toMatchObject({ credentials: "same-origin" });
  });

  it("reports a failed policy load in the section error banner", async () => {
    stubPolicyFetch(() => jsonResponse({ reason: "policy file unreadable" }, 500));
    await openPolicySection();

    await waitFor(() => {
      expect(screen.getByText(/Failed to load policy/i)).toBeDefined();
    });
  });

  it("surfaces the server reason when a policy save is rejected", async () => {
    const fetchMock = stubPolicyFetch((init) => {
      if (init?.method === "PUT") {
        return jsonResponse(
          { reason: "Invariant violation: credential targets loopback." },
          422
        );
      }
      return jsonResponse(policyPayload);
    });
    const user = await openPolicySection();
    await waitForPolicyLoaded();

    await user.click(screen.getByRole("button", { name: /Raw TOML Editor/i }));
    const editor = screen.getByLabelText(/Edit policy\.toml directly/i);
    fireEvent.change(editor, { target: { value: policyCandidateToml } });
    await user.click(screen.getByRole("button", { name: /Save Policy/i }));

    await waitFor(() => {
      expect(
        screen.getByText(/Invariant violation: credential targets loopback\./)
      ).toBeDefined();
    });
    // A rejected candidate stays in the editor so the owner can fix it in
    // place, and the write itself carried the shared auth convention.
    expect((editor as HTMLTextAreaElement).value).toBe(policyCandidateToml);
    const putCall = fetchMock.mock.calls.find(
      ([url, init]) => String(url) === "/settings/policy" && init?.method === "PUT"
    );
    expect(putCall?.[1]?.credentials).toBe("same-origin");
    expect(JSON.parse(String(putCall?.[1]?.body))).toEqual({
      raw_toml: policyCandidateToml,
    });
  });

  it("renders violations returned by a candidate verify", async () => {
    const violation = "Credential binding targets loopback (127.0.0.1).";
    const fetchMock = stubPolicyFetch((init) => {
      if (init?.method === "POST") {
        return jsonResponse({ valid: false, violations: [violation] });
      }
      return jsonResponse(policyPayload);
    });
    const user = await openPolicySection();
    await waitForPolicyLoaded();

    await user.click(screen.getByRole("button", { name: /Verify/i }));
    await waitFor(() => {
      expect(screen.getByText(/1 Invariant Violation\(s\) Detected/)).toBeDefined();
    });
    expect(screen.getByText(violation)).toBeDefined();

    const verifyCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === "/settings/policy/verify" && init?.method === "POST"
    );
    expect(verifyCall?.[1]?.credentials).toBe("same-origin");
    expect(JSON.parse(String(verifyCall?.[1]?.body))).toEqual({
      raw_toml: policyPayload.raw_toml,
    });
  });

  it("confirms a clean candidate verify and clears prior violations", async () => {
    const loadedPolicy = {
      ...policyPayload,
      violations: ["Stale violation from a hand-edited file."],
    };
    stubPolicyFetch((init) => {
      if (init?.method === "POST") {
        return jsonResponse({ valid: true, violations: [] });
      }
      return jsonResponse(loadedPolicy);
    });
    const user = await openPolicySection();
    await waitFor(() => {
      expect(screen.getByText(/1 Invariant Violation\(s\) Detected/)).toBeDefined();
    });
    expect(screen.getByText(/Stale violation from a hand-edited file\./)).toBeDefined();

    await user.click(screen.getByRole("button", { name: /Verify/i }));
    await waitFor(() => {
      expect(screen.getByText(/All 4 Formal Security Invariants Verified/)).toBeDefined();
      expect(screen.getByText(/saved successfully/i)).toBeDefined();
    });
  });

  it("carries the owner bearer on policy load, save, and verify", async () => {
    // Token mode is exactly where a bare fetch 401s, so pin the convention on
    // all three policy calls: same-origin credentials plus the configured
    // bearer alongside any JSON content type.
    setAuthToken("policy-owner-token");
    try {
      const fetchMock = stubPolicyFetch((init) => {
        if (init?.method === "POST") {
          return jsonResponse({ valid: true, violations: [] });
        }
        return jsonResponse(policyPayload);
      });
      const user = await openPolicySection();
      await waitForPolicyLoaded();

      await user.click(screen.getByRole("button", { name: /Save Policy/i }));
      await waitFor(() => {
        expect(screen.getByText(/saved successfully/i)).toBeDefined();
      });
      await user.click(screen.getByRole("button", { name: /Verify/i }));
      await waitFor(() => {
        expect(
          fetchMock.mock.calls.filter(([url]) =>
            String(url).startsWith("/settings/policy")
          )
        ).toHaveLength(3);
      });

      const policyCalls = fetchMock.mock.calls.filter(([url]) =>
        String(url).startsWith("/settings/policy")
      );
      for (const [, init] of policyCalls) {
        expect(init?.credentials).toBe("same-origin");
        expect((init?.headers as Record<string, string>).Authorization).toBe(
          "Bearer policy-owner-token"
        );
      }
    } finally {
      clearAuthToken();
    }
  });
});

describe("secret status chunk contract", () => {
  it("pins the badge-probe chunk size to the server status cap", () => {
    // Single cross-language contract: the server owns `maxSecretStatusKeys` in
    // `Sources/RuneWeaverServer/ServerSettingsRoutes.swift` and this mirror
    // must stay equal at 500 so badge-probe chunks never trip the status gate;
    // update both together.
    expect(SECRET_STATUS_CHUNK_SIZE).toBe(500);
  });
});

describe("bash defaults and bounds contract", () => {
  it("pins the bash mirrors to the engine BashConfig", () => {
    // Single cross-language contract: the server owns the defaults in
    // `Sources/RuneWeaverCore/Config.swift` (BashConfig) and the bounds in
    // `Sources/RuneWeaverCore/Config+Validation.swift` plus
    // `Sources/RuneWeaverServer/ServerBashDTOs.swift`; these mirrors must
    // stay equal so the fresh form and the client validator never drift from
    // the engine. Update both together.
    expect(DEFAULT_BASH_ENABLED).toBe(true);
    expect(DEFAULT_BASH_DEFAULT_ACTION).toBe("ask");
    expect(DEFAULT_BASH_TIMEOUT_SECONDS).toBe(30);
    expect(DEFAULT_BASH_ALLOW_NETWORK).toBe(false);
    expect(DEFAULT_BASH_RULES).toEqual([{ pattern: "*", action: "ask" }]);
    expect(DEFAULT_BASH_CONFIG.enabled).toBe(DEFAULT_BASH_ENABLED);
    expect(DEFAULT_BASH_CONFIG.default_action).toBe(DEFAULT_BASH_DEFAULT_ACTION);
    expect(DEFAULT_BASH_CONFIG.timeout_seconds).toBe(DEFAULT_BASH_TIMEOUT_SECONDS);
    expect(DEFAULT_BASH_CONFIG.allow_network).toBe(DEFAULT_BASH_ALLOW_NETWORK);
    expect(DEFAULT_BASH_CONFIG.rules).toEqual(DEFAULT_BASH_RULES);
    expect([...BASH_PERMISSION_ACTIONS]).toEqual(["allow", "ask", "deny"]);
    expect(BASH_TIMEOUT_MIN_SECONDS).toBe(1);
    expect(BASH_TIMEOUT_MAX_SECONDS).toBe(3600);
  });
});


