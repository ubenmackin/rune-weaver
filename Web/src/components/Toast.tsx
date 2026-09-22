// Rune Weaver Dashboard — Shared toast for transient success notices.
// Renders one auto-dismissing notice fixed to the bottom-right so success copy
// never blocks the form, with role=status for assistive technology. Errors stay
// as persistent banners; only success and notice flows use this surface.

import { useEffect } from "react";

// Auto-dismiss delay for transient notices, balancing readability against
// lingering chrome. Single-sourced so every toast agrees on timing.
export const TOAST_DISMISS_MS = 5000;

interface ToastProps {
  // Transient copy to display; null renders nothing so callers keep one
  // nullable state without a separate visibility flag.
  message: string | null;
  // Clears the notice when the timer fires or the user dismisses it.
  onDismiss?: () => void;
  // Override for tests or dense flows; defaults to the shared delay.
  durationMs?: number;
}

export default function Toast({ message, onDismiss, durationMs = TOAST_DISMISS_MS }: ToastProps) {
  // Auto-dismiss on a timer so the notice never needs a manual clear to leave.
  // The timer restarts when the copy changes, so a second save replaces the
  // first instead of stacking expirations.
  useEffect(() => {
    if (!message) return;
    if (!onDismiss) return;
    const timer = setTimeout(() => {
      onDismiss();
    }, durationMs);
    return () => clearTimeout(timer);
  }, [message, onDismiss, durationMs]);

  if (!message) return null;

  return (
    <div
      role="status"
      aria-live="polite"
      data-testid="toast"
      className="toast"
    >
      <span>{message}</span>
      {onDismiss ? (
        <button
          type="button"
          onClick={onDismiss}
          aria-label="Dismiss notification"
          className="toast-dismiss"
        >
          ✕
        </button>
      ) : null}
    </div>
  );
}
