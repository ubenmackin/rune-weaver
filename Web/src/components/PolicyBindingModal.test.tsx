// Rune Weaver Dashboard — Component tests for the binding wizard modal.

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { PolicyBindingModal, type PolicyBindingDraft } from "./PolicyBindingModal";

function renderAddModal(onSave = vi.fn()) {
  const onClose = vi.fn();
  const onAddAllowedDomains = vi.fn();
  render(
    <PolicyBindingModal
      onSave={onSave}
      onClose={onClose}
      onAddAllowedDomains={onAddAllowedDomains}
    />,
  );
  return { onSave, onClose, onAddAllowedDomains };
}

function progressWidth(modal: HTMLElement): string {
  const bar = within(modal)
    .getByTestId("wizard-progress")
    .querySelector(".wizard-progress-bar") as HTMLElement | null;
  return bar?.style.width ?? "";
}

async function advanceWithKey(
  user: ReturnType<typeof userEvent.setup>,
  key: string,
) {
  const modal = screen.getByTestId("policy-binding-modal");
  await user.type(within(modal).getByLabelText("Key"), key);
  await user.click(within(modal).getByTestId("wizard-next"));
  return modal;
}

async function walkToReview(
  user: ReturnType<typeof userEvent.setup>,
  key: string,
  hosts: string,
) {
  await advanceWithKey(user, key);
  let modal = await screen.findByTestId("policy-binding-modal");
  await waitFor(() => {
    expect(within(modal).getByTestId("hosts-section")).toBeDefined();
  });
  modal = screen.getByTestId("policy-binding-modal");
  await user.type(within(modal).getByLabelText("Hosts"), hosts);
  await user.click(within(modal).getByTestId("wizard-next"));
  modal = await screen.findByTestId("policy-binding-modal");
  await waitFor(() => {
    expect(within(modal).getByTestId("methods-section")).toBeDefined();
  });
  modal = screen.getByTestId("policy-binding-modal");
  await user.click(within(modal).getByTestId("wizard-next"));
  modal = await screen.findByTestId("policy-binding-modal");
  await waitFor(() => {
    expect(within(modal).getByTestId("binding-review")).toBeDefined();
  });
  return screen.getByTestId("policy-binding-modal");
}

