// Rune Weaver Dashboard — Shared mobile breakpoint hook matrix for the dashboard shell.

import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { isMobileViewport, useIsMobile } from "./useIsMobile";
import { MOBILE_BREAKPOINT_PX } from "../components/navigationConfig";

// Minimal MediaQueryList double capturing the change subscriber so tests can
// drive viewport transitions without a layout engine. Modern and legacy
// subscribe paths share one listener slot to mirror the production branching.
interface MockQuery {
  matches: boolean;
  media: string;
  addEventListener: ReturnType<typeof vi.fn>;
  removeEventListener: ReturnType<typeof vi.fn>;
  addListener: ReturnType<typeof vi.fn>;
  removeListener: ReturnType<typeof vi.fn>;
  fire: (matches: boolean) => void;
}

function installMatchMedia(
  matches: boolean,
  options: { legacyOnly?: boolean; queries?: string[] } = {},
): { query: MockQuery; queries: string[] } {
  const queries: string[] = options.queries ?? [];
  let listener: ((event: { matches: boolean }) => void) | null = null;
  const fire = (next: boolean) => {
    query.matches = next;
    if (listener) {
      listener({ matches: next });
    }
  };
  const query = {
    matches,
    media: "",
    addEventListener: vi.fn((_event: string, cb: (e: { matches: boolean }) => void) => {
      listener = cb;
    }),
    removeEventListener: vi.fn(() => {
      listener = null;
    }),
    addListener: vi.fn((cb: (e: { matches: boolean }) => void) => {
      listener = cb;
    }),
    removeListener: vi.fn(() => {
      listener = null;
    }),
    fire,
  } as unknown as MockQuery;
  // Legacy-only doubles expose no modern subscribe pair so the hook must fall
  // back to addListener without branching the cleanup identity.
  if (options.legacyOnly) {
    (query as unknown as Record<string, unknown>).addEventListener = undefined;
    (query as unknown as Record<string, unknown>).removeEventListener = undefined;
  }
  const stub = vi.fn((mediaQuery: string) => {
    queries.push(mediaQuery);
    query.media = mediaQuery;
    return query;
  });
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    configurable: true,
    value: stub,
  });
  return { query, queries };
}

// Width-driven double implementing the shared contract: viewports at or below
// the ceiling match the handheld query while wider viewports do not. Pins the
// 375px phone and 1024px desktop matrix points plus the exact boundary.
function installViewport(widthPx: number): { queries: string[] } {
  const queries: string[] = [];
  const listeners = new Set<(event: { matches: boolean }) => void>();
  const stub = (mediaQuery: string) => {
    queries.push(mediaQuery);
    const ceiling = Number(
      (/max-width:\s*(\d+)px/.exec(mediaQuery)?.[1] ?? MOBILE_BREAKPOINT_PX) as unknown as string,
    );
    const matches = widthPx <= (Number.isFinite(ceiling) ? ceiling : MOBILE_BREAKPOINT_PX);
    return {
      matches,
      media: mediaQuery,
      addEventListener: vi.fn((_event: string, cb: (e: { matches: boolean }) => void) => {
        listeners.add(cb);
      }),
      removeEventListener: vi.fn((_event: string, cb: (e: { matches: boolean }) => void) => {
        listeners.delete(cb);
      }),
      addListener: vi.fn((cb: (e: { matches: boolean }) => void) => {
        listeners.add(cb);
      }),
      removeListener: vi.fn((cb: (e: { matches: boolean }) => void) => {
        listeners.delete(cb);
      }),
    };
  };
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    configurable: true,
    value: stub,
  });
  return { queries };
}

