// Rune Weaver Dashboard — Persona avatar rendering, avatar-state resolution, and the
// shared persona-signals store.

import { useEffect, useState, useSyncExternalStore } from "react";
import {
  DEFAULT_PERSONA_AVATAR,
  PERSONA_AVATAR_COLORS,
  normalizePersonaAvatarColor,
  type PersonaData,
} from "../api";
import { RuneGlyph } from "./icons";

// Sprite states render one body with eyes and accents only differing; the closed
// set is fixed by the asset generator, so a drifted server or store value must
// degrade to `idle` instead of pointing at a PNG that does not exist.
export type AvatarState = "idle" | "sleeping" | "working" | "attention";

const AVATAR_STATES: readonly AvatarState[] = [
  "idle",
  "sleeping",
  "working",
  "attention",
];

// Minutes of silence before the Wisp dims to sleeping.
export const AVATAR_SLEEP_MS = 10 * 60 * 1000;

// Cadence and duration of the idle blink.
export const BLINK_INTERVAL_MS = 4000;
export const BLINK_CLOSED_MS = 150;

// Body-mid gradient stop per colorway, mirroring the generator's fixed palette.
const BLINK_LID_COLORS: Record<string, string> = {
  violet: "#8b5cf6",
  cyan: "#22d3ee",
  emerald: "#34d399",
  rose: "#fb7185",
};

// The three raster sizes the generator emits per colorway-state pair. The srcSet
// ships all three so a 16px trigger reads the 32px sheet and a 64px picker cell
// reads 1:1 instead of being downsampled from 256 by the browser.
export const AVATAR_SIZES = [32, 64, 256] as const;

export interface AvatarStateInput {
  // Attention wins unconditionally: a pending approval or a goal parked on owner
  // input is the one thing the owner must not miss, so it outranks every mood.
  hasAttention?: boolean;
  // Any in-flight run — chat, scheduler, goal, index, or fan-out — means the
  // agent is working regardless of the idle clock.
  isWorking?: boolean;
  // Epoch ms of the last observed turn end or run frame. Zero or a non-finite
  // value means "no activity observed yet" and reads as idle, never sleeping:
  // a freshly loaded dashboard has no elapsed-time basis for a sleep claim.
  lastActivityAtMs?: number | null;
  // Caller-supplied clock so the priority is pure and the 10-minute boundary is
  // unit-testable without fake timers reaching into this module.
  nowMs?: number;
}

// Pure avatar-state priority: attention > working > sleeping > idle.
export function resolveAvatarState(input: AvatarStateInput): AvatarState {
  if (input.hasAttention === true) return "attention";
  if (input.isWorking === true) return "working";
  const lastActivityAtMs = input.lastActivityAtMs;
  const nowMs = input.nowMs ?? Date.now();
  if (
    typeof lastActivityAtMs === "number" &&
    Number.isFinite(lastActivityAtMs) &&
    lastActivityAtMs > 0 &&
    Number.isFinite(nowMs) &&
    nowMs - lastActivityAtMs >= AVATAR_SLEEP_MS
  ) {
    return "sleeping";
  }
  return "idle";
}

// Builds the public asset path for one sprite frame.
export function personaAvatarFramePath(
  color: string,
  state: string,
  size: number,
): string {
  return `/avatars/wisp-${color}-${state}-${size}.png`;
}

function normalizeAvatarState(value: string | null | undefined): AvatarState {
  const candidate = (value ?? "").trim().toLowerCase();
  return (AVATAR_STATES as readonly string[]).includes(candidate)
    ? (candidate as AvatarState)
    : "idle";
}

function normalizeAvatarColor(value: string | null | undefined): string {
  const candidate = normalizePersonaAvatarColor(value);
  return (PERSONA_AVATAR_COLORS as readonly string[]).includes(candidate)
    ? candidate
    : DEFAULT_PERSONA_AVATAR;
}

// ---------------------------------------------------------------------------
// Shared persona signals store
// ---------------------------------------------------------------------------

// Client-owned persona signals.
export interface PersonaSignals {
  persona: PersonaData | null;
  // Distinguishes "never fetched" from "fetched, and the engine carries no
  // persona": the mount fetch skips itself once a load has answered, while
  // consumers still render the stock identity either way.
  personaLoaded: boolean;
  attention: boolean;
  working: boolean;
  // Epoch ms; 0 means no turn end or run frame has been observed yet.
  lastActivityAtMs: number;
}

