// Rune Weaver Dashboard — Component tests for SettingsManager.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsManager from "./SettingsManager";
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
    const saveButton = screen.getByRole("button", { name: /Save Settings/i });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
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
    const saveButton = screen.getByRole("button", { name: /Save Settings/i });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
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

    // Empty initial registry proves the empty state; rescan returning a rune
    // proves local discovery still works without any marketplace interaction.
    // The second fetch parameter stays unused here because this path only
    // serves GET fixtures and never inspects request bodies.
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
    // Hold the state POST open so the test can observe the pending row
    // before the refreshed list resolves. A mutable holder keeps the
    // resolver visible across the fetch closure without narrowing the
    // local to null at the release site.
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

    const saveButton = screen.getByRole("button", { name: /Save Settings/i });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
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

    const saveButton = screen.getByRole("button", { name: /Save Settings/i });
    await user.click(saveButton);

    await waitFor(() => {
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
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
      expect(screen.getByText(/Settings saved successfully/i)).toBeDefined();
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
});

