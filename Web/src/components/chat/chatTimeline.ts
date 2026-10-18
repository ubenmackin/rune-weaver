// Rune Weaver Dashboard — Chat message timeline reconstruction, segment aggregation, and tool action ordering.

import {
  compareToolActionsByRound,
  groupToolActionsByRound,
  normalizeLineEndings,
  parseRunTimestamp,
  placeholderCallIDsInText,
  sortToolActionsByRound,
  type ChatSegment,
  type SessionMessageToolActions,
  type ToolAction,
  type ToolResult,
} from "../../api";
import { isRecord } from "../../approvalsSession";
import {
  WAITING_PREFIX,
  type InFlightTurn,
  type MessageItem,
} from "./chatTypes";

// Folds flat summaries from an ordered timeline so legacy readers that only know
// `text`/`toolActions` still see the same content that segmented rendering shows.
export function flatTextFromSegments(segments: ChatSegment[]): string {
  return segments
    .filter((segment) => segment.kind === "text")
    .map((segment) => segment.text)
    .filter(Boolean)
    .join("\n\n")
    .trim();
}

// Flattens tool batches oldest-first so the legacy bucket matches segment order.
export function flatActionsFromSegments(segments: ChatSegment[]): ToolAction[] {
  const flat: ToolAction[] = [];
  for (const segment of segments) {
    if (segment.kind === "tools") flat.push(...segment.actions);
  }
  return flat;
}

// Keeps the pending user bubble out of reloaded history while its reply streams.
export function messagesUpToLastUser<T extends { role: string }>(messages: T[]): T[] {
  let lastUserIdx = -1;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === "user") {
      lastUserIdx = i;
      break;
    }
  }
  if (lastUserIdx >= 0) {
    return messages.slice(0, lastUserIdx + 1);
  }
  return messages;
}

// Appends one started call to the live timeline, closing the open text segment
// by opening a fresh tools batch instead of concatenating onto prior prose.
export function appendToolStartToSegments(
  segments: ChatSegment[],
  action: ToolAction,
): ChatSegment[] {
  const next = segments.map((segment) =>
    segment.kind === "tools"
      ? { kind: "tools" as const, actions: [...segment.actions] }
      : { ...segment },
  );
  const last = next[next.length - 1];
  if (last && last.kind === "tools") {
    last.actions.push(action);
    return next;
  }
  return [...next, { kind: "tools" as const, actions: [action] }];
}

// Merges one completed result into the matching live batch by call identity so resumed batches
// rejoin the same timeline instead of forking a duplicate row.
export function updateToolEndInSegments(
  segments: ChatSegment[],
  callID: string,
  toolName: string,
  result: ToolResult | null,
  roundIndex?: number,
): ChatSegment[] {
  const hasCallIDMatch = segments.some(
    (segment) =>
      segment.kind === "tools" &&
      segment.actions.some((action) => action.callID === callID),
  );
  if (hasCallIDMatch) {
    return segments.map((segment) => {
      if (segment.kind !== "tools") return segment;
      return {
        kind: "tools" as const,
        actions: segment.actions.map((action) =>
          action.callID === callID
            ? {
                ...action,
                result,
                ...(roundIndex !== undefined ? { roundIndex } : {}),
              }
            : action,
        ),
      };
    });
  }
  let claimed = false;
  return segments.map((segment) => {
    if (segment.kind !== "tools" || claimed) return segment;
    let updatedInSegment = false;
    const actions = segment.actions.map((action) => {
      if (!claimed && !action.result && action.toolName === toolName) {
        claimed = true;
        updatedInSegment = true;
        return {
          ...action,
          result,
          ...(roundIndex !== undefined ? { roundIndex } : {}),
        };
      }
      return action;
    });
    if (!updatedInSegment) return segment;
    return {
      kind: "tools" as const,
      actions,
    };
  });
}