const EMPTY_SIGNALS: PersonaSignals = Object.freeze({
  persona: null,
  personaLoaded: false,
  attention: false,
  working: false,
  lastActivityAtMs: 0,
});

// Snapshot reference only changes on a real publish so React's store reads stay
// stable between writes, mirroring the shared-runs idiom: readers never tear and
// an identical write never re-renders the whole shell.
let signals: PersonaSignals = Object.freeze({ ...EMPTY_SIGNALS });
const signalsListeners = new Set<() => void>();

function publishSignals(next: Partial<PersonaSignals>): void {
  let changed = false;
  for (const key of Object.keys(next) as Array<keyof PersonaSignals>) {
    if (signals[key] !== next[key]) {
      changed = true;
      break;
    }
  }
  if (!changed) return;
  signals = Object.freeze({ ...signals, ...next });
  for (const listener of [...signalsListeners]) {
    try {
      listener();
    } catch {
      // One throwing subscriber never starves the rest.
    }
  }
}

function subscribePersonaSignals(listener: () => void): () => void {
  signalsListeners.add(listener);
  return () => {
    signalsListeners.delete(listener);
  };
}

function getPersonaSignalsSnapshot(): PersonaSignals {
  return signals;
}

// Direct non-React read of the current snapshot. The store hands out frozen
// objects, so callers outside a render cycle (one-shot mount probes and tests
// asserting the single-writer contract) can read it without subscribing.
export function peekPersonaSignals(): PersonaSignals {
  return signals;
}

function getPersonaSignalsServerSnapshot(): PersonaSignals {
  return EMPTY_SIGNALS;
}

export function usePersonaSignals(): PersonaSignals {
  return useSyncExternalStore(
    subscribePersonaSignals,
    getPersonaSignalsSnapshot,
    getPersonaSignalsServerSnapshot,
  );
}

// Records the persona carried by a settings payload. Undefined normalizes to null
// (an engine predating `[persona]` keeps the stock identity), and the loaded flag
// is set even on a persona-less answer so the one-shot mount fetch never repeats.
export function publishPersonaFromSettings(
  persona: PersonaData | null | undefined,
): void {
  publishSignals({
    persona: persona ?? null,
    personaLoaded: true,
  });
}

export function publishAgentAttention(attention: boolean): void {
  publishSignals({ attention });
}

export function publishAgentWorking(working: boolean): void {
  publishSignals({ working });
}

// Monotonic by construction: a late-arriving stale frame must never rewind the
// idle clock, because rewinding would keep a sleeping Wisp awake after the
// silence it claims to measure. Non-positive or non-finite input is dropped.
export function publishAgentActivity(activityMs: number): void {
  if (!Number.isFinite(activityMs) || activityMs <= 0) return;
  if (activityMs <= signals.lastActivityAtMs) return;
  publishSignals({ lastActivityAtMs: activityMs });
}

// Test-only reset that detaches the module singleton between suites, mirroring
// `resetSharedRunsForTesting`. Gated to the test bundle so production can never
// wipe live signals.
export function resetPersonaSignalsForTesting(): void {
  if (import.meta.env.MODE !== "test") return;
  signals = Object.freeze({ ...EMPTY_SIGNALS });
  signalsListeners.clear();
}

// Largest delay `setTimeout` can actually represent: both Node and the HTML timer spec treat
// anything above the signed 32-bit ceiling as an overflow — Node warns and fires after 1 ms,
// browsers refuse the wake silently.
export const MAX_TIMER_DELAY_MS = 2_147_483_647;

// Single clamp for every sleep-deadline wake: keeps an epoch-scale remaining
// duration inside the platform timer ceiling. On a coherent clock the clamp
// is inert because the deadline sits at most `AVATAR_SLEEP_MS` away.
export function clampSleepWakeDelay(remainingMs: number): number {
  return Math.min(remainingMs, MAX_TIMER_DELAY_MS);
}

// Shared idle→sleeping clock. Returns a `nowMs` that advances exactly when the idle clock crosses
// `AVATAR_SLEEP_MS`, so idle→sleeping lands without any polling.
export function useSleepWakeNow(
  hasAttention: boolean,
  isWorking: boolean,
  lastActivityAtMs: number,
): number {
  const [nowMs, setNowMs] = useState(() => Date.now());
  useEffect(() => {
    if (hasAttention || isWorking) return;
    if (lastActivityAtMs <= 0) return;
    const sleepDeadlineAtMs = lastActivityAtMs + AVATAR_SLEEP_MS;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const arm = () => {
      const remaining = sleepDeadlineAtMs - Date.now();
      if (remaining <= 0) {
        // The store moved (e.g. working cleared) past the threshold while no
        // timer was armed, so re-evaluate now instead of waiting for the next
        // unrelated render.
        setNowMs(Date.now());
        return;
      }
      timer = setTimeout(arm, clampSleepWakeDelay(remaining));
    };
    arm();
    return () => {
      if (timer !== null) clearTimeout(timer);
    };
  }, [hasAttention, isWorking, lastActivityAtMs]);
  return nowMs;
}

