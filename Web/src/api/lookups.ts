// Rune Weaver Dashboard — Mailbox and calendar lookup fetches plus cache.
import { ApiError, fetchJson } from "./http";
import { isRecord } from "../typeGuards";

export interface CalendarLookup {
  id: string;
  title: string;
}

const CALENDARS_CACHE_KEY = "rw.calendars";

function mailboxCacheKey(account: string): string {
  return `rw.mailboxes.${account}`;
}

interface CacheEnvelope {
  items: unknown[];
  savedAt: number;
}

// Returns the parsed envelope or null when storage is missing or malformed.
function readEnvelope(key: string): CacheEnvelope | null {
  try {
    if (typeof window === "undefined" || !window.localStorage) return null;
    const raw = window.localStorage.getItem(key);
    if (!raw) return null;
    const parsed: unknown = JSON.parse(raw);
    if (!isRecord(parsed)) return null;
    if (!Array.isArray(parsed.items)) return null;
    if (typeof parsed.savedAt !== "number" || !Number.isFinite(parsed.savedAt)) {
      return null;
    }
    return { items: parsed.items as unknown[], savedAt: parsed.savedAt };
  } catch {
    return null;
  }
}

// Persists a successful lookup; quota or private-mode failures stay uncached.
function writeEnvelope(key: string, items: unknown[]): void {
  try {
    if (typeof window === "undefined" || !window.localStorage) return;
    window.localStorage.setItem(key, JSON.stringify({ items, savedAt: Date.now() }));
  } catch {
    // Best-effort cache only.
  }
}

function isCalendarLookup(value: unknown): value is CalendarLookup {
  if (!isRecord(value)) return false;
  return typeof value.id === "string" && typeof value.title === "string";
}

export async function fetchMailboxes(account: string): Promise<string[]> {
  const path = `/email/accounts/${encodeURIComponent(account)}/mailboxes`;
  const data = await fetchJson<unknown>(path);
  if (!isRecord(data) || !Array.isArray(data.mailboxes)) {
    throw new ApiError("Invalid mailboxes response", 0);
  }
  if (!data.mailboxes.every((entry) => typeof entry === "string")) {
    throw new ApiError("Invalid mailboxes response", 0);
  }
  const mailboxes = data.mailboxes as string[];
  writeEnvelope(mailboxCacheKey(account), mailboxes);
  return [...mailboxes];
}

export async function fetchCalendars(): Promise<CalendarLookup[]> {
  const data = await fetchJson<unknown>("/calendars");
  if (!isRecord(data) || !Array.isArray(data.calendars)) {
    throw new ApiError("Invalid calendars response", 0);
  }
  if (!data.calendars.every(isCalendarLookup)) {
    throw new ApiError("Invalid calendars response", 0);
  }
  const calendars = (data.calendars as CalendarLookup[]).map((entry) => ({
    id: entry.id,
    title: entry.title,
  }));
  writeEnvelope(CALENDARS_CACHE_KEY, calendars);
  return calendars;
}

// Reads the last successful mailbox list, or null when absent or malformed.
export function readCachedMailboxes(account: string): string[] | null {
  const envelope = readEnvelope(mailboxCacheKey(account));
  if (!envelope) return null;
  if (!envelope.items.every((entry) => typeof entry === "string")) return null;
  return [...(envelope.items as string[])];
}

// Reads the last successful calendar list, or null when absent or malformed.
export function readCachedCalendars(): CalendarLookup[] | null {
  const envelope = readEnvelope(CALENDARS_CACHE_KEY);
  if (!envelope) return null;
  if (!envelope.items.every(isCalendarLookup)) return null;
  return (envelope.items as CalendarLookup[]).map((entry) => ({
    id: entry.id,
    title: entry.title,
  }));
}

// Age of the cached mailbox list, or null when no valid entry exists.
export function mailboxCacheAgeMs(account: string): number | null {
  if (readCachedMailboxes(account) === null) return null;
  const envelope = readEnvelope(mailboxCacheKey(account));
  if (!envelope) return null;
  return Date.now() - envelope.savedAt;
}

// Age of the cached calendar list, or null when no valid entry exists.
export function calendarCacheAgeMs(): number | null {
  if (readCachedCalendars() === null) return null;
  const envelope = readEnvelope(CALENDARS_CACHE_KEY);
  if (!envelope) return null;
  return Date.now() - envelope.savedAt;
}
