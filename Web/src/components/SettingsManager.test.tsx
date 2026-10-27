// Rune Weaver Dashboard — Component tests for SettingsManager.

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager, { SECRET_STATUS_CHUNK_SIZE, getToolCategory, isSettingsTab } from "./SettingsManager";
import { peekPersonaSignals } from "./PersonaAvatar";
import {
  BASH_CPU_MAX_SECONDS,
  BASH_CPU_MIN_SECONDS,
  BASH_HOST_ALLOW_PATTERNS_MAX,
  BASH_HOST_ALLOW_PATTERN_MAX_LENGTH,
  BASH_MEMORY_MAX_MB,
  BASH_MEMORY_MIN_MB,
  BASH_PERMISSION_ACTIONS,
  BASH_SANDBOX_COPY,
  BASH_SANDBOX_MODES,
  BASH_SANDBOX_TIERS,
  BASH_TIMEOUT_MAX_SECONDS,
  BASH_TIMEOUT_MIN_SECONDS,
  CONTAINERS_MAX_CONCURRENT_MAX,
  CONTAINERS_MAX_CONCURRENT_MIN,
  CONTAINERS_MEMORY_MAX_MB,
  CONTAINERS_MEMORY_MIN_MB,
  CONTAINERS_TTL_MAX_MINUTES,
  CONTAINERS_TTL_MIN_MINUTES,
  bashSandboxSummary,
  clearAuthToken,
  DEFAULT_BASH_ALLOW_NETWORK,
  DEFAULT_BASH_CONFIG,
  DEFAULT_BASH_CPU_SECONDS,
  DEFAULT_BASH_DEFAULT_ACTION,
  DEFAULT_BASH_ENABLED,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS,
  DEFAULT_BASH_MEMORY_MB,
  DEFAULT_BASH_RULES,
  DEFAULT_BASH_SANDBOX_MODE,
  DEFAULT_BASH_TIMEOUT_SECONDS,
  DEFAULT_CONTAINERS_MAX_CONCURRENT,
  DEFAULT_CONTAINERS_MEMORY_MB,
  DEFAULT_CONTAINERS_TTL_MINUTES,
  DEFAULT_PERSONA_AVATAR,
  DEFAULT_PERSONA_TONE,
  DEFAULT_WORKSPACE_CONFIG,
  DEFAULT_WORKSPACE_QUOTA_FILES,
  DEFAULT_WORKSPACE_QUOTA_MB,
  DEFAULT_WORKSPACE_TMP_TTL_DAYS,
  formatWorkspaceBytes,
  MAX_PERSONA_ASSISTANT_NAME_LENGTH,
  MAX_PERSONA_STYLE_LENGTH,
  MAX_PERSONA_USER_NAME_LENGTH,
  PERSONA_AVATAR_COLORS,
  PERSONA_TONES,
  WORKSPACE_QUOTA_FILES_MAX,
  WORKSPACE_QUOTA_FILES_MIN,
  WORKSPACE_QUOTA_MB_MAX,
  WORKSPACE_QUOTA_MB_MIN,
  WORKSPACE_TMP_TTL_MAX_DAYS,
  WORKSPACE_TMP_TTL_MIN_DAYS,
  workspaceQuotaPercent,
} from "../api";
import { resetSharedRunsForTesting } from "../hooks/useRunningRuns";
import { jsonResponse } from "../test-utils/http";
import {
  createMockWebSocket,
  createMockWebSocketCapture,
  dispatchFrameOrThrow,
  resetSharedSocket,
} from "../test-utils/mockWebSocket";

