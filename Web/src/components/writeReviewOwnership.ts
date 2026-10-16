// Rune Weaver Dashboard — Newest-write ownership and hydration-target scan for
// rendered files.write cards.

import type { ToolAction } from "../api";
import { writeReviewKey, writeReviewTarget } from "./DiffCard";
import type { WriteReviewHydrationTarget } from "../hooks/useFileReviewHydration";

// Newest-write ownership across one surface's rendered action sequence: the last files.write card
// per (path, envelope kind) owns the review, and every earlier card for the same key shows a note
// instead of controls so it cannot race the newer write's ledger row.
export function collectWriteReviewOwners(
  actions: Iterable<ToolAction>,
): Map<string, ToolAction> {
  const owners = new Map<string, ToolAction>();
  for (const action of actions) {
    if (action.toolName !== "files.write") continue;
    const key = action.result ? writeReviewKey(action.result) : null;
    if (key) owners.set(key, action);
  }
  return owners;
}

// One hydration target per rendered write card, keyed by call identity so a
// replacement write for an existing path starts a fresh batch instead of
// inheriting the previous card's ledger posture.
export function collectWriteHydrationTargets(
  actions: Iterable<ToolAction>,
): WriteReviewHydrationTarget[] {
  const targets: WriteReviewHydrationTarget[] = [];
  const seen = new Set<string>();
  for (const action of actions) {
    if (action.toolName !== "files.write") continue;
    const target = action.result ? writeReviewTarget(action.result) : null;
    if (!target) continue;
    const identity = `${target.kind}\u0000${target.path}\u0000${action.callID}`;
    if (seen.has(identity)) continue;
    seen.add(identity);
    targets.push({ kind: target.kind, path: target.path, cardKey: action.callID });
  }
  return targets;
}

// True when this card is not shadowed by a newer write for the same path and
// envelope kind; non-write rows and unreviewable envelopes are never gated.
export function isWriteReviewOwner(
  owners: Map<string, ToolAction>,
  action: ToolAction,
): boolean {
  if (action.toolName !== "files.write") return true;
  const key = action.result ? writeReviewKey(action.result) : null;
  return key === null || owners.get(key) === action;
}
