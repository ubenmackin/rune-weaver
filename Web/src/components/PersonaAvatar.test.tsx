// Rune Weaver Dashboard — Tests for the persona avatar module: the pure
// avatar-state priority, the idle→sleeping wake timer that feeds it, the
// fail-closed image rendering contract, the idle blink's visibility pause,
// the transform-only float motion with its reduced-motion gate, and the
// generated bundle assets.
//
// The priority matrix is the behavioral core of the persona layer, so the
// attention > working > sleeping > idle ordering and the 10-minute sleeping
// boundary are pinned here without timers or fetches, and the wake-timer suite
// pins that the deadline timer lands on the boundary and never hands
// `setTimeout` an epoch-scale duration when two clock sources disagree. The
// component suite pins the two fallback promises (unknown server keys and a
// load failure must never produce a broken image), and the asset suite pins
// that the bundle the dashboard's srcSet points at actually exists per
// colorway-state pair. The motion suite pins that avatar movement is
// transform-only float gated behind `prefers-reduced-motion: no-preference`
// with a static fallback, so reduced-motion owners always see still frames.

import { act, fireEvent, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AVATAR_SLEEP_MS,
  BLINK_CLOSED_MS,
  BLINK_INTERVAL_MS,
  PersonaAvatar,
  personaAvatarFramePath,
  publishAgentActivity,
  resetPersonaSignalsForTesting,
  resolveAvatarState,
  useResolvedAvatarState,
} from "./PersonaAvatar";
import { PERSONA_AVATAR_COLORS } from "../api";

// The web suite carries no @types/node (the production bundle must never gain
// a Node dependency), so the Node globals the test-only probes reach for are
// declared locally, mirroring the `process` shim in vite.config.ts.
declare const process: { cwd: () => string };

const NOW = 1_700_000_000_000;

describe("resolveAvatarState priority", () => {
  it("pins the sleep threshold at the documented 10 minutes", () => {
    // The constant is a deliberate contract, not configuration: renaming or
    // retuning it must fail here so every surface keeps one threshold.
    expect(AVATAR_SLEEP_MS).toBe(10 * 60 * 1000);
  });

  it("lets attention outrank working and a freshly active clock", () => {
    expect(
      resolveAvatarState({
        hasAttention: true,
        isWorking: true,
        lastActivityAtMs: NOW - 1000,
        nowMs: NOW,
      }),
    ).toBe("attention");
    expect(
      resolveAvatarState({ hasAttention: true, nowMs: NOW }),
    ).toBe("attention");
  });

  it("lets working outrank an expired idle clock", () => {
    expect(
      resolveAvatarState({
        isWorking: true,
        lastActivityAtMs: NOW - AVATAR_SLEEP_MS * 2,
        nowMs: NOW,
      }),
    ).toBe("working");
  });

  it("sleeps at exactly the 10-minute boundary and stays idle a millisecond short", () => {
    expect(
      resolveAvatarState({
        lastActivityAtMs: NOW - AVATAR_SLEEP_MS,
        nowMs: NOW,
      }),
    ).toBe("sleeping");
    expect(
      resolveAvatarState({
        lastActivityAtMs: NOW - AVATAR_SLEEP_MS + 1,
        nowMs: NOW,
      }),
    ).toBe("idle");
  });

  it("treats a never-observed clock and drifted numbers as idle, never sleeping", () => {
    // A fresh dashboard has no elapsed-time basis for a sleep claim, and a
    // garbage timestamp must not render a sleeping Wisp forever.
    expect(resolveAvatarState({ lastActivityAtMs: 0, nowMs: NOW })).toBe("idle");
    expect(resolveAvatarState({ lastActivityAtMs: null, nowMs: NOW })).toBe("idle");
    expect(
      resolveAvatarState({ lastActivityAtMs: Number.NaN, nowMs: NOW }),
    ).toBe("idle");
    expect(
      resolveAvatarState({ lastActivityAtMs: NOW - AVATAR_SLEEP_MS * 2, nowMs: Number.NaN }),
    ).toBe("idle");
  });

  it("defaults idle when no signals are supplied at all", () => {
    expect(resolveAvatarState({})).toBe("idle");
  });
});

