// Rune Weaver Dashboard — Component tests for SettingsManager.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager, { SECRET_STATUS_CHUNK_SIZE } from "./SettingsManager";
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
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*", "*.pem"],
      filesAllowRoots: ["~"],
      filesRequireApprovalOnDeny: true,
    };
    const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithFiles,
          ...sentPayload,
        });
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

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([".env*", "*.pem", ".ssh/*"]);

    // Traversal escapes fail closed with their editor line number so the
    // author can jump straight to the offending glob.
    await user.clear(denyTextarea);
    await user.type(denyTextarea, ".env*\n../escape\n*.pem");
    await user.click(saveButton);
    await waitFor(() => {
      expect(screen.getByText(/Line 2.*\.\./i)).toBeDefined();
    });

    // Empty means allow all in scope: clearing the editor saves an empty
    // array and surfaces the allow-all hint instead of an error.
    await user.clear(denyTextarea);
    await user.click(saveButton);
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([]);
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

    const denyTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    expect(denyTextarea.value).toContain("custom*");

    // Reset opens a shared confirmation stating counts and the form-local
    // nature; cancelling leaves the in-progress text untouched.
    const resetDenyBtn = screen.getByRole("button", { name: /Reset to Defaults/i });
    await user.click(resetDenyBtn);
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom pattern/i)).toBeDefined();
    });
    expect(screen.getByText(/nothing is saved until you choose Save/i)).toBeDefined();
    await user.click(screen.getByRole("button", { name: /Cancel/i }));
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

  it("uses ghost icon buttons in Reset-then-Add order for files and roots", async () => {
    const user = userEvent.setup();
    const settingsWithFiles = {
      ...mockSettings,
      filesDenyPatterns: [".env*"],
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

    // Ghost treatment carries the hover and alignment tokens; secondary
    // buttons have no stylesheet entry and render misaligned, so every
    // header action must use the shared ghost icon style.
    const resetDefaultsBtn = screen.getByRole("button", { name: /Reset to Defaults/i });
    const addPatternBtn = screen.getByRole("button", { name: /Add Pattern/i });
    for (const btn of [resetDefaultsBtn, addPatternBtn]) {
      expect(btn.className).toContain("ghost");
      expect(btn.className).toContain("icon-text-btn");
    }
    // Reset precedes Add to match the roots subsection below it.
    expect(
      Boolean(
        resetDefaultsBtn.compareDocumentPosition(addPatternBtn) &
          Node.DOCUMENT_POSITION_FOLLOWING
      )
    ).toBe(true);

    const resetRootsBtn = screen.getByRole("button", { name: /Reset Roots/i });
    const addRootBtn = screen.getByRole("button", { name: /Add Root/i });
    for (const btn of [resetRootsBtn, addRootBtn]) {
      expect(btn.className).toContain("ghost");
      expect(btn.className).toContain("icon-text-btn");
    }
    expect(
      Boolean(
        resetRootsBtn.compareDocumentPosition(addRootBtn) &
          Node.DOCUMENT_POSITION_FOLLOWING
      )
    ).toBe(true);

    // Subsection headings keep each policy surface discoverable in one pane.
    expect(screen.getByText("Blocked Paths")).toBeDefined();
    expect(screen.getByText("Allowed Roots")).toBeDefined();
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


