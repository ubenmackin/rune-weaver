// Rune Weaver Dashboard — Goals and Ideas API endpoints.
import { fetchJson } from "./http";
import { isRecord } from "../typeGuards";
import { parseRunTimestamp } from "./types";
import { formatRelativeIn } from "../relativeTime";

// ---------------------------------------------------------------------------
// Long-horizon goals
// ---------------------------------------------------------------------------

// Finished-versus-planned tally nested on one goal row. `done` counts only
// finished steps while `total` is the whole plan, so an empty plan reads 0/0
// instead of a misleading full bar. Mirrors the engine `WSGoalProgress`.
export interface GoalProgress {
  done: number;
  total: number;
}

// One goal row shared by the list, detail, and `goal_updated` push shapes.
export interface Goal {
  id: string;
  title: string;
  statement: string;
  status: string;
  progress: GoalProgress;
  stepIntervalMinutes: number;
  nextDueAt: string | number | null;
  originSessionId: string | null;
  createdAt: string | number;
  updatedAt: string | number;
  isPlanning?: boolean;
}

// One ordered step in a goal plan. `status` rides as the engine raw value
// (`pending`, `in_progress`, `done`, `blocked`, `skipped`) so the dashboard
// never invents a case the store cannot round-trip through a PATCH.
export interface GoalStep {
  id: string;
  goalId: string;
  ordinal: number;
  title: string;
  status: string;
  notes: string | null;
  lastRunId: string | null;
  createdAt: string | number;
  updatedAt: string | number;
}

// One append-only audit entry for a goal. `id` is the SQLite rowid so the trail
// stays ordered without a second sequence; `message` is model- or
// operator-authored prose and must render through the sanitized Markdown path.
export interface GoalEvent {
  id: number;
  goalId: string;
  kind: string;
  message: string;
  createdAt: string | number;
}

export interface GoalsListResponse {
  goals: Goal[];
  count: number;
}

// Detail response shared by `GET /goals/:id` and every mutating goal route.
// Steps ride whole because plans stay small by config bound; events ride
// bounded by the caller's limit so a long audit trail never crowds the row.
export interface GoalDetailResponse {
  goal: Goal;
  steps: GoalStep[];
  events: GoalEvent[];
}

// Creation request for `POST /goals`. The cadence hint is optional so an
// omitted value lets the engine apply its configured default.
export interface GoalCreateInput {
  title: string;
  statement: string;
  stepIntervalMinutes?: number;
}

// Edit request for `PATCH /goals/:id`. Every field is optional so one call can rename, restate,
// retime, or flip lifecycle state; absent keys leave their columns untouched.
export interface GoalPatchInput {
  status?: string;
  title?: string;
  statement?: string;
  stepIntervalMinutes?: number;
}

// Manual step move for `PATCH /goals/:id/steps/:stepId`. Status is required
// because a move without a destination is a no-op, while the note stays
// optional so terse moves need no annotation.
export interface GoalStepPatchInput {
  status: string;
  note?: string;
}

// Manual-advance receipt for `POST /goals/:id/advance`. Both durable identifiers ride along so the
// dashboard can link the fresh run row and its session without a second lookup.
export interface GoalAdvanceResponse {
  runID: string;
  sessionID: string;
  goalId: string;
}

// Display label per lifecycle state. An unknown future raw value falls back to
// itself so a newer engine still renders honestly instead of blanking the pill.
export function goalStatusLabel(status: string): string {
  switch (status) {
    case "active":
      return "Active";
    case "paused":
      return "Paused";
    case "needs_input":
    case "needsInput":
      return "Needs input";
    case "achieved":
      return "Achieved";
    case "abandoned":
      return "Abandoned";
    case "unplanned":
      return "Unplanned";
    default:
      return status || "Unknown";
  }
}

// Advanceable states for manual Work on it now. Only active and unplanned run;
// resting and terminal states stay disabled so no run row is created for them.
export function isGoalAdvanceable(status: string): boolean {
  return status === "active" || status === "unplanned";
}

// Blocked tooltip for Work on it now. Resting names resume as the recovery;
// terminal and unknown states read as finished and no longer workable.
export function goalAdvanceBlockedTitle(status: string): string {
  if (
    status === "paused" ||
    status === "needs_input" ||
    status === "needsInput"
  ) {
    return "Resume this goal before working on it now.";
  }
  return "This goal is finished and can no longer be worked on.";
}

