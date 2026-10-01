// Rune Weaver Dashboard — Client-side chat preferences and settings store.
//
// Manages user-configurable chat options such as default thinking expansion,
// default file write card expansion, message submission shortcut, and streaming
// auto-scroll. Backed by localStorage with event-driven synchronization across
// components and tabs.

import { useCallback, useEffect, useState } from "react";

export type ThinkingDefaultState = "expanded" | "collapsed";
export type FileWriteDefaultState = "expanded" | "collapsed";

export interface ChatSettings {
  /**
   * Whether thought/reasoning blocks should be expanded or collapsed by default.
   */
  thinkingDefault: ThinkingDefaultState;
  /**
   * Whether in-chat files.write diff cards should show their diff body by
   * default; collapsed keeps write cards to their header until clicked.
   */
  fileWriteDefault: FileWriteDefaultState;
  /**
   * Whether pressing Enter sends the message (Shift+Enter for newline)
   * vs Cmd/Ctrl+Enter to send (Enter for newline).
   */
  sendOnEnter: boolean;
  /**
   * Whether to auto-scroll the message stream as new tokens and tool actions arrive.
   */
  autoScrollOnStream: boolean;
}

export const CHAT_SETTINGS_STORAGE_KEY = "rw_chat_settings";
export const CHAT_SETTINGS_CHANGE_EVENT = "rw_chat_settings_changed";

export const DEFAULT_CHAT_SETTINGS: Readonly<ChatSettings> = Object.freeze({
  thinkingDefault: "collapsed",
  fileWriteDefault: "collapsed",
  sendOnEnter: true,
  autoScrollOnStream: true,
});

/**
 * Validates and normalizes unknown input into a valid ChatSettings object.
 */
export function normalizeChatSettings(raw: unknown): ChatSettings {
  if (!raw || typeof raw !== "object") {
    return { ...DEFAULT_CHAT_SETTINGS };
  }
  const obj = raw as Record<string, unknown>;

  const thinkingDefault: ThinkingDefaultState =
    obj.thinkingDefault === "expanded" ? "expanded" : "collapsed";

  const fileWriteDefault: FileWriteDefaultState =
    obj.fileWriteDefault === "expanded" ? "expanded" : "collapsed";

  const sendOnEnter =
    typeof obj.sendOnEnter === "boolean"
      ? obj.sendOnEnter
      : DEFAULT_CHAT_SETTINGS.sendOnEnter;

  const autoScrollOnStream =
    typeof obj.autoScrollOnStream === "boolean"
      ? obj.autoScrollOnStream
      : DEFAULT_CHAT_SETTINGS.autoScrollOnStream;

  return {
    thinkingDefault,
    fileWriteDefault,
    sendOnEnter,
    autoScrollOnStream,
  };
}

/**
 * Loads chat settings from localStorage, falling back to defaults if absent or malformed.
 */
export function loadChatSettings(): ChatSettings {
  if (typeof window === "undefined" || !window.localStorage) {
    return { ...DEFAULT_CHAT_SETTINGS };
  }
  try {
    const raw = window.localStorage.getItem(CHAT_SETTINGS_STORAGE_KEY);
    if (!raw) return { ...DEFAULT_CHAT_SETTINGS };
    const parsed = JSON.parse(raw);
    return normalizeChatSettings(parsed);
  } catch {
    return { ...DEFAULT_CHAT_SETTINGS };
  }
}

/**
 * Persists chat settings to localStorage and notifies listeners.
 */
export function saveChatSettings(settings: ChatSettings): void {
  const normalized = normalizeChatSettings(settings);
  if (typeof window !== "undefined" && window.localStorage) {
    try {
      window.localStorage.setItem(
        CHAT_SETTINGS_STORAGE_KEY,
        JSON.stringify(normalized)
      );
    } catch {
      // Storage quota or private mode restriction
    }
    try {
      window.dispatchEvent(
        new CustomEvent(CHAT_SETTINGS_CHANGE_EVENT, { detail: normalized })
      );
    } catch {
      // Ignore if event dispatch fails in test environments
    }
  }
}

/**
 * Resets chat settings to default values and notifies listeners.
 */
export function resetChatSettings(): ChatSettings {
  const defaults = { ...DEFAULT_CHAT_SETTINGS };
  saveChatSettings(defaults);
  return defaults;
}

/**
 * Hook to access and update reactive chat settings.
 */
export function useChatSettings(): {
  settings: ChatSettings;
  updateSettings: (patch: Partial<ChatSettings>) => void;
  resetSettings: () => void;
} {
  const [settings, setSettings] = useState<ChatSettings>(() => loadChatSettings());

  useEffect(() => {
    function handleLocalChange(event: Event) {
      const customEvent = event as CustomEvent<ChatSettings>;
      if (customEvent.detail) {
        setSettings(customEvent.detail);
      } else {
        setSettings(loadChatSettings());
      }
    }

    function handleStorageChange(event: StorageEvent) {
      if (event.key === CHAT_SETTINGS_STORAGE_KEY) {
        setSettings(loadChatSettings());
      }
    }

    if (typeof window !== "undefined") {
      window.addEventListener(CHAT_SETTINGS_CHANGE_EVENT, handleLocalChange);
      window.addEventListener("storage", handleStorageChange);
      return () => {
        window.removeEventListener(CHAT_SETTINGS_CHANGE_EVENT, handleLocalChange);
        window.removeEventListener("storage", handleStorageChange);
      };
    }
  }, []);

  const updateSettings = useCallback((patch: Partial<ChatSettings>) => {
    setSettings((current) => {
      const updated = normalizeChatSettings({ ...current, ...patch });
      saveChatSettings(updated);
      return updated;
    });
  }, []);

  const reset = useCallback(() => {
    const defaults = resetChatSettings();
    setSettings(defaults);
  }, []);

  return {
    settings,
    updateSettings,
    resetSettings: reset,
  };
}
