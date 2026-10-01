import { describe, expect, it, beforeEach } from "vitest";
import {
  CHAT_SETTINGS_STORAGE_KEY,
  DEFAULT_CHAT_SETTINGS,
  loadChatSettings,
  normalizeChatSettings,
  resetChatSettings,
  saveChatSettings,
  type ChatSettings,
} from "./chatSettings";

describe("chatSettings", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("loads defaults when localStorage is empty", () => {
    const settings = loadChatSettings();
    expect(settings).toEqual(DEFAULT_CHAT_SETTINGS);
    expect(settings.thinkingDefault).toBe("collapsed");
    expect(settings.fileWriteDefault).toBe("collapsed");
    expect(settings.sendOnEnter).toBe(true);
    expect(settings.autoScrollOnStream).toBe(true);
  });

  it("recovers gracefully from corrupted JSON in localStorage", () => {
    localStorage.setItem(CHAT_SETTINGS_STORAGE_KEY, "invalid-json{{{");
    const settings = loadChatSettings();
    expect(settings).toEqual(DEFAULT_CHAT_SETTINGS);
  });

  it("saves and loads custom chat settings", () => {
    const custom: ChatSettings = {
      thinkingDefault: "expanded",
      fileWriteDefault: "expanded",
      sendOnEnter: false,
      autoScrollOnStream: false,
    };
    saveChatSettings(custom);

    const loaded = loadChatSettings();
    expect(loaded).toEqual(custom);
    expect(loaded.thinkingDefault).toBe("expanded");
    expect(loaded.fileWriteDefault).toBe("expanded");
    expect(loaded.sendOnEnter).toBe(false);
    expect(loaded.autoScrollOnStream).toBe(false);
  });

  it("normalizes incomplete objects with default values for missing keys", () => {
    const partial = { thinkingDefault: "expanded" };
    localStorage.setItem(CHAT_SETTINGS_STORAGE_KEY, JSON.stringify(partial));

    const loaded = loadChatSettings();
    expect(loaded.thinkingDefault).toBe("expanded");
    expect(loaded.fileWriteDefault).toBe("collapsed");
    expect(loaded.sendOnEnter).toBe(true);
    expect(loaded.autoScrollOnStream).toBe(true);
  });

  it("normalizes invalid thinkingDefault values to collapsed", () => {
    const invalid = { thinkingDefault: "unknown-mode", sendOnEnter: "not-bool" };
    const normalized = normalizeChatSettings(invalid);
    expect(normalized.thinkingDefault).toBe("collapsed");
    expect(normalized.fileWriteDefault).toBe("collapsed");
    expect(normalized.sendOnEnter).toBe(true);
    expect(normalized.autoScrollOnStream).toBe(true);
  });

  it("normalizes fileWriteDefault to expanded only for the exact value", () => {
    expect(
      normalizeChatSettings({ fileWriteDefault: "expanded" }).fileWriteDefault,
    ).toBe("expanded");
    expect(
      normalizeChatSettings({ fileWriteDefault: "collapsed" }).fileWriteDefault,
    ).toBe("collapsed");
    // Stored junk (wrong type, unknown mode) collapses rather than expanding.
    expect(
      normalizeChatSettings({ fileWriteDefault: "always" }).fileWriteDefault,
    ).toBe("collapsed");
    expect(
      normalizeChatSettings({ fileWriteDefault: true }).fileWriteDefault,
    ).toBe("collapsed");
  });

  it("normalizes non-object input to defaults", () => {
    expect(normalizeChatSettings(null)).toEqual(DEFAULT_CHAT_SETTINGS);
    expect(normalizeChatSettings(undefined)).toEqual(DEFAULT_CHAT_SETTINGS);
    expect(normalizeChatSettings("string")).toEqual(DEFAULT_CHAT_SETTINGS);
    expect(normalizeChatSettings(123)).toEqual(DEFAULT_CHAT_SETTINGS);
  });

  it("resets chat settings back to defaults", () => {
    saveChatSettings({
      thinkingDefault: "expanded",
      fileWriteDefault: "expanded",
      sendOnEnter: false,
      autoScrollOnStream: false,
    });
    expect(loadChatSettings().thinkingDefault).toBe("expanded");

    const reset = resetChatSettings();
    expect(reset).toEqual(DEFAULT_CHAT_SETTINGS);
    expect(loadChatSettings()).toEqual(DEFAULT_CHAT_SETTINGS);
  });
});
