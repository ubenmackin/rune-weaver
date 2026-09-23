// Rune Weaver Dashboard — Shared toast for transient notices.
// Renders auto-dismissing notices in a top-right stack so action feedback
// never blocks the form, with role=status for confirmations and role=alert
// for errors so assistive technology announces failures promptly. Supports
// success (green) and error (red) variants so both confirmation and failure
// messages share the same surface instead of persistent inline banners.

import { useEffect, useRef } from "react";

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
  // Visual variant: "success" (green, default) or "error" (red/orange).
  variant?: "success" | "error";
}

// Stacked toast entry with a stable key so each notice owns an independent
// timer and successive saves offset with a gap instead of overwriting.
export interface ToastStackItem {
  // Stable key distinguishing stacked notices from the same variant.
  id: number;
  // Transient copy to display.
  message: string;
  // Visual variant: "success" (green, default) or "error" (red/orange).
  variant?: "success" | "error";
  // Override for tests or dense flows; defaults to the shared delay.
  durationMs?: number;
}

interface ToastStackProps {
  // Queued notices to render; empty renders nothing.
  toasts: ToastStackItem[];
  // Dismisses one stacked notice by id without touching its siblings.
  onDismiss: (id: number) => void;
}

// Stack-only surface: the fixed `.toast-stack` container owns the top-right
// anchoring while each `.toast` lays out in normal flow with its own timer,
// so N notices offset with a gap instead of painting at identical coordinates.
export function ToastStack({ toasts, onDismiss }: ToastStackProps) {
  if (toasts.length === 0) return null;
  return (
    <div className="toast-stack">
      {toasts.map((toast) => (
        <Toast
          key={toast.id}
          message={toast.message}
          variant={toast.variant}
          durationMs={toast.durationMs}
          onDismiss={() => onDismiss(toast.id)}
        />
      ))}
    </div>
  );
}

export default function Toast({ message, onDismiss, durationMs = TOAST_DISMISS_MS, variant = "success" }: ToastProps) {
  // Auto-dismiss on a timer so the notice never needs a manual clear to leave.
  // Each stacked toast owns its timer through the stack list, so notices
  // dismiss independently instead of sharing one expiration.
  // Finite-elapsed guard: normalize arbitrary durations to a positive
  // integer, falling back to the shared delay so NaN/Infinity/non-positive never
  // renders an immediate or sticky dismissal.
  const safeDurationMs =
    typeof durationMs === "number" &&
    Number.isFinite(durationMs) &&
    Number.isInteger(durationMs) &&
    durationMs > 0
      ? durationMs
      : TOAST_DISMISS_MS;
  const onDismissRef = useRef(onDismiss);
  // Keep refs behind effects so render stays pure; the timer below always
  // reads the latest callback without mutating during render.
  useEffect(() => {
    onDismissRef.current = onDismiss;
  }, [onDismiss]);
  useEffect(() => {
    if (!message) return;
    if (!onDismissRef.current) return;
    const timer = setTimeout(() => {
      onDismissRef.current?.();
    }, safeDurationMs);
    return () => clearTimeout(timer);
  }, [message, safeDurationMs]);

  if (!message) return null;

  const className = variant === "error" ? "toast toast-error" : "toast";

  return (
    <div
      role={variant === "error" ? "alert" : "status"}
      aria-live={variant === "error" ? "assertive" : "polite"}
      data-testid={variant === "error" ? "toast-error" : "toast"}
      className={className}
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
