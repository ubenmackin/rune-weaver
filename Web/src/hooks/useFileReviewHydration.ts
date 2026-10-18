// Rune Weaver Dashboard — Batched review-ledger hydration for rendered write cards.

import { useEffect, useState } from "react";
import { getFileReviewStates, type FileReviewStates } from "../api";

// Upper bound on paths per request, mirroring the engine route's validation
// (1 to 200 non-empty paths): a longer card set splits into consecutive
// requests instead of failing the whole hydration with one 400.
export const MAX_REVIEW_STATUS_PATHS = 200;

// One rendered write card in a surface's batch. `cardKey` is the card's stable
// identity (its call ID), so a replacement write for an existing path starts a
// fresh batch instead of inheriting the previous card's ledger posture.
export interface WriteReviewHydrationTarget {
  kind: "staged" | "live";
  path: string;
  cardKey: string;
}

// Canonical key for one rendered card set: sorted so reordering the render
// list never refetches, and NUL-separated because a POSIX path cannot contain
// NUL, so crafted values cannot collapse two distinct targets into one key.
export function writeReviewHydrationKey(
  targets: WriteReviewHydrationTarget[],
): string {
  return targets
    .map((target) => `${target.kind}\u0000${target.cardKey}\u0000${target.path}`)
    .sort()
    .join("\u0001");
}

export function useFileReviewHydration(
  targets: WriteReviewHydrationTarget[],
): FileReviewStates | null {
  const requestKey = writeReviewHydrationKey(targets);
  const [resolved, setResolved] = useState<{
    key: string;
    states: FileReviewStates;
  } | null>(null);
  // Adjusts the tracked key during render (before children commit) so a card set that changes --
  // including one that flips away and later returns -- never serves its previous key's states: the
  // old map drops in the same render, and the changed set reads pending until its own batch settles.
  const [trackedKey, setTrackedKey] = useState(requestKey);
  if (trackedKey !== requestKey) {
    setTrackedKey(requestKey);
    setResolved(null);
  }

  useEffect(() => {
    if (!requestKey) return;
    // Deduplicate so sibling cards for one path never repeat it in the batch;
    // blank paths are skipped because the route rejects any blank entry and a
    // single malformed envelope must not poison the surface's whole hydration.
    const paths: string[] = [];
    const seen = new Set<string>();
    for (const target of targets) {
      if (!target.path || seen.has(target.path)) continue;
      seen.add(target.path);
      paths.push(target.path);
    }
    if (paths.length === 0) return;
    const chunks: string[][] = [];
    for (let index = 0; index < paths.length; index += MAX_REVIEW_STATUS_PATHS) {
      chunks.push(paths.slice(index, index + MAX_REVIEW_STATUS_PATHS));
    }
    const controller = new AbortController();
    let cancelled = false;
    Promise.all(
      chunks.map((chunk) => getFileReviewStates(chunk, controller.signal)),
    )
      .then((results) => {
        if (cancelled) return;
        const states: FileReviewStates = { stagedStates: {}, liveStates: {} };
        for (const result of results) {
          Object.assign(states.stagedStates, result.stagedStates);
          Object.assign(states.liveStates, result.liveStates);
        }
        setResolved({ key: requestKey, states });
      })
      .catch(() => {
        // Best-effort hydration: a failed batch leaves the pending UI intact
        // and only a later card-set change re-reads the ledger.
      });
    return () => {
      cancelled = true;
      controller.abort();
    };
    // `targets` is intentionally not a dependency: `requestKey` is its canonical projection, so a
    // re-render that merely rebuilds the array (streaming text, unrelated state) never re-requests
    // while the rendered card set itself is unchanged.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [requestKey]);

  // Report states only for the batch matching the rendered card set: a stale resolved map from an
  // earlier set must never hydrate a newly mounted card while its own batch is in flight or failed.
  return resolved && resolved.key === requestKey && trackedKey === requestKey
    ? resolved.states
    : null;
}
