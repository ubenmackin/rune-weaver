// Rune Weaver Dashboard — Greeting helpers with time-of-day copy.
import { MAX_TIMER_DELAY_MS } from "../PersonaAvatar";

// Rendered avatar edge: large enough to read the sprite's eyes and state ring
// at a glance, without overwhelming the headline it shares a row with.
export const GREETING_AVATAR_SIZE = 112;

// Caption budget for the in-flight title: one line beside the name, so a runaway
// scheduler message truncates instead of pushing the greeting row taller.
export const WORKING_TITLE_LIMIT = 60;

// Live poll cadence while work is in flight, mirroring the Working Right Now
// stream so the caption title stays fresh without extra network.
export const GREETING_POLL_MS = Math.min(4000, MAX_TIMER_DELAY_MS);

export function getGreeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

// Shortens a run title to one caption line. Truncation keeps the raw message
// intact elsewhere; the ellipsis marks the cut so a clipped title never reads as full.
export function truncateWorkingTitle(title: string): string {
  const trimmed = title.trim();
  if (trimmed.length <= WORKING_TITLE_LIMIT) return trimmed;
  return `${trimmed.slice(0, WORKING_TITLE_LIMIT).trimEnd()}…`;
}