// Resolves the sprite state from the shared signals for one identity surface.
export function useResolvedAvatarState(): AvatarState {
  const { attention, working, lastActivityAtMs } = usePersonaSignals();
  const nowMs = useSleepWakeNow(attention, working, lastActivityAtMs);
  return resolveAvatarState({
    hasAttention: attention,
    isWorking: working,
    lastActivityAtMs,
    nowMs,
  });
}

// Reads the reduced-motion preference once per render cycle and stays subscribed to live toggles.
function readPrefersReducedMotion(): boolean {
  const query = "(prefers-reduced-motion: reduce)";
  try {
    if (
      typeof window !== "undefined" &&
      typeof window.matchMedia === "function"
    ) {
      return window.matchMedia(query).matches === true;
    }
    if (
      typeof globalThis !== "undefined" &&
      typeof (globalThis as { matchMedia?: unknown }).matchMedia ===
        "function"
    ) {
      return (
        (
          globalThis as {
            matchMedia: (q: string) => { matches: boolean };
          }
        ).matchMedia(query).matches === true
      );
    }
  } catch {
    return false;
  }
  return false;
}

// Minimal structural shape for the reduced-motion query.
type ReducedMotionQuery = {
  matches: boolean;
  addEventListener?: (
    type: string,
    listener: (e: { matches: boolean }) => void,
  ) => void;
  removeEventListener?: (
    type: string,
    listener: (e: { matches: boolean }) => void,
  ) => void;
  addListener?: (listener: (e: { matches: boolean }) => void) => void;
  removeListener?: (listener: (e: { matches: boolean }) => void) => void;
};

function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(() => readPrefersReducedMotion());
  useEffect(() => {
    const query = "(prefers-reduced-motion: reduce)";
    // Typed explicitly rather than via `typeof mql`: a self-referential cast
    // collapses the union to its null member, leaving every later member
    // access narrowed to never.
    let mql: ReducedMotionQuery | null = null;
    try {
      if (
        typeof window !== "undefined" &&
        typeof window.matchMedia === "function"
      ) {
        mql = window.matchMedia(query) as unknown as ReducedMotionQuery;
      } else if (
        typeof globalThis !== "undefined" &&
        typeof (globalThis as { matchMedia?: unknown }).matchMedia ===
          "function"
      ) {
        mql = (
          globalThis as {
            matchMedia: (q: string) => ReducedMotionQuery;
          }
        ).matchMedia(query);
      }
    } catch {
      mql = null;
    }
    if (mql === null) return;
    // Snapshot the non-null handle so later closures keep the narrowed shape
    // instead of widening back to the nullable declaration.
    const current = mql;
    // Re-sync in case the preference flipped between the lazy initializer
    // and this subscription.
    setReduced(current.matches === true);
    const onChange = (event: { matches: boolean }) => {
      setReduced(event.matches === true);
    };
    if (typeof current.addEventListener === "function") {
      current.addEventListener("change", onChange);
      return () => {
        current.removeEventListener?.("change", onChange);
      };
    }
    if (typeof current.addListener === "function") {
      current.addListener(onChange);
      return () => {
        current.removeListener?.(onChange);
      };
    }
    return;
  }, []);
  return reduced;
}

interface PersonaAvatarProps {
  // Raw server accent (or a picker draft); validated inside, never here — callers
  // pass what they hold and the fallback rule stays single-sourced.
  color?: string | null;
  // Raw state token; unknown values render the idle frame.
  state?: string | null;
  // Rendered size in px; srcSet always ships the full 32/64/256 triple.
  size?: number;
  className?: string;
  // Accessible name; surfaces that pair the avatar with the visible persona name
  // pass an empty string so the image stays decorative and screen readers do not
  // announce the identity twice.
  label?: string;
  dataTestId?: string;
  // Idle blink opt-out. The live identity surfaces blink because a resting
  // assistant reads as alive; the settings picker renders static frames — a
  // blinking swatch would look like a state change it cannot acknowledge.
  blink?: boolean;
}