// Shared copy/append shape for streamed prose segments, parameterized by kind so text and reasoning
// never drift apart.
export function appendSegmentDelta(
  segments: ChatSegment[],
  kind: "text" | "thought",
  deltaText: string,
): ChatSegment[] {
  if (!deltaText) return segments;
  const next = segments.map((segment) =>
    segment.kind === "tools"
      ? { kind: "tools" as const, actions: [...segment.actions] }
      : { ...segment },
  );
  const last = next[next.length - 1];
  if (kind === "text") {
    if (last && last.kind === "text") {
      return [
        ...next.slice(0, -1),
        { kind: "text" as const, text: last.text + deltaText },
      ];
    }
    return [...next, { kind: "text" as const, text: deltaText }];
  }
  if (last && last.kind === "thought") {
    return [
      ...next.slice(0, -1),
      { kind: "thought" as const, text: last.text + deltaText },
    ];
  }
  return [...next, { kind: "thought" as const, text: deltaText }];
}

// Appends streamed prose to the live timeline, opening a fresh text segment when
// the previous piece is a tool batch so text never merges across round bounds.
export function appendDeltaToSegments(
  segments: ChatSegment[],
  deltaText: string,
): ChatSegment[] {
  return appendSegmentDelta(segments, "text", deltaText);
}

// Appends streamed reasoning / thought to the live timeline.
export function appendReasoningDeltaToSegments(
  segments: ChatSegment[],
  deltaText: string,
): ChatSegment[] {
  return appendSegmentDelta(segments, "thought", deltaText);
}

// Keeps only prose lines not already covered by structured actions, identified
// by the authoritative call identifier, so narration fallback lines never
// double-count with structured actions while unrelated prose stays visible.
export function filterUncoveredText(text: string, coveredCallIDs: Set<string>): string {
  // Carriage returns fold like the engine before matching; the set grammar decides coverage
  // so prose that merely mentions an identifier is never hidden and grammar changes land in
  // one place.
  const normalized = normalizeLineEndings(text);
  return normalized
    .split("\n")
    .filter((line) => {
      if (!line.trim()) return false;
      const ids = placeholderCallIDsInText(line);
      if (ids.size === 0) return true;
      for (const id of ids) {
        if (coveredCallIDs.has(id)) return false;
      }
      return true;
    })
    .join("\n")
    .trim();
}

// Collapses repeats of one execution to a single row, keeping the
// execution-backed record over a pending twin so a narrated line plus its
// persisted placeholder never renders as two boxes for one call.
export function deduplicateToolActionsByCallID(actions: ToolAction[]): ToolAction[] {
  const best = new Map<string, ToolAction>();
  const order: string[] = [];
  const unidentified: ToolAction[] = [];
  for (const action of actions) {
    if (!action.callID) {
      unidentified.push(action);
      continue;
    }
    const existing = best.get(action.callID);
    if (!existing) {
      best.set(action.callID, action);
      order.push(action.callID);
      continue;
    }
    const existingHasResult = existing.result != null;
    const candidateHasResult = action.result != null;
    if (candidateHasResult && !existingHasResult) {
      best.set(action.callID, action);
    }
  }
  return [...order.map((id) => best.get(id) as ToolAction), ...unidentified];
}

// Shared cold builder for terminal timelines without a live skeleton: dedups by preserved call
// identity, orders oldest-first, groups one tools segment per round, then trails uncovered prose.
export function buildSegmentsFromActionsAndText(
  actions: ToolAction[],
  text: string,
): ChatSegment[] {
  const deduped = deduplicateToolActionsByCallID(actions);
  const ordered = [...deduped].sort(compareToolActionsByRound);
  const built: ChatSegment[] = [];
  for (const group of groupToolActionsByRound(ordered)) {
    built.push({ kind: "tools" as const, actions: group });
  }
  const trailing = text.trim();
  // Avoid duplicating narration fallback lines already covered by structured actions: only
  // uncovered prose becomes a text segment.
  if (trailing.length > 0) {
    const covered = new Set(ordered.map((a) => a.callID).filter(Boolean));
    const uncovered = filterUncoveredText(trailing, covered);
    if (uncovered.length > 0) {
      built.push({ kind: "text" as const, text: uncovered });
    } else if (built.length === 0) {
      built.push({ kind: "text" as const, text: trailing });
    }
  }
  return built;
}