describe("PolicyBindingModal wizard", () => {
  it("opens on Step 1 of 4 showing key while hosts stays hidden and Continue stays blocked", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    renderAddModal(onSave);

    const modal = screen.getByTestId("policy-binding-modal");
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 1 of 4",
    );
    expect(progressWidth(modal)).toBe("25%");
    expect(within(modal).getByTestId("key-section")).toBeDefined();
    expect(within(modal).queryByTestId("hosts-section")).toBeNull();
    expect(within(modal).queryByTestId("methods-section")).toBeNull();
    expect(within(modal).queryByTestId("binding-review")).toBeNull();

    const next = within(modal).getByTestId("wizard-next") as HTMLButtonElement;
    expect(next.disabled).toBe(true);
    expect(next.textContent).toContain("Continue");

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
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 2 of 4",
    );
    expect(progressWidth(modal)).toBe("50%");

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
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 3 of 4",
    );
    expect(progressWidth(modal)).toBe("75%");
  });

  it("keeps the probe off the first two steps while showing coverage on Hosts", async () => {
    const user = userEvent.setup();
    renderAddModal();

    await advanceWithKey(user, "COVER_KEY");
    const modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });

    expect(within(modal).getByTestId("network-coverage")).toBeDefined();
    expect(within(modal).queryByTestId("probe-result")).toBeNull();
    expect(within(modal).queryByTestId("probe-helper")).toBeNull();
    expect(within(modal).queryByLabelText("Probe method")).toBeNull();
    expect(within(modal).queryByLabelText("Probe host")).toBeNull();
    expect(within(modal).queryByLabelText("Probe path")).toBeNull();

    // Scope keeps the probe off too: only Review hosts the helper.
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    expect(within(modal).queryByTestId("probe-result")).toBeNull();
    expect(within(modal).queryByTestId("probe-helper")).toBeNull();
  });

  it("hides method boxes in Any mode and shows them in select mode", async () => {
    const user = userEvent.setup();
    renderAddModal();

    await advanceWithKey(user, "SCOPE_KEY");
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
    expect(within(modal).queryByLabelText("GET")).toBeNull();

    await user.click(within(modal).getByText("Select methods"));
    expect(within(modal).getByLabelText("GET")).toBeDefined();
    expect(within(modal).getByLabelText("POST")).toBeDefined();

    await user.click(within(modal).getByText("Any (empty means Any)"));
    expect(within(modal).queryByLabelText("GET")).toBeNull();
  });

  it("walks to Review with Continue and shows single Key plus Hosts summary rows", async () => {
    const user = userEvent.setup();
    renderAddModal();

    const modal = await walkToReview(user, "REVIEW_KEY", "api.example.com");
    expect(within(modal).getByTestId("wizard-step-indicator").textContent).toContain(
      "Step 4 of 4",
    );
    expect(progressWidth(modal)).toBe("100%");

    expect(within(modal).getByTestId("binding-review")).toBeDefined();
    expect(within(modal).getAllByTestId("review-key")).toHaveLength(1);
    expect(within(modal).getAllByTestId("review-hosts")).toHaveLength(1);
    expect(within(modal).getByTestId("review-key").textContent).toContain("REVIEW_KEY");
    expect(within(modal).getByTestId("review-hosts").textContent).toContain(
      "api.example.com",
    );
    expect(within(modal).queryByTestId("wizard-next")).toBeNull();
    expect(
      within(modal).getByRole("button", { name: "Save binding" }),
    ).toBeDefined();
  });

  it("states the conjunction with only when and without iff", async () => {
    const user = userEvent.setup();
    renderAddModal();

    const modal = await walkToReview(user, "CONJ_KEY", "api.example.com");
    const sentence =
      within(modal).getByTestId("binding-conjunction").textContent ?? "";
    expect(sentence).toContain("only when");
    expect(sentence).not.toContain("iff");
  });

  it("shows typed values with zero Edited tags in add mode", async () => {
    const user = userEvent.setup();
    renderAddModal();

    await advanceWithKey(user, "SAVE_KEY");
    let modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByText("Select methods"));
    await user.click(within(modal).getByLabelText("GET"));
    await user.click(within(modal).getByLabelText("POST"));
    await user.click(within(modal).getByText("Restrict to paths (optional)"));
    await user.type(within(modal).getByLabelText("Path prefixes"), "/v1");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("review-key").textContent).toContain("SAVE_KEY");
    expect(within(modal).getByTestId("review-hosts").textContent).toContain(
      "api.example.com",
    );
    expect(within(modal).getByTestId("review-methods").textContent).toContain("GET");
    expect(within(modal).getByTestId("review-methods").textContent).toContain("POST");
    expect(within(modal).getByTestId("review-paths").textContent).toContain("/v1");
    expect(within(modal).queryAllByTestId("edited-tag")).toHaveLength(0);
  });

  it("shows Edited tags for changed rows in edit mode", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    const onClose = vi.fn();
    render(
      <PolicyBindingModal
        mode="edit"
        initialBinding={{
          key: "EDIT_KEY",
          hosts: ["api.example.com"],
          methods: ["GET"],
          pathPrefixes: ["/v1"],
        }}
        editingKey="EDIT_KEY"
        existingBindingKeys={["EDIT_KEY"]}
        onSave={onSave}
        onClose={onClose}
      />,
    );

    let modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByLabelText("POST"));
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("review-methods").textContent).toContain("POST");
    const tags = within(modal).getAllByTestId("edited-tag");
    expect(tags.length).toBeGreaterThan(0);
    expect(within(modal).getByTestId("review-methods").textContent).toContain("Edited");
    expect(within(modal).getByTestId("review-key").textContent).not.toContain("Edited");
  });

  it("moves the probe verdict only on Test clicks", async () => {
    const user = userEvent.setup();
    renderAddModal();

    const modal = await walkToReview(user, "PROBE_KEY", "api.example.com");
    expect(within(modal).getByTestId("probe-helper")).toBeDefined();
    expect(within(modal).getByTestId("probe-result").textContent).toContain(
      "Yes — the secret would be sent.",
    );

    const probeHost = within(modal).getByLabelText("Probe host") as HTMLInputElement;
    await user.type(probeHost, "evil-collector.io");
    expect(within(modal).getByTestId("probe-result").textContent).toContain(
      "Yes — the secret would be sent.",
    );

    await user.click(within(modal).getByTestId("probe-run"));
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result").textContent).toContain("No —");
    });
    expect(within(modal).getByTestId("probe-result").textContent).toContain(
      "evil-collector.io",
    );
  });

  it("checks the coverage box by default and calls add then onSave", async () => {
    const user = userEvent.setup();
    const callOrder: string[] = [];
    const onSave = vi.fn((_draft: PolicyBindingDraft) => {
      callOrder.push("save");
    });
    const onClose = vi.fn();
    const onAddAllowedDomains = vi.fn(() => {
      callOrder.push("add");
    });
    render(
      <PolicyBindingModal
        onSave={onSave}
        onClose={onClose}
        onAddAllowedDomains={onAddAllowedDomains}
      />,
    );

    await advanceWithKey(user, "COVER_SAVE_KEY");
    let modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    const checkbox = within(modal).getByTestId(
      "allow-domains-checkbox",
    ) as HTMLInputElement;
    expect(checkbox.checked).toBe(true);

    await user.click(within(modal).getByRole("button", { name: "Save binding" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onAddAllowedDomains).toHaveBeenCalledTimes(1);
    expect(onAddAllowedDomains).toHaveBeenCalledWith(["api.example.com"]);
    expect(callOrder).toEqual(["add", "save"]);
    const draft = onSave.mock.calls[0][0] as unknown as {
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
    expect(draft.key).toBe("COVER_SAVE_KEY");
    expect(draft.hosts).toEqual(["api.example.com"]);
    expect(draft.methods).toEqual([]);
    expect(draft.pathPrefixes).toEqual([]);
    expect(draft.allowedHosts).toEqual(["api.example.com"]);
    expect(draft.allowed_hosts).toEqual(["api.example.com"]);
    expect(draft.allowedMethods).toEqual([]);
    expect(draft.allowed_methods).toEqual([]);
    expect(draft.allowedPathPrefixes).toEqual([]);
    expect(draft.allowed_path_prefixes).toEqual([]);
  });

  it("saves alone with the staying-blocked note when the coverage box is unchecked", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    const onClose = vi.fn();
    const onAddAllowedDomains = vi.fn();
    render(
      <PolicyBindingModal
        onSave={onSave}
        onClose={onClose}
        onAddAllowedDomains={onAddAllowedDomains}
      />,
    );

    await advanceWithKey(user, "UNCHECKED_KEY");
    let modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    await user.click(within(modal).getByTestId("allow-domains-checkbox"));
    await waitFor(() => {
      expect(
        (
          within(screen.getByTestId("policy-binding-modal")).getByTestId(
            "allow-domains-checkbox",
          ) as HTMLInputElement
        ).checked,
      ).toBe(false);
    });
    expect(screen.getByTestId("policy-binding-modal").textContent).toContain(
      "stay blocked",
    );

    await user.click(within(modal).getByRole("button", { name: "Save binding" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onAddAllowedDomains).not.toHaveBeenCalled();
  });

  it("hides the coverage box when hosts are fully covered", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    const onClose = vi.fn();
    const onAddAllowedDomains = vi.fn();
    render(
      <PolicyBindingModal
        onSave={onSave}
        onClose={onClose}
        onAddAllowedDomains={onAddAllowedDomains}
        allowedDomains={["api.example.com"]}
      />,
    );

    const modal = await walkToReview(user, "COVERED_KEY", "api.example.com");
    expect(within(modal).getByTestId("network-coverage").textContent).toContain(
      "All binding hosts are covered",
    );
    expect(within(modal).queryByTestId("allow-domains-checkbox")).toBeNull();

    await user.click(within(modal).getByRole("button", { name: "Save binding" }));
    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    expect(onAddAllowedDomains).not.toHaveBeenCalled();
  });

  it("shows methods plus paths plus probe on Review and saves the typed draft", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn((_draft: PolicyBindingDraft) => undefined);
    const onClose = vi.fn();
    const onAddAllowedDomains = vi.fn();
    render(
      <PolicyBindingModal
        onSave={onSave}
        onClose={onClose}
        onAddAllowedDomains={onAddAllowedDomains}
        allowedDomains={["api.example.com"]}
      />,
    );

    await advanceWithKey(user, "SAVE_KEY");
    let modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    expect(within(modal).getByTestId("paths-section")).toBeDefined();
    modal = screen.getByTestId("policy-binding-modal");
    await user.click(within(modal).getByText("Select methods"));
    await user.click(within(modal).getByLabelText("GET"));
    await user.click(within(modal).getByLabelText("POST"));
    await user.click(within(modal).getByText("Restrict to paths (optional)"));
    await user.type(within(modal).getByLabelText("Path prefixes"), "/v1");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("probe-result")).toBeDefined();
    });
    expect(within(modal).getByTestId("probe-helper")).toBeDefined();

    await user.click(within(modal).getByRole("button", { name: "Save binding" }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledTimes(1);
    });
    const draft = onSave.mock.calls[0][0] as unknown as {
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

  it("shows the pairing sentence on Review only", async () => {
    const user = userEvent.setup();
    renderAddModal();

    let modal = screen.getByTestId("policy-binding-modal");
    expect(within(modal).queryByTestId("binding-pairing-sentence")).toBeNull();

    await advanceWithKey(user, "PAIR_KEY");
    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    expect(within(modal).queryByTestId("binding-pairing-sentence")).toBeNull();

    modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));
    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    expect(within(modal).queryByTestId("binding-pairing-sentence")).toBeNull();

    await user.click(within(modal).getByTestId("wizard-next"));
    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("binding-review")).toBeDefined();
    });
    expect(within(modal).getByTestId("binding-pairing-sentence").textContent).toContain(
      "One binding pairs one key",
    );
    expect(within(modal).getByTestId("binding-pairing-sentence").textContent).toContain(
      "prefixes apply to every host",
    );
  });

  it("shows the Scope intro plus host context on Step 3", async () => {
    const user = userEvent.setup();
    renderAddModal();

    await advanceWithKey(user, "SCOPE_INTRO_KEY");
    let modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("hosts-section")).toBeDefined();
    });
    modal = screen.getByTestId("policy-binding-modal");
    await user.type(within(modal).getByLabelText("Hosts"), "api.example.com");
    await user.click(within(modal).getByTestId("wizard-next"));

    modal = await screen.findByTestId("policy-binding-modal");
    await waitFor(() => {
      expect(within(modal).getByTestId("methods-section")).toBeDefined();
    });
    expect(within(modal).getByTestId("scope-intro").textContent).toContain("Any");
    expect(within(modal).getByTestId("scope-hosts-context").textContent).toContain(
      "api.example.com",
    );
  });

  it("offers a primary Test action for the committed probe on Review", async () => {
    const user = userEvent.setup();
    renderAddModal();

    const modal = await walkToReview(user, "PRIMARY_TEST_KEY", "api.example.com");
    const probeRun = within(modal).getByTestId("probe-run") as HTMLButtonElement;
    expect(probeRun.textContent).toBe("Test");
    expect(probeRun.className).toContain("primary");
  });
});