const mockSettings = {
  engineName: "Test Engine",
  logLevel: "info",
  defaultProvider: "mlx",
  fallbackProvider: "openrouter",
  providers: {
    mlx: {
      enabled: true,
      model: "gemma-4-9b",
      serverURL: "http://localhost:8080",
      apiStyle: "openai",
      contextLength: 32000,
    },
    openrouter: {
      enabled: true,
      model: "anthropic/claude-3.5-sonnet",
      serverURL: "https://openrouter.ai/api/v1",
      apiKeyEnv: "OPENROUTER_API_KEY",
      apiStyle: "openai",
      contextLength: 128000,
    },
  },
  memoryVectorDBPath: "memory/vectors",
  memoryEpisodesDBPath: "memory/episodes.db",
  memoryEmbeddingModel: "bge-small-en-v1.5",
  memoryEmbeddingBackend: "local",
  voiceSTTProvider: "whisper",
  voiceWhisperModel: "base.en",
  voiceTTSProvider: "system",
  containers: {
    memoryMb: DEFAULT_CONTAINERS_MEMORY_MB,
    maxConcurrent: DEFAULT_CONTAINERS_MAX_CONCURRENT,
    ttlMinutes: DEFAULT_CONTAINERS_TTL_MINUTES,
  },
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
  pluginsMarketplaceIndexURL:
    "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json",
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

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
      expect(screen.getByDisplayValue("http://localhost:8080")).toBeDefined();
      expect(screen.getByText("/Users/test/.runeweaver/config.toml")).toBeDefined();
    });

    const engineTabBtn = screen.getByRole("tab", { name: /Engine and Logs/i });
    await user.click(engineTabBtn);
    expect(screen.getByDisplayValue("Test Engine")).toBeDefined();

    const sandboxTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(sandboxTabBtn);
    // Containers contract: no legacy sandbox editors remain; pinned images are read-only text.
    expect(screen.queryByLabelText(/Staging Path/i)).toBeNull();
    expect(screen.queryByLabelText(/Retention/i)).toBeNull();
    expect(screen.queryByLabelText(/Max Total Size/i)).toBeNull();
    expect(screen.queryByLabelText(/Cleanup Interval/i)).toBeNull();
    expect(screen.queryByDisplayValue("sandbox/staging")).toBeNull();
    expect(screen.queryByLabelText(/Container Runtime/i)).toBeNull();
    expect(screen.queryByLabelText(/Base Image/i)).toBeNull();
    expect(screen.getByTestId("containers-strict-image").textContent).toContain(
      "debian:stable-slim"
    );
    expect(screen.getByTestId("containers-machine-image").textContent).toContain(
      "debian:stable-slim"
    );
    expect(screen.getByTestId("containers-detonation-image").textContent).toContain(
      "alpine:3.22"
    );
    expect(screen.queryByDisplayValue("debian:stable-slim")).toBeNull();
    expect(screen.queryByDisplayValue("alpine:3.22")).toBeNull();
    expect(screen.getByLabelText(/Memory \(MB\)/i)).toBeDefined();
    expect(screen.getByLabelText(/Max Concurrent Containers/i)).toBeDefined();
    expect(screen.getByLabelText(/Idle TTL/i)).toBeDefined();

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

    const addProviderBtn = screen.getByRole("button", { name: /Add Provider/i });
    await user.click(addProviderBtn);

    expect(screen.getByDisplayValue("provider_3")).toBeDefined();

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

    const emailTabBtn = screen.getByRole("tab", { name: /Email Accounts/i });
    await user.click(emailTabBtn);

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

    const memoryTabBtn = screen.getByRole("tab", { name: /Memory and Storage/i });
    await user.click(memoryTabBtn);

    const backendSelect = screen.getByLabelText(/Embedding Backend/i) as HTMLSelectElement;
    expect(backendSelect.value).toBe("local");

    // No editable model input: provider follows the chat model and local is
    // managed on-device, so the prior value stays hidden but persisted.
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
    expect(screen.getAllByText(/EmbeddingGemma 2/i).length).toBeGreaterThan(0);
    expect(screen.getByText(/active chat model/i)).toBeDefined();
    expect(screen.getByText(/keyword-only/i)).toBeDefined();

    await user.selectOptions(backendSelect, "provider");
    expect(backendSelect.value).toBe("provider");

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    expect(sentPayload).toBeDefined();
    expect((sentPayload as unknown as Record<string, unknown>)["memoryEmbeddingBackend"]).toBe("provider");
    // Prior model value persists untouched for forward compatibility.
    expect((sentPayload as unknown as Record<string, unknown>)["memoryEmbeddingModel"]).toBe("bge-small-en-v1.5");
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
        name: "memories.store",
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

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    await waitFor(() => {
      expect(screen.getByText(/awaiting review/i)).toBeDefined();
      expect(screen.getByText("Weather Reporter")).toBeDefined();
      expect(screen.getAllByText(/PENDING REVIEW/i).length).toBeGreaterThan(0);
    });

    const enableBtn = screen.getByRole("button", { name: /Approve & Enable/i });
    expect(enableBtn).toBeDefined();

    await user.click(enableBtn);

    await waitFor(() => {
      expect(enableCalled).toBe(true);
      expect(screen.getByText(/Enabled rune 'Weather Reporter'/i)).toBeDefined();
    });
  });

  it("shows marketplace entry point alongside plugin rescan", async () => {
    const user = userEvent.setup();
    const discoveredRune = {
      id: "community.weather", name: "Weather Reporter", version: "1.0.0",
      description: "Fetches current weather.", runtime: "python", source: "local_disk",
      status: "discovered", isEnabled: false, integrityHash: null,
      tools: [{ name: "weather.get", description: "Get weather", permissionLevel: "readOnly", inputSchema: "{}", isEnabled: false, isBuiltIn: false, pluginID: "community.weather", source: "plugin", integrityStatus: "valid" }],
      permissionOverrides: {}, discoveredAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
    };
    const mockTools = [{ name: "memories.store", description: "Store persistent fact", permissionLevel: "readOnly", inputSchema: "{}", isEnabled: true, isBuiltIn: true, pluginID: null, source: "builtin", integrityStatus: "valid" }];
    const marketplaceItems = [
      { id: "community.market-weather", name: "Marketplace Weather", version: "1.0.0", author: "Community", description: "Fetches current weather from the catalog.", downloadURL: "https://example.com/weather.json", tags: ["weather"], runtime: "python", declaredTools: ["weather.get"], isInstalled: false },
      { id: "community.clock", name: "World Clock", version: "1.0.0", author: "Community", description: "Shows time across zones.", downloadURL: "https://example.com/clock.json", tags: ["time"], runtime: "python", declaredTools: ["clock.current_time"], isInstalled: true },
    ];

    // Empty registry with two catalog runes.
    const fetchMock = vi.fn(async (url: string | URL | Request) => {
      const urlStr = String(url);
      if (urlStr.includes("/marketplace/plugins")) {
        return jsonResponse({ items: marketplaceItems, count: 2 });
      }
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

    await waitFor(() => {
      expect(
        screen.getByText(/No external runes discovered in plugins directory/i)
      ).toBeDefined();
    });
    expect(screen.getByText(/Rescan Plugins to discover them/i)).toBeDefined();

    const browseBtn = screen.getByRole("button", { name: /Browse Marketplace/i });
    expect(browseBtn).toBeDefined();

    expect(screen.getByLabelText(/^Plugins Directory$/i)).toBeDefined();
    expect(screen.getByLabelText(/Marketplace Index URL/i)).toBeDefined();

    await user.click(browseBtn);
    await waitFor(() => {
      expect(screen.getByText("Community Rune Marketplace")).toBeDefined();
    });
    await waitFor(() => {
      expect(screen.getByText("Marketplace Weather")).toBeDefined();
      expect(screen.getByText("World Clock")).toBeDefined();
    });
    expect(screen.getByPlaceholderText(/Search runes by name/i)).toBeDefined();
    const marketplaceDialog = screen.getByRole("dialog", { name: /Rune Marketplace/i });
    expect(within(marketplaceDialog).queryByRole("button", { name: /^Refresh$/i })).not.toBeNull();
    const marketplaceInstallButton = screen.getByRole("button", { name: /^Install$/i });
    expect(marketplaceInstallButton).toBeDefined();
    expect(marketplaceInstallButton.className).toContain("primary");
    expect(marketplaceInstallButton.className).not.toContain("btn-primary");
    expect(screen.getByText(/^Installed$/i)).toBeDefined();
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/marketplace/plugins"))).toBe(true);

    await user.click(screen.getByRole("button", { name: /Close marketplace/i }));
    const rescanBtn = screen.getByRole("button", { name: /Rescan Plugins/i });
    await user.click(rescanBtn);

    await waitFor(() => {
      expect(screen.getByText("Weather Reporter")).toBeDefined();
    });
    expect(screen.getByRole("button", { name: /Browse Marketplace/i })).toBeDefined();
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/plugins/rescan"))).toBe(true);
  });

  it("disables an enabled builtin tool via the tool state endpoint with per-row pending", async () => {
    const user = userEvent.setup();
    // Sibling tools prove per-tool granularity.
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
    // Hold POST open to observe the pending row.
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

    // Switch mirrors persisted bus flag.
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
    expect(screen.getAllByText("Enabled").length).toBeGreaterThan(0);
    expect(
      screen.queryByRole("switch", { name: "Disable email.read" })
    ).toBeNull();
    expect(
      screen.queryByRole("switch", { name: "Enable email.read" })
    ).toBeNull();
    // Track/knob mirrors persisted state.
    const tracks = document.querySelectorAll(".builtin-tool-card .tool-switch-track");
    expect(tracks.length).toBe(2);
    tracks.forEach((track) => {
      expect(track.getAttribute("data-on")).toBe("true");
      expect(track.querySelector(".tool-switch-thumb")).not.toBeNull();
    });

    const clickPromise = user.click(readToggle);

    // Pending gate isolates the acted-on row.
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

    // Refreshed list flips only the toggled switch.
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
    const refreshedTracks = document.querySelectorAll(".builtin-tool-card .tool-switch-track");
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

    // Sibling stays off: no bulk enable.
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

  it("allows configuring container settings and saving", async () => {
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

    // Containers contract: pinned images read-only, no legacy editors.
    expect(screen.queryByLabelText(/Container Runtime/i)).toBeNull();
    expect(screen.queryByLabelText(/Base Image/i)).toBeNull();
    expect(screen.queryByLabelText(/Staging Path/i)).toBeNull();
    expect(screen.queryByLabelText(/Retention/i)).toBeNull();
    expect(screen.queryByLabelText(/Max Total Size/i)).toBeNull();
    expect(screen.queryByLabelText(/Cleanup Interval/i)).toBeNull();
    expect(screen.getByTestId("containers-strict-image").textContent).toContain(
      "debian:stable-slim"
    );
    expect(screen.getByTestId("containers-machine-image").textContent).toContain(
      "debian:stable-slim"
    );
    expect(screen.getByTestId("containers-detonation-image").textContent).toContain(
      "alpine:3.22"
    );
    expect(screen.queryByDisplayValue("debian:stable-slim")).toBeNull();
    expect(screen.queryByDisplayValue("alpine:3.22")).toBeNull();

    const memoryInput = screen.getByLabelText(/Memory \(MB\)/i);
    await user.clear(memoryInput);
    await user.type(memoryInput, "1024");

    const maxConcurrentInput = screen.getByLabelText(/Max Concurrent Containers/i);
    await user.clear(maxConcurrentInput);
    await user.type(maxConcurrentInput, "7");

    const ttlInput = screen.getByLabelText(/Idle TTL/i);
    await user.clear(ttlInput);
    await user.type(ttlInput, "90");

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    expect(sentPayload).toBeDefined();
    // Patch carries snake_case engine keys.
    const containersPatch = sentPayload?.["containers"] as
      | Record<string, unknown>
      | undefined;
    expect(containersPatch?.["memoryMb"]).toBe(1024);
    expect(containersPatch?.["maxConcurrent"]).toBe(7);
    expect(containersPatch?.["ttlMinutes"]).toBe(90);
    // Replaced sandbox keys have no alias and must not send.
    expect(sentPayload).not.toHaveProperty("sandboxContainerBaseImage");
    expect(sentPayload).not.toHaveProperty("sandboxArchiveSessionTTLMinutes");
    expect(sentPayload).not.toHaveProperty("sandboxMaxConcurrentMachines");
    expect(sentPayload).not.toHaveProperty("sandboxStagingPath");
    expect(sentPayload).not.toHaveProperty("sandboxRetentionDays");
    expect(sentPayload).not.toHaveProperty("sandboxMaxTotalBytes");
    expect(sentPayload).not.toHaveProperty("sandboxCleanupIntervalSeconds");
    expect(sentPayload).not.toHaveProperty("sandboxContainerRuntime");
  });

  it("rejects out-of-range container knobs inline with no network write", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => {
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const sandboxTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(sandboxTabBtn);

    const memoryInput = screen.getByLabelText(/Memory \(MB\)/i);
    await user.clear(memoryInput);
    await user.type(memoryInput, "99999");

    const saveButton = screen.getByRole("button", { name: "Save" });
    await user.click(saveButton);

    // Out-of-range fails inline with no PUT.
    await waitFor(() => {
      expect(
        screen.getByText(
          new RegExp(
            `memoryMb must be between ${CONTAINERS_MEMORY_MIN_MB} and ${CONTAINERS_MEMORY_MAX_MB}`,
            "i",
          ),
        )
      ).toBeDefined();
    });
    expect(
      fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT")
    ).toHaveLength(0);
  });

  it("pins containers knob bounds to the server containers contract", () => {
    // Cross-language pin: match ContainersConfig in Config.swift.
    expect(DEFAULT_CONTAINERS_MEMORY_MB).toBe(512);
    expect(DEFAULT_CONTAINERS_MAX_CONCURRENT).toBe(5);
    expect(DEFAULT_CONTAINERS_TTL_MINUTES).toBe(60);
    expect(CONTAINERS_MEMORY_MIN_MB).toBe(256);
    expect(CONTAINERS_MEMORY_MAX_MB).toBe(8192);
    expect(CONTAINERS_MAX_CONCURRENT_MIN).toBe(1);
    expect(CONTAINERS_MAX_CONCURRENT_MAX).toBe(32);
    expect(CONTAINERS_TTL_MIN_MINUTES).toBe(5);
    expect(CONTAINERS_TTL_MAX_MINUTES).toBe(1440);
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

    // Open via Access tab Files rail.
    const accessTabBtn = screen.getByRole("tab", { name: "Access" });
    await user.click(accessTabBtn);
    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // Editor shows one-per-line shape.
    const denyTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    expect(denyTextarea.placeholder).toContain(".env*");
    expect(denyTextarea.placeholder).toContain("*.pem");
    expect(denyTextarea.placeholder).toContain(".ssh/*");
    expect(denyTextarea.value).toContain(".env*");
    expect(screen.getByText(/2 patterns/i)).toBeDefined();

    // Blanks collapse; emptied editor stays allow-all.
    await user.clear(denyTextarea);
    await user.type(denyTextarea, "  .env*  \n\n*.pem\n   \n.ssh/*  ");
    expect(screen.getByText(/3 patterns/i)).toBeDefined();

    // No section-level Save Configuration remains.
    expect(
      screen.queryByRole("button", { name: /Save Configuration/i })
    ).toBeNull();
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([".env*", "*.pem", ".ssh/*"]);
    await waitFor(() => {
      expect(screen.getByTestId("files-write-saved")).toBeDefined();
    });

    const reopenedTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;

    // Traversal fails closed with its line number.
    const putsBeforeTraversal = putCount;
    await user.clear(reopenedTextarea);
    await user.type(reopenedTextarea, ".env*\n../escape\n*.pem");
    await user.click(screen.getByTestId("files-write-save"));
    await waitFor(() => {
      expect(screen.getByText(/Line 2.*\.\./i)).toBeDefined();
    });
    expect(putCount).toBe(putsBeforeTraversal);

    // Empty saves allow-all hint.
    await user.clear(reopenedTextarea);
    await user.click(screen.getByTestId("files-write-save"));
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

    const accessTabBtn = screen.getByRole("tab", { name: "Access" });
    await user.click(accessTabBtn);
    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    const denyTextarea = screen.getByLabelText(
      /Deny patterns, one per line/i
    ) as HTMLTextAreaElement;
    expect(denyTextarea.value).toContain("custom*");

    // Reset states counts; cancel keeps text.
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

    // Confirm rewrites form text only.
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

    const resetRootsBtn = screen.getByRole("button", { name: /Reset Roots/i });
    await user.click(resetRootsBtn);
    await waitFor(() => {
      expect(screen.getByText(/replace 1 custom root/i)).toBeDefined();
    });
    expect(screen.getByText(/nothing is saved until you choose Save/i)).toBeDefined();
    await user.click(
      screen.getByRole("button", { name: /Confirm reset allowed roots/i })
    );
    // Confirm swaps custom root for home default.
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

    const accessTabBtn = screen.getByRole("tab", { name: "Access" });
    await user.click(accessTabBtn);
    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // Ghost style keeps header actions aligned.
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

    expect(screen.getByText("Blocked Paths")).toBeDefined();
    expect(screen.getByText("Allowed Roots")).toBeDefined();

    expect(screen.getByLabelText(/Require approval on deny/i)).toBeDefined();
    expect(screen.getByText(/approvals inbox instead of failing silently/i)).toBeDefined();

    const securityTabBtn = screen.getByRole("tab", { name: /Security/i });
    await user.click(securityTabBtn);
    expect(screen.getByText("Containers")).toBeDefined();
    expect(screen.getByTestId("containers-strict-image")).toBeDefined();
    expect(screen.getByTestId("containers-machine-image")).toBeDefined();
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
            schedulerMaxToolIterations: 30,
            goals: {
              maxToolIterations: 40,
            },
          });
        }
        return jsonResponse({});
      }),
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const engineTabBtn = screen.getByRole("tab", { name: /Engine and Logs/i });
    await user.click(engineTabBtn);

    const input = await screen.findByLabelText(/Max Tool Rounds per Turn \(Chats\)/i);
    expect(input).toHaveValue(12);

    expect(screen.getByText(/Applies to interactive chats only/i)).toBeDefined();
    expect(screen.getByText(/parks for your approval to continue/i)).toBeDefined();

    // Summary tracks GET values.
    const summary = screen.getByText(/Chats use/i);
    expect(summary.textContent).toContain("12");
    expect(summary.textContent).toContain("30");
    expect(summary.textContent).toContain("40");
    expect(summary.textContent).toMatch(/Chats use 12 rounds per turn \(parks for approval\)/);
    expect(summary.textContent).toMatch(/Scheduled runs use 30 rounds by default with per-job override/);
    expect(summary.textContent).toMatch(/synthesizes plus budget_exceeded/);
    expect(summary.textContent).toMatch(/parks when the job sets on_tool_limit to park/);
    expect(summary.textContent).toMatch(/Goal runs use 40 rounds \(always synthesizes plus budget_exceeded\)/);

    await user.clear(input);
    await user.type(input, "15");
    expect(input).toHaveValue(15);

    await user.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(savedBody).not.toBeNull();
    });
    expect((savedBody as unknown as Record<string, unknown>)?.maxToolIterations).toBe(15);
  });

  it("renders the live goal-runs budget note in the Goals tab with no editable tool-rounds input", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request) => {
        const urlStr = String(url);
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: [] });
        }
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
        }
        return jsonResponse({
          ...mockSettings,
          goals: {
            enabled: true,
            stepIntervalMinutes: 1440,
            maxActiveGoals: 10,
            maxStepsPerGoal: 8,
            planTimeoutSeconds: 120,
            maxTriggersPerGoal: 4,
            maxToolIterations: 47,
          },
        });
      }),
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    await user.click(screen.getByRole("tab", { name: /^Goals$/i }));
    const goalsPane = screen.getByTestId("goals-pane");

    const note = within(goalsPane).getByText(/Goal runs use/i);
    expect(note.tagName.toLowerCase()).toBe("p");
    expect(note.className).toContain("settings-field-hint");
    expect(note.textContent).toMatch(/Goal runs use 47 consecutive tool rounds per turn/);
    expect(note.textContent).toContain("range 1–100");
    expect(note.textContent).toContain("[goals] max_tool_iterations");
    expect(note.textContent).toContain("budget_exceeded");
    expect(note.textContent).toMatch(/instead of parking for approval/);

    expect(within(goalsPane).queryByLabelText(/tool rounds/i)).toBeNull();
    expect(goalsPane.querySelector('input[id*="tool"]')).toBeNull();
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

    // Browser, web, and api prefixes share one section, so tools render under a
    // single Browser, Web & API heading with no leftover split sections.
    await waitFor(() => {
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
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

    // Should open "Configure Web, Browser & API Automation" modal
    expect(screen.getByRole("heading", { name: /Configure Web, Browser & API Automation/i })).toBeDefined();
    // Must NOT show the fallback error message
    expect(screen.queryByText(/No configuration UI is available/i)).toBeNull();
  });

  it("retires the homelab allowed origins editor in favor of the Access tab pointer", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "browser.navigate",
        description: "Navigate a page",
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
    const settingsWithOrigins = {
      ...mockSettings,
      browserTimeoutSeconds: 30,
      browserFetchTimeoutSeconds: 45,
    };
    let sentPayload: Record<string, unknown> | null = null;
    let putCount = 0;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({ ...settingsWithOrigins, ...sentPayload });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithOrigins);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
    });
    await user.click((await screen.findAllByRole("button", { name: /^Configure$/ }))[0]);

    // The legacy editor is gone; the engine no longer exposes origin-config
    // fields, and the compact pointer names the Access tab.
    expect(screen.queryByLabelText(/Allowed Origins \(one per line\)/i)).toBeNull();
    expect(screen.queryByText(/Homelab Allowed Origins/i)).toBeNull();
    expect(screen.queryByText(/SSRF guard reads that list/i)).toBeNull();
    expect(
      screen.getByRole("heading", { name: /Security & Network Policy/i })
    ).toBeDefined();
    expect(
      screen.getByText(
        /Domain allow\/deny rules and local network access are managed under the Access tab\./i
      )
    ).toBeDefined();

    // The service summary card is gone and the modal no longer claims email
    // auto-trust (the supervisor ignores emailConfig).
    expect(screen.queryByText(/Auto-Allowed Services/i)).toBeNull();
    expect(
      screen.queryByText(/email host servers are automatically trusted/i)
    ).toBeNull();
    expect(screen.queryByText(/Email servers.*automatically trusted/i)).toBeNull();

    // The pointer navigates to the Access tab and closes the modal.
    await user.click(screen.getByRole("button", { name: /Manage Security Policy/i }));
    await waitFor(() => {
      expect(
        screen.getByRole("tab", { name: /^Access$/i }).getAttribute("aria-selected")
      ).toBe("true");
    });
    expect(
      screen.queryByRole("heading", { name: /Configure Web, Browser & API Automation/i })
    ).toBeNull();

    // Reopen the modal and save: the payload carries timeouts without the
    // retired origins field.
    await user.click(screen.getByRole("tab", { name: /Tools and Runes/i }));
    await waitFor(() => {
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
    });
    await user.click((await screen.findAllByRole("button", { name: /^Configure$/ }))[0]);
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(putCount).toBe(1);
    expect(sentPayload).not.toHaveProperty("browserAllowedOrigins");
    expect((sentPayload as unknown as Record<string, unknown>)["browserFetchTimeoutSeconds"]).toBe(45);
  });

  it("validates browser fetch timeout bounds in the modal and full-save paths", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "browser.navigate",
        description: "Navigate a page",
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
    const settingsWithTimeouts = {
      ...mockSettings,
      browserTimeoutSeconds: 30,
      browserFetchTimeoutSeconds: 45,
    };
    let sentPayload: Record<string, unknown> | null = null;
    let putCount = 0;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse({ ...settingsWithTimeouts, ...sentPayload });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithTimeouts);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
    });
    await user.click((await screen.findAllByRole("button", { name: /^Configure$/ }))[0]);

    // Modal path: an out-of-range HTTP request timeout fails on the client
    // before any PUT, matching the server's 1-120 bound.
    const fetchTimeoutInput = screen.getByLabelText(/HTTP Request Timeout/i);
    await user.clear(fetchTimeoutInput);
    await user.type(fetchTimeoutInput, "121");
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));
    await waitFor(() => {
      expect(screen.getByText(/Invalid HTTP request timeout/i)).toBeDefined();
    });
    expect(putCount).toBe(0);

    // Full-save path shares the helper: closing the modal keeps the draft, so
    // the page Save rejects the same value before the network write.
    await user.click(screen.getByRole("button", { name: /Cancel/i }));
    await user.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => {
      expect(screen.getByText(/Invalid HTTP request timeout/i)).toBeDefined();
    });
    expect(putCount).toBe(0);

    // A valid value saves through the modal and persists to the browser section.
    await user.click((await screen.findAllByRole("button", { name: /^Configure$/ }))[0]);
    const reopenedFetchTimeoutInput = screen.getByLabelText(/HTTP Request Timeout/i);
    await user.clear(reopenedFetchTimeoutInput);
    await user.type(reopenedFetchTimeoutInput, "60");
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(putCount).toBe(1);
    expect((sentPayload as unknown as Record<string, unknown>)["browserFetchTimeoutSeconds"]).toBe(60);
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
        name: "memories.store",
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
        name: "memories.store",
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

    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    const modelInput = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(modelInput);
    await user.type(modelInput, "gemma-4-9b-edited");
    const saveButton = screen.getByRole("button", { name: "Save" });
    expect(saveButton).toBeEnabled();
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });

    const toast = screen.getByRole("status");
    expect(toast.textContent).toContain("Settings saved.");
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

    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    const toastModelInput = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(toastModelInput);
    await user.type(toastModelInput, "gemma-4-9b-edited");
    const saveButton = screen.getByRole("button", { name: "Save" });
    expect(saveButton).toBeEnabled();
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

    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    const guardModelInput = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(guardModelInput);
    await user.type(guardModelInput, "gemma-4-9b-edited");
    const saveButton = screen.getByRole("button", { name: "Save" });
    expect(saveButton).toBeEnabled();
    await user.click(saveButton);

    await waitFor(() => {
      expect(
        screen.getByText(
          "If you continue, in progress chats will be cancelled. Do you want to continue?"
        )
      ).toBeDefined();
    });

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

    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    const continueModelInput = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(continueModelInput);
    await user.type(continueModelInput, "gemma-4-9b-edited");
    const saveButton = screen.getByRole("button", { name: "Save" });
    expect(saveButton).toBeEnabled();
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
    expect(desktop).toHaveProperty("maxImageDimension");
    expect(desktop).toHaveProperty("jpegQuality");
    expect(desktop).toHaveProperty("blockedApps");
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

    // One Configure covers both desktop tools.
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
    expect(desktop.blockedApps).toEqual(["Terminal", "1Password"]);
    expect(desktop).toHaveProperty("maxImageDimension");
    expect(desktop).toHaveProperty("jpegQuality");
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

    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    const parkedModelInput = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(parkedModelInput);
    await user.type(parkedModelInput, "gemma-4-9b-edited");
    const saveButton = screen.getByRole("button", { name: "Save" });
    expect(saveButton).toBeEnabled();
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
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
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

    // Only the media row earns a header button; unflagged email rows stay clean.
    await waitFor(() => {
      expect(screen.getByText("Media & Streaming")).toBeDefined();
    });
    expect(screen.getByText("Email & Mailboxes")).toBeDefined();
    expect(screen.getByText("Files & Workspace")).toBeDefined();
    expect(screen.getByText("files.read")).toBeDefined();
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
    // prefixes, and the grid holds one Browser, Web & API section plus email.
    await waitFor(() => {
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
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
      expect(screen.getByText("Browser, Web & API")).toBeDefined();
    });
    expect(screen.getByText("browser.navigate")).toBeDefined();
  });

  it("routes bash.exec to Bash & Shell with no category Configure", async () => {
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

    // Bash has its own category beside the email section
    await waitFor(() => {
      expect(screen.getByText("Bash & Shell")).toBeDefined();
    });
    expect(screen.getByText("Email & Mailboxes")).toBeDefined();
    expect(screen.getByText("bash.exec")).toBeDefined();
    expect(document.querySelectorAll(".tool-category-section").length).toBe(2);
    const pillsBar = document.querySelector(".tools-category-pills");
    expect(pillsBar).not.toBeNull();
    expect(within(pillsBar as HTMLElement).getByText("Bash")).toBeDefined();
    expect(within(pillsBar as HTMLElement).getByText("Email")).toBeDefined();
    expect(screen.queryByRole("button", { name: /^Configure$/ })).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);
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

    const accessTabBtn = screen.getByRole("tab", { name: "Access" });
    await user.click(accessTabBtn);
    await user.click(screen.getByTestId("access-tab-files"));

    // Access owns the single Files & Access editor through the shared
    // files payload helper; Tools owns no files editor.
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });

    // The section mirrors the guard form through the shared payload helper.
    expect(screen.getByLabelText(/Deny patterns, one per line/i)).toBeDefined();
    expect(screen.getByLabelText(/Allowed roots, one per line/i)).toBeDefined();
    expect(screen.getByLabelText(/Require approval on deny/i)).toBeDefined();

    expect(
      screen.queryByRole("button", { name: /Save Configuration/i })
    ).toBeNull();
    expect(screen.getByText(/Allow roots bound/i)).toBeDefined();
    expect(screen.queryByTestId("files-consumer-note")).toBeNull();

    const denyTextarea = screen.getByLabelText(/Deny patterns, one per line/i);
    await user.clear(denyTextarea);
    await user.type(denyTextarea, ".env*\n*.secret");
    await user.click(screen.getByLabelText(/Require approval on deny/i));
    await user.click(screen.getByTestId("files-write-save"));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(sentPayload?.["filesDenyPatterns"]).toEqual([".env*", "*.secret"]);
    expect(sentPayload?.["filesRequireApprovalOnDeny"]).toBe(false);
  });

  it("keeps Files & Access in Access pane without redundant card in Security pane", async () => {
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

    // Security owns container governance plus access management only;
    // file policy lives cleanly under Access > Files.
    await waitFor(() => {
      expect(screen.getByText("Containers")).toBeDefined();
    });
    expect(screen.getByText("Access Management")).toBeDefined();
    expect(screen.queryByText("Files & Access")).toBeNull();
    expect(screen.queryByLabelText(/Deny patterns, one per line/i)).toBeNull();
    expect(screen.queryByLabelText(/Allowed roots, one per line/i)).toBeNull();
    expect(screen.getByTestId("containers-strict-image")).toBeDefined();
    expect(screen.getByTestId("containers-machine-image")).toBeDefined();

    // Navigating to Access -> Files surfaces the active file editors
    const accessTabBtn = screen.getByRole("tab", { name: "Access" });
    await user.click(accessTabBtn);
    await user.click(screen.getByTestId("access-tab-files"));
    await waitFor(() => {
      expect(screen.getByText("Files & Access")).toBeDefined();
    });
    expect(screen.getByText("Blocked Paths")).toBeDefined();
    expect(screen.getByText("Allowed Roots")).toBeDefined();
    expect(screen.getByLabelText(/Deny patterns, one per line/i)).toBeDefined();
    expect(screen.getByLabelText(/Allowed roots, one per line/i)).toBeDefined();
  });

  it("routes bash.exec to Bash & Shell while unknown prefixes land in Other Tools", async () => {
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

    // Bash routes to Bash & Shell, while custom.widget lands in Other Tools
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
    expect(bashSection?.textContent).toContain("bash.exec");
    const otherSection = sections.find((section) =>
      section.textContent?.includes("Other Tools")
    );
    expect(otherSection?.textContent).toContain("custom.widget");
  });

  it("routes colliding external names and builtin bash and files tools to Other", () => {
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
    // Builtin shell entry routes to bash category with the provenance gate.
    expect(getToolCategory(builtinBash)).toBe("bash");
    // External names never join builtin sections regardless of prefix.
    expect(getToolCategory(pluginBashEvil)).toBe("other");
    expect(getToolCategory(pluginFilesEvil)).toBe("other");
    // String fallback resolves exact known builtin names
    expect(getToolCategory("bash.exec")).toBe("bash");
    expect(getToolCategory("files.read")).toBe("files");
    expect(getToolCategory("calendar.list")).toBe("calendar-reminders");
    expect(getToolCategory("reminders.list")).toBe("calendar-reminders");
    // api.* collapses into browser-web like browser.* and web.*, so the removed
    // dead API category entry can never strand a pill or section.
    expect(getToolCategory("api.request")).toBe("browser-web");
    expect(getToolCategory("bash.evil")).toBe("other");
    expect(getToolCategory("files.evil")).toBe("other");
    expect(getToolCategory("custom.widget")).toBe("other");
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

    const accessTabBtn = screen.getByRole("tab", { name: "Access" });
    await user.click(accessTabBtn);
    await user.click(screen.getByTestId("access-tab-files"));
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
    expect(
      screen.queryByRole("button", { name: /Save Configuration/i })
    ).toBeNull();
    const editedTextarea = screen.getByLabelText(
      /Allowed roots, one per line/i
    ) as HTMLTextAreaElement;
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "  ~/a  \n\n~/b\n   \n");
    expect(screen.getByText(/2 roots/i)).toBeDefined();
    await user.click(screen.getByTestId("files-write-save"));
    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    expect(sentPayload?.["filesAllowRoots"]).toEqual(["~/a", "~/b"]);
    await waitFor(() => {
      expect(screen.getByTestId("files-write-saved")).toBeDefined();
    });
    const putsAfterSave = putCount;

    // Traversal escapes fail closed with their editor line number.
    await user.clear(editedTextarea);
    await user.type(editedTextarea, "~/a\n../escape");
    await user.click(screen.getByTestId("files-write-save"));
    await waitFor(() => {
      expect(screen.getByText(/Line 2.*\.\./i)).toBeDefined();
    });
    expect(putCount).toBe(putsAfterSave);

    // Empty means no roots: clearing the editor rejects with an error and
    // never reaches the network.
    await user.clear(editedTextarea);
    await user.click(screen.getByTestId("files-write-save"));
    await waitFor(() => {
      expect(screen.getByText(/Allowed roots cannot be empty/i)).toBeDefined();
    });
    expect(putCount).toBe(putsAfterSave);
    // Many sequential user-event keystrokes under loaded CI burst past the 5s
    // default; this test alone carries headroom.
  }, 15000);

  it("renders the fan-out Configure modal from the server hasConfig flag", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "fanout.run",
        description: "Fan out subtasks to parallel workers",
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
    const settingsWithFanout = {
      ...mockSettings,
      fanout: {
        maxWorkers: 4,
        workerTimeoutSeconds: 300,
        fullTools: false,
      },
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
        return jsonResponse(settingsWithFanout);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    // Fan-out groups under its own section rather than falling through to
    // Other Tools; the header owns the single Configure entry point.
    await waitFor(() => {
      expect(screen.getByText("Fan-Out Workers")).toBeDefined();
    });
    expect(screen.getByText("fanout.run")).toBeDefined();
    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    expect(configureButtons.length).toBe(1);
    expect(configureButtons[0].closest(".tool-category-actions")).not.toBeNull();
    expect(configureButtons[0].closest(".builtin-tool-card")).toBeNull();
    await user.click(configureButtons[0]);

    // The fan-out modal carries its knobs and never the fallback copy.
    expect(screen.getByRole("heading", { name: /Configure Parallel Fan-Out/i })).toBeDefined();
    expect(screen.queryByText(/No configuration UI is available/i)).toBeNull();
    expect(screen.getByLabelText(/Max workers/i)).toBeDefined();
    expect(screen.getByLabelText(/Worker timeout/i)).toBeDefined();
    expect(screen.getByLabelText(/Full tools/i)).toBeDefined();
    // Stored values round-trip into the form.
    expect(screen.getByDisplayValue("4")).toBeDefined();
    expect(screen.getByDisplayValue("300")).toBeDefined();
    expect(screen.getByText(/Lets workers call the full tool registry/i)).toBeDefined();
    // Loaded CI worker contention can push initial renders past the 5s
    // default; this test alone carries headroom.
  }, 15000);

  it("hides the fan-out Configure button when the server reports no config", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "fanout.run",
        description: "Fan out subtasks to parallel workers",
        permissionLevel: "requiresApproval",
        inputSchema: "{}",
        isEnabled: false,
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
        if (urlStr.includes("/tools")) {
          return jsonResponse({ tools: mockTools });
        }
        if (urlStr.includes("/plugins")) {
          return jsonResponse({ plugins: [] });
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

    // The tool still lists with its enablement switch, but no Configure
    // renders without the server hasConfig flag.
    await waitFor(() => {
      expect(screen.getByText("fanout.run")).toBeDefined();
    });
    expect(screen.queryByRole("button", { name: /^Configure$/ })).toBeNull();
  });

  it("saves cleared fan-out fields as the default constants with a changed-only patch", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "fanout.run",
        description: "Fan out subtasks to parallel workers",
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
    const settingsWithFanout = {
      ...mockSettings,
      fanout: {
        maxWorkers: 4,
        workerTimeoutSeconds: 300,
        fullTools: false,
      },
    };
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        // Deep-merge the partial fan-out patch like the engine does so the
        // reloaded form sees the full stored section.
        const sentFanout = (sentPayload["fanout"] ?? {}) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithFanout,
          ...sentPayload,
          fanout: { ...settingsWithFanout.fanout, ...sentFanout },
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFanout);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    await user.click(configureButtons[0]);
    expect(screen.getByRole("heading", { name: /Configure Parallel Fan-Out/i })).toBeDefined();

    // Placeholders name the empty-field fallbacks.
    const maxInput = screen.getByLabelText(/Max workers/i) as HTMLInputElement;
    const timeoutInput = screen.getByLabelText(/Worker timeout/i) as HTMLInputElement;
    expect(maxInput.placeholder).toContain("2 (default)");
    expect(timeoutInput.placeholder).toContain("0 (unlimited)");
    expect(screen.getByText(/0 = no timeout/i)).toBeDefined();

    // Clearing both fields saves the defaults as explicit changes.
    await user.clear(maxInput);
    await user.clear(timeoutInput);
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const fanout = (sentPayload as unknown as Record<string, unknown>)["fanout"] as Record<
      string,
      unknown
    >;
    expect(fanout).toBeDefined();
    expect(fanout["maxWorkers"]).toBe(2);
    expect(fanout["workerTimeoutSeconds"]).toBe(0);
    // Untouched toggle stays omitted so the stored value survives; the modal
    // never carries an enablement key.
    expect(fanout).not.toHaveProperty("fullTools");
    expect(fanout).not.toHaveProperty("enabled");
    await waitFor(() => {
      expect(screen.getByText(/Fan-out settings saved/i)).toBeDefined();
    });
  });

  it("sends only the changed fan-out knob and round-trips the full-tools toggle", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "fanout.run",
        description: "Fan out subtasks to parallel workers",
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
    const settingsWithFanout = {
      ...mockSettings,
      fanout: {
        maxWorkers: 4,
        workerTimeoutSeconds: 300,
        fullTools: false,
      },
    };
    let sentPayload: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        sentPayload = JSON.parse(init.body as string) as Record<string, unknown>;
        // Deep-merge the partial fan-out patch like the engine does so the
        // reloaded form sees the full stored section.
        const sentFanout = (sentPayload["fanout"] ?? {}) as Record<string, unknown>;
        return jsonResponse({
          ...settingsWithFanout,
          ...sentPayload,
          fanout: { ...settingsWithFanout.fanout, ...sentFanout },
        });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFanout);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    await user.click(configureButtons[0]);
    expect(screen.getByRole("heading", { name: /Configure Parallel Fan-Out/i })).toBeDefined();

    // The toggle starts off and flips on as a boolean round-trip.
    const fullToolsToggle = screen.getByLabelText(/Full tools/i) as HTMLInputElement;
    expect(fullToolsToggle.checked).toBe(false);
    await user.click(fullToolsToggle);
    expect(fullToolsToggle.checked).toBe(true);

    // Editing only the worker cap keeps the patch to that knob plus the
    // flipped toggle.
    const maxInput = screen.getByLabelText(/Max workers/i) as HTMLInputElement;
    await user.clear(maxInput);
    await user.type(maxInput, "6");
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const fanout = (sentPayload as unknown as Record<string, unknown>)["fanout"] as Record<
      string,
      unknown
    >;
    expect(fanout).toEqual({ maxWorkers: 6, fullTools: true });
    expect(fanout).not.toHaveProperty("workerTimeoutSeconds");
    expect(fanout).not.toHaveProperty("enabled");
  });

  it("surfaces an honest server error from the fan-out save", async () => {
    const user = userEvent.setup();
    const mockTools = [
      {
        name: "fanout.run",
        description: "Fan out subtasks to parallel workers",
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
    const settingsWithFanout = {
      ...mockSettings,
      fanout: {
        maxWorkers: 4,
        workerTimeoutSeconds: 300,
        fullTools: false,
      },
    };
    const serverReason = "fanout.maxWorkers must be between 1 and 8 (got 99)";
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        return jsonResponse({ reason: serverReason }, 400);
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: mockTools });
      }
      if (urlStr.includes("/plugins")) {
        return jsonResponse({ plugins: [] });
      }
      return jsonResponse(settingsWithFanout);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);

    const configureButtons = await screen.findAllByRole("button", { name: /^Configure$/ });
    await user.click(configureButtons[0]);
    expect(screen.getByRole("heading", { name: /Configure Parallel Fan-Out/i })).toBeDefined();

    const maxInput = screen.getByLabelText(/Max workers/i) as HTMLInputElement;
    await user.clear(maxInput);
    await user.type(maxInput, "99");
    await user.click(screen.getByRole("button", { name: /Save Configuration/i }));

    // The honest server message surfaces in the modal instead of a generic
    // failure, and the modal stays open for repair.
    await waitFor(() => {
      expect(screen.getByText(serverReason)).toBeDefined();
    });
    expect(screen.getByRole("heading", { name: /Configure Parallel Fan-Out/i })).toBeDefined();
    expect(screen.queryByText(/Fan-out settings saved/i)).toBeNull();
  });

  it("routes fanout.run to the Fan-Out category while keeping external names in Other", () => {
    const builtinFanout = {
      name: "fanout.run",
      description: "Fan out subtasks",
      permissionLevel: "requiresApproval",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: true,
      pluginID: null,
      source: "builtin",
      integrityStatus: "valid",
      hasConfig: true,
    };
    const pluginFanoutEvil = {
      name: "fanout.evil",
      description: "External colliding name",
      permissionLevel: "readOnly",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: false,
      pluginID: "external.plugin",
      source: "plugin",
      integrityStatus: "valid",
    };
    expect(getToolCategory(builtinFanout)).toBe("fanout");
    expect(getToolCategory(pluginFanoutEvil)).toBe("other");
    expect(getToolCategory("fanout.run")).toBe("fanout");
    expect(getToolCategory("fanout.evil")).toBe("other");
  });

  it("routes files tools to Files & Workspace with no Configure anywhere in Tools", async () => {
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
        hasConfig: false,
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
        hasConfig: false,
      },
      {
        name: "files.write",
        description: "Write a file",
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
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    const toolsTabBtn = screen.getByRole("tab", { name: /Tools and Runes/i });
    await user.click(toolsTabBtn);
    await waitFor(() => {
      expect(screen.getByText("Files & Workspace")).toBeDefined();
    });
    expect(screen.getByText("files.write")).toBeDefined();
    expect(screen.getByText("files.read")).toBeDefined();
    expect(screen.getByText("files.grep")).toBeDefined();
    expect(document.querySelectorAll(".tool-category-section").length).toBe(1);
    // No header Configure renders at all — the stale flag cannot dangle a
    // button for an editor that moved — and no per-card control either.
    expect(screen.queryByRole("button", { name: /^Configure$/ })).toBeNull();
    expect(document.querySelectorAll(".builtin-tool-card button").length).toBe(0);

    // No inline write-posture editors ride the rows: the posture radios stay
    // on the Access surface beside this pane, so opening Tools never writes.
    expect(screen.queryByLabelText(/Let the model decide/i)).toBeNull();
    expect(screen.queryByLabelText(/Always stage for review/i)).toBeNull();
    expect(screen.queryByLabelText(/Always write live/i)).toBeNull();
  });
});