// Builds a terminal timeline from the streamed skeleton plus authoritative done
// actions: tool results merge by call identity while the streamed text order
// stays, so live and reload render the same interleaving without double-counting.
export function buildDoneSegments(
  snapshotSegments: ChatSegment[],
  doneToolActions: ToolAction[],
  doneText: string | undefined,
  snapshotText: string,
): ChatSegment[] {
  const dedupedDone = deduplicateToolActionsByCallID(doneToolActions);
  const byCallID = new Map<string, ToolAction>();
  for (const action of dedupedDone) {
    if (action.callID) byCallID.set(action.callID, action);
  }
  if (snapshotSegments.length > 0) {
    const merged = snapshotSegments.map((segment) => {
      if (segment.kind !== "tools") return segment;
      const refreshed = segment.actions.map((action) => {
        const authoritative = action.callID
          ? byCallID.get(action.callID)
          : undefined;
        return authoritative ? { ...authoritative } : { ...action };
      });
      // A narrated line plus its persisted twin share one identifier after the
      // backend preserves call IDs, so collapse repeats here as well.
      return {
        kind: "tools" as const,
        actions: deduplicateToolActionsByCallID(refreshed),
      };
    });
    // Done actions for calls never streamed (parked resumes) append as their own
    // round groups so the same turn timeline grows instead of dropping them.
    const streamedCallIDs = new Set(
      merged.flatMap((segment) =>
        segment.kind === "tools"
          ? segment.actions.map((action) => action.callID)
          : [],
      ),
    );
    const missing = dedupedDone.filter(
      (action) => action.callID && !streamedCallIDs.has(action.callID),
    );
    if (missing.length > 0) {
      const groups = groupToolActionsByRound(
        [...missing].sort(compareToolActionsByRound),
      );
      for (const group of groups) {
        merged.push({ kind: "tools" as const, actions: group });
      }
    }
    // The streamed skeleton already carries every round's prose in order; the terminal text repeats
    // only the final round, so preferring it blindly would discard intermediate narration.
    const hasStreamedText = merged.some(
      (segment) => segment.kind === "text" && segment.text.trim().length > 0,
    );
    const doneTrimmed =
      typeof doneText === "string" ? doneText.trim() : "";
    if (!hasStreamedText && doneTrimmed.length > 0) {
      merged.push({ kind: "text" as const, text: doneText as string });
    } else if (
      !hasStreamedText &&
      snapshotText.trim().length > 0 &&
      doneTrimmed.length === 0
    ) {
      merged.push({ kind: "text" as const, text: snapshotText });
    } else if (hasStreamedText && doneTrimmed.length > 0) {
      // A reloaded tab adopts mid-turn, so its streamed fragment misses every delta from before the
      // reload while the terminal frame carries the full reply.
      const streamedFlat = flatTextFromSegments(merged).trim();
      const hasToolSegments = merged.some(
        (segment) => segment.kind === "tools",
      );
      if (!hasToolSegments) {
        if (
          streamedFlat.length > 0 &&
          (doneTrimmed.startsWith(streamedFlat) ||
            (doneTrimmed.length > streamedFlat.length &&
              doneTrimmed.includes(streamedFlat)))
        ) {
          const nonText = merged.filter(
            (segment) => segment.kind !== "text",
          );
          return [
            ...nonText,
            { kind: "text" as const, text: doneText as string },
          ];
        }
      } else {
        // Multi-round turns interleave prose with tool batches, so only the final prose piece may
        // extend into the terminal copy.
        let lastTextIndex = -1;
        for (let index = merged.length - 1; index >= 0; index--) {
          const candidate = merged[index];
          if (
            candidate.kind === "text" &&
            candidate.text.trim().length > 0
          ) {
            lastTextIndex = index;
            break;
          }
        }
        if (lastTextIndex !== -1) {
          const lastText = (
            merged[lastTextIndex] as { kind: "text"; text: string }
          ).text.trim();
          if (
            lastText.length > 0 &&
            doneTrimmed.startsWith(lastText) &&
            doneTrimmed.length !== lastText.length
          ) {
            const next = [...merged];
            next[lastTextIndex] = {
              kind: "text" as const,
              text: doneText as string,
            };
            return next;
          }
        }
      }
    }
    return merged;
  }
  // No live skeleton (cold done): share the grouped builder with the REST path
  // so both order and cover-filter identically.
  return buildSegmentsFromActionsAndText(
    dedupedDone,
    doneText ?? snapshotText ?? "",
  );
}