describe("PersonaAvatar rendering", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("maps a known colorway and state to the 64px frame with a 32/64/256 srcSet", () => {
    const { container } = render(<PersonaAvatar color="emerald" state="working" size={32} />);
    const img = container.querySelector("img.persona-avatar");
    expect(img).not.toBeNull();
    expect(img?.getAttribute("src")).toBe(personaAvatarFramePath("emerald", "working", 64));
    const srcSet = img?.getAttribute("srcSet") ?? "";
    expect(srcSet).toContain(personaAvatarFramePath("emerald", "working", 32));
    expect(srcSet).toContain(personaAvatarFramePath("emerald", "working", 256));
    expect(img?.getAttribute("width")).toBe("32");
    expect(img?.className).toContain("persona-avatar--working");
  });

  it("falls back to the violet colorway on an unknown accent key", () => {
    // Server data is never trusted to name a file: a drifted accent degrades
    // to the master colorway instead of pointing at a PNG that does not exist.
    const { container } = render(<PersonaAvatar color="chartreuse" state="idle" />);
    expect(
      container.querySelector("img")?.getAttribute("src"),
    ).toBe(personaAvatarFramePath("violet", "idle", 64));
  });

  it("falls back to the idle frame on an unknown state key", () => {
    const { container } = render(<PersonaAvatar color="cyan" state="drowsy" />);
    expect(
      container.querySelector("img")?.getAttribute("src"),
    ).toBe(personaAvatarFramePath("cyan", "idle", 64));
  });

  it("swaps to the brand glyph when the image cannot load", () => {
    // The last line of the no-broken-image promise: a missing asset on disk
    // surfaces the violet-family rune mark instead of a browser tear.
    const { container } = render(<PersonaAvatar color="rose" state="attention" />);
    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    fireEvent.error(img as HTMLImageElement);
    expect(container.querySelector("img")).toBeNull();
    expect(container.querySelector(".persona-avatar-fallback")).not.toBeNull();
  });

  it("blinks with a CSS lid over the idle frame, never the sleeping asset", () => {
    // A blink is closed eyes without the sleeping frame's Z marks or dimmed
    // core, so the src must stay on the idle frame and the lid overlay must
    // supply the closed-eyes read for exactly the closed window.
    vi.useFakeTimers();
    const { container } = render(<PersonaAvatar color="violet" state="idle" />);
    const img = () =>
      container.querySelector("img") as HTMLImageElement | null;
    const frame = () => img()?.getAttribute("src") ?? "";
    expect(frame()).toContain("-idle-64");
    act(() => {
      vi.advanceTimersByTime(BLINK_INTERVAL_MS);
    });
    expect(frame()).toContain("-idle-64");
    expect(frame()).not.toContain("-sleeping-");
    expect(img()?.getAttribute("srcSet") ?? "").not.toContain("-sleeping-");
    expect(img()?.className).toContain("persona-avatar--idle");
    expect(img()?.className).toContain("persona-avatar--blinking");
    expect(img()?.className).not.toContain("persona-avatar--sleeping");
    expect(
      container.querySelector(".persona-avatar-blink-lid"),
    ).not.toBeNull();
    act(() => {
      vi.advanceTimersByTime(BLINK_CLOSED_MS);
    });
    expect(frame()).toContain("-idle-64");
    expect(container.querySelector(".persona-avatar-blink-lid")).toBeNull();
  });

  it("never emits a sleeping src or sleeping class while blinking", () => {
    // Regression: the blink's closed phase must not masquerade as the sleeping
    // state in the DOM — no `wisp-*-sleeping-*` src/srcSet and no
    // `persona-avatar--sleeping` class on any tick of the blink cycle — while
    // genuine sleeping (resolved after ten silent minutes) still renders the
    // sleeping frame untouched.
    vi.useFakeTimers();
    const { container } = render(<PersonaAvatar color="violet" state="idle" />);
    const img = () =>
      container.querySelector("img") as HTMLImageElement | null;
    for (let cycle = 0; cycle < 3; cycle += 1) {
      act(() => {
        vi.advanceTimersByTime(BLINK_INTERVAL_MS);
      });
      expect(img()?.getAttribute("src") ?? "").not.toContain("-sleeping-");
      expect(img()?.getAttribute("srcSet") ?? "").not.toContain("-sleeping-");
      expect(img()?.className ?? "").not.toContain("persona-avatar--sleeping");
      expect(img()?.getAttribute("src") ?? "").toContain("-idle-64");
      act(() => {
        vi.advanceTimersByTime(BLINK_CLOSED_MS);
      });
      expect(img()?.getAttribute("src") ?? "").not.toContain("-sleeping-");
      expect(img()?.getAttribute("srcSet") ?? "").not.toContain("-sleeping-");
      expect(img()?.className ?? "").not.toContain("persona-avatar--sleeping");
    }
    // The control still holds: a truly sleeping Wisp renders the sleeping
    // frame and class, proving the assertions above pin the blink rather than
    // the absence of the asset.
    const { container: sleeping } = render(
      <PersonaAvatar color="violet" state="sleeping" blink={false} />,
    );
    const sleepingImg = sleeping.querySelector(
      "img",
    ) as HTMLImageElement | null;
    expect(sleepingImg?.getAttribute("src") ?? "").toContain("-sleeping-64");
    expect(sleepingImg?.className ?? "").toContain("persona-avatar--sleeping");
  });

  it("pauses the blink timer while the tab is hidden and resumes on return", () => {
    // A background tab must not keep swapping frames: nobody is watching, and
    // an unpaused interval turns a cosmetic blink into timer traffic.
    vi.useFakeTimers();
    let hidden = true;
    const descriptor = Object.getOwnPropertyDescriptor(document, "hidden");
    Object.defineProperty(document, "hidden", {
      configurable: true,
      get: () => hidden,
    });
    try {
      const { container } = render(<PersonaAvatar color="violet" state="idle" />);
      const frame = () =>
        (container.querySelector("img") as HTMLImageElement | null)?.getAttribute("src") ?? "";
      act(() => {
        vi.advanceTimersByTime(BLINK_INTERVAL_MS * 3);
      });
      expect(frame()).toContain("-idle-64");
      hidden = false;
      act(() => {
        document.dispatchEvent(new Event("visibilitychange"));
        vi.advanceTimersByTime(BLINK_INTERVAL_MS);
      });
      // The resumed blink lands on the idle frame under a CSS lid, never on
      // the sleeping asset: visibility only pauses the cadence, it must not
      // change which frame a blink renders.
      expect(frame()).toContain("-idle-64");
      expect(frame()).not.toContain("-sleeping-");
      expect(
        (container.querySelector("img") as HTMLImageElement).className,
      ).not.toContain("persona-avatar--sleeping");
      expect(
        container.querySelector(".persona-avatar-blink-lid"),
      ).not.toBeNull();
    } finally {
      if (descriptor) {
        Object.defineProperty(document, "hidden", descriptor);
      } else {
        delete (document as { hidden?: unknown }).hidden;
      }
    }
  });

  it("never blinks in non-idle states, keeping attention static", () => {
    vi.useFakeTimers();
    const { container } = render(<PersonaAvatar color="violet" state="attention" />);
    act(() => {
      vi.advanceTimersByTime(BLINK_INTERVAL_MS * 2);
    });
    expect(
      (container.querySelector("img") as HTMLImageElement).getAttribute("src"),
    ).toContain("-attention-64");
  });

  it("keeps the four colorway keys the picker and store speak", () => {
    // The closed set is one contract shared by the pane, the sprite path, and
    // this module's fallback logic; a fifth colorway must land on every frame.
    expect([...PERSONA_AVATAR_COLORS]).toEqual(["violet", "cyan", "emerald", "rose"]);
  });
});

