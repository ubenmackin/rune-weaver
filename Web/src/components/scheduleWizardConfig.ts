// Rune Weaver Dashboard — Schedule wizard presets, intervals, and pure timing helpers.
export type TriggerType = "cron" | "email" | "messages" | "calendar";

export interface CronPreset {
  id: string;
  label: string;
  cron: string;
  description: string;
}

export const CRON_PRESETS: CronPreset[] = [
  {
    id: "15m",
    label: "Every 15 Minutes",
    cron: "*/15 * * * *",
    description: "Fires repeatedly every 15 minutes throughout the day.",
  },
  {
    id: "hourly",
    label: "Hourly",
    cron: "0 * * * *",
    description: "Fires at the top of every hour.",
  },
  {
    id: "daily-8am",
    label: "Daily at 8:00 AM",
    cron: "0 8 * * *",
    description: "Fires once a day every morning at 8:00 AM local time.",
  },
  {
    id: "weekdays-9am",
    label: "Weekdays at 9:00 AM",
    cron: "0 9 * * 1-5",
    description: "Fires Monday through Friday at 9:00 AM.",
  },
  {
    id: "weekly-mon",
    label: "Weekly (Monday 8 AM)",
    cron: "0 8 * * 1",
    description: "Fires once per week every Monday morning at 8:00 AM.",
  },
  {
    id: "custom",
    label: "Custom Cron",
    cron: "",
    description: "Specify any standard 5-field cron expression.",
  },
];

export const POLL_INTERVAL_PRESETS = [60, 300, 900, 1800, 3600];

// Wizard poll cadence bounds so a typo cannot sweep minutes of meetings.
export const CHECK_INTERVAL_MIN_SECONDS = 60;
export const CHECK_INTERVAL_MAX_SECONDS = 86400;

export const PROMPT_TEMPLATES = [
  {
    label: "Inbox Summary",
    prompt:
      "Summarize all new emails received since the last run, categorized by sender and importance.",
  },
  {
    label: "Action Items Digest",
    prompt:
      "Scan incoming messages for required follow-ups, pending questions, or deadlines, and list them clearly.",
  },
  {
    label: "Pre-Meeting Prep",
    prompt:
      "Review the attendees, agenda notes, and relevant recent history to generate a comprehensive pre-meeting brief.",
  },
  {
    label: "System Status Brief",
    prompt:
      "Check recent system alerts and logs, and provide a brief status overview of service health.",
  },
];

// Renders a cache age as a short human span for the stale badge.
export function formatCacheAge(ageMs: number | null): string {
  if (ageMs == null || !Number.isFinite(ageMs) || ageMs < 0) return "";
  const seconds = Math.floor(ageMs / 1000);
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}

// Strict decimal whole seconds; null means the input is not submittable.
export function parsePollIntervalSeconds(text: string): number | null {
  const trimmed = text.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value) || value <= 0) return null;
  return value;
}

export function validateCheckInterval(text: string): string | null {
  const parsed = parsePollIntervalSeconds(text);
  if (
    parsed == null ||
    parsed < CHECK_INTERVAL_MIN_SECONDS ||
    parsed > CHECK_INTERVAL_MAX_SECONDS
  ) {
    return `Check Interval must be between ${CHECK_INTERVAL_MIN_SECONDS} and ${CHECK_INTERVAL_MAX_SECONDS} seconds.`;
  }
  return null;
}

export function effectiveCron(selectedPreset: string, customCron: string): string {
  if (selectedPreset === "custom") {
    return customCron.trim();
  }
  const preset = CRON_PRESETS.find((p) => p.id === selectedPreset);
  return preset?.cron ?? "0 8 * * *";
}
