// Rune Weaver Dashboard — Settings helpers, tool categorization, validation, and normalization.

import type { ToolInfo } from "../../api";
import {
  canonicalRestartHost,
  DEFAULT_PERSONA_AVATAR,
  DEFAULT_PERSONA_TONE,
  normalizePersonaAvatarColor,
  normalizePersonaTone,
  normalizeServerAllowedHost,
  PERSONA_AVATAR_COLORS,
  PERSONA_TONES,
} from "../../api";
import {
  CalendarIcon,
  FolderIcon,
  GlobeIcon,
  MailIcon,
  MemoryIcon,
  MessageSquareIcon,
  MonitorIcon,
  TargetIcon,
  TerminalIcon,
  WrenchIcon,
} from "../icons";
import { SERVER_BIND_PRESETS, type ToolCategoryMeta } from "./settingsTypes";

export function canonicalPersonaTone(value: unknown): string {
  const normalized = normalizePersonaTone(value);
  return (PERSONA_TONES as readonly string[]).includes(normalized)
    ? normalized
    : DEFAULT_PERSONA_TONE;
}

export function canonicalPersonaAvatarColor(value: unknown): string {
  const normalized = normalizePersonaAvatarColor(value);
  return (PERSONA_AVATAR_COLORS as readonly string[]).includes(normalized)
    ? normalized
    : DEFAULT_PERSONA_AVATAR;
}

export const TOOL_CATEGORIES: readonly ToolCategoryMeta[] = [
  { id: "desktop", name: "Desktop & Automation", description: "Screen capture, OCR, and approval-gated mouse/keyboard control", icon: MonitorIcon },
  { id: "messages", name: "Messages & SMS", description: "Search, read, and send macOS iMessages and text messages", icon: MessageSquareIcon },
  { id: "email", name: "Email & Mailboxes", description: "IMAP search, message read, attachment inspection, and drafts", icon: MailIcon },
  { id: "calendar-reminders", name: "Calendar & Reminders", description: "macOS Calendar events and Reminders management", icon: CalendarIcon },
  { id: "browser-web", name: "Browser, Web & API", description: "Web search, page fetch, browser automation, and API requests", icon: GlobeIcon },
  { id: "bash", name: "Bash & Shell", description: "Terminal execution and sandboxed system commands", icon: TerminalIcon },
  { id: "files", name: "Files & Workspace", description: "Filesystem reads, staged changes, and workspace writes", icon: FolderIcon },
  { id: "memories", name: "Long-Term Memory", description: "Episodic and profile memory store and recall", icon: MemoryIcon },
  { id: "goal", name: "Autonomous Goals", description: "Multi-turn goal planning, tracking, and execution", icon: TargetIcon },
  { id: "fanout", name: "Fan-Out Workers", description: "Concurrent worker turns for parallel subtasks", icon: WrenchIcon },
  { id: "media", name: "Media & Streaming", description: "Media search and client control", icon: WrenchIcon },
  { id: "other", name: "Other Tools", description: "General utility tools and external plugins", icon: WrenchIcon },
];

export const KNOWN_BUILTIN_TOOL_CATEGORIES: Record<string, string> = {
  "desktop.screenshot": "desktop",
  "desktop.action": "desktop",
  "messages.search": "messages",
  "messages.read": "messages",
  "messages.send": "messages",
  "email.search": "email",
  "email.read": "email",
  "email.attachment": "email",
  "email.send": "email",
  "email.listMailboxes": "email",
  "email.move": "email",
  "calendar.search": "calendar-reminders",
  "calendar.create": "calendar-reminders",
  "calendar.update": "calendar-reminders",
  "calendar.delete": "calendar-reminders",
  "calendar.list": "calendar-reminders",
  "reminders.search": "calendar-reminders",
  "reminders.create": "calendar-reminders",
  "reminders.update": "calendar-reminders",
  "reminders.delete": "calendar-reminders",
  "reminders.list": "calendar-reminders",
  "browser.navigate": "browser-web",
  "browser.act": "browser-web",
  "web.search": "browser-web",
  "web.fetch": "browser-web",
  "bash.exec": "bash",
  "files.read": "files",
  "files.grep": "files",
  "files.glob": "files",
  "files.write": "files",
  "files.list": "files",
  "memories.store": "memories",
  "memories.recall": "memories",
  "goal.create": "goal",
  "goal.status": "goal",
  "goal.progress": "goal",
  "fanout.run": "fanout",
  "media.arr": "media",
  "media.arr.read": "media",
  "api.request": "browser-web",
};