// Renders the store-resolved state through the shared signals so the
// sleep-wake deadline timer inside `useResolvedAvatarState` is exercised
// end-to-end. `blink={false}` keeps the idle blink lid out of the same fake
// clock, so the landing assertion reads the resolved sleeping frame without a
// concurrent blink overlay in the tree.
function PersonaSignalsProbe() {
  const state = useResolvedAvatarState();
  return <PersonaAvatar color="violet" state={state} blink={false} dataTestId="signals-probe" />;
}

describe("useResolvedAvatarState sleep-wake timer", () => {
  beforeEach(() => {
    // The signals store is a module singleton; each timer test starts from a
    // detached snapshot so the published clock is the only activity value.
    resetPersonaSignalsForTesting();
  });
  afterEach(() => {
    resetPersonaSignalsForTesting();
    vi.useRealTimers();
  });

  it("lands idle to sleeping exactly when the 10-minute deadline passes", () => {
    // The documented landing driven through the timer rather than the pure
    // priority: one wake on the deadline edge, no polling in between.
    vi.useFakeTimers({ now: NOW });
    publishAgentActivity(NOW);
    const { container } = render(<PersonaSignalsProbe />);
    const frame = () =>
      (container.querySelector("img") as HTMLImageElement | null)?.getAttribute("src") ?? "";
    expect(frame()).toContain("-idle-64");
    act(() => {
      vi.advanceTimersByTime(AVATAR_SLEEP_MS - 1);
    });
    expect(frame()).toContain("-idle-64");
    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(frame()).toContain("-sleeping-64");
  });

  it("never hands the wake timer an epoch-scale duration when the clocks diverge", () => {
    // Regression for the TimeoutOverflowWarning: a clock parked at the epoch
    // beside a store value written by a real `Date.now()` made the raw
    // remaining time an absolute timestamp, and past setTimeout's 32-bit
    // ceiling Node warns and fires after 1 ms instead of waiting. Every delay
    // scheduled from this mount must stay inside that ceiling, and the
    // re-arming landing must still deliver idle→sleeping once the deadline
    // genuinely passes.
    const EPOCH_SCALE_ACTIVITY = 1_791_194_688_042;
    const TIMER_CEILING_MS = 2_147_483_647;
    vi.useFakeTimers({ now: 0 });
    publishAgentActivity(EPOCH_SCALE_ACTIVITY);
    const scheduled = vi.spyOn(globalThis, "setTimeout");
    const { container } = render(<PersonaSignalsProbe />);
    expect(scheduled).toHaveBeenCalled();
    for (const call of scheduled.mock.calls) {
      const delay = call[1];
      if (typeof delay === "number") {
        expect(delay).toBeGreaterThanOrEqual(0);
        expect(delay).toBeLessThanOrEqual(TIMER_CEILING_MS);
      }
    }
    // Restore the spy (its original is the fake clock, so re-arming during the
    // advance stays on the clock) before driving the deadline forward.
    scheduled.mockRestore();
    act(() => {
      vi.advanceTimersByTime(EPOCH_SCALE_ACTIVITY + AVATAR_SLEEP_MS + 1);
    });
    expect(
      (container.querySelector("img") as HTMLImageElement).getAttribute("src"),
    ).toContain("-sleeping-64");
  });
});