// Run-status pill tone reused by goal cards so goal and run surfaces share one color language:
// active pursuit reads like a running turn, parked-on-owner like a parked approval, achieved like an
// ok run, abandoned like an error, and paused like a skipped row.
export type GoalStatusTone =
  | "ok"
  | "error"
  | "skipped"
  | "running"
  | "awaiting_approval";

export function goalStatusTone(status: string): GoalStatusTone {
  switch (status) {
    case "active":
      return "running";
    case "needs_input":
    case "needsInput":
      return "awaiting_approval";
    case "unplanned":
      return "awaiting_approval";
    case "achieved":
      return "ok";
    case "abandoned":
      return "error";
    case "paused":
      return "skipped";
    default:
      return "skipped";
  }
}

// Reports whether a goal is in the unplanned state.
export function isGoalUnplanned(status: string | null | undefined): boolean {
  return status === "unplanned";
}

// Reports whether a goal is actively being planned by the agent.
export function isGoalPlanning(goal: Goal | null | undefined): boolean {
  return Boolean(goal?.isPlanning);
}

// Reports whether a goal is parked awaiting owner input, the single state the
// attention badge counts; the camelCase alias mirrors the engine's alternate
// REST spelling.
export function goalNeedsInput(status: string | null | undefined): boolean {
  return status === "needs_input" || status === "needsInput";
}

// Display label per audit kind. Unknown kinds fall back to the trimmed raw
// token so a newer engine's event still names itself instead of rendering blank.
export function goalEventKindLabel(kind: string): string {
  switch (kind) {
    case "created":
      return "Created";
    case "plan_ready":
      return "Plan ready";
    case "step_started":
      return "Step started";
    case "step_done":
      return "Step done";
    case "step_blocked":
      return "Step blocked";
    case "needs_input":
      return "Needs input";
    case "completed":
      return "Completed";
    case "resumed":
      return "Resumed";
    case "paused":
      return "Paused";
    case "note":
      return "Note";
    default:
      return kind.trim() || "Update";
  }
}

