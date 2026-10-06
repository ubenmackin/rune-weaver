// Rune Weaver Dashboard — Component tests for the binding wizard modal.
//
// Purpose: Pins the stepped key to hosts to methods-plus-paths flow that keeps
// one key paired with hosts, methods, and path prefixes with per-step gating,
// so the secret is sent only when host, method, and effective path all match.
// Scope: Step progression, per-step Continue gating, mini versus full probe
// placement, and the onSave draft shape only; TOML persistence, Keychain
// writes, and network allowlist updates stay with the owning pane.
// Architectural role: Guards the visual editor over the declarative
// credential-binding contract, so a wizard edit cannot persist unvalidated
// text or a mismatched draft shape.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { PolicyBindingModal } from "./PolicyBindingModal";

function renderAddModal(onSave = vi.fn()) {
  const onClose = vi.fn();
  render(<PolicyBindingModal onSave={onSave} onClose={onClose} />);
  return { onSave, onClose };
}

async function advanceWithKey(user: ReturnType<typeof userEvent.setup>, key: string) {
  const modal = screen.getByTestId("policy-binding-modal");
  await user.type(within(modal).getByLabelText("Key"), key);
  await user.click(within(modal).getByTestId("wizard-next"));
  return modal;
}

describe("PolicyBindingModal wizard", () => {
  it("opens on Step 1 showing key while hosts stays hidden and Continue stays blocked", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    renderAddModal(onSave);

    const modal = screen.getByTestId("policy-binding-modal");
    expect(within(modal).getByTestId("key-section")).toBeDefined();
    expect(within(modal).queryByTestId("hosts-section")).toBeNull();

    const next = within(modal).getByTestId("wizard-next") as HTMLButtonElement;
    expect(next.disabled).toBe(true);

    await user.click(next);
    expect(within(modal).getByTestId("key-section")).toBeDefined();
    expect(within(modal).queryByTestId("hosts-section")).toBeNull();
    expect(onSave).not.toHaveBeenCalled();
  });

  it("advances on a valid key and gates empty hosts with one error before accepting hosts", async () => {
    const user = userEvent.setup();
    renderAddModal();

    let modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Key"), "WIZARD_KEY");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });

    const next = within(modal).getByTestId("wizard-next") as HTMLButtonElement;
    expect(next.disabled).toBe(true);
    expect(within(modal).getByTestId("hosts-errors")).toBeDefined();
    expect(modal.querySelectorAll(".error-banner")).toHaveLength(1);

    await user.click(next);
    expect(within(modal).getByTestId("hosts-section")).toBeDefined();

    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await waitFor(() => {
      expect((within(modal).getByTestId("wizard-next") as HTMLButtonElement).disabled).toBe(
        false,
      );
    });
    await user.click(within(modal).getByTestId("wizard-next"));

    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
  });

  it("shows coverage without the shortcut and a mini probe without inputs on the hosts step", async () => {
    const user = userEvent.setup();
    renderAddModal();

    await advanceWithKey(user, "COVER_KEY");
    const modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });

    expect(within(modal).getByTestId("network-coverage")).toBeDefined();
    expect(
      within(modal).queryByRole("button", { name: "Store in Keychain" }),
    ).toBeNull();
    expect(within(modal).getByTestId("hosts-probe-mini")).toBeDefined();
    expect(within(modal).queryByLabelText("Probe method")).toBeNull();
    expect(within(modal).queryByLabelText("Probe host")).toBeNull();
    expect(within(modal).queryByLabelText("Probe path")).toBeNull();
  });

  it("shows methods plus paths plus probe on the review step and saves the typed draft", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    renderAddModal(onSave);

    await advanceWithKey(user, "SAVE_KEY");
    let modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    expect(within(modal).getByTestId("paths-section")).toBeDefined();
    expect(within(modal).getByTestId("probe-result")).toBeDefined();

    const selectScope = within(modal).queryByText("Select methods");
    if (selectScope) {
      await user.click(selectScope);
    }
    await user.click(within(modal).getByLabelText("GET"));
    await user.click(within(modal).getByLabelText("POST"));

    const restrictToggle = within(modal).queryByText("Restrict to paths (optional)");
    if (restrictToggle) {
      await user.click(restrictToggle);
    }
    await user.type(within(modal).getByLabelText("Path prefixes"), "/v1");

    await user.click(within(modal).getByRole("button", { name: "Save binding" }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    const draft = onSave.mock.calls[0][0] as {
      key: string;
      hosts: string[];
      methods: string[];
      pathPrefixes: string[];
      allowedHosts: string[];
      allowedMethods: string[];
      allowedPathPrefixes: string[];
      allowed_hosts: string[];
      allowed_methods: string[];
      allowed_path_prefixes: string[];
    };
    expect(draft.key).toBe("SAVE_KEY");
    expect(draft.hosts).toEqual(["api.example.com"]);
    expect(draft.methods).toEqual(["GET", "POST"]);
    expect(draft.pathPrefixes).toEqual(["/v1"]);
    expect(draft.allowedHosts).toEqual(["api.example.com"]);
    expect(draft.allowed_hosts).toEqual(["api.example.com"]);
    expect(draft.allowedMethods).toEqual(["GET", "POST"]);
    expect(draft.allowed_methods).toEqual(["GET", "POST"]);
    expect(draft.allowedPathPrefixes).toEqual(["/v1"]);
    expect(draft.allowed_path_prefixes).toEqual(["/v1"]);
  });
});
