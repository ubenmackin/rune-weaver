// Rune Weaver Dashboard — Component tests for the shared Keychain secret modal.
//
// Purpose: Pins the single owner behind every in-pane secret Set and Update:
// one header naming the key, Keychain-scoped copy that never echoes secret
// bytes, prefix-tolerant key normalization, and a guarded submit path that
// reports empty, oversize, and transport failures honestly while staying
// inert under Escape and backdrop dismissal mid-flight.
// Scope: Header, scope copy, and dialog role, normalizeSecretKey vectors, the
// empty-trim guard with no request, the 413 size message, success clearing
// plus onSuccess, and mid-flight dismissal guards only; wire shapes stay with
// the api client suite and row badges stay with the pane suite.
// Architectural role: Guards the only dashboard surface that carries secret
// bytes, so every entry point stores through one validated modal instead of
// drifting per-tab copies that could log, persist, or replay a value.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { StoreSecretModal, normalizeSecretKey } from "./StoreSecretModal";
import { jsonResponse } from "../test-utils/http";

describe("StoreSecretModal", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  function renderModal(overrides?: {
    secretKey?: string;
    title?: string;
    isUpdate?: boolean;
    onClose?: () => void;
    onSuccess?: (key: string) => void;
  }) {
    const onClose = overrides?.onClose ?? (() => {});
    const onSuccess = overrides?.onSuccess ?? (() => {});
    render(
      <StoreSecretModal
        isOpen={true}
        secretKey={overrides?.secretKey ?? "MY_KEY"}
        title={overrides?.title ?? "Store secret for MY_KEY"}
        isUpdate={overrides?.isUpdate ?? false}
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );
    return { onClose, onSuccess };
  }

  it("renders the header, Keychain scope copy, and dialog role", () => {
    renderModal();

    // Header names the action under test; the dialog carries the same name so
    // assistive technology announces the store it confirms.
    expect(screen.getByRole("heading", { name: "Store secret for MY_KEY" })).toBeDefined();
    expect(
      screen.getByRole("dialog", { name: "Store secret for MY_KEY" })
    ).toBeDefined();
    // Scope copy bounds the write to the Keychain service without echoing any
    // value; the key itself renders as the account under edit.
    expect(screen.getByText(/com\.runeweaver\.secrets/)).toBeDefined();
    expect(screen.getByText("MY_KEY")).toBeDefined();
  });

  it("renders update copy when editing a stored secret", () => {
    renderModal({ title: "Update secret for MY_KEY", isUpdate: true });

    expect(screen.getByLabelText(/new secret/i)).toBeDefined();
    expect(screen.getByRole("button", { name: /update in keychain/i })).toBeDefined();
  });

  it("strips a single rwsecret: prefix after trimming", () => {
    // Pasted surrogate spellings normalize to the bare key; a doubled prefix
    // strips once so the remainder stays visible instead of vanishing.
    expect(normalizeSecretKey("rwsecret:MY_KEY")).toBe("MY_KEY");
    expect(normalizeSecretKey("  rwsecret:MY_KEY  ")).toBe("MY_KEY");
    expect(normalizeSecretKey("rwsecret:rwsecret:MY_KEY")).toBe("rwsecret:MY_KEY");
    expect(normalizeSecretKey("MY_KEY")).toBe("MY_KEY");
    expect(normalizeSecretKey("  MY_KEY  ")).toBe("MY_KEY");
    expect(normalizeSecretKey("")).toBe("");
    expect(normalizeSecretKey("   ")).toBe("");
  });

  it("refuses a blank secret without touching the network", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    const onSuccess = vi.fn();
    const user = userEvent.setup();
    renderModal({ onSuccess });

    // Whitespace-only keeps the named save disabled, so the form submits
    // directly to prove the trim guard reports before any request exists.
    // The dialog aria-label also contains "secret", so the input is pinned
    // by test id to avoid matching the dialog wrapper.
    const secretInput = screen.getByTestId("secret-value-input");
    const form = secretInput.closest("form");
    expect(form).not.toBeNull();
    await user.type(secretInput, "   ");
    fireEvent.submit(form as HTMLFormElement);

    expect(await screen.findByText("Please enter a secret value.")).toBeDefined();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it("surfaces the size rejection when the secret exceeds the byte bound", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ reason: "Secret exceeds 16384 bytes." }, 413)
    );
    vi.stubGlobal("fetch", fetchMock);
    const onSuccess = vi.fn();
    const user = userEvent.setup();
    renderModal({ onSuccess });

    // The dialog aria-label also contains "secret", so the input is pinned
    // by test id to avoid matching the dialog wrapper.
    await user.type(screen.getByTestId("secret-value-input"), "too-big-value");
    await user.click(screen.getByRole("button", { name: /save to keychain/i }));

    // The engine reason names the bound; the modal repeats it verbatim and
    // stays open so the owner can retry with a shorter value.
    expect(await screen.findByText("Secret exceeds 16384 bytes.")).toBeDefined();
    expect(onSuccess).not.toHaveBeenCalled();
    expect(
      screen.getByRole("dialog", { name: "Store secret for MY_KEY" })
    ).toBeDefined();
  });

  it("clears the value and reports success on store", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    const onSuccess = vi.fn();
    const onClose = vi.fn();
    const user = userEvent.setup();
    renderModal({ onSuccess, onClose });

    // The dialog aria-label also contains "secret", so the input is pinned
    // by test id to avoid matching the dialog wrapper.
    const secretInput = screen.getByTestId("secret-value-input") as HTMLInputElement;
    await user.type(secretInput, "fresh-secret");
    await user.click(screen.getByRole("button", { name: /save to keychain/i }));

    await waitFor(() => {
      expect(onSuccess).toHaveBeenCalledWith("MY_KEY");
      expect(secretInput.value).toBe("");
    });
    // The write routes to the secrets endpoint; only the key is asserted, so
    // the value itself is never replayed by the suite.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/settings/secrets");
    expect(init.method).toBe("POST");
    expect((JSON.parse(init.body as string) as { key?: unknown }).key).toBe("MY_KEY");
  });

  it("ignores Escape and backdrop while a store is in flight", async () => {
    let resolvePost!: (value: Response) => void;
    const pending = new Promise<Response>((resolve) => {
      resolvePost = resolve;
    });
    const fetchMock = vi.fn(async () => pending);
    vi.stubGlobal("fetch", fetchMock);
    const onClose = vi.fn();
    const onSuccess = vi.fn();
    const user = userEvent.setup();
    renderModal({ onClose, onSuccess });

    // The dialog aria-label also contains "secret", so the input is pinned
    // by test id to avoid matching the dialog wrapper.
    await user.type(screen.getByTestId("secret-value-input"), "in-flight-value");
    await user.click(screen.getByRole("button", { name: /save to keychain/i }));

    // The saving copy proves the request is in flight before dismissal is probed.
    expect(await screen.findByText("Saving…")).toBeDefined();
    await user.keyboard("{Escape}");
    expect(onClose).not.toHaveBeenCalled();
    // The dialog element is the shared backdrop, so clicking it exercises the
    // same dismissal path as a click outside the container.
    await user.click(screen.getByRole("dialog", { name: "Store secret for MY_KEY" }));
    expect(onClose).not.toHaveBeenCalled();
    expect(
      screen.getByRole("dialog", { name: "Store secret for MY_KEY" })
    ).toBeDefined();
    expect(fetchMock).toHaveBeenCalledTimes(1);

    // Settling still reports once the flight lands: the guard blocked
    // dismissal, never the completion.
    resolvePost(new Response(null, { status: 204 }));
    await waitFor(() => {
      expect(onSuccess).toHaveBeenCalledWith("MY_KEY");
    });
  });

  it("closes on Escape when idle", async () => {
    const onClose = vi.fn();
    const user = userEvent.setup();
    renderModal({ onClose });

    // Idle dismissal stays live so the mid-flight guard reads as a submitting
    // exception rather than a permanently trapped dialog.
    await user.keyboard("{Escape}");
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
