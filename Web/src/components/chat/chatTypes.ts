// Rune Weaver Dashboard — Chat interface types and architectural constants.

import type {
  ChatSegment,
  HealthResponse,
  RecallDiagnostics,
  ToolAction,
} from "../../api";

export interface MessageItem {
  id: string;
  role: "user" | "assistant" | "system" | "tool";
  text: string;
  // Content-free recall summary for the per-turn chip. Absent on history
  // reloads and older engines, which render no chip and no placeholder.
  recallDiagnostics?: RecallDiagnostics | null;
  toolActions?: ToolAction[];
  // Chronological timeline for this turn: text and tool batches alternate in the order the engine
  // produced them so multi-round turns never collapse into one lumped bucket.
  segments?: ChatSegment[];
  // Completion instant as milliseconds since the epoch on the server clock.
  // The stamp stays grounded in the persisted creation time so live cards and
  // history reloads agree; an omitted stamp renders no footer.
  completedAt?: number;
  isError?: boolean;
  errorText?: string;
}

export interface InFlightTurn {
  toolActions: ToolAction[];
  // Committed grapheme-safe prefix rendered through live MarkdownText. The
  // trailing incomplete cluster lives in `held` so partial emoji never
  // flashes; the full turn text is always `text + held` with zero loss.
  text: string;
  held: string;
  // Live chronological timeline built incrementally: the current text segment
  // closes when a tool starts and a fresh text segment opens on the next delta
  // after tools, mirroring the persisted per-round note boundaries for reloads.
  segments: ChatSegment[];
}

// One background turn parked while the user browses another session.
export interface ParkedFlight {
  turn: InFlightTurn | null;
  pending: boolean;
  messages?: MessageItem[];
  completedMessage?: MessageItem | null;
  warnings: string[];
  turnTokens: number | null;
  base: number;
  cancelled: boolean;
  // Last live activity for this flight. Drives least-recently-used eviction and
  // expiry so hidden sessions cannot accumulate without bound while the user
  // keeps browsing; refreshed on every parked frame and on park.
  updatedAt: number;
}

// Bounds the per-session flight map so hidden sessions cannot accumulate without bound while the
// user keeps browsing.
export const MAX_PARKED_FLIGHTS = 10;
export const PARKED_FLIGHT_TTL_MS = 30 * 60 * 1000;
export const PARKED_SETTLE_GRACE_MS = 10 * 1000;

// Bounds the per-session Up/Down input recall stack oldest-first so reload
// restores survive without unbounded storage; shares the named-constant
// discipline of the parked-flight and message caps above.
export const MAX_INPUT_HISTORY = 50;

// Outcome of a capped store so callers can surface lossy evictions through component state.
export interface ParkedFlightStoreOutcome {
  evictedKey: string | null;
  evictedLive: boolean;
  refused: boolean;
}

// Expired-flight reclaim result so callers can clear badges and surface live drops through state.
export interface PrunedParkedFlights {
  prunedKeys: string[];
  prunedLiveKeys: string[];
}

export const MAX_MESSAGES = 200;

// Maximum steering texts tracked for retraction. Mirrors the engine
// SteeringQueue.maxPendingPerSession so the optimistic list sheds the same
// oldest entry the server queue drops on overflow.
export const MAX_PENDING_STEERS = 20;

// Brief guard after steering so an accidental double-tap on Cancel does not
// drop guidance just sent. Named so the send and cancel paths share one
// bound instead of drifting on separate literals.
export const STEER_CANCEL_DEBOUNCE_MS = 500;

// Interim waiting placeholder prefix for parked approval turns. The engine composes parked text
// without a structured history flag (`waitingOnApprovalMessage`: "Waiting for approval to run
// ..."), so live updates and history reconstruction key interim detection on this prefix.
export const WAITING_PREFIX = "Waiting for approval";

// Liveness-aware inactivity budget for a WebSocket-started turn.
export const TURN_TIMEOUT_BASE_MS = 600_000;
export const TURN_TIMEOUT_PER_CONTEXT_TOKEN_MS = 30;
export const TURN_TIMEOUT_MAX_MS = 900_000;

// Strict session-ID validator for attacker-controlled URL values (`?session=`, `#chat/...`).
export const strictSessionIDPattern =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export interface ChatViewProps {
  health?: HealthResponse | null;
  // Shell tab selector so the goal drawer can jump to the full Goals surface.
  // Optional so standalone ChatView renders (and tests) stay shell-free.
  onSelectTab?: (tab: "goals") => void;
  // Shell activation flag for the Chat tab.
  isActive?: boolean;
  initialPrompt?: string | null;
  onClearInitialPrompt?: () => void;
  targetSessionId?: string | null;
  onClearTargetSessionId?: () => void;
}
