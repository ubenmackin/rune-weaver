// Rune Weaver Dashboard — Settings search index matcher and highlight coverage.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  highlightSettingTarget,
  searchSettingsItems,
  SETTINGS_SEARCH_ITEMS,
} from "./settingsSearchIndex";

describe("searchSettingsItems", () => {
  it("covers every tab twice within the entry budget", () => {
    expect(SETTINGS_SEARCH_ITEMS.length).toBeLessThanOrEqual(40);
    const counts = new Map<string, number>();
    for (const item of SETTINGS_SEARCH_ITEMS) {
      counts.set(item.tab, (counts.get(item.tab) ?? 0) + 1);
      expect(item.keywords).toBe(item.keywords.toLowerCase());
    }
    for (const tab of [
      "access",
      "providers",
      "persona",
      "goals",
      "engine",
      "tools",
      "indexing",
      "search",
      "email",
      "security",
      "network",
      "memory",
      "voice",
    ]) {
      expect(counts.get(tab) ?? 0).toBeGreaterThanOrEqual(2);
    }
  });

  it("matches labels and keywords case-insensitively", () => {
    const lower = searchSettingsItems("provider");
    const upper = searchSettingsItems("PROVIDER");
    expect(lower.length).toBeGreaterThan(0);
    expect(upper.map((item) => item.id)).toEqual(
      lower.map((item) => item.id),
    );
    expect(lower.some((item) => item.targetId === "default-provider")).toBe(
      true,
    );
  });

  it("ranks label substring above keyword-only substring", () => {
    const results = searchSettingsItems("provider");
    const defaultIndex = results.findIndex(
      (item) => item.id === "providers-default",
    );
    const backendIndex = results.findIndex(
      (item) => item.id === "memory-backend",
    );
    expect(defaultIndex).toBeGreaterThanOrEqual(0);
    expect(backendIndex).toBeGreaterThanOrEqual(0);
    expect(defaultIndex).toBeLessThan(backendIndex);
  });

  it("caps results at twenty matches", () => {
    const results = searchSettingsItems("a");
    expect(results.length).toBeGreaterThan(0);
    expect(results.length).toBeLessThanOrEqual(20);
  });

  it("returns empty for blank queries", () => {
    expect(searchSettingsItems("   ")).toEqual([]);
  });
});

describe("highlightSettingTarget", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
    const proto = Element.prototype as unknown as {
      scrollIntoView?: () => void;
    };
    if (typeof proto.scrollIntoView !== "function") {
      proto.scrollIntoView = () => {};
    }
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  it("opens collapsed details, pulses the group, then clears", () => {
    const scrollMock = vi.fn();
    const proto = Element.prototype as unknown as {
      scrollIntoView: (...args: Array<unknown>) => void;
    };
    proto.scrollIntoView = scrollMock;
    document.body.innerHTML = `
      <details id="outer">
        <summary>Advanced</summary>
        <div class="form-group">
          <label for="highlight-input">Name</label>
          <input id="highlight-input" type="text" />
        </div>
      </details>
    `;
    const details = document.querySelector(
      "#outer",
    ) as HTMLDetailsElement | null;
    const input = document.getElementById(
      "highlight-input",
    ) as HTMLInputElement | null;
    expect(details?.open).toBe(false);

    highlightSettingTarget("highlight-input");

    expect(scrollMock).toHaveBeenCalledWith({
      behavior: "smooth",
      block: "center",
    });
    expect(details?.open).toBe(true);
    expect(
      input?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(true);
    expect(document.activeElement?.id).toBe("highlight-input");

    vi.advanceTimersByTime(2400);
    expect(
      input?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(false);
  });

  it("replaces an active pulse with a single-flight timeout", () => {
    document.body.innerHTML = `
      <div class="form-group"><input id="first-target" type="text" /></div>
      <div class="form-group"><input id="second-target" type="text" /></div>
    `;
    const first = document.getElementById("first-target");
    const second = document.getElementById("second-target");

    highlightSettingTarget("first-target");
    expect(
      first?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(true);

    highlightSettingTarget("second-target");
    expect(
      first?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(false);
    expect(
      second?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(true);

    vi.advanceTimersByTime(2399);
    expect(
      second?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(true);
    vi.advanceTimersByTime(1);
    expect(
      second?.closest(".form-group")?.classList.contains(
        "settings-search-highlight",
      ),
    ).toBe(false);
  });

  it("ignores unknown targets without throwing", () => {
    expect(() => highlightSettingTarget("missing-target")).not.toThrow();
  });
});
