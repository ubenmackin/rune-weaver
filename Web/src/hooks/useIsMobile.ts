// Rune Weaver Dashboard — Shared mobile viewport hook for the dashboard shell.

import { useEffect, useState } from "react";
import { MOBILE_BREAKPOINT_PX } from "../components/navigationConfig";

// Resolves a caller breakpoint fail-closed to the shared ceiling. Non-finite,
// zero, and negative inputs fall back instead of building a wasted
// `(max-width: NaNpx)` subscription that can never match.
function resolveBreakpoint(breakpoint: number): number {
  if (!Number.isFinite(breakpoint) || breakpoint <= 0) {
    return MOBILE_BREAKPOINT_PX;
  }
  return breakpoint;
}

// Synchronous viewport probe shared by the hook and by mount initializers (such as the chat sidebar
// default) so exactly one matchMedia string exists.
export function isMobileViewport(
  breakpoint: number = MOBILE_BREAKPOINT_PX,
): boolean {
  const resolved = resolveBreakpoint(breakpoint);
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return false;
  }
  try {
    return window.matchMedia(`(max-width: ${resolved}px)`).matches;
  } catch {
    // A throwing matchMedia implementation must never break mount; treat
    // the viewport as desktop and let the subscription below retry.
    return false;
  }
}

// Reports whether the viewport currently falls within the handheld range.
export function useIsMobile(breakpoint: number = MOBILE_BREAKPOINT_PX): boolean {
  // Validate once so NaN, Infinity, zero, and negatives all fail closed to
  // the shared ceiling instead of subscribing to an unmatchable query.
  const resolved = resolveBreakpoint(breakpoint);
  // Resolve the initial match synchronously on the client so the first paint
  // already reflects the viewport; server rendering and environments without
  // matchMedia fail closed to desktop (false) rather than guessing mobile.
  const [isMobile, setIsMobile] = useState<boolean>(() => {
    return isMobileViewport(resolved);
  });

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
      return;
    }
    let query: MediaQueryList;
    try {
      query = window.matchMedia(`(max-width: ${resolved}px)`);
    } catch {
      return;
    }
    // Reconcile once in case the viewport moved between the lazy initializer
    // and this subscription; without this a resize in that window would stick
    // until the next change event.
    setIsMobile(query.matches);
    // MediaQueryListEvent carries the new match state directly, avoiding a
    // second query read that could race a rapid resize sequence.
    const handleChange = (event: MediaQueryListEvent) => {
      setIsMobile(event.matches);
    };
    query.addEventListener("change", handleChange);
    return () => {
      query.removeEventListener("change", handleChange);
    };
  }, [resolved]);

  return isMobile;
}

export default useIsMobile;