describe("useIsMobile breakpoint contract", () => {
  let originalMatchMedia: typeof window.matchMedia | undefined;

  beforeEach(() => {
    originalMatchMedia = (window as unknown as { matchMedia?: typeof window.matchMedia })
      .matchMedia;
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    if (originalMatchMedia === undefined) {
      Reflect.deleteProperty(window as unknown as Record<string, unknown>, "matchMedia");
    } else {
      Object.defineProperty(window, "matchMedia", {
        writable: true,
        configurable: true,
        value: originalMatchMedia,
      });
    }
  });

  it("pins the single 640px ceiling from the navigation contract", () => {
    // Single source of truth lives in navigationConfig.ts; the hook imports
    // it instead of redefining so styles, drawer, top nav, and bottom bar
    // cannot drift on duplicated literals.
    expect(MOBILE_BREAKPOINT_PX).toBe(640);
  });

  it("queries the handheld max-width media string by default", () => {
    const { queries } = installMatchMedia(false);
    const { unmount } = renderHook(() => useIsMobile());
    expect(queries).toContain("(max-width: 640px)");
    unmount();
  });

  it("reports handheld for a 375px phone viewport", () => {
    installViewport(375);
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(true);
  });

  it("reports desktop for a 1024px wide viewport", () => {
    installViewport(1024);
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(false);
  });

  it("treats exactly 640px as mobile and 641px as desktop", () => {
    installViewport(640);
    const mobile = renderHook(() => useIsMobile());
    expect(mobile.result.current).toBe(true);
    mobile.unmount();

    installViewport(641);
    const desktop = renderHook(() => useIsMobile());
    expect(desktop.result.current).toBe(false);
    desktop.unmount();
  });

  it("fails closed to desktop when no viewport implementation exists", () => {
    // Server rendering and bare jsdom expose no matchMedia: hydration must
    // start detached as desktop rather than guessing mobile and flashing.
    Reflect.deleteProperty(window as unknown as Record<string, unknown>, "matchMedia");
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(false);
  });

  it("fails closed to desktop when matchMedia throws", () => {
    Object.defineProperty(window, "matchMedia", {
      writable: true,
      configurable: true,
      value: () => {
        throw new Error("no viewport");
      },
    });
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(false);
  });

  it("syncs when the viewport crosses the breakpoint", () => {
    const { query } = installMatchMedia(false);
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(false);
    act(() => {
      query.fire(true);
    });
    expect(result.current).toBe(true);
    act(() => {
      query.fire(false);
    });
    expect(result.current).toBe(false);
  });

  it("detaches the change listener on unmount", () => {
    const { query } = installMatchMedia(true);
    const { unmount } = renderHook(() => useIsMobile());
    expect(query.addEventListener).toHaveBeenCalledWith("change", expect.any(Function));
    unmount();
    expect(query.removeEventListener).toHaveBeenCalledTimes(1);
  });

  it("supports the legacy addListener pair where modern events are absent", () => {
    const { query } = installMatchMedia(false, { legacyOnly: true });
    const { result, unmount } = renderHook(() => useIsMobile());
    expect(query.addListener).toHaveBeenCalledTimes(1);
    act(() => {
      query.fire(true);
    });
    expect(result.current).toBe(true);
    unmount();
    expect(query.removeListener).toHaveBeenCalledTimes(1);
  });

  it("honors an explicit breakpoint override for experiments", () => {
    const { queries } = installMatchMedia(true);
    const { result } = renderHook(() => useIsMobile(500));
    expect(queries).toContain("(max-width: 500px)");
    expect(result.current).toBe(true);
  });

  it("fails closed to the shared ceiling for non-finite and non-positive breakpoints", () => {
    // NaN, Infinity, zero, and negatives never build an unmatchable query;
    // they fall back to the single shared ceiling instead.
    for (const invalid of [Number.NaN, Number.POSITIVE_INFINITY, 0, -100]) {
      const { queries } = installMatchMedia(true);
      const { result, unmount } = renderHook(() => useIsMobile(invalid));
      expect(queries).toContain("(max-width: 640px)");
      expect(result.current).toBe(true);
      unmount();
    }
  });

  it("exposes the shared synchronous viewport probe for mount initializers", () => {
    installViewport(375);
    expect(isMobileViewport()).toBe(true);
    installViewport(1024);
    expect(isMobileViewport()).toBe(false);
  });

  it("fails the shared probe closed for invalid breakpoints", () => {
    const { queries } = installMatchMedia(true);
    expect(isMobileViewport(Number.NaN)).toBe(true);
    expect(queries).toContain("(max-width: 640px)");
  });
});