// Structured policy surface: Network plus Credentials editors live outside the shared form.
const structuredPolicyPayload = {
  policy: {
    version: 1,
    network: {
      mode: "allowlist_only",
      allowedDomains: ["api.example.com"],
      blockedDomains: ["metadata.google.internal"],
    },
    credentials: {
      GITHUB_TOKEN: {
        allowedHosts: ["api.github.com"],
        allowedMethods: ["GET"],
        allowedPathPrefixes: ["/repos"],
      },
    },
  },
  path: "/Users/test/.runeweaver/policy.toml",
  loadedFromDisk: true,
  violations: [],
};

describe("SettingsManager access tab", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    resetSharedRunsForTesting();
  });

  // Routes shell, Rules section, and policy fetch; unrelated boot probes stay benign.
  function stubPolicyTabFetch(
    policyResponse: (init?: RequestInit) => Response | Promise<Response>
  ) {
    const fetchMock = vi.fn(
      async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        const urlStr = String(url);
        if (urlStr === "/settings/policy") {
          return policyResponse(init);
        }
        if (urlStr === "/approvals/rules") {
          return jsonResponse({ rules: [], count: 0 });
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

  async function openAccessPane() {
    const user = userEvent.setup();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: "Access" }));
    await waitFor(() => {
      expect(screen.getByTestId("access-pane")).toBeDefined();
    });
    // Policy editor mounts behind Network Policy; Credentials list has its own tab.
    await user.click(screen.getByTestId("access-tab-network"));
    await waitFor(() => {
      expect(screen.getByTestId("policy-pane")).toBeDefined();
    });
    return user;
  }

  it("renders the structured pane on its own tab with no raw editor and no Verify button", async () => {
    const fetchMock = stubPolicyTabFetch(() => jsonResponse(structuredPolicyPayload));
    const user = await openAccessPane();

    // Network editors own the egress posture: mode select plus domain textareas.
    await waitFor(() => {
      expect((screen.getByLabelText("Mode") as HTMLSelectElement).value).toBe("allowlist_only");
    });
    expect(
      (screen.getByLabelText("Allowed domains") as HTMLTextAreaElement).value
    ).toContain("api.example.com");
    expect(
      (screen.getByLabelText("Blocked domains") as HTMLTextAreaElement).value
    ).toContain("metadata.google.internal");

    // Network displays the network egress posture with credentials hidden on their own tab.
    expect(screen.getByTestId("policy-network-section")).toBeDefined();
    expect(screen.queryByTestId("credentials-list")).toBeNull();

    // Credentials read as a bound list, not text: the seeded key renders a row on the Credentials tab.
    await user.click(screen.getByTestId("access-tab-credentials"));
    await waitFor(() => {
      expect(screen.getByTestId("credentials-list")).toBeDefined();
    });
    expect(screen.getByTestId("credential-row")).toBeDefined();
    expect(screen.getByText("GITHUB_TOKEN")).toBeDefined();
    expect(screen.getByTestId("policy-save")).toBeDefined();

    // Retired raw editor and candidate Verify button are gone from the new contract.
    expect(screen.getByText(/All 3 Formal Security Invariants Verified/)).toBeDefined();
    expect(screen.queryByText(/Raw TOML/i)).toBeNull();
    expect(screen.queryByLabelText(/Edit policy\.toml directly/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /^Verify$/i })).toBeNull();

    const loadCall = fetchMock.mock.calls.find(
      ([url]) => String(url) === "/settings/policy"
    );
    expect(loadCall?.[1]).toMatchObject({ credentials: "same-origin" });
  });

  it(
    "saves the structured draft without ever sending raw TOML",
    { timeout: 15000 },
    async () => {
      let sentBody: Record<string, unknown> | null = null;
      stubPolicyTabFetch((init) => {
        if (init?.method === "PUT") {
          sentBody = JSON.parse(init.body as string) as Record<string, unknown>;
          return jsonResponse({ ...structuredPolicyPayload, policy: (sentBody as { policy: unknown }).policy });
        }
        return jsonResponse(structuredPolicyPayload);
      });
      await openAccessPane();

      await waitFor(
        () => {
          expect(screen.getByTestId("policy-save")).toBeDefined();
        },
        { timeout: 10000 },
      );
      // Synchronous click avoids user-event timing flakes under full-suite load.
      fireEvent.click(screen.getByTestId("policy-save"));

      // The pane persists the DTO only; the retired text field never rides along.
      await waitFor(
        () => {
          expect(screen.getByTestId("policy-saved")).toBeDefined();
        },
        { timeout: 10000 },
      );
      expect(sentBody).not.toBeNull();
      expect(sentBody).toHaveProperty("policy");
      expect(sentBody).not.toHaveProperty("raw_toml");
      expect(sentBody).not.toHaveProperty("rawToml");
      const sentPolicy = (sentBody as unknown as { policy: { network: { mode: string } } }).policy;
      expect(sentPolicy.network.mode).toBe("allowlist_only");

      // Policy writes apply live with no restart banner ever for policy.
      expect(screen.getByTestId("policy-saved").textContent).toContain("no restart");
      expect(screen.queryByText(/needs a restart/i)).toBeNull();
      expect(screen.queryByText(/restart to apply/i)).toBeNull();
    },
  );

  it("reports a failed structured load in the pane error banner", async () => {
    stubPolicyTabFetch(() => jsonResponse({ reason: "policy file unreadable" }, 500));
    await openAccessPane();

    await waitFor(() => {
      expect(screen.getByTestId("policy-error")).toBeDefined();
    });
    expect(screen.getByText(/Failed to load policy/i)).toBeDefined();
  });
});