// The Wisp avatar itself.
export function PersonaAvatar({
  color,
  state,
  size = 32,
  className = "",
  label = "Assistant avatar",
  dataTestId,
  blink = true,
}: PersonaAvatarProps) {
  const avatarColor = normalizeAvatarColor(color);
  const avatarState = normalizeAvatarState(state);
  // A failed frame load latches the glyph fallback, but the latch clears with
  // the frame: a different colorway or state may resolve fine, and a persistent
  // glyph for the whole session would hide a recovery the browser already made.
  const [imageFailed, setImageFailed] = useState(false);
  useEffect(() => {
    setImageFailed(false);
  }, [avatarColor, avatarState]);

  const [blinkClosed, setBlinkClosed] = useState(false);
  // Reduced-motion owners get the static frame: the lid is animation by another name, so it shares
  // the same opt-out as the float keyframes in the stylesheet.
  const prefersReducedMotion = usePrefersReducedMotion();
  const blinkActive =
    avatarState === "idle" && !imageFailed && blink && !prefersReducedMotion;
  useEffect(() => {
    if (!blinkActive) {
      setBlinkClosed(false);
      return;
    }
    let interval: ReturnType<typeof setInterval> | null = null;
    let closedTimer: ReturnType<typeof setTimeout> | null = null;
    const blinkOnce = () => {
      setBlinkClosed(true);
      closedTimer = setTimeout(() => {
        closedTimer = null;
        setBlinkClosed(false);
      }, BLINK_CLOSED_MS);
    };
    const start = () => {
      if (interval === null) interval = setInterval(blinkOnce, BLINK_INTERVAL_MS);
    };
    const stop = () => {
      if (interval !== null) {
        clearInterval(interval);
        interval = null;
      }
      if (closedTimer !== null) {
        clearTimeout(closedTimer);
        closedTimer = null;
      }
      // A hidden tab that closed mid-blink must never re-show a half-blinked
      // Wisp when the owner returns.
      setBlinkClosed(false);
    };
    const onVisibility = () => {
      if (typeof document !== "undefined" && document.hidden) stop();
      else start();
    };
    if (!(typeof document !== "undefined" && document.hidden)) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      stop();
    };
  }, [blinkActive]);

  if (imageFailed) {
    // The brand rune mark is the definitive no-broken-image fallback. It is wrapped (rather than
    // given the test id directly) because the icon's props type is a plain SVG spread.
    return (
      <span
        className={`persona-avatar persona-avatar-fallback${className ? ` ${className}` : ""}`}
        data-testid={dataTestId}
        role={label ? "img" : undefined}
        aria-label={label || undefined}
        aria-hidden={label ? undefined : true}
      >
        <RuneGlyph size={size} className="rune-glyph-icon" />
      </span>
    );
  }

  // The blink never swaps the frame: the src and the state class always name the resolved avatar
  // state, so a blink can never flash the sleeping PNG's Z marks, dimmed core, or float animation,
  // nor masquerade as sleeping in the DOM.
  const shownState: AvatarState = avatarState;
  const isBlinking = avatarState === "idle" && blinkClosed;
  const srcSet = AVATAR_SIZES.map(
    (px) => `${personaAvatarFramePath(avatarColor, shownState, px)} ${px}w`,
  ).join(", ");
  const imgClassName = `persona-avatar persona-avatar--${shownState}${isBlinking ? " persona-avatar--blinking" : ""}${className ? ` ${className}` : ""}`;
  const img = (
    <img
      src={personaAvatarFramePath(avatarColor, shownState, 64)}
      srcSet={srcSet}
      sizes={`${size}px`}
      width={size}
      height={size}
      alt={label}
      draggable={false}
      data-testid={dataTestId}
      className={imgClassName}
      onError={() => setImageFailed(true)}
    />
  );
  if (!isBlinking) return img;
  // Closed-eyes lid for the 150 ms blink window.
  return (
    <span
      className="persona-avatar-blink"
      style={{
        position: "relative",
        display: "inline-block",
        width: size,
        height: size,
        lineHeight: 0,
        verticalAlign: "middle",
      }}
    >
      {img}
      <span
        aria-hidden="true"
        className="persona-avatar-blink-lid"
        style={{
          position: "absolute",
          left: "30%",
          right: "30%",
          top: "37%",
          height: "11%",
          background: BLINK_LID_COLORS[avatarColor] ?? BLINK_LID_COLORS.violet,
          borderRadius: "9999px",
        }}
      />
    </span>
  );
}
