// Rune Weaver Dashboard — Unit tests for PluginConfigModal.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PluginConfigModal } from "./PluginConfigModal";
import type { PluginSummary } from "../../api";

const mockPlugin: PluginSummary = {
  id: "community.monarch-money",
  name: "Monarch Money",
  version: "1.0.0",
  author: "Community",
  description: "Monarch Money financial assistant",
  runtime: "python",
  source: "marketplace",
  status: "enabled",
  isEnabled: true,
  tools: [
    {
      name: "monarch.accounts",
      description: "Query accounts",
      permissionLevel: "readOnly",
      inputSchema: "{}",
      isEnabled: true,
      isBuiltIn: false,
      source: "marketplace",
      integrityStatus: "valid",
    },
  ],
  permissionOverrides: {},
  discoveredAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
  credentials: [
    {
      key: "MONARCH_TOKEN",
      label: "Monarch Token",
      description: "API access token",
      required: true,
    },
    {
      key: "MONARCH_PASSWORD",
      label: "Monarch Password",
      description: "Account password",
      required: false,
    },
  ],
  options: [
    {
      key: "default_currency",
      label: "Default Currency",
      description: "ISO currency code",
      type: "string",
      defaultValue: "USD",
    },
  ],
  declaredNetworkHosts: ["api.monarch.com"],
  userConfig: {
    default_currency: "USD",
  },
};

describe("PluginConfigModal", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation((input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/settings/policy")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                policy: {
                  version: 1,
                  network: {
                    mode: "allowlist_only",
                    allowed_domains: ["example.com"],
                    blocked_domains: [],
                  },
                  credentials: {},
                },
              }),
              { status: 200, headers: { "Content-Type": "application/json" } }
            )
          );
        }
        return Promise.resolve(new Response(null, { status: 404 }));
      })
    );
  });

  it("renders credentials, required status, and keychain action buttons", async () => {
    const handleOpenSecret = vi.fn();
    render(
      <PluginConfigModal
        isOpen={true}
        onClose={vi.fn()}
        plugin={mockPlugin}
        secretStatus={{ MONARCH_TOKEN: true }}
        handleOpenStoreSecretModal={handleOpenSecret}
      />
    );

    expect(screen.getByText("Configure Monarch Money")).toBeInTheDocument();
    expect(screen.getByText("Monarch Token")).toBeInTheDocument();
    expect(screen.getByText("Required")).toBeInTheDocument();
    expect(screen.getByText("Stored in Keychain")).toBeInTheDocument();
    expect(screen.getByText("Not Set in Keychain")).toBeInTheDocument();

    const buttons = screen.getAllByRole("button");
    const updateBtn = buttons.find((b) => b.textContent?.includes("Update Key"));
    expect(updateBtn).toBeDefined();
    await userEvent.click(updateBtn!);
    expect(handleOpenSecret).toHaveBeenCalledWith("MONARCH_TOKEN", "Monarch Token", true);
  });

  it("renders declared network egress hosts and checks policy status", async () => {
    render(
      <PluginConfigModal
        isOpen={true}
        onClose={vi.fn()}
        plugin={mockPlugin}
        secretStatus={{}}
        handleOpenStoreSecretModal={vi.fn()}
      />
    );

    await waitFor(() => {
      expect(screen.getByText("api.monarch.com")).toBeInTheDocument();
    });
    expect(screen.getByText("Not in Policy")).toBeInTheDocument();
    expect(screen.getByText("Allow in Policy")).toBeInTheDocument();
  });
});