describe("secret status chunk contract", () => {
  it("pins the badge-probe chunk size to the server status cap", () => {
    // Cross-language contract: server owns maxSecretStatusKeys; mirror stays at 500.
    expect(SECRET_STATUS_CHUNK_SIZE).toBe(500);
  });
});

describe("bash defaults and bounds contract", () => {
  it("pins the bash mirrors to the engine BashConfig", () => {
    // Cross-language contract: defaults mirror BashConfig; bounds mirror server DTOs.
    expect(DEFAULT_BASH_ENABLED).toBe(true);
    expect(DEFAULT_BASH_DEFAULT_ACTION).toBe("ask");
    expect(DEFAULT_BASH_TIMEOUT_SECONDS).toBe(30);
    expect(DEFAULT_BASH_ALLOW_NETWORK).toBe(false);
    expect(DEFAULT_BASH_RULES).toEqual([{ pattern: "*", action: "ask" }]);
    expect(DEFAULT_BASH_CONFIG.enabled).toBe(DEFAULT_BASH_ENABLED);
    expect(DEFAULT_BASH_CONFIG.defaultAction).toBe(DEFAULT_BASH_DEFAULT_ACTION);
    expect(DEFAULT_BASH_CONFIG.timeoutSeconds).toBe(DEFAULT_BASH_TIMEOUT_SECONDS);
    expect(DEFAULT_BASH_CONFIG.cpuSeconds).toBe(DEFAULT_BASH_CPU_SECONDS);
    expect(DEFAULT_BASH_CONFIG.memoryMb).toBe(DEFAULT_BASH_MEMORY_MB);
    expect(DEFAULT_BASH_CONFIG.allowNetwork).toBe(DEFAULT_BASH_ALLOW_NETWORK);
    expect(DEFAULT_BASH_CONFIG.rules).toEqual(DEFAULT_BASH_RULES);
    expect(DEFAULT_BASH_SANDBOX_MODE).toBe("strictContainer");
    expect(DEFAULT_BASH_HOST_ALLOW_PATTERNS).toEqual(["xcodebuild*", "codesign*"]);
    expect(DEFAULT_BASH_CONFIG.sandboxMode).toBe(DEFAULT_BASH_SANDBOX_MODE);
    expect(DEFAULT_BASH_CONFIG.hostAllowPatterns).toEqual(DEFAULT_BASH_HOST_ALLOW_PATTERNS);
    expect([...BASH_SANDBOX_MODES]).toEqual(["strictContainer", "machineScoped", "hostSeatbelt"]);
    expect(BASH_HOST_ALLOW_PATTERNS_MAX).toBe(50);
    expect(BASH_HOST_ALLOW_PATTERN_MAX_LENGTH).toBe(256);
    expect([...BASH_PERMISSION_ACTIONS]).toEqual(["allow", "ask", "deny"]);
    expect(BASH_TIMEOUT_MIN_SECONDS).toBe(1);
    expect(BASH_TIMEOUT_MAX_SECONDS).toBe(3600);
    expect(DEFAULT_BASH_CPU_SECONDS).toBe(120);
    expect(DEFAULT_BASH_MEMORY_MB).toBe(1024);
    expect(BASH_CPU_MIN_SECONDS).toBe(1);
    expect(BASH_CPU_MAX_SECONDS).toBe(3600);
    expect(BASH_MEMORY_MIN_MB).toBe(64);
    expect(BASH_MEMORY_MAX_MB).toBe(8192);
  });

  it("pins the workspace mirrors to the engine WorkspaceConfig", () => {
    // Cross-language contract: server owns defaults in Config.swift.
    expect(DEFAULT_WORKSPACE_QUOTA_MB).toBe(500);
    expect(DEFAULT_WORKSPACE_QUOTA_FILES).toBe(10000);
    expect(DEFAULT_WORKSPACE_TMP_TTL_DAYS).toBe(7);
    expect(DEFAULT_WORKSPACE_CONFIG.quotaMB).toBe(DEFAULT_WORKSPACE_QUOTA_MB);
    expect(DEFAULT_WORKSPACE_CONFIG.quotaFiles).toBe(DEFAULT_WORKSPACE_QUOTA_FILES);
    expect(DEFAULT_WORKSPACE_CONFIG.tmpTTLDays).toBe(DEFAULT_WORKSPACE_TMP_TTL_DAYS);
    expect(WORKSPACE_QUOTA_MB_MIN).toBe(10);
    expect(WORKSPACE_QUOTA_MB_MAX).toBe(10240);
    expect(WORKSPACE_QUOTA_FILES_MIN).toBe(100);
    expect(WORKSPACE_QUOTA_FILES_MAX).toBe(100000);
    expect(WORKSPACE_TMP_TTL_MIN_DAYS).toBe(0);
    expect(WORKSPACE_TMP_TTL_MAX_DAYS).toBe(90);
  });
});

