// Rune Weaver Dashboard — logged-out shell shown when no valid owner token is
// present.

import { useState, type FormEvent } from "react";
import { authenticateWithToken } from "../api";

interface LoginViewProps {
  // Called after a token is accepted and adopted so the parent can open the
  // authenticated shell without waiting for the auth subscription to fire.
  onAuthenticated?: () => void;
}

export default function LoginView({ onAuthenticated }: LoginViewProps) {
  const [token, setToken] = useState("");
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Fixed identity paired with the owner token so password managers recognize this as a saveable
  // sign-in.
  const username = "owner";

  const trimmed = token.trim();
  const canSubmit = trimmed.length > 0 && !checking;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canSubmit) return;
    setChecking(true);
    setError(null);
    // authenticateWithToken adopts the credential on success via the engine-set HttpOnly session
    // cookie, so the parent gate and the shared socket observe it through the same auth transition.
    const result = await authenticateWithToken(trimmed);
    setChecking(false);
    if (result === "ok") {
      // Drop the typed credential as soon as it is adopted so it does not linger
      // in the form after this view is replaced.
      setToken("");
      onAuthenticated?.();
      return;
    }
    // One honest line per failure class; a rejected token is never echoed, so a
    // guess cannot be confirmed by the response wording.
    if (result === "throttled") {
      setError("Too many attempts. Wait a moment and try again.");
    } else if (result === "unreachable") {
      setError("Could not reach the engine.");
    } else {
      setError("Invalid access token.");
    }
  }

  return (
    <div
      className="login-screen"
      style={{
        minHeight: "100vh",
        display: "grid",
        placeItems: "center",
        padding: "24px",
        boxSizing: "border-box",
      }}
    >
      <main
        aria-label="Sign in"
        style={{
          width: "min(360px, 90vw)",
          padding: "32px",
          borderRadius: "14px",
          background: "var(--bg-card, #181c26)",
          boxShadow: "0 18px 50px rgba(0, 0, 0, 0.45)",
        }}
      >
        <h1 style={{ margin: "0 0 4px", fontSize: "20px" }}>Rune Weaver</h1>
        <p
          style={{
            margin: "0 0 20px",
            color: "var(--text-secondary, #98a0b3)",
          }}
        >
          Enter your owner access token to continue.
        </p>
        <form onSubmit={handleSubmit} method="post">
          <label
            htmlFor="owner-username"
            style={{
              display: "block",
              marginBottom: "6px",
              fontSize: "13px",
              color: "var(--text-secondary, #b7bdcb)",
            }}
          >
            Username
          </label>
          <input
            id="owner-username"
            name="username"
            type="text"
            autoComplete="username"
            className="input-field"
            value={username}
            readOnly
            style={{
              width: "100%",
              boxSizing: "border-box",
              marginBottom: "12px",
            }}
          />
          <label
            htmlFor="owner-password"
            style={{
              display: "block",
              marginBottom: "6px",
              fontSize: "13px",
              color: "var(--text-secondary, #b7bdcb)",
            }}
          >
            Access token
          </label>
          <input
            id="owner-password"
            name="password"
            type="password"
            autoComplete="current-password"
            className="input-field"
            value={token}
            onChange={(event) => setToken(event.target.value)}
            required
            disabled={checking}
            style={{ width: "100%", boxSizing: "border-box" }}
          />
          <button
            type="submit"
            className="primary"
            disabled={!canSubmit}
            style={{ marginTop: "14px", width: "100%" }}
          >
            {checking ? "Signing in…" : "Sign in"}
          </button>
        </form>
        <p
          style={{
            margin: "12px 0 0",
            fontSize: "12px",
            color: "var(--text-secondary, #98a0b3)",
          }}
        >
          Your browser will offer to remember this sign-in so you don&apos;t
          have to re-enter the token each time.
        </p>
        <p
          role="status"
          aria-live="polite"
          style={{
            margin: "14px 0 0",
            minHeight: "1.2em",
            fontSize: "13px",
            color: "#f0a35e",
          }}
        >
          {error}
        </p>
      </main>
    </div>
  );
}
