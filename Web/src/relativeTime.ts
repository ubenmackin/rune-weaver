// Rune Weaver Dashboard — Shared relative-time ladders for elapsed and countdown labels.
// Chat footers and approval grant cards previously carried their own copies of
// the seconds/minutes/hours/days ladder, so a granularity tweak in one place
// left the other reading differently. Centralizing both tenses here keeps every
// "ago" and "in" label on the same granularity by construction.

// Past-tense elapsed label sharing one granularity ladder across the dashboard.
// Sub-second and future-skewed deltas collapse to "just now" so fresh events
// never render as "0s ago" and clock skew never surfaces as a negative countdown.
export function formatRelativeAgo(diffMs: number): string {
  if (!Number.isFinite(diffMs) || diffMs < 1000) return "just now";
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHour = Math.floor(diffMin / 60);
  if (diffHour < 24) return `${diffHour}h ago`;
  const diffDays = Math.floor(diffHour / 24);
  return `${diffDays}d ago`;
}

// Future-tense countdown label on the same granularity ladder so remaining time
// reads with identical steps as elapsed time. Sub-second deltas floor to
// "in 1s" so imminent expiries never render "in 0s"; callers keep owning
// expired/empty sentinels just like the past-tense branch above.
export function formatRelativeIn(diffMs: number): string {
  if (!Number.isFinite(diffMs) || diffMs < 1000) return "in 1s";
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return `in ${diffSec}s`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `in ${diffMin}m`;
  const diffHour = Math.floor(diffMin / 60);
  if (diffHour < 24) return `in ${diffHour}h`;
  const diffDays = Math.floor(diffHour / 24);
  return `in ${diffDays}d`;
}