describe("SettingsManager persona pane", () => {
  const STYLE_TEXT = "Answer in complete sentences.";
  const PERSONA_SETTINGS = { ...mockSettings, persona: { assistantName: "Zephyra", tone: "concise", style: STYLE_TEXT, userName: "Kupan", avatar: "rose" } };

  type PutOptions = {
    putResponse?: (body: Record<string, unknown>) => Response;
    settings?: Record<string, unknown>;
  };

  // One stub answers all reads with the persona snapshot; PUT is captured.
  function stubPersonaFetch(options: PutOptions = {}): Record<string, unknown>[] {
    const settings = options.settings ?? PERSONA_SETTINGS;
    const putBodies: Record<string, unknown>[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const url = String(input);
        if (url === "/settings" && init?.method === "PUT") {
          const body = JSON.parse(String(init.body)) as Record<string, unknown>;
          putBodies.push(body);
          if (options.putResponse) return options.putResponse(body);
          return jsonResponse({
            ...settings,
            persona: {
              ...((settings as { persona?: Record<string, unknown> }).persona ?? {}),
              ...((body as { persona?: Record<string, unknown> }).persona ?? {}),
            },
          });
        }
        return jsonResponse(settings);
      }),
    );
    return putBodies;
  }

  // Opens the Persona tab and returns its pane. The identity block moved out
  // of Engine, so every persona assertion starts here instead of the engine
  // surface.
  async function openPersonaPane(user: ReturnType<typeof userEvent.setup>) {
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /^Persona$/i }));
    return screen.getByTestId("persona-pane");
  }

  async function openEngineTab(user: ReturnType<typeof userEvent.setup>) {
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Engine and Logs/i }));
  }

  // Single submit per tab pins the double-save guard.
  function tabSaveButton() {
    return screen.getByRole("button", { name: "Save" });
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedRunsForTesting();
  });

  it("renders the loaded persona values in the Persona tab", async () => {
    const user = userEvent.setup();
    stubPersonaFetch();
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    expect(within(pane).getByDisplayValue("Zephyra")).toBeDefined();
    expect((within(pane).getByLabelText("Tone") as HTMLSelectElement).value).toBe(
      "concise",
    );
    expect(within(pane).getByDisplayValue(STYLE_TEXT)).toBeDefined();
    expect(within(pane).getByDisplayValue("Kupan")).toBeDefined();
    expect(
      within(pane).getByTestId("persona-style-count").textContent,
    ).toContain(`${STYLE_TEXT.length} / ${MAX_PERSONA_STYLE_LENGTH}`);
    // The stored accent carries the ring, and the picker cells are the
    // 64px colorway sprites the dashboard ships.
    expect(
      within(pane).getByTestId("persona-avatar-rose"),
    ).toHaveAttribute("aria-pressed", "true");
    expect(
      within(pane)
        .getByTestId("persona-avatar-rose")
        .querySelector("img")
        ?.getAttribute("src"),
    ).toBe("/avatars/wisp-rose-idle-64.png");
    // The per-card save is gone: the tab form footer owns the single submit.
    expect(within(pane).queryByTestId("persona-save")).toBeNull();
    expect(tabSaveButton()).toBeDefined();
    // Every settings read republishes the persona into the shared store so
    // the profile block and chat header mirror this pane without a reload.
    expect(peekPersonaSignals().persona?.assistantName).toBe("Zephyra");
  });

  it("saves exactly one request carrying only the persona delta", async () => {
    const user = userEvent.setup();
    const putBodies = stubPersonaFetch();
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    const nameInput = within(pane).getByLabelText("Assistant Name");
    await user.clear(nameInput);
    await user.type(nameInput, "Vex");
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(putBodies.length).toBe(1);
    });
    // The partial-patch contract: the wire carries the single changed key
    // only — no tone, style, user name, or avatar, and nothing outside the
    // persona section.
    expect(putBodies[0]).toEqual({ persona: { assistantName: "Vex" } });
    await waitFor(() => {
      expect(screen.getByText(/Persona saved/)).toBeDefined();
    });
    // The saved identity publishes live so the nav and chat header re-render
    // with the new name without waiting for an engine reload.
    expect(peekPersonaSignals().persona?.assistantName).toBe("Vex");
  });

  it("maps a server 400 to the shared tab-form error banner", async () => {
    const user = userEvent.setup();
    stubPersonaFetch({
      putResponse: () =>
        jsonResponse(
          { reason: "persona.tone must be one of concise, warm, formal, playful" },
          400,
        ),
    });
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    await user.selectOptions(within(pane).getByLabelText("Tone"), "formal");
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(screen.getByText(/persona\.tone/)).toBeDefined();
    });
    // The retired per-card slot is gone; the shared banner owns the message.
    expect(within(pane).queryByTestId("persona-error")).toBeNull();
    expect(screen.queryByText(/Persona saved/)).toBeNull();
  });

  it("selects all four colorways through the avatar picker", async () => {
    const user = userEvent.setup();
    const putBodies = stubPersonaFetch();
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    for (const accent of ["violet", "cyan", "emerald", "rose"]) {
      await user.click(within(pane).getByTestId(`persona-avatar-${accent}`));
      expect(
        within(pane).getByTestId(`persona-avatar-${accent}`),
      ).toHaveAttribute("aria-pressed", "true");
      // Exactly one ring at a time so the selection never splits.
      for (const other of ["violet", "cyan", "emerald", "rose"]) {
        if (other === accent) continue;
        expect(
          within(pane).getByTestId(`persona-avatar-${other}`),
        ).toHaveAttribute("aria-pressed", "false");
      }
    }
    // The loop ended on the stored rose accent; move to emerald and the save
    // names only the avatar key in the delta.
    await user.click(within(pane).getByTestId("persona-avatar-emerald"));
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(putBodies.length).toBe(1);
    });
    expect(putBodies[0]).toEqual({ persona: { avatar: "emerald" } });
  });

  it("falls back to the violet selection when the stored accent is unknown", async () => {
    const user = userEvent.setup();
    const putBodies = stubPersonaFetch({
      settings: {
        ...PERSONA_SETTINGS,
        persona: { ...PERSONA_SETTINGS.persona, avatar: "chartreuse" },
      },
    });
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    // A drifted stored accent never blanks the picker: the ring lands on the
    // master colorway exactly the way the avatar renderer falls back.
    expect(
      within(pane).getByTestId("persona-avatar-violet"),
    ).toHaveAttribute("aria-pressed", "true");
    expect(
      within(pane).getByTestId("persona-avatar-rose"),
    ).toHaveAttribute("aria-pressed", "false");
    // Pristine form keeps Save disabled with no network write.
    const pristineSave = tabSaveButton();
    expect(pristineSave).toBeDisabled();
    expect(pristineSave).toHaveAttribute("title", "No unsaved changes");
    expect(putBodies.length).toBe(0);
    // An edit enables Save and persists only the avatar delta.
    await user.click(within(pane).getByTestId("persona-avatar-emerald"));
    expect(tabSaveButton()).toBeEnabled();
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(putBodies.length).toBe(1);
    });
    expect(putBodies[0]).toEqual({ persona: { avatar: "emerald" } });
  });

  it("updates the style character count live while typing", async () => {
    const user = userEvent.setup();
    stubPersonaFetch();
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    await user.type(within(pane).getByLabelText("Style Guidance"), " please");
    const nextLength = STYLE_TEXT.length + " please".length;
    expect(
      within(pane).getByTestId("persona-style-count").textContent,
    ).toContain(`${nextLength} / ${MAX_PERSONA_STYLE_LENGTH}`);
  });

  it("renders the stock identity and stays clean when the engine predates [persona]", async () => {
    const user = userEvent.setup();
    const legacy = { ...mockSettings };
    const putBodies = stubPersonaFetch({ settings: legacy });
    render(<SettingsManager />);
    const pane = await openPersonaPane(user);
    // Absent persona seeds the stock form: blank assistant name (the engine
    // keeps its default identity), warm tone, violet accent.
    expect(within(pane).getByLabelText("Assistant Name")).toHaveValue("");
    expect((within(pane).getByLabelText("Tone") as HTMLSelectElement).value).toBe(
      "warm",
    );
    expect(
      within(pane).getByTestId("persona-avatar-violet"),
    ).toHaveAttribute("aria-pressed", "true");
    expect(peekPersonaSignals().persona).toBeNull();
    // Pristine stock form keeps Save disabled, so no PUT leaves the pane.
    const stockSave = tabSaveButton();
    expect(stockSave).toBeDisabled();
    expect(stockSave).toHaveAttribute("title", "No unsaved changes");
    expect(putBodies.length).toBe(0);
    // Typing a name enables Save and persists the single-key delta.
    await user.type(within(pane).getByLabelText("Assistant Name"), "Vex");
    expect(tabSaveButton()).toBeEnabled();
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(putBodies.length).toBe(1);
    });
    expect(putBodies[0]).toEqual({ persona: { assistantName: "Vex" } });
  });

  it("lists fourteen sidebar tabs in promotion order", async () => {
    stubPersonaFetch();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const tabs = screen.getAllByRole("tab");
    expect(tabs.length).toBe(14);
    const labels = tabs.map((tab) => tab.textContent ?? "");
    expect(labels[0]).toMatch(/^Access$/);
    expect(labels[1]).toMatch(/LLM Providers/);
    expect(labels[2]).toMatch(/Persona/);
    expect(labels[3]).toMatch(/^Voice/);
    expect(labels[4]).toMatch(/Memory and Storage/);
    expect(labels[5]).toMatch(/Goals/);
    expect(labels[6]).toMatch(/Tools and Runes/);
    expect(labels[7]).toMatch(/Indexing/);
    expect(labels[8]).toMatch(/^Web/);
    expect(labels[9]).toMatch(/Email Accounts/);
    expect(labels[10]).toMatch(/^Security/);
    expect(labels.slice(11).join("|")).toMatch(/Network\|Engine and Logs\|Notifications/);
    // Retired Policy tab stays absorbed by Access at the rail head.
    expect(labels.join("|")).not.toMatch(/Policy/);
  });

  it("finds item rows from capability words in the section finder", async () => {
    stubPersonaFetch();
    const user = userEvent.setup();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const finder = screen.getByTestId("settings-nav-search") as HTMLInputElement;
    expect(finder).toHaveAttribute("aria-label", "Search settings");
    const railTabs = () =>
      within(
        screen.getByRole("tablist", { name: "Settings categories" })
      ).getAllByRole("tab");
    // "bash" names a knob behind the Access rail, not a tab label: the rail
    // hides and only the matching item rows render with their tab.
    await user.type(finder, "bash");
    expect(
      screen.queryByRole("tablist", { name: "Settings categories" })
    ).toBeNull();
    const results = screen.getByRole("listbox", { name: "Matching settings" });
    const bashHit = within(results).getByRole("option", {
      name: /Bash and shell policy/,
    });
    expect(bashHit).toHaveAttribute(
      "data-testid",
      "settings-search-result-access-bash-shell"
    );
    expect(bashHit.textContent).toMatch(/Access/);
    // Selecting a row jumps to its tab, restores the rail, and pulses the target.
    await user.click(bashHit);
    expect(railTabs()).toHaveLength(14);
    expect(
      within(
        screen.getByRole("tablist", { name: "Settings categories" })
      )
        .getByRole("tab", { name: "Access" })
        .getAttribute("aria-selected")
    ).toBe("true");
    await waitFor(() => {
      const target = document.getElementById("access-tab-bash");
      expect(target).not.toBeNull();
      const highlighted =
        target?.classList.contains("settings-search-highlight") === true ||
        document.activeElement === target;
      expect(highlighted).toBe(true);
    });
    // "policy" — the vocabulary owners still reach for — surfaces the same row.
    await user.type(finder, "policy");
    expect(
      screen.queryByRole("tablist", { name: "Settings categories" })
    ).toBeNull();
    expect(
      screen.getByTestId("settings-search-result-access-bash-shell")
    ).toBeDefined();
    // A starved query shows the honest empty-state note with no rail and no
    // rows, and clearing restores the full list.
    await user.clear(finder);
    await user.type(finder, "zzz-no-such-section");
    expect(screen.getByTestId("settings-nav-empty")).toBeDefined();
    expect(screen.queryByTestId("settings-search-result-access-bash-shell")).toBeNull();
    expect(
      screen.queryByRole("tablist", { name: "Settings categories" })
    ).toBeNull();
    await user.clear(finder);
    expect(railTabs()).toHaveLength(14);
  });

  it("drills from a Your Name item result and highlights the field", async () => {
    stubPersonaFetch();
    const user = userEvent.setup();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    const finder = screen.getByTestId("settings-nav-search") as HTMLInputElement;
    await user.type(finder, "Your Name");
    const results = screen.getByRole("listbox", { name: "Matching settings" });
    const yourNameHit = within(results).getByRole("option", {
      name: /Your Name/,
    });
    expect(yourNameHit).toHaveAttribute(
      "data-testid",
      "settings-search-result-persona-user-name",
    );
    await user.click(yourNameHit);
    expect(
      screen.getByRole("tab", { name: /^Persona$/i }).getAttribute("aria-selected"),
    ).toBe("true");
    await waitFor(() => {
      const target = document.getElementById("persona-user-name");
      expect(target).not.toBeNull();
      const group = target?.closest(".form-group") ?? target;
      expect(group?.classList.contains("settings-search-highlight")).toBe(true);
    });
    expect(document.activeElement?.id).toBe("persona-user-name");
  });

  it("renders moved blocks only in their own tabs and never in engine", async () => {
    const user = userEvent.setup();
    stubPersonaFetch({
      settings: {
        ...PERSONA_SETTINGS,
        goals: {
          enabled: true,
          stepIntervalMinutes: 1440,
          maxActiveGoals: 3,
          maxStepsPerGoal: 8,
          planTimeoutSeconds: 120,
          maxTriggersPerGoal: 4,
        },
        ideas: { enabled: false, maxPerCycle: 3, timeoutSeconds: 60 },
        proactive: { mode: "all", judgeTimeoutSeconds: 20 },
      },
    });
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    // Persona tab owns the identity block.
    await user.click(screen.getByRole("tab", { name: /^Persona$/i }));
    expect(screen.getByTestId("persona-pane")).toBeDefined();
    expect(screen.getByLabelText("Assistant Name")).toBeDefined();
    expect(screen.queryByTestId("goals-pane")).toBeNull();
    expect(screen.queryByLabelText("Default Cadence (minutes)")).toBeNull();

    // Goals tab owns the pursuit block.
    await user.click(screen.getByRole("tab", { name: /^Goals$/i }));
    const goalsPane = screen.getByTestId("goals-pane");
    expect(within(goalsPane).getByLabelText(/Enable goal pursuit/i)).toBeDefined();
    expect(screen.getByLabelText("Default Cadence (minutes)")).toBeDefined();
    expect(screen.queryByTestId("persona-pane")).toBeNull();
    expect(screen.queryByLabelText("Assistant Name")).toBeNull();

    // Engine keeps only knobs plus the interruption policy.
    await user.click(screen.getByRole("tab", { name: /Engine and Logs/i }));
    expect(screen.getByDisplayValue("Test Engine")).toBeDefined();
    expect(screen.getByLabelText("Proactivity Mode")).toBeDefined();
    expect(screen.queryByTestId("persona-pane")).toBeNull();
    expect(screen.queryByTestId("goals-pane")).toBeNull();
    expect(screen.queryByLabelText("Assistant Name")).toBeNull();
    expect(screen.queryByLabelText("Default Cadence (minutes)")).toBeNull();
  });

  it("keeps exactly one submit per tab as the double-save guard", async () => {
    const user = userEvent.setup();
    stubPersonaFetch();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    for (const name of [/^Persona$/i, /^Goals$/i, /Engine and Logs/i]) {
      await user.click(screen.getByRole("tab", { name }));
      const form = document.querySelector("form.settings-form");
      expect(form).not.toBeNull();
      const submits = within(form as HTMLElement).getAllByRole("button", {
        name: "Save",
      });
      // One footer submit only; the retired per-card persona save is gone.
      expect(submits.length).toBe(1);
      expect(
        document.querySelector('[data-testid="persona-save"]'),
      ).toBeNull();
    }
  });

  it("keeps the engine save payload byte-equivalent with goals and proactive and no persona", async () => {
    const user = userEvent.setup();
    const settingsWithAutonomy = {
      ...PERSONA_SETTINGS,
      goals: {
        enabled: true,
        stepIntervalMinutes: 1440,
        maxActiveGoals: 3,
        maxStepsPerGoal: 8,
        planTimeoutSeconds: 120,
        maxTriggersPerGoal: 4,
      },
      ideas: { enabled: false, maxPerCycle: 3, timeoutSeconds: 60 },
      proactive: { mode: "all", judgeTimeoutSeconds: 20 },
    };
    let sentPayload: Record<string, unknown> | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
        if (init?.method === "PUT") {
          sentPayload = JSON.parse(String(init.body)) as Record<string, unknown>;
          return jsonResponse({ ...settingsWithAutonomy, ...sentPayload });
        }
        return jsonResponse(settingsWithAutonomy);
      }),
    );
    render(<SettingsManager />);
    await openEngineTab(user);
    const engineInput = screen.getByLabelText("Engine Name");
    await user.clear(engineInput);
    await user.type(engineInput, "Renamed Engine");
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const body = sentPayload as unknown as Record<string, unknown>;
    // The autonomous policy still rides the engine save exactly as before.
    expect(body).toHaveProperty("goals");
    expect(body).toHaveProperty("proactive");
    expect(body).toHaveProperty("ideas");
    expect((body["goals"] as Record<string, unknown>)["enabled"]).toBe(true);
    // Persona never rides the shared full save; it owns its tab save.
    expect(body).not.toHaveProperty("persona");
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
  });

  it("allows setting goals plan timeout to 0 for unlimited planning time", async () => {
    const user = userEvent.setup();
    const settingsWithGoals = {
      ...PERSONA_SETTINGS,
      goals: {
        enabled: true,
        stepIntervalMinutes: 1440,
        maxActiveGoals: 3,
        maxStepsPerGoal: 8,
        planTimeoutSeconds: 60,
        maxTriggersPerGoal: 4,
      },
    };
    let sentPayload: Record<string, unknown> | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
        if (init?.method === "PUT") {
          sentPayload = JSON.parse(String(init.body)) as Record<string, unknown>;
          return jsonResponse({ ...settingsWithGoals, ...sentPayload });
        }
        return jsonResponse(settingsWithGoals);
      }),
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /^Goals$/i }));
    const timeoutInput = screen.getByLabelText("Planning Timeout (seconds)");
    expect(timeoutInput).toBeDefined();
    await user.clear(timeoutInput);
    await user.type(timeoutInput, "0");
    await user.click(tabSaveButton());
    await waitFor(() => {
      expect(sentPayload).not.toBeNull();
    });
    const body = sentPayload as unknown as Record<string, unknown>;
    expect((body["goals"] as Record<string, unknown>)["planTimeoutSeconds"]).toBe(0);
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
  });

  it("keeps an unknown tab id on the current tab", async () => {
    stubPersonaFetch();
    // Fail-closed: unknown ids never narrow to the tab vocabulary.
    expect(isSettingsTab("bogus-tab")).toBe(false);
    expect(isSettingsTab("providers")).toBe(true);
    expect(isSettingsTab("access")).toBe(true);
    expect(isSettingsTab("policy")).toBe(false);
    expect(isSettingsTab(null)).toBe(false);
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    // Drifted ids never strand the pane; default providers tab stays selected.
    expect(
      screen.getByRole("tab", { name: /LLM Providers/i }).getAttribute("aria-selected"),
    ).toBe("true");
    expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
  });
});

