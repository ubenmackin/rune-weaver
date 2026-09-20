// Rune Weaver Dashboard — Component tests for the in-bundle owner-token gate.
//
// The engine serves the dashboard bundle publicly because a browser cannot
// attach a bearer header to a navigation or an asset fetch, so this view is the
// real credential gate. These tests pin its contract: a candidate is probed
// against the protected settings route, adopted only on success, and every
// failure class renders one honest line that never echoes the typed token.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import LoginView from "./LoginView";
import { clearAuthToken, getAuthToken } from "../api";

describe("LoginView owner-token gate", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
  });

  it("adopts a candidate token, clears the form, and notifies the parent", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const onAuthenticated = vi.fn();
    render(<LoginView onAuthenticated={onAuthenticated} />);

    const input = screen.getByLabelText("Access token") as HTMLInputElement;
    await user.type(input, "owner-token");
    await user.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => expect(onAuthenticated).toHaveBeenCalledOnce());
    expect(getAuthToken()).toBe("owner-token");
    // The typed credential is dropped as soon as it is adopted so it does not
    // linger in the replaced form.
    expect(input.value).toBe("");
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/settings");
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer owner-token",
    );
  });

  it("shows one generic rejection without echoing the typed token", async () => {
    const user = userEvent.setup();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: "unauthorized" }), {
            status: 401,
            headers: { "Content-Type": "application/json" },
          }),
      ),
    );
    render(<LoginView />);

    await user.type(screen.getByLabelText("Access token"), "guess-token-123");
    await user.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent("Invalid access token."),
    );
    // A near-miss guess must not be confirmable from the rendered wording.
    expect(document.body.textContent).not.toContain("guess-token-123");
    expect(getAuthToken()).toBeNull();
  });

  it("reports throttling and transport failures distinctly", async () => {
    const user = userEvent.setup();
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 429 })));
    render(<LoginView />);
    await user.type(screen.getByLabelText("Access token"), "any-token");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Too many attempts. Wait a moment and try again.",
      ),
    );

    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("engine down");
      }),
    );
    await user.clear(screen.getByLabelText("Access token"));
    await user.type(screen.getByLabelText("Access token"), "any-token");
    await user.click(screen.getByRole("button", { name: "Sign in" }));
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Could not reach the engine.",
      ),
    );
  });
});