// Whole-percent completion for the progress bar. An empty plan reads 0 instead
// of dividing by zero, and the value is clamped so a drifted done > total never
// overflows the track; non-finite inputs degrade to 0 rather than rendering NaN.
export function goalProgressPercent(
  progress: GoalProgress | null | undefined,
): number {
  const done = progress?.done;
  const total = progress?.total;
  if (
    typeof done !== "number" ||
    typeof total !== "number" ||
    !Number.isFinite(done) ||
    !Number.isFinite(total) ||
    total <= 0
  ) {
    return 0;
  }
  const percent = (done / total) * 100;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

// Human countdown to the next due advancement.
export function formatGoalNextAdvance(
  status: string,
  nextDueAt: string | number | null | undefined,
  now: number = Date.now(),
): string {
  if (
    status === "paused" ||
    goalNeedsInput(status) ||
    status === "achieved" ||
    status === "abandoned"
  ) {
    return "-";
  }
  if (nextDueAt == null) return "No schedule";
  const due = parseRunTimestamp(nextDueAt).getTime();
  if (!Number.isFinite(due) || due <= 0) return "No schedule";
  const diff = due - now;
  if (diff <= 0) return "due now";
  return formatRelativeIn(diff);
}

// Parses a goal snapshot carried on a `goal_updated` frame (or a raw REST row) before it enters
// view state.
export function parseGoalSnapshot(value: unknown): Goal | null {
  if (!isRecord(value)) return null;
  const rawID = value.id;
  const id = typeof rawID === "string" ? rawID.trim() : "";
  if (!id) return null;
  // Bind the string fields to locals first so the narrowings survive into the
  // returned object literal without re-reading the index signature.
  const title = value.title;
  const status = value.status;
  if (typeof title !== "string" || typeof status !== "string") {
    return null;
  }
  const statement = typeof value.statement === "string" ? value.statement : "";
  const progressRaw: Record<string, unknown> = isRecord(value.progress)
    ? value.progress
    : {};
  const doneRaw = progressRaw.done;
  const totalRaw = progressRaw.total;
  const done =
    typeof doneRaw === "number" && Number.isFinite(doneRaw)
      ? Math.max(0, Math.floor(doneRaw))
      : 0;
  const total =
    typeof totalRaw === "number" && Number.isFinite(totalRaw)
      ? Math.max(0, Math.floor(totalRaw))
      : 0;
  const intervalRaw = value.stepIntervalMinutes;
  const stepIntervalMinutes =
    typeof intervalRaw === "number" && Number.isFinite(intervalRaw)
      ? Math.max(0, Math.floor(intervalRaw))
      : 0;
  const originRaw = value.originSessionId;
  const originSessionId =
    typeof originRaw === "string" && originRaw.trim() ? originRaw : null;
  // Runtime-validate each timestamp instead of casting: a drifted object or
  // boolean must fall back (null due date, epoch created/updated) rather than
  // flow into parseRunTimestamp, whose string path calls `.trim()`.
  const nextDueRaw = value.nextDueAt;
  const nextDueAt =
    typeof nextDueRaw === "string" || typeof nextDueRaw === "number"
      ? nextDueRaw
      : null;
  const createdRaw = value.createdAt;
  const createdAt =
    typeof createdRaw === "string" || typeof createdRaw === "number"
      ? createdRaw
      : 0;
  const updatedRaw = value.updatedAt;
  const updatedAt =
    typeof updatedRaw === "string" || typeof updatedRaw === "number"
      ? updatedRaw
      : 0;
  const isPlanningRaw = value.isPlanning ?? value.is_planning;
  const isPlanning =
    typeof isPlanningRaw === "boolean" ? isPlanningRaw : undefined;
  return {
    id,
    title,
    statement,
    status,
    progress: { done, total },
    stepIntervalMinutes,
    nextDueAt,
    originSessionId,
    createdAt,
    updatedAt,
    isPlanning,
  };
}

// Extracts the goal snapshot from a `goal_updated` frame. Returns null for any
// other frame type or a malformed payload so the socket handler refreshes only
// on a real update instead of on unrelated traffic.
export function parseGoalUpdatedFrame(value: unknown): Goal | null {
  if (!isRecord(value) || value.type !== "goal_updated") return null;
  return parseGoalSnapshot(value.goal);
}

// Reports whether a `proactive_message` frame signals a goal awaiting owner input.
export function isGoalNeedsInputProactive(value: unknown): boolean {
  if (!isRecord(value) || value.type !== "proactive_message") return false;
  // Bind to a local so the string narrowing survives the normalization chain.
  const kind = value.kind;
  if (typeof kind !== "string") return false;
  const normalized = kind.trim().toLowerCase().replace(/[_-]/g, "");
  return normalized.includes("needsinput");
}

// Reports whether a `proactive_message` frame announces a freshly proposed idea.
export function isIdeaProposedProactive(value: unknown): boolean {
  if (!isRecord(value) || value.type !== "proactive_message") return false;
  // Bind to a local so the string narrowing survives the normalization chain.
  const kind = value.kind;
  if (typeof kind !== "string") return false;
  const normalized = kind.trim().toLowerCase().replace(/[_-]/g, "");
  return normalized === "ideaproposed";
}

// Lists goals, optionally filtered by lifecycle state. A blank filter is
// omitted so the caller gets every state and can apply its own default hiding.
export function listGoals(status?: string): Promise<GoalsListResponse> {
  const trimmed = status?.trim();
  const query = trimmed ? `?status=${encodeURIComponent(trimmed)}` : "";
  return fetchJson<GoalsListResponse>(`/goals${query}`);
}

// Fetches one goal with its plan and bounded audit history.
export function getGoal(id: string): Promise<GoalDetailResponse> {
  return fetchJson<GoalDetailResponse>(`/goals/${encodeURIComponent(id)}`);
}

// Creates a goal; the engine returns the row immediately and lands the plan on
// a background task, with a later `goal_updated` push carrying the ready plan.
export function createGoal(input: GoalCreateInput): Promise<GoalDetailResponse> {
  return fetchJson<GoalDetailResponse>("/goals", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

// Renames, restates, retimes, or flips the lifecycle state of one goal.
export function patchGoal(
  id: string,
  input: GoalPatchInput,
): Promise<GoalDetailResponse> {
  return fetchJson<GoalDetailResponse>(`/goals/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify(input),
  });
}

// Tombstones a goal by default so history stays joinable; `purge` hard-deletes
// the row and its plan instead. Both paths answer 204 with no body.
export function deleteGoal(id: string, purge = false): Promise<void> {
  const query = purge ? "?purge=true" : "";
  return fetchJson<void>(`/goals/${encodeURIComponent(id)}${query}`, {
    method: "DELETE",
  });
}

// Fires one manual advancement. The engine owns the single-flight lock, so a
// goal already advancing answers 409, which callers surface as already running.
export function advanceGoal(id: string): Promise<GoalAdvanceResponse> {
  return fetchJson<GoalAdvanceResponse>(
    `/goals/${encodeURIComponent(id)}/advance`,
    { method: "POST", body: JSON.stringify({}) },
  );
}

// Moves one plan step and returns the refreshed step row.
export function patchGoalStep(
  goalId: string,
  stepId: string,
  input: GoalStepPatchInput,
): Promise<GoalStep> {
  return fetchJson<GoalStep>(
    `/goals/${encodeURIComponent(goalId)}/steps/${encodeURIComponent(stepId)}`,
    { method: "PATCH", body: JSON.stringify(input) },
  );
}

// One proactive Wayfinder suggestion mirrored from the engine `Idea` snapshot.
export interface Idea {
  id: string;
  kind: string;
  title: string;
  body: string;
  goalId: string | null;
  status: string;
  createdAt: string | number;
  updatedAt: string | number;
}

export interface IdeasListResponse {
  ideas: Idea[];
  count: number;
}

export interface IdeasSummaryResponse {
  total: number;
  proposed: number;
  accepted: number;
  dismissed: number;
}

// Parses one idea row before it enters view state.
export function parseIdea(value: unknown): Idea | null {
  if (!isRecord(value)) return null;
  const rawID = value.id;
  const id = typeof rawID === "string" ? rawID.trim() : "";
  if (!id) return null;
  const rawTitle = value.title;
  const kind = value.kind;
  const status = value.status;
  if (
    typeof rawTitle !== "string" ||
    typeof kind !== "string" ||
    typeof status !== "string"
  ) {
    return null;
  }
  const title = rawTitle.trim();
  if (!title) return null;
  const body = typeof value.body === "string" ? value.body : "";
  const goalRaw = value.goalId ?? value.goalID;
  const trimmedGoal = typeof goalRaw === "string" ? goalRaw.trim() : "";
  const goalId = trimmedGoal ? trimmedGoal : null;
  // Type-check timestamps rather than casting so a drifted object or boolean
  // cannot reach parseRunTimestamp, whose string path calls `.trim()`.
  const createdRaw = value.createdAt;
  const createdAt =
    typeof createdRaw === "string" || typeof createdRaw === "number"
      ? createdRaw
      : 0;
  const updatedRaw = value.updatedAt;
  const updatedAt =
    typeof updatedRaw === "string" || typeof updatedRaw === "number"
      ? updatedRaw
      : 0;
  return { id, kind, title, body, goalId, status, createdAt, updatedAt };
}

// Display label per idea family. An unknown future raw value falls back to its
// underscored spelling so a newer engine still renders a readable pill.
export function ideaKindLabel(kind: string): string {
  switch (kind) {
    case "plan_adjustment":
      return "Plan";
    case "new_goal":
      return "New goal";
    case "tip":
      return "Tip";
    default:
      return kind.replace(/_/g, " ").trim() || "Idea";
  }
}

// Lists ideas, optionally filtered by lifecycle state. A blank filter is
// omitted so the caller gets every state and applies its own default hiding.
export function listIdeas(status?: string): Promise<IdeasListResponse> {
  const trimmed = status?.trim();
  const query = trimmed ? `?status=${encodeURIComponent(trimmed)}` : "";
  return fetchJson<IdeasListResponse>(`/ideas${query}`);
}

// Fetches the per-status idea tallies for the attention badge.
export function getIdeasSummary(): Promise<IdeasSummaryResponse> {
  return fetchJson<IdeasSummaryResponse>("/ideas/summary");
}

// Accepts one idea and returns its refreshed row. The engine applies the
// suggestion's change (plan adjustment or new goal) before flipping status, so
// a 400/409 here is the honest reason the change could not be applied.
export function acceptIdea(id: string): Promise<Idea> {
  return fetchJson<Idea>(`/ideas/${encodeURIComponent(id)}/accept`, {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// Dismisses one idea and returns its refreshed row. Dismissal never blocks a
// future suggestion with the same title; it only records the owner's "no".
export function dismissIdea(id: string): Promise<Idea> {
  return fetchJson<Idea>(`/ideas/${encodeURIComponent(id)}/dismiss`, {
    method: "POST",
    body: JSON.stringify({}),
  });
}

