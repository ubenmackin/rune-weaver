// Rune Weaver Dashboard — Component tests for the in-bundle owner-token gate.

import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import LoginView from "./LoginView";
import { AUTH_TOKEN_STORAGE_KEY, clearAuthToken, getAuthToken, isSessionAuthenticated } from "../api";

describe("LoginView owner-token gate", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    clearAuthToken();
    window.sessionStorage.clear();
  });

  it("adopts a candidate token, clears the form, and notifies the parent", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ status: "ok" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const onAuthenticated = vi.fn();
    render(<LoginView onAuthenticated={onAuthenticated} />);

    // The fixed username must be present before typing so managers recognize
    // the pair on first render, and the hint tells the owner a save offer
    // is expected instead of another manual entry next session.
    const username = screen.getByLabelText("Username") as HTMLInputElement;
    expect(username.value).toBe("owner");
    expect(
      screen.getByText(/browser will offer to remember/i),
    ).toBeInTheDocument();

    const input = screen.getByLabelText("Access token") as HTMLInputElement;
    await user.type(input, "owner-token");
    await user.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => expect(onAuthenticated).toHaveBeenCalledOnce());
    expect(isSessionAuthenticated()).toBe(true);
    // Secret token is NOT retained in client-side memory or sessionStorage to prevent XSS exfiltration
    expect(getAuthToken()).toBeNull();
    expect(window.sessionStorage.getItem(AUTH_TOKEN_STORAGE_KEY)).toBeNull();
    // The typed credential is dropped as soon as it is adopted so it does not
    // linger in the replaced form, while the fixed username stays put for the
    // next save offer.
    expect(input.value).toBe("");
    expect(username.value).toBe("owner");
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/auth/session");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({ token: "owner-token" });
    expect(init.credentials).toBe("same-origin");
  });

  it("exposes password-manager-friendly fields so the sign-in is saveable", () => {
    render(<LoginView />);

    // Managers key entries by a username plus a password pair, so the fixed
    // identity must carry the username token and the secret the
    // current-password token with matching form names.
    const username = screen.getByLabelText("Username") as HTMLInputElement;
    expect(username.value).toBe("owner");
    expect(username.getAttribute("autocomplete")).toBe("username");
    expect(username.getAttribute("name")).toBe("username");
    expect(username.readOnly).toBe(true);

    const password = screen.getByLabelText("Access token") as HTMLInputElement;
    expect(password.getAttribute("type")).toBe("password");
    expect(password.getAttribute("autocomplete")).toBe("current-password");
    expect(password.getAttribute("name")).toBe("password");

    // Without a username the browser stays silent and every session needs
    // manual entry, so the hint sets the expectation that a save offer
    // appears after signing in.
    expect(
      screen.getByText(/browser will offer to remember/i),
    ).toBeInTheDocument();
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
    expect(isSessionAuthenticated()).toBe(false);
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
