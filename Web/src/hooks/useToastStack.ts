// Rune Weaver Dashboard — Shared transient toast stack for action feedback.
// Distinct notices stack with independent timers; an identical copy replaces
// its sibling so repeat saves refresh one notice instead of duplicating.

import { useCallback, useRef, useState } from "react";
import type { ToastStackItem } from "../components/Toast";

// Shared toast stack with the agreed identical-copy dedupe policy. Repeat
// pushes of the same message + variant replace the sibling notice; distinct
// messages still stack with independent timers.
export function useToastStack() {
  const [toasts, setToasts] = useState<ToastStackItem[]>([]);
  const toastIdRef = useRef(0);

  // Single cap/dedupe path so success and error pushes cannot drift:
  // replacing any identical copy already in the stack keeps repeat saves to
  // a single refreshed notice, while distinct messages still stack with
  // independent timers. Caps the stack at the last 5 notices so distinct
  // messages cannot grow without bound and cover the UI. Stable so each
  // per-toast auto-dismiss timer never restarts on unrelated renders.
  const pushToast = useCallback((message: string, variant: "success" | "error", durationMs?: number) => {
    if (typeof message !== "string") return;
    // Trimmed-identity hardening: compare and store the trimmed copy so
    // padded duplicates cannot bypass identical-copy dedupe, and blank
    // messages never render an empty bubble.
    const trimmed = message.trim();
    if (trimmed.length === 0) return;
    toastIdRef.current += 1;
    const id = toastIdRef.current;
    setToasts((prev) => [
      // Cap the stack at the last 5 notices so distinct messages cannot grow
      // without bound and cover the UI.
      ...prev
        .filter(
          (toast) => !(toast.message === trimmed && (toast.variant ?? "success") === variant)
        )
        .slice(-4),
      { id, message: trimmed, variant, durationMs },
    ]);
  }, []);

  // Appends one transient success notice, replacing any identical copy
  // already in the stack so repeat saves refresh a single notice instead of
  // stacking duplicates. Distinct messages still stack with independent
  // timers. Stable so each per-toast auto-dismiss timer never restarts on
  // unrelated renders.
  const pushSuccessToast = useCallback(
    (message: string, durationMs?: number) => {
      pushToast(message, "success", durationMs);
    },
    [pushToast]
  );

  // Appends one transient error notice, replacing any identical copy already
  // in the stack; mirrors pushSuccessToast.
  const pushErrorToast = useCallback(
    (message: string, durationMs?: number) => {
      pushToast(message, "error", durationMs);
    },
    [pushToast]
  );

  // Dismisses one stacked toast without touching its siblings. Stable so the
  // toast auto-dismiss timer never restarts on unrelated renders.
  const dismissToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((toast) => toast.id !== id));
  }, []);

  // Clears the whole stack, e.g. so a save notice never follows navigation.
  const clearToasts = useCallback(() => {
    setToasts([]);
  }, []);

  return { toasts, pushSuccessToast, pushErrorToast, dismissToast, clearToasts };
}