describe("persona avatar motion", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("floats on transform only and freezes under reduced-motion", async () => {
    // Motion is float-only by contract: the sleeping and working states drift
    // on translateY alone with no opacity pulse, and every avatar animation
    // arms only under `prefers-reduced-motion: no-preference` with a static
    // fallback — so reduced-motion owners always see still frames and the
    // sleeping dim can only come from the prerendered asset, never a filter.
    //
    // The stylesheet probe mirrors the bundle-asset probe below: Node builtins
    // resolve via dynamic import because the suite carries no @types/node.
    const { readFileSync } = (await import(
      // @ts-expect-error node builtin without @types/node; test-only probe.
      "node:fs"
    )) as { readFileSync: (path: string, encoding: string) => string };
    const { resolve } = (await import(
      // @ts-expect-error node builtin without @types/node; test-only probe.
      "node:path"
    )) as { resolve: (...pathSegments: string[]) => string };
    const cssPath = resolve(process.cwd(), "src/styles.css");
    const css = readFileSync(cssPath, "utf8");
    // All avatar animation arms behind the no-preference gate.
    expect(css).toContain("prefers-reduced-motion: no-preference");
    expect(css).toContain(".persona-avatar--sleeping");
    expect(css).toContain(".persona-avatar--working");
    // The float keyframe itself moves on transform alone.
    expect(css).toContain("@keyframes personaFloat");
    expect(css).toContain("translateY");
    // Avatar states never borrow the opacity pulse token: working floats like
    // sleeping instead of pulsing through a shared opacity keyframe.
    const avatarMotionBlock = css.slice(
      css.indexOf(".persona-avatar--sleeping"),
      css.indexOf(".persona-avatar-grid"),
    );
    expect(avatarMotionBlock).not.toContain("pulseTool");
    expect(avatarMotionBlock).not.toContain("opacity");
    // The explicit reduced-motion fallback keeps static frames even where the
    // no-preference gate already implies it.
    expect(css).toContain("prefers-reduced-motion: reduce");
  });

  it("holds the blink lid still when reduced-motion is requested", () => {
    // The blink is animation by another name: owners who ask for no animation
    // get the static idle frame rather than a lid flashing every few seconds.
    const matchMedia = vi.fn(() => ({
      matches: true,
      media: "(prefers-reduced-motion: reduce)",
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    }));
    vi.stubGlobal("matchMedia", matchMedia);
    try {
      vi.useFakeTimers();
      const { container } = render(
        <PersonaAvatar color="violet" state="idle" />,
      );
      act(() => {
        vi.advanceTimersByTime(BLINK_INTERVAL_MS * 3);
      });
      expect(
        container.querySelector(".persona-avatar-blink-lid"),
      ).toBeNull();
      expect(
        (container.querySelector("img") as HTMLImageElement).getAttribute(
          "src",
        ),
      ).toContain("-idle-64");
    } finally {
      vi.useRealTimers();
      vi.unstubAllGlobals();
    }
  });
});