describe("persona defaults and bounds contract", () => {
  it("pins the persona mirrors to the engine PersonaConfig", () => {
    // Cross-language contract: server owns PersonaConfig bounds, defaults, and enums.
    expect(MAX_PERSONA_ASSISTANT_NAME_LENGTH).toBe(32);
    expect(MAX_PERSONA_STYLE_LENGTH).toBe(2000);
    expect(MAX_PERSONA_USER_NAME_LENGTH).toBe(64);
    expect(DEFAULT_PERSONA_TONE).toBe("warm");
    expect(DEFAULT_PERSONA_AVATAR).toBe("violet");
    expect([...PERSONA_TONES]).toEqual(["concise", "warm", "formal", "playful"]);
    expect([...PERSONA_AVATAR_COLORS]).toEqual(["violet", "cyan", "emerald", "rose"]);
  });
});

describe("SettingsManager workspace", () => {
  const workspaceUsagePayload = { bytes: 12 * 1024 * 1024, files: 120, truncated: false, quotaMB: 500, quotaFiles: 10000 };

  function stubWorkspaceFetch(overrides: {
    onFetch?: (url: string, init?: RequestInit) => Response | Promise<Response> | null;
  } = {}) {
    const calls: Array<{ url: string; init?: RequestInit }> = [];
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      calls.push({ url: urlStr, init });
      const override = overrides.onFetch?.(urlStr, init);
      if (override) return override;
      if (urlStr === "/workspace/usage") return jsonResponse(workspaceUsagePayload);
      if (urlStr === "/workspace/tmp/prune" && init?.method === "POST") {
        return jsonResponse({ removed: 3 });
      }
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: [] });
      }
      if (urlStr.includes("/plugins")) return jsonResponse({ plugins: [] });
      if (urlStr === "/settings" && init?.method === "PUT") {
        return jsonResponse({ ...mockSettings, ...(JSON.parse(String(init.body)) as object) });
      }
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);
    return { fetchMock, calls };
  }

  async function openToolsTab() {
    const user = userEvent.setup();
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Tools and Runes/i }));
    await waitFor(() => {
      expect(screen.getByText("Workspace Storage")).toBeDefined();
    });
    return user;
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedRunsForTesting();
  });

  it("renders usage bars from GET /workspace/usage and prunes through a confirm", async () => {
    const { calls } = stubWorkspaceFetch();
    const user = await openToolsTab();

    await waitFor(() => {
      expect(screen.getByText(/12\.0 MB of 500 MB/)).toBeDefined();
    });
    expect(screen.getByText(/120 of 10,000 files/)).toBeDefined();
    expect(calls.some((c) => c.url === "/workspace/usage")).toBe(true);

    await user.click(screen.getByRole("button", { name: /Prune tmp/i }));
    expect(screen.getByRole("heading", { name: /Prune workspace tmp\?/i })).toBeDefined();
    await user.click(screen.getByRole("button", { name: "Confirm prune workspace tmp" }));
    await waitFor(() => {
      expect(calls.some((c) => c.url === "/workspace/tmp/prune" && c.init?.method === "POST")).toBe(true);
    });
    await waitFor(() => {
      expect(screen.getByText(/Pruned 3 tmp entries/)).toBeDefined();
    });
  });

  it("pins the workspace formatters and quota calculations", () => {
    expect(formatWorkspaceBytes(12 * 1024 * 1024)).toBe("12.0 MB");
    expect(workspaceQuotaPercent(12 * 1024 * 1024, 500 * 1024 * 1024)).toBe(2);
    expect(workspaceQuotaPercent(1, 0)).toBe(0);
  });
});