// Builds REST fallback timelines without a live skeleton: round groups in order
// then the terminal text, so polling clients agree with streaming ones.
export function buildRestSegments(actions: ToolAction[], text: string): ChatSegment[] {
  return buildSegmentsFromActionsAndText(actions, text);
}

// Validates a tool result before it enters turn state: the engine always
// emits the call identifier, content, and error flag together, so a partial
// object must never render as a completed execution.
export function isToolResult(value: unknown): value is ToolResult {
  if (!isRecord(value)) return false;
  return (
    typeof value.toolCallID === "string" &&
    typeof value.content === "string" &&
    typeof value.isError === "boolean"
  );
}

// Validates a tool action before it enters message or turn state, keeping
// history rendering honest about which executions actually ran.
export function isToolAction(value: unknown): value is ToolAction {
  if (!isRecord(value)) return false;
  if (typeof value.toolName !== "string" || value.toolName.trim().length === 0)
    return false;
  if (typeof value.callID !== "string" || value.callID.trim().length === 0)
    return false;
  if (typeof value.argumentsJSON !== "string") return false;
  const result = value.result;
  return result == null || isToolResult(result);
}

// Normalizes a completion instant from either wire shape the engine emits (ISO-8601 strings from
// Vapor versus Unix seconds as JSON numbers from SQLite persistence) into milliseconds since the
// epoch.
export function normalizeCompletedAtMs(value: unknown): number | undefined {
  if (value == null) return undefined;
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const parsed = parseRunTimestamp(value).getTime();
  if (!Number.isFinite(parsed) || parsed <= 0) return undefined;
  return parsed;
}

// Indexes server-derived per-message groups by parent message ID, oldest message first.
export function toolActionMap(
  groups: SessionMessageToolActions[] | undefined,
): Map<string, ToolAction[]> {
  const map = new Map<string, ToolAction[]>();
  for (const group of groups ?? []) {
    const deduped = deduplicateToolActionsByCallID([...(group.actions ?? [])]);
    map.set(group.messageID, sortToolActionsByRound(deduped));
  }
  return map;
}

// Indexes server-derived per-message completion times by parent message ID so reloads reconcile to
// the same server instant that live done frames advertise.
export function toolActionCompletedAtMap(
  groups: SessionMessageToolActions[] | undefined,
): Map<string, number> {
  const map = new Map<string, number>();
  for (const group of groups ?? []) {
    const normalized = normalizeCompletedAtMs(group.completedAt);
    if (normalized != null) map.set(group.messageID, normalized);
  }
  return map;
}

// Groups one message's authoritative actions into chronological tools segments,
// oldest round first, so a multi-call note never collapses rounds into one bucket.
export function toolsSegmentsForMessage(actions: ToolAction[]): ChatSegment[] {
  const ordered = [...actions].sort(compareToolActionsByRound);
  return groupToolActionsByRound(ordered).map((group) => ({
    kind: "tools" as const,
    actions: group,
  }));
}