describe("persona avatar bundle assets", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it(
    "ships a 256/64/32 PNG triple per colorway-state pair plus one SVG master per state",
    async () => {
      // The frames are derived assets owned by scripts/generate_persona_avatars.py
      // and the srcSet above points at them by name, so a missing file is a
      // broken avatar surface. If this machine has never rendered them, the
      // canonical generator (the same single rasterizer everything else uses)
      // materializes the full set deterministically; the test never writes a
      // second pipeline.
      //
      // Node builtins are resolved via dynamic import on purpose: the project
      // carries no @types/node (the production bundle must never gain a Node
      // dependency) and this file-system probe runs only inside the Vitest
      // process. The @ts-expect-error directives are a tripwire — adding
      // @types/node later will fail here loudly until this shim is retired.
      const { existsSync } = (await import(
        // @ts-expect-error node builtin without @types/node; test-only probe.
        "node:fs"
      )) as { existsSync: (path: string) => boolean };
      const { execFileSync } = (await import(
        // @ts-expect-error node builtin without @types/node; test-only probe.
        "node:child_process"
      )) as {
        execFileSync: (
          command: string,
          args: string[],
          options?: { stdio?: string },
        ) => unknown;
      };
      // Anchor both paths to `process.cwd()`, not `import.meta.url`: under
      // Vitest the module URL sits in Vite's `/@fs/` serving space, and a
      // `new URL(..., import.meta.url).pathname` there yields a `/@fs/...`
      // string that neither `existsSync` nor a `python3` argv can open — the
      // probe reported the present SVG masters as missing and the generator
      // fallback died on a file that does not exist. The web suite is always
      // launched from the `Web/` package directory (`make test-web` runs
      // `cd Web && npm test`, and the fork pool workers inherit that cwd), so
      // cwd is the one address every runner shares. The generator anchors its
      // own outputs to its `__file__`, so handing it this absolute script
      // path materializes the bundle into `Web/public/avatars` regardless of
      // any later process-relative drift.
      const { resolve } = (await import(
        // @ts-expect-error node builtin without @types/node; test-only probe.
        "node:path"
      )) as { resolve: (...pathSegments: string[]) => string };
      const avatarsDir = resolve(process.cwd(), "public/avatars");
      const generator = resolve(
        process.cwd(),
        "../scripts/generate_persona_avatars.py",
      );
      const states = ["idle", "sleeping", "working", "attention"] as const;
      const sizes = [256, 64, 32] as const;
      const allPresent = () =>
        PERSONA_AVATAR_COLORS.every((color) =>
          states.every(
            (state) =>
              sizes.every((size) =>
                existsSync(`${avatarsDir}/wisp-${color}-${state}-${size}.png`),
              ) && existsSync(`${avatarsDir}/wisp-${state}.svg`),
          ),
        );
      if (!allPresent()) {
        try {
          execFileSync("python3", [generator], { stdio: "pipe" });
        } catch (failure) {
          // The same toolchain as the favicon/app-icon scripts (python3 plus
          // Pillow plus sips) is a repo prerequisite; surface its stderr
          // rather than a bare ENOENT so a broken bundle failure reads as
          // what it is instead of a mystery.
          const stderr = (failure as { stderr?: unknown }).stderr;
          throw new Error(
            `scripts/generate_persona_avatars.py could not render the bundle: ${
              stderr === undefined || stderr === null ? String(failure) : String(stderr)
            }`,
          );
        }
      }
      for (const color of [...PERSONA_AVATAR_COLORS]) {
        for (const state of states) {
          for (const size of sizes) {
            expect(
              existsSync(`${avatarsDir}/wisp-${color}-${state}-${size}.png`),
              `wisp-${color}-${state}-${size}.png missing from Web/public/avatars`,
            ).toBe(true);
          }
        }
      }
      for (const state of states) {
        expect(
          existsSync(`${avatarsDir}/wisp-${state}.svg`),
          `wisp-${state}.svg master missing from Web/public/avatars`,
        ).toBe(true);
      }
    },
    // First render shells the full set through sips and Pillow; later runs
    // find the bundle present and skip generation entirely.
    120_000,
  );
});