describe("SettingsManager bash bounds and workspace quotas", () => {
  const bashToolRow = { name: "bash.exec", description: "Run shell commands", permissionLevel: "requiresApproval", inputSchema: "{}", isEnabled: true, isBuiltIn: true, pluginID: null, source: "builtin", integrityStatus: "valid", hasConfig: true };
  const usagePayload = { bytes: 12 * 1024 * 1024, files: 120, truncated: false, quotaMB: 500, quotaFiles: 10000 };

  // One stubbed fetch answers settings, tools, plugins, and usage.
  function stubBoundFetch(settings: Record<string, unknown>, onPut?: (body: Record<string, unknown>) => Response) {
    const puts: Record<string, unknown>[] = [];
    let putCount = 0;
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        putCount += 1;
        const body = JSON.parse(String(init.body)) as Record<string, unknown>;
        puts.push(body);
        if (onPut) return onPut(body);
        return jsonResponse({ ...settings, ...body });
      }
      if (urlStr === "/workspace/usage") return jsonResponse(usagePayload);
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: [bashToolRow] });
      }
      if (urlStr.includes("/plugins")) return jsonResponse({ plugins: [] });
      return jsonResponse(settings);
    });
    vi.stubGlobal("fetch", fetchMock);
    return { puts, getPutCount: () => putCount };
  }

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedRunsForTesting();
  });

  it("renders editable workspace quotas beside read-only usage bars", async () => {
    const user = userEvent.setup();
    const settingsWithWorkspace = {
      ...mockSettings,
      bash: {
        enabled: true,
        defaultAction: "ask",
        rules: [{ pattern: "*", action: "ask" }],
        timeoutSeconds: 30,
        cpuSeconds: 60,
        memoryMb: 512,
        allowNetwork: false,
      },
      workspace: { quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 7 },
    };
    stubBoundFetch(settingsWithWorkspace);
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Tools and Runes/i }));
    await waitFor(() => {
      expect(screen.getByText("Workspace Storage")).toBeDefined();
    });

    // Bars still read the live tree from GET /workspace/usage.
    await waitFor(() => {
      expect(screen.getByText(/12\.0 MB of 500 MB/)).toBeDefined();
    });
    expect(screen.getByText(/120 of 10,000 files/)).toBeDefined();
    // Quota editors seed from GET /settings [workspace] beside the bars.
    expect((screen.getByLabelText(/Quota \(MB\)/i) as HTMLInputElement).value).toBe("500");
    expect((screen.getByLabelText(/Max files/i) as HTMLInputElement).value).toBe("10000");
    expect((screen.getByLabelText(/Tmp TTL \(days\)/i) as HTMLInputElement).value).toBe("7");
    // The config-file-only pointer is gone; retention now notes its prune timing.
    expect(screen.queryByText(/edit \[workspace\] quotaMB \/ quotaFiles in the config file/i)).toBeNull();
    expect(screen.getByText(/TTL applies on next prune/i)).toBeDefined();
  });

  it("saves edited quotas through the tab save with a workspace delta", async () => {
    const user = userEvent.setup();
    const settingsWithWorkspace = {
      ...mockSettings,
      bash: {
        enabled: true,
        defaultAction: "ask",
        rules: [{ pattern: "*", action: "ask" }],
        timeoutSeconds: 30,
        cpuSeconds: 60,
        memoryMb: 512,
        allowNetwork: false,
      },
      workspace: { quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 7 },
    };
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      if (init?.method === "PUT") {
        const body = JSON.parse(String(init.body)) as Record<string, unknown>;
        return jsonResponse({ ...settingsWithWorkspace, ...body });
      }
      if (urlStr === "/workspace/usage") return jsonResponse(usagePayload);
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: [bashToolRow] });
      }
      if (urlStr.includes("/plugins")) return jsonResponse({ plugins: [] });
      return jsonResponse(settingsWithWorkspace);
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Tools and Runes/i }));
    await waitFor(() => {
      expect(screen.getByText("Workspace Storage")).toBeDefined();
    });
    await waitFor(() => {
      expect(screen.getByText(/12\.0 MB of 500 MB/)).toBeDefined();
    });

    // Quota edits flow through the tab's single Save as a workspace delta.
    const quotaInput = screen.getByLabelText(/Quota \(MB\)/i) as HTMLInputElement;
    await user.clear(quotaInput);
    await user.type(quotaInput, "600");
    await user.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      const puts = fetchMock.mock.calls.filter(([, init]) => (init as RequestInit)?.method === "PUT");
      expect(puts.length).toBe(1);
    });
    const putCall = fetchMock.mock.calls.find(([, init]) => (init as RequestInit)?.method === "PUT");
    const sent = JSON.parse(String((putCall?.[1] as RequestInit)?.body)) as Record<string, unknown>;
    const workspace = sent["workspace"] as Record<string, unknown>;
    expect(workspace).toEqual({ quotaMB: 600, quotaFiles: 10000, tmpTTLDays: 7 });
    await waitFor(() => {
      expect(screen.getByText("Settings saved.")).toBeDefined();
    });
  });

  it("rejects an out-of-range workspace quota before any network write", async () => {
    const user = userEvent.setup();
    const settingsWithWorkspace = {
      ...mockSettings,
      workspace: { quotaMB: 500, quotaFiles: 10000, tmpTTLDays: 7 },
    };
    let putCount = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        const urlStr = String(url);
        if (init?.method === "PUT") {
          putCount += 1;
          return jsonResponse({ ...settingsWithWorkspace });
        }
        if (urlStr === "/workspace/usage") return jsonResponse(usagePayload);
      if (urlStr.includes("/tools")) return jsonResponse({ tools: [bashToolRow] });
        if (urlStr.includes("/plugins")) return jsonResponse({ plugins: [] });
        return jsonResponse(settingsWithWorkspace);
      }),
    );
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Tools and Runes/i }));
    await waitFor(() => {
      expect(screen.getByText("Workspace Storage")).toBeDefined();
    });

    // A single-digit quota would not fit a working checkout, so the form fails
    // closed with the bound instead of returning a server 400.
    const quotaInput = screen.getByLabelText(/Quota \(MB\)/i) as HTMLInputElement;
    await user.clear(quotaInput);
    await user.type(quotaInput, "5");
    await user.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(screen.getByText(/Invalid workspace quota/i)).toBeDefined();
    });
    expect(putCount).toBe(0);
  });
});