export function reconstructMessages(
  rawMessages: Array<{
    id?: string;
    role: string;
    content: string;
    reasoning?: string | null;
    toolCallID?: string | null;
    isError?: boolean | null;
    createdAt?: string | number;
  }> = [],
  // Authoritative server-derived actions keyed by parent message ID (from `GET /sessions/:id/tool-
  // actions` via `toolActionMap`).
  structuredByMessageID?: Map<string, ToolAction[]> | Record<string, ToolAction[]>,
  // Per-message completion times from the same tool-actions payload (via
  // `toolActionCompletedAtMap`).
  completedAtByMessageID?: Map<string, number> | Record<string, number>,
): MessageItem[] {
  const getStructured = (messageID: string | undefined): ToolAction[] | undefined => {
    if (!structuredByMessageID || !messageID) return undefined;
    if (structuredByMessageID instanceof Map) {
      return structuredByMessageID.get(messageID);
    }
    return (structuredByMessageID as Record<string, ToolAction[]>)[messageID];
  };
  const getStructuredCompletedAt = (
    messageID: string | undefined,
  ): number | undefined => {
    if (!completedAtByMessageID || !messageID) return undefined;
    const raw: unknown =
      completedAtByMessageID instanceof Map
        ? completedAtByMessageID.get(messageID)
        : (completedAtByMessageID as Record<string, number>)[messageID];
    return typeof raw === "number" &&
      Number.isFinite(raw) &&
      raw > 0
      ? raw
      : undefined;
  };
  // Latest completion across the notes folded into one turn, so a resumed
  // parked batch reports its final synthesis rather than the first park.
  const mergeCompletedAt = (
    current: number | undefined,
    candidate: number | undefined,
  ): number | undefined => {
    if (candidate == null) return current;
    if (current == null) return candidate;
    return Math.max(current, candidate);
  };
  // Flushes one turn's ordered timeline while keeping flat summaries for legacy
  // readers: text joins text segments and actions flatten tool batches in order.
  const flushTurn = (
    segments: ChatSegment[],
    id: string,
    completedAt?: number,
    isError?: boolean,
  ): MessageItem => {
    const text = flatTextFromSegments(segments);
    const flat = flatActionsFromSegments(segments);
    return {
      id,
      role: "assistant",
      text,
      toolActions: flat.length > 0 ? flat : undefined,
      segments: [...segments],
      ...(completedAt != null ? { completedAt } : {}),
      ...(isError ? { isError: true } : {}),
    };
  };
  const result: MessageItem[] = [];
  let pendingSegments: ChatSegment[] = [];
  let pendingCompletedAt: number | undefined;

  for (let i = 0; i < rawMessages.length; i++) {
    const m = rawMessages[i];
    if (m.role === "user") {
      if (pendingSegments.length > 0) {
        result.push(
          flushTurn(pendingSegments, `interim_${i}`, pendingCompletedAt),
        );
        pendingSegments = [];
        pendingCompletedAt = undefined;
      }
      result.push({
        id: m.id || `${m.createdAt || i}`,
        role: "user",
        text: m.content,
      });
      continue;
    }

    if (m.role === "tool") {
      continue;
    }

    if (m.role === "assistant") {
      const isInterimWaiting = (() => {
        if (!m.content.trim().startsWith(WAITING_PREFIX)) return false;
        for (let j = i + 1; j < rawMessages.length; j++) {
          const next = rawMessages[j];
          if (next.role === "user") break;
          if (next.role === "tool") return true;
          if (next.role === "assistant" && !next.content.trim().startsWith(WAITING_PREFIX)) {
            return true;
          }
        }
        return false;
      })();
      if (isInterimWaiting) {
        continue;
      }

      // Restore persisted reasoning / thought block to the turn timeline before actions or prose.
      if (
        typeof m.reasoning === "string" &&
        m.reasoning.trim().length > 0
      ) {
        const trimmedReasoning = m.reasoning.trim();
        const alreadyHasReasoning = pendingSegments.some(
          (s) => s.kind === "thought" && s.text.trim() === trimmedReasoning,
        );
        if (!alreadyHasReasoning) {
          pendingSegments.push({
            kind: "thought",
            text: m.reasoning,
          });
        }
      }

      // Completion for this note prefers the persisted history instant so
      // reloads agree with live server times; the tool-actions timestamp only
      // fills gaps where history omits the creation time.
      const noteCompletedAt = mergeCompletedAt(
        normalizeCompletedAtMs(m.createdAt),
        getStructuredCompletedAt(m.id),
      );
      pendingCompletedAt = mergeCompletedAt(pendingCompletedAt, noteCompletedAt);
      const structured = getStructured(m.id);
      if (structured && structured.length > 0) {
        // A narrated line plus its persisted twin share one preserved identifier,
        // so collapse repeats before covering text to leave a single Done box.
        const dedupedStructured = deduplicateToolActionsByCallID(structured);
        const coveredCallIDs = new Set(
          dedupedStructured.map((action) => action.callID).filter(Boolean),
        );
        const uncovered = filterUncoveredText(m.content, coveredCallIDs);
        if (uncovered.length > 0) {
          pendingSegments.push({
            kind: "text",
            text: uncovered,
          });
        }
        pendingSegments.push(...toolsSegmentsForMessage(dedupedStructured));
        if (m.isError) {
          result.push(
            flushTurn(
              pendingSegments,
              m.id || `${m.createdAt || i}`,
              pendingCompletedAt,
              true,
            ),
          );
          pendingSegments = [];
          pendingCompletedAt = undefined;
        }
        continue;
      }
      const leftoverLines: string[] = [];
      const normalizedBareContent = normalizeLineEndings(m.content);
      for (const rawLine of normalizedBareContent.split("\n")) {
        if (!rawLine.trim()) continue;
        leftoverLines.push(rawLine);
      }
      if (leftoverLines.length > 0) {
        pendingSegments.push({
          kind: "text",
          text: leftoverLines.join("\n").trim(),
        });
        result.push(
          flushTurn(
            pendingSegments,
            m.id || `${m.createdAt || i}`,
            pendingCompletedAt,
            m.isError ?? false,
          ),
        );
        pendingSegments = [];
        pendingCompletedAt = undefined;
      } else if (pendingSegments.length > 0) {
        continue;
      } else {
        continue;
      }
    }
  }

  if (pendingSegments.length > 0) {
    const lastRaw = rawMessages[rawMessages.length - 1];
    result.push(
      flushTurn(
        pendingSegments,
        `trailing_${rawMessages.length}`,
        pendingCompletedAt,
        lastRaw?.isError ?? false,
      ),
    );
  }

  return result.filter(
    (m) => m.text.trim().length > 0 || (m.toolActions && m.toolActions.length > 0) || m.isError
  );
}

// Collects every tool action a rendered transcript shows, in display order: persisted messages in
// order, then the in-flight turn, which always renders last.
export function renderedToolActions(
  messages: MessageItem[],
  inFlightTurn: InFlightTurn | null,
): ToolAction[] {
  const actions: ToolAction[] = [];
  const scan = (list: ToolAction[]) => {
    for (const action of list) actions.push(action);
  };
  for (const message of messages) {
    if (message.role !== "assistant") continue;
    if (message.segments && message.segments.length > 0) {
      for (const segment of message.segments) {
        if (segment.kind === "tools") scan(segment.actions);
      }
    } else if (message.toolActions) {
      scan(message.toolActions);
    }
  }
  if (inFlightTurn) {
    if (inFlightTurn.segments.length > 0) {
      for (const segment of inFlightTurn.segments) {
        if (segment.kind === "tools") scan(segment.actions);
      }
    } else {
      scan(inFlightTurn.toolActions);
    }
  }
  return actions;
}