export function resolveBuiltinCategoryByName(toolName: string): string {
  if (toolName.startsWith("desktop.")) return "desktop";
  if (toolName.startsWith("messages.")) return "messages";
  if (toolName.startsWith("email.")) return "email";
  if (toolName.startsWith("calendar.") || toolName.startsWith("reminders.")) return "calendar-reminders";
  if (toolName.startsWith("browser.") || toolName.startsWith("web.") || toolName.startsWith("api.")) return "browser-web";
  if (toolName.startsWith("bash.")) return "bash";
  if (toolName.startsWith("files.")) return "files";
  if (toolName.startsWith("memories.")) return "memories";
  if (toolName.startsWith("goal.")) return "goal";
  if (toolName.startsWith("fanout.")) return "fanout";
  if (toolName.startsWith("media.")) return "media";
  return "other";
}

export function getToolCategory(tool: ToolInfo): string;
export function getToolCategory(toolName: string): string;
export function getToolCategory(tool: ToolInfo | string): string {
  if (typeof tool === "string") {
    return KNOWN_BUILTIN_TOOL_CATEGORIES[tool] ?? "other";
  }
  if (tool.isBuiltIn === false) return "other";
  return resolveBuiltinCategoryByName(tool.name);
}

export function getCategoryConfigKey(categoryId: string): string | null {
  if (categoryId === "desktop") return "desktop";
  if (categoryId === "media") return "media.arr";
  if (categoryId === "fanout") return "fanout.run";
  if (categoryId === "browser-web") return "browser.navigate";
  return null;
}

export function getEmailPasswordEnv(name: string): string {
  const safeName = name.toUpperCase().replace(/[^\p{L}\p{N}]/gu, "_");
  return `EMAIL_${safeName}_PASSWORD`;
}

export function validateDesktopCaptureBounds(
  maxImageDimension: number | string,
  jpegQuality: number | string
): string | null {
  const dimNum = Number(maxImageDimension);
  if (!Number.isInteger(dimNum) || dimNum < 256 || dimNum > 3840) {
    return "Invalid desktop image dimension: max image dimension must be between 256 and 3840.";
  }
  const qualityNum = Number(jpegQuality);
  if (!Number.isFinite(qualityNum) || qualityNum < 0.1 || qualityNum > 1.0) {
    return "Invalid desktop JPEG quality: jpeg quality must be between 0.1 and 1.0.";
  }
  return null;
}

export function validateBrowserTimeoutSeconds(value: number | string): string | null {
  const timeoutNum = Number(value);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 5 || timeoutNum > 300) {
    return "Invalid browser timeout: automation timeout must be between 5 and 300 seconds.";
  }
  return null;
}

export function validateBrowserFetchTimeoutSeconds(value: number | string): string | null {
  const timeoutNum = Number(value);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 1 || timeoutNum > 120) {
    return "Invalid HTTP request timeout: request timeout must be between 1 and 120 seconds.";
  }
  return null;
}

export function validateMediaTimeoutSeconds(value: number | string): string | null {
  const timeoutNum = Number(value);
  if (!Number.isInteger(timeoutNum) || timeoutNum < 5 || timeoutNum > 120) {
    return "Invalid media timeout: request timeout must be between 5 and 120 seconds.";
  }
  return null;
}

export function isServerBindPreset(hostname: string): boolean {
  const candidate = canonicalRestartHost(hostname);
  return SERVER_BIND_PRESETS.some(
    (preset) => canonicalRestartHost(preset) === candidate,
  );
}

export function areServerAllowedHostsEqual(a: string[], b: string[]): boolean {
  const sortedA = [...new Set(a.map((h) => canonicalRestartHost(normalizeServerAllowedHost(h))))].sort();
  const sortedB = [...new Set(b.map((h) => canonicalRestartHost(normalizeServerAllowedHost(h))))].sort();
  if (sortedA.length !== sortedB.length) return false;
  return sortedA.every((h, i) => h === sortedB[i]);
}
