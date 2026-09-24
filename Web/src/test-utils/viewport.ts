// Rune Weaver Dashboard — Shared viewport test helper for Vitest suites.
//
// Single source for the width-driven matchMedia double so handheld and desktop
// suites agree on the shared mobile breakpoint without duplicating the query
// parser. Widths at or below the navigation contract ceiling report handheld
// while wider viewports stay on the desktop branch.
import { vi } from "vitest";
import { MOBILE_BREAKPOINT_PX } from "../components/navigationConfig";

export function installViewport(widthPx: number): void {
  const stub = (query: string) => {
    const ceiling = Number(
      /max-width:\s*(\d+)px/.exec(query)?.[1] ?? String(MOBILE_BREAKPOINT_PX),
    );
    const matches = widthPx <= (Number.isFinite(ceiling) ? ceiling : MOBILE_BREAKPOINT_PX);
    return {
      matches,
      media: query,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
    };
  };
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    configurable: true,
    value: stub,
  });
}
