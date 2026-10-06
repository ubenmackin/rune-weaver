// Rune Weaver Dashboard — Shared secret-value modal for Keychain writes.
//
// Single owner for the store/update secret form so Providers, Media, and
// Email flows share one password input, one focus path, and one submit path.
// Secret bytes stay in local state only and clear on open, close, and success.

import { useEffect, useRef, useState, type FormEvent } from "react";
import { ApiError, storeSecret } from "../api";
import Modal from "./Modal";
import { CloseIcon, EyeIcon, EyeOffIcon, KeyIcon } from "./icons";

export interface StoreSecretModalProps {
  isOpen: boolean;
  secretKey: string;
  title: string;
  isUpdate: boolean;
  onClose: () => void;
  onSuccess: (key: string) => void;
}

// Trims then strips exactly one leading surrogate prefix when present, so a
// pasted `rwsecret:MY_KEY` stores as `MY_KEY` while `MY_KEY` passes through.
// Only one prefix strips, so `rwsecret:rwsecret:KEY` keeps the inner prefix.
export function normalizeSecretKey(raw: string | null | undefined): string {
  const trimmed = (raw ?? "").trim();
  const prefix = "rwsecret:";
  if (trimmed.startsWith(prefix)) {
    return trimmed.slice(prefix.length);
  }
  return trimmed;
}

export function StoreSecretModal({
  isOpen,
  secretKey,
  title,
  isUpdate,
  onClose,
  onSuccess,
}: StoreSecretModalProps) {
  const [secretValue, setSecretValue] = useState("");
  const [showPlaintext, setShowPlaintext] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isOpen) {
      setSecretValue("");
      setShowPlaintext(false);
      setError(null);
      const timer = setTimeout(() => inputRef.current?.focus(), 50);
      return () => clearTimeout(timer);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const handleClose = () => {
    if (submitting) return;
    setSecretValue("");
    onClose();
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    const normalizedKey = normalizeSecretKey(secretKey);
    if (normalizedKey.length === 0 || secretValue.trim().length === 0) {
      setError("Please enter a secret value.");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      await storeSecret(normalizedKey, secretValue);
      setSecretValue("");
      onSuccess(normalizedKey);
      onClose();
    } catch (err: unknown) {
      if (err instanceof ApiError && err.status === 413) {
        setError("Secret exceeds 16384 bytes.");
      } else {
        setError(err instanceof Error ? err.message : "Failed to store secret in Keychain.");
      }
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal label={title} onClose={submitting ? () => {} : handleClose} containerClassName="modal-container store-secret-modal" testId="store-secret-modal">
      <form onSubmit={handleSubmit}>
        <div className="modal-header">
          <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
            <KeyIcon size={18} style={{ color: "#38bdf8" }} />
            <h3>{title}</h3>
          </div>
          <button
            type="button"
            className="icon-button"
            onClick={handleClose}
            disabled={submitting}
            aria-label="Close"
          >
            <CloseIcon size={16} />
          </button>
        </div>

        <div className="modal-body" style={{ display: "flex", flexDirection: "column", gap: "16px" }}>
          <p style={{ margin: 0, fontSize: "13px", color: "var(--text-muted)", lineHeight: 1.5 }}>
            This secret will be stored directly into your macOS Keychain under service <code>com.runeweaver.secrets</code>. It is never written to disk files, database, or browser storage.
          </p>

          <div className="form-group">
            <label style={{ fontSize: "12px", color: "var(--text-muted)", marginBottom: "4px", display: "block" }}>
              Keychain Key / Account
            </label>
            <div style={{ padding: "8px 12px", background: "var(--bg-main, #0f0f13)", borderRadius: "6px", fontFamily: "monospace", fontSize: "13px", border: "1px solid var(--border-color, #272733)" }}>
              {secretKey}
            </div>
          </div>

          <div className="form-group">
            <label htmlFor="secret-value-input" style={{ fontSize: "12px", fontWeight: 600, marginBottom: "4px", display: "block" }}>
              {isUpdate ? "New Secret / Password" : "Secret / Password"}
            </label>
            <div style={{ display: "flex", gap: "8px", position: "relative", alignItems: "center" }}>
              <input
                ref={inputRef}
                id="secret-value-input"
                data-testid="secret-value-input"
                type={showPlaintext ? "text" : "password"}
                className="input-field"
                value={secretValue}
                onChange={(e) => setSecretValue(e.target.value)}
                placeholder="Enter secret..."
                disabled={submitting}
                required
                style={{ flex: 1, paddingRight: "40px" }}
              />
              <button
                type="button"
                className="icon-button"
                data-testid="store-secret-toggle"
                onClick={() => setShowPlaintext((prev) => !prev)}
                title={showPlaintext ? "Hide secret" : "Show secret"}
                style={{ position: "absolute", right: "6px", background: "transparent", border: "none" }}
              >
                {showPlaintext ? <EyeOffIcon size={16} /> : <EyeIcon size={16} />}
              </button>
            </div>
          </div>

          {error && (
            <div
              data-testid="store-secret-error"
              role="alert"
              style={{
                padding: "8px 12px",
                background: "rgba(239, 68, 68, 0.12)",
                border: "1px solid rgba(239, 68, 68, 0.35)",
                borderRadius: "6px",
                color: "#ef4444",
                fontSize: "13px",
              }}
            >
              {error}
            </div>
          )}
        </div>

        <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}>
          <button
            type="button"
            className="ghost"
            data-testid="store-secret-cancel"
            onClick={handleClose}
            disabled={submitting}
          >
            Cancel
          </button>
          <button
            type="submit"
            className="primary"
            data-testid="store-secret-submit"
            disabled={submitting || secretValue.trim().length === 0}
          >
            {submitting ? "Saving…" : isUpdate ? "Update in Keychain" : "Save to Keychain"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

export default StoreSecretModal;
