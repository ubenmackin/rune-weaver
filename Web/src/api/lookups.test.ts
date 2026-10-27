// Rune Weaver Dashboard — Lookup cache client tests.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  calendarCacheAgeMs,
  fetchCalendars,
  fetchMailboxes,
  mailboxCacheAgeMs,
  readCachedCalendars,
  readCachedMailboxes,
} from "./lookups";
import { ApiError } from "./http";
import { jsonResponse } from "../test-utils/http";

beforeEach(() => {
  vi.unstubAllGlobals();
  window.localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  window.localStorage.clear();
});

describe("fetchMailboxes", () => {
  it("hits the exact encoded path and caches the envelope shape", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ mailboxes: ["INBOX", "Sent"], delimiter: "/" }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const result = await fetchMailboxes("me@example.com");
    expect(result).toEqual(["INBOX", "Sent"]);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/email/accounts/me%40example.com/mailboxes");
    const raw = window.localStorage.getItem("rw.mailboxes.me@example.com");
    expect(raw).not.toBeNull();
    const parsed = JSON.parse(raw as string) as { items: unknown; savedAt: unknown };
    expect(parsed.items).toEqual(["INBOX", "Sent"]);
    expect(typeof parsed.savedAt).toBe("number");
  });

  it("encodes reserved characters in the account segment", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ mailboxes: ["INBOX"], delimiter: null }));
    vi.stubGlobal("fetch", fetchMock);
    await fetchMailboxes("a/b c");
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/email/accounts/a%2Fb%20c/mailboxes");
  });

  it("passes the server message through and skips the cache write", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ error: "mailbox fetch failed" }, 502)),
    );
    const failure = await fetchMailboxes("me@example.com").catch((err) => err);
    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message).toContain("mailbox fetch failed");
    expect(window.localStorage.getItem("rw.mailboxes.me@example.com")).toBeNull();
  });

  it("rejects a drifted payload without caching", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse({ mailboxes: "INBOX" })));
    await expect(fetchMailboxes("me@example.com")).rejects.toBeInstanceOf(ApiError);
    expect(window.localStorage.getItem("rw.mailboxes.me@example.com")).toBeNull();
  });
});

describe("fetchCalendars", () => {
  it("hits the exact calendars path and caches the envelope shape", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({ calendars: [{ id: "1", title: "Home" }] }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const result = await fetchCalendars();
    expect(result).toEqual([{ id: "1", title: "Home" }]);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [path] = fetchMock.mock.calls[0] as unknown as [string];
    expect(path).toBe("/calendars");
    const raw = window.localStorage.getItem("rw.calendars");
    expect(raw).not.toBeNull();
    const parsed = JSON.parse(raw as string) as { items: unknown; savedAt: unknown };
    expect(parsed.items).toEqual([{ id: "1", title: "Home" }]);
    expect(typeof parsed.savedAt).toBe("number");
  });

  it("passes the server message through and skips the cache write", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ reason: "calendar fetch failed" }, 502)),
    );
    const failure = await fetchCalendars().catch((err) => err);
    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message).toContain("calendar fetch failed");
    expect(window.localStorage.getItem("rw.calendars")).toBeNull();
  });
});

describe("cached reads", () => {
  it("returns null when nothing is cached", () => {
    expect(readCachedMailboxes("me@example.com")).toBeNull();
    expect(readCachedCalendars()).toBeNull();
    expect(mailboxCacheAgeMs("me@example.com")).toBeNull();
    expect(calendarCacheAgeMs()).toBeNull();
  });

  it("returns null on corrupt envelopes", () => {
    window.localStorage.setItem("rw.mailboxes.me@example.com", "not-json{{{");
    window.localStorage.setItem("rw.calendars", JSON.stringify({ items: "nope" }));
    expect(readCachedMailboxes("me@example.com")).toBeNull();
    expect(readCachedCalendars()).toBeNull();
    expect(mailboxCacheAgeMs("me@example.com")).toBeNull();
    expect(calendarCacheAgeMs()).toBeNull();
  });

  it("returns null when cached items have the wrong element shape", () => {
    window.localStorage.setItem(
      "rw.mailboxes.me@example.com",
      JSON.stringify({ items: ["INBOX", 42], savedAt: Date.now() }),
    );
    window.localStorage.setItem(
      "rw.calendars",
      JSON.stringify({ items: [{ id: "1" }], savedAt: Date.now() }),
    );
    expect(readCachedMailboxes("me@example.com")).toBeNull();
    expect(readCachedCalendars()).toBeNull();
  });

  it("computes cache age from the stored timestamp", () => {
    const now = Date.now();
    window.localStorage.setItem(
      "rw.mailboxes.me@example.com",
      JSON.stringify({ items: ["INBOX"], savedAt: now - 5000 }),
    );
    window.localStorage.setItem(
      "rw.calendars",
      JSON.stringify({ items: [{ id: "1", title: "Home" }], savedAt: now - 9000 }),
    );
    const mailboxAge = mailboxCacheAgeMs("me@example.com");
    const calendarAge = calendarCacheAgeMs();
    expect(mailboxAge).not.toBeNull();
    expect(calendarAge).not.toBeNull();
    expect(Math.abs((mailboxAge as number) - 5000)).toBeLessThan(1000);
    expect(Math.abs((calendarAge as number) - 9000)).toBeLessThan(1000);
    expect(readCachedMailboxes("me@example.com")).toEqual(["INBOX"]);
    expect(readCachedCalendars()).toEqual([{ id: "1", title: "Home" }]);
  });
});
