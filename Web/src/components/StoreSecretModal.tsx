// Rune Weaver Dashboard — Shared secret-value modal for Keychain writes.

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
          <div className="store-secret-header-row">
            <KeyIcon size={18} className="store-secret-icon" />
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

        <div className="modal-body store-secret-body">
          <p className="store-secret-lead text-sm">
            This secret will be stored directly into your macOS Keychain under service <code>com.runeweaver.secrets</code>. It is never written to disk files, database, or browser storage.
          </p>

          <div className="form-group">
            <label className="store-secret-label">Keychain Key / Account</label>
            <div className="store-secret-key-box text-sm">{secretKey}</div>
          </div>

          <div className="form-group">
            <label htmlFor="secret-value-input" className="store-secret-label-strong">
              {isUpdate ? "New Secret / Password" : "Secret / Password"}
            </label>
            <div className="store-secret-input-row">
              <input
                ref={inputRef}
                id="secret-value-input"
                data-testid="secret-value-input"
                type={showPlaintext ? "text" : "password"}
                className="input-field store-secret-value-input"
                value={secretValue}
                onChange={(e) => setSecretValue(e.target.value)}
                placeholder="Enter secret..."
                disabled={submitting}
                required
              />
              <button
                type="button"
                className="icon-button store-secret-toggle"
                data-testid="store-secret-toggle"
                onClick={() => setShowPlaintext((prev) => !prev)}
                title={showPlaintext ? "Hide secret" : "Show secret"}
              >
                {showPlaintext ? <EyeOffIcon size={16} /> : <EyeIcon size={16} />}
              </button>
            </div>
          </div>

          {error && (
            <div data-testid="store-secret-error" role="alert" className="store-secret-error text-sm">
              {error}
            </div>
          )}
        </div>

        <div className="modal-footer store-secret-footer">
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