describe("bash sandbox copy and tiers", () => {
  it("pins tier values plus labels plus scope sentences", () => {
    expect(BASH_SANDBOX_TIERS.map((tier) => tier.value)).toEqual([
      "strictContainer",
      "machineScoped",
      "hostSeatbelt",
    ]);
    expect(BASH_SANDBOX_TIERS.map((tier) => tier.label)).toEqual([
      "Temporary container",
      "Workspace machine",
      "On this Mac",
    ]);
    expect(BASH_SANDBOX_TIERS.map((tier) => tier.scope)).toEqual([
      "Scope: fresh workspace scratch, deleted at turn end.",
      "Scope: full workspace, kept across runs.",
      "Scope: your entire Mac, running as you.",
    ]);
  });

  it("pins per-tier approval copy for every tier plus network flag", () => {
    expect(bashSandboxSummary("strictContainer", false)).toBe("Runs in a temporary container with no internet access. Nothing is kept after the run.");
    expect(bashSandboxSummary("strictContainer", true)).toBe("Runs in a temporary container with internet access to approved destinations only. Nothing is kept after the run.");
    expect(bashSandboxSummary("machineScoped", false)).toBe("Runs in a persistent workspace machine with no internet access. Workspace files persist across runs.");
    expect(bashSandboxSummary("machineScoped", true)).toBe("Runs in a persistent workspace machine with internet access to approved destinations only. Workspace files persist across runs.");
    expect(bashSandboxSummary("hostSeatbelt", false)).toBe("Runs on your Mac as you with full access to your files.");
    expect(bashSandboxSummary("hostSeatbelt", true)).toBe("Runs on your Mac as you with full access to your files.");
    expect(BASH_SANDBOX_COPY.host).toBe("Runs on your Mac as you with full access to your files.");
  });
});

describe("SettingsManager workspace machine control", () => {
  const usagePayload = {
    bytes: 12 * 1024 * 1024,
    files: 120,
    truncated: false,
    quotaMB: 500,
    quotaFiles: 10000,
  };

  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedRunsForTesting();
  });

  it("reads machine status and posts stop plus recycle with refresh", async () => {
    const user = userEvent.setup();
    let machineState = { exists: true, running: true, image: "alpine:latest", configMatch: true };
    const calls: Array<{ url: string; method?: string }> = [];
    const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const urlStr = String(url);
      calls.push({ url: urlStr, method: init?.method });
      if (urlStr === "/workspace/machine" && (!init?.method || init.method === "GET")) {
        return jsonResponse({ ...machineState });
      }
      if (urlStr === "/workspace/machine/stop" && init?.method === "POST") {
        machineState = { ...machineState, running: false };
        return jsonResponse({ ...machineState });
      }
      if (urlStr === "/workspace/machine/recycle" && init?.method === "POST") {
        machineState = { exists: false, running: false, image: "", configMatch: false };
        return jsonResponse({ ...machineState });
      }
      if (urlStr === "/workspace/usage") return jsonResponse(usagePayload);
      if (urlStr.includes("/tools")) {
        return jsonResponse({ tools: [] });
      }
      if (urlStr.includes("/plugins")) return jsonResponse({ plugins: [] });
      return jsonResponse(mockSettings);
    });
    vi.stubGlobal("fetch", fetchMock);
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Tools and Runes/i }));
    await waitFor(() => {
      expect(screen.getByText("Workspace Storage")).toBeDefined();
    });

    await waitFor(() => {
      expect(screen.getByTestId("workspace-machine-status").textContent).toContain("alpine:latest");
    });
    expect(screen.getByTestId("workspace-machine-status").textContent).toContain("exists");
    expect(screen.getByTestId("workspace-machine-status").textContent).toContain("running");
    expect(screen.getByTestId("workspace-machine-status").textContent).toContain("image");
    expect(calls.some((call) => call.url === "/workspace/machine")).toBe(true);

    await user.click(screen.getByRole("button", { name: "Stop" }));
    await waitFor(() => {
      expect(calls.some((call) => call.url === "/workspace/machine/stop" && call.method === "POST")).toBe(true);
    });
    await waitFor(() => {
      expect(screen.getByTestId("workspace-machine-status").textContent).toContain("running: no");
    });

    await user.click(screen.getByRole("button", { name: "Recycle" }));
    await waitFor(() => {
      expect(calls.some((call) => call.url === "/workspace/machine/recycle" && call.method === "POST")).toBe(true);
    });
    await waitFor(() => {
      expect(screen.getByTestId("workspace-machine-status").textContent).toContain("exists: no");
    });
  });

  it("renders LLM Providers pane title matching the nav bar", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(mockSettings)));
    render(<SettingsManager />);

    await waitFor(() => {
      const heading = screen.getByRole("heading", { level: 3, name: "LLM Providers" });
      expect(heading).toBeInTheDocument();
    });
  });

  it("sorts provider cards alphabetically by provider name on load", async () => {
    const unorderedProvidersSettings = { ...mockSettings, providers: { zulu: { enabled: true, model: "zulu-model" }, alpha: { enabled: true, model: "alpha-model" }, bravo: { enabled: true, model: "bravo-model" } } };
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(unorderedProvidersSettings)));
    render(<SettingsManager />);
    await waitFor(() => {
      const providerInputs = screen.getAllByPlaceholderText("Provider Name") as HTMLInputElement[];
      expect(providerInputs.length).toBe(3);
      expect(providerInputs[0].value).toBe("alpha");
      expect(providerInputs[1].value).toBe("bravo");
      expect(providerInputs[2].value).toBe("zulu");
    });
  });

  it("calls onSettingsSaved when settings are successfully saved", async () => {
    const user = userEvent.setup();
    const onSettingsSaved = vi.fn();
    let saved = false;

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const url = String(input);
        if (init?.method === "PUT" && url.includes("/settings")) {
          saved = true;
          return jsonResponse({ ...mockSettings, requiresRestart: false });
        }
        if (url.includes("/runs")) {
          return jsonResponse({ runs: [] });
        }
        return jsonResponse(mockSettings);
      })
    );

    render(<SettingsManager onSettingsSaved={onSettingsSaved} />);

    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });

    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    const savedModelInput = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(savedModelInput);
    await user.type(savedModelInput, "gemma-4-9b-edited");
    const saveBtn = screen.getByRole("button", { name: "Save" });
    expect(saveBtn).toBeEnabled();
    await user.click(saveBtn);

    await waitFor(() => {
      expect(saved).toBe(true);
      expect(onSettingsSaved).toHaveBeenCalled();
    });
  });

  it("initializes active tab to access when hash contains access=rules", async () => {
    window.location.hash = "#settings?access=rules";
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(mockSettings)));
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: "Access" }).getAttribute("aria-selected")).toBe("true");
    });
    window.location.hash = "";
  });

  it("renders sidenav tab buttons in the logical governance-first order", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(mockSettings)));
    render(<SettingsManager />);

    await waitFor(() => {
      expect(screen.getByRole("tab", { name: "Access" })).toBeDefined();
    });

    const sidenav = document.querySelector(".settings-sidenav");
    expect(sidenav).not.toBeNull();
    const tabButtons = Array.from(sidenav!.querySelectorAll(".settings-tab-btn > span")).map((s) => s.textContent);
    expect(tabButtons).toEqual(["Access", "LLM Providers", "Persona", "Voice", "Memory and Storage", "Goals", "Tools and Runes", "Indexing", "Web", "Email Accounts", "Security", "Network", "Engine and Logs", "Notifications"]);
  });
});

describe("SettingsManager engine advanced disclosure", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    resetSharedRunsForTesting();
  });

  it("keeps the Engine Advanced trigger static with no chip", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(mockSettings)));
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Engine and Logs/i }));
    const trigger = screen.getByTestId("advanced-engine-trigger");
    expect(trigger.textContent).toBe("Advanced Engine settings");
    expect(screen.queryByTestId("advanced-engine-chip")).toBeNull();
    await user.click(trigger);
    await waitFor(() => {
      expect((screen.getByTestId("advanced-engine") as HTMLDetailsElement).open).toBe(true);
    });
    expect(screen.getByTestId("advanced-engine-trigger").textContent).toBe("Advanced Engine settings");
    expect(screen.queryByTestId("advanced-engine-chip")).toBeNull();
  });

  it("keeps the Engine Reset advanced button retargeted to the static trigger", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(mockSettings)));
    render(<SettingsManager />);
    await waitFor(() => {
      expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined();
    });
    await user.click(screen.getByRole("tab", { name: /Engine and Logs/i }));
    await user.click(screen.getByTestId("advanced-engine-trigger"));
    await waitFor(() => {
      expect((screen.getByTestId("advanced-engine") as HTMLDetailsElement).open).toBe(true);
    });
    const reset = screen.getByTestId("advanced-engine-reset");
    expect(reset.textContent).toBe("Reset advanced");
    await user.click(reset);
    expect(screen.getByTestId("advanced-engine-trigger").textContent).toBe("Advanced Engine settings");
    expect(screen.queryByTestId("advanced-engine-chip")).toBeNull();
  });
});

describe("SettingsManager live refresh", () => {
  beforeEach(() => { vi.unstubAllGlobals(); resetSharedRunsForTesting(); resetSharedSocket(); });
  function stubLiveSettingsFetch() {
    let n = 0;
    vi.stubGlobal("fetch", vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url === "/settings" && !init?.method) { n += 1; return jsonResponse(mockSettings); }
      if (url.includes("/plugins") || url.includes("/tools")) return jsonResponse({ plugins: [], tools: [] });
      return jsonResponse(mockSettings);
    }));
    return { get settingsCalls() { return n; } };
  }
  function installLiveSocket() {
    const c = createMockWebSocketCapture(); vi.stubGlobal("WebSocket", createMockWebSocket(c));
    return c;
  }
  it("carries no manual Refresh button and converges through live frames alone", async () => {
    installLiveSocket(); stubLiveSettingsFetch(); render(<SettingsManager />);
    await waitFor(() => expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined());
    expect(screen.queryByRole("button", { name: "Refresh" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Refresh/i })).not.toBeInTheDocument();
  });
  it("refetches clean settings on frame, foreground return, and socket reopen", async () => {
    const c = installLiveSocket(); const k = stubLiveSettingsFetch();
    const view = render(<SettingsManager />);
    await waitFor(() => expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined());
    await waitFor(() => expect(c.onMessage).not.toBeNull());
    await waitFor(() => expect(k.settingsCalls).toBeGreaterThan(0));
    const s0 = k.settingsCalls;
    await dispatchFrameOrThrow(c.onMessage, { type: "settings_changed" });
    await waitFor(() => expect(k.settingsCalls).toBeGreaterThan(s0));
    expect(screen.queryByTestId("settings-stale-banner")).toBeNull();
    const s1 = k.settingsCalls;
    const spy = vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
    fireEvent(document, new Event("visibilitychange"));
    await waitFor(() => expect(k.settingsCalls).toBeGreaterThan(s1));
    spy.mockRestore();
    const s2 = k.settingsCalls;
    view.unmount(); resetSharedSocket(); render(<SettingsManager />);
    await waitFor(() => expect(k.settingsCalls).toBeGreaterThan(s2));
  });
  it("suppresses auto-refetch when dirty and shows the stale banner", async () => {
    const user = userEvent.setup(); const c = installLiveSocket(); const k = stubLiveSettingsFetch();
    render(<SettingsManager />);
    await waitFor(() => expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined());
    await waitFor(() => expect(c.onMessage).not.toBeNull());
    // Dirty draft must not be clobbered by a remote wake-up.
    const field = screen.getByDisplayValue("gemma-4-9b");
    await user.clear(field); await user.type(field, "gemma-4-9b-edited");
    const s0 = k.settingsCalls;
    await dispatchFrameOrThrow(c.onMessage, { type: "settings_changed" });
    await waitFor(() => expect(screen.getByTestId("settings-stale-banner")).toBeInTheDocument());
    expect(screen.getByText("Settings changed elsewhere")).toBeInTheDocument();
    await new Promise((r) => setTimeout(r, 150));
    expect(k.settingsCalls).toBe(s0);
    await user.click(screen.getByRole("button", { name: "Reload" }));
    await waitFor(() => expect(k.settingsCalls).toBeGreaterThan(s0));
    await waitFor(() => expect(screen.queryByTestId("settings-stale-banner")).toBeNull());
  });
  it("ignores unknown frames without refetching or stale banner", async () => {
    const c = installLiveSocket(); const k = stubLiveSettingsFetch();
    render(<SettingsManager />);
    await waitFor(() => expect(screen.getByDisplayValue("gemma-4-9b")).toBeDefined());
    await waitFor(() => expect(c.onMessage).not.toBeNull());
    await waitFor(() => expect(k.settingsCalls).toBeGreaterThan(0));
    const s0 = k.settingsCalls;
    for (const t of ["definitely_unknown_xyz", "scheduler_jobs_changed", "scheduled_sends_changed", "run_started", "run_completed", "goal_updated"]) await dispatchFrameOrThrow(c.onMessage, { type: t });
    await new Promise((r) => setTimeout(r, 150));
    expect(k.settingsCalls).toBe(s0);
    expect(screen.queryByTestId("settings-stale-banner")).toBeNull();
  });
});


