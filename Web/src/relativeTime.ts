// Rune Weaver Dashboard — Shared relative-time ladders for elapsed and countdown labels.

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

// Future-tense countdown label on the same granularity ladder so remaining time reads with
// identical steps as elapsed time.
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
