// Shared mobile viewport hook for the dashboard shell.
//
// The breakpoint truth lives in `components/navigationConfig.ts` alongside the
// tab contract so styles and components agree on which widths count as
// handheld. This module imports that single definition (never redefines it)
// and owns the viewport probe plus the live hook, letting owners render a
// fixed drawer on small screens and a static sidebar on wide screens without
// duplicating the media query string.

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

// Synchronous viewport probe shared by the hook and by mount initializers
// (such as the chat sidebar default) so exactly one matchMedia string exists.
// Returns false during server rendering where no viewport exists so hydration
// starts detached and reconciles on mount instead of throwing.
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
// The optional override exists for callers that need a different ceiling in
// tests or experiments; production callers omit it to stay on the shared
// breakpoint. Returns false during server rendering where no viewport exists
// so hydration starts detached and reconciles on mount instead of throwing.
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
    // Modern browsers expose addEventListener; older Safari exposes only the
    // legacy addListener pair, so support both without branching the cleanup.
    if (typeof query.addEventListener === "function") {
      query.addEventListener("change", handleChange);
      return () => {
        query.removeEventListener("change", handleChange);
      };
    }
    // Legacy fallback keeps the same listener identity for add/remove so the
    // cleanup below detaches exactly what was attached above.
    const legacyQuery = query as unknown as {
      addListener: (listener: (event: MediaQueryListEvent) => void) => void;
      removeListener: (listener: (event: MediaQueryListEvent) => void) => void;
    };
    if (typeof legacyQuery.addListener === "function") {
      legacyQuery.addListener(handleChange);
      return () => {
        legacyQuery.removeListener(handleChange);
      };
    }
    return;
  }, [resolved]);

  return isMobile;
}

export default useIsMobile;
