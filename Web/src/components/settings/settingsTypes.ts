// Rune Weaver Dashboard — Settings types, tab vocabulary, keywords, and contracts.

import type React from "react";
import type {
  EmailAccountData,
  ProviderConfigData,
} from "../../api";
import { startElapsedSeconds } from "../../api";
import {
  ACCESS_RULES_SECTION_TOKEN,
  readAccessDeepLink,
  readAccessParamValue,
} from "../access/accessNav";

export type SettingsTab =
  | "access"
  | "providers"
  | "persona"
  | "goals"
  | "engine"
  | "tools"
  | "security"
  | "memory"
  | "voice"
  | "search"
  | "email"
  | "network"
  | "indexing";

export const SETTINGS_TABS: readonly SettingsTab[] = [
  "access",
  "providers",
  "persona",
  "voice",
  "memory",
  "goals",
  "tools",
  "indexing",
  "search",
  "email",
  "security",
  "network",
  "engine",
];

export const SETTINGS_TAB_KEYWORDS: Record<SettingsTab, string> = {
  access:
    "access rules permissions allow deny standing bash shell commands network domains egress credentials keys files write posture policy sandbox review",
  providers: "llm providers models api keys routing fallback",
  persona: "persona identity tone style avatar assistant name",
  goals: "goals pursuit cadence plan steps triggers",
  engine: "engine logs name compaction tool rounds proactive ideas interruption",
  tools: "tools runes plugins builtin agents workspace scripts marketplace",
  security: "security containers sandbox files allow roots deny approval blocked paths token rotation",
  memory: "memory storage vectors episodes embeddings recall",
  voice: "voice whisper speech stt tts",
  search: "web search searxng browser timeouts fetch",
  email: "email accounts imap smtp mailboxes",
  network: "network server hostname port bind allowed hosts restart",
  indexing: "indexing index documents status",
};

export function matchesSettingsTab(tab: SettingsTab, query: string): boolean {
  if (!query) return true;
  return SETTINGS_TAB_KEYWORDS[tab].includes(query);
}

export function isSettingsTab(value: unknown): value is SettingsTab {
  return (
    typeof value === "string" &&
    (SETTINGS_TABS as readonly string[]).includes(value)
  );
}

export function hasAccessSectionLink(): boolean {
  if (typeof window === "undefined") return false;
  if (readAccessDeepLink() !== null) return true;
  return readAccessParamValue() === ACCESS_RULES_SECTION_TOKEN;
}

export interface ToolCategoryMeta {
  id: string;
  name: string;
  description: string;
  icon: (props: { size?: number; className?: string }) => React.JSX.Element;
}

export interface ProviderEntry {
  id: string;
  name: string;
  config: ProviderConfigData;
}

export interface EmailEntry {
  id: string;
  account: EmailAccountData;
}

export interface LiveServerBind {
  hostname: string;
  port: number;
  allowedHosts: string[];
}

export const BROWSER_PYTHON_VENV_DISPLAY = "~/.runeweaver/python";
export const BROWSER_START_POLL_INTERVAL_MS = 1000;
export const BROWSER_START_CAP_MS = 600_000;
export const BROWSER_PYTHON_PLAYWRIGHT_REQUIREMENT = "playwright==1.49.1";

export const BROWSER_PYTHON_STAGE_COPY: Record<string, string> = {
  resolving: "Finding system Python",
  creating: "Creating managed browser environment",
  installing: "Installing Playwright package",
  browsers: "Installing Chromium browser",
};

export const SERVER_BIND_PRESETS = ["127.0.0.1", "0.0.0.0"];
export const SERVER_BOOT_POLL_INTERVAL_MS = 5000;

export interface BrowserPythonHealthPayload {
  ready?: boolean | null;
  pythonPath?: string | null;
  venvPath?: string | null;
  stage?: string | null;
  startedAt?: number | null;
  message?: string | null;
  diagnostics?: string | null;
  started?: boolean | null;
}

export function resolveBrowserStage(
  response: BrowserPythonHealthPayload | null | undefined,
): string | null {
  if (!response) return null;
  const raw =
    typeof response.stage === "string" && response.stage.trim()
      ? response.stage.trim()
      : "";
  return raw || null;
}

export function resolveBrowserStartedAt(
  response: BrowserPythonHealthPayload | null | undefined,
): number | null {
  if (!response) return null;
  const raw = response.startedAt;
  return typeof raw === "number" && Number.isFinite(raw) && raw > 0
    ? raw
    : null;
}

export function browserStageCopy(stage: string | null | undefined): string {
  if (stage && BROWSER_PYTHON_STAGE_COPY[stage])
    return BROWSER_PYTHON_STAGE_COPY[stage];
  return "Preparing";
}

export function isBrowserLongStage(stage: string | null | undefined): boolean {
  return stage === "installing" || stage === "browsers";
}

export const browserElapsedSeconds = startElapsedSeconds;

export function trimBrowserText(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export const SECRET_STATUS_CHUNK_SIZE = 500;

export interface SettingsManagerProps {
  onSettingsSaved?: () => void;
}
