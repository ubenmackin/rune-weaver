// Rune Weaver Dashboard — Grapheme-safe live text buffer for streaming Markdown.
//
// Single owner for the live grapheme hold: deltas arrive in arbitrary UTF-16
// splits, so the trailing incomplete cluster stays in `held` while only
// complete clusters advance `committed`. The live bubble renders `committed`
// through MarkdownText while the full turn text stays lossless as
// `committed + held`.

type SegmenterConstructor = new (
  locales?: string | string[],
  options?: { granularity: string },
) => {
  segment(input: string): Iterable<{ segment: string }>;
};

// Resolves one grapheme segmenter per call. A null result means the runtime
// has no Segmenter, so callers fall back to code-point append. A fresh
// instance per delta keeps the Segmenter-absent fallback observable.
function getSegmenter(): {
  segment(input: string): Iterable<{ segment: string }>;
} | null {
  try {
    const ctor = (Intl as unknown as { Segmenter?: unknown }).Segmenter;
    if (typeof ctor !== "function") {
      return null;
    }
    return new (ctor as SegmenterConstructor)(undefined, {
      granularity: "grapheme",
    });
  } catch {
    return null;
  }
}

// True for one regional indicator (a lone flag half). A paired flag is twice
// as long, so only the single form needs to wait for its partner.
function isSingleRegionalIndicator(cluster: string): boolean {
  if (cluster.length !== 2) return false;
  return (
    cluster.charCodeAt(0) === 0xd83c &&
    cluster.charCodeAt(1) >= 0xdde6 &&
    cluster.charCodeAt(1) <= 0xddff
  );
}

// True when the trailing cluster may still grow with the next delta, so it
// must stay held instead of rendering. Complete prose, standalone emoji, and
// paired flags commit immediately; only provably splittable tails hold: a
// dangling high surrogate, any lone surrogate cluster, a trailing joiner, a
// lone regional indicator, or a dangling carriage return awaiting line feed.
function isHoldableTail(tail: string, lastCluster: string): boolean {
  if (!tail) return false;
  const tailLast = tail.charCodeAt(tail.length - 1);
  if (tailLast >= 0xd800 && tailLast <= 0xdbff) return true;
  if (
    lastCluster.length === 1 &&
    lastCluster.charCodeAt(0) >= 0xd800 &&
    lastCluster.charCodeAt(0) <= 0xdfff
  ) {
    return true;
  }
  if (tail.charCodeAt(tail.length - 1) === 0x200d) return true;
  if (isSingleRegionalIndicator(lastCluster)) return true;
  if (tail.charCodeAt(tail.length - 1) === 0x0d) return true;
  return false;
}

// Buffers one streamed delta by grapheme cluster. The tail under review is
// always `held + delta`; complete clusters join `committed` while at most one
// trailing incomplete cluster stays in `held`. Zero loss holds on every path:
// `committed + held` after the call always equals `committed + held + delta`
// from before, so the terminal frame converges by construction.
export function appendLiveDelta(
  committed: string,
  held: string,
  delta: string,
): { committed: string; held: string } {
  const safeCommitted = typeof committed === "string" ? committed : "";
  const safeHeld = typeof held === "string" ? held : "";
  const safeDelta = typeof delta === "string" ? delta : "";
  if (!safeHeld && !safeDelta) return { committed: safeCommitted, held: "" };
  const tail = safeHeld + safeDelta;
  if (!tail) return { committed: safeCommitted, held: "" };
  const segmenter = getSegmenter();
  if (!segmenter) {
    return { committed: safeCommitted + tail, held: "" };
  }
  let clusters: string[];
  try {
    clusters = Array.from(segmenter.segment(tail), (entry) => entry.segment);
  } catch {
    return { committed: safeCommitted + tail, held: "" };
  }
  if (clusters.length === 0) return { committed: safeCommitted, held: "" };
  if (clusters.length === 1) {
    if (isHoldableTail(tail, clusters[0])) {
      return { committed: safeCommitted, held: tail };
    }
    return { committed: safeCommitted + tail, held: "" };
  }
  const last = clusters[clusters.length - 1];
  if (isHoldableTail(tail, last)) {
    return {
      committed: safeCommitted + clusters.slice(0, -1).join(""),
      held: last,
    };
  }
  return { committed: safeCommitted + tail, held: "" };
}
