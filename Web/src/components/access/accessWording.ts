// Rune Weaver Dashboard — Shared plain-English wording for access rules and
// decision scopes.

import type { AccessRule, AccessScopeDTO, TrustDuration } from "../../api";
import { parseRuleExpiry, trustDurationOptions } from "../../api";

// One-line reading of a scope that names what trust reaches.
export function describeAccessScope(scope: AccessScopeDTO | undefined): string {
  if (!scope || typeof scope !== "object") return "unknown scope";
  const kind = (scope as { kind?: unknown }).kind;
  switch (kind) {
    case "tool":
    case "toolWide":
      return "any target";
    case "exactTarget": {
      const target = (scope as unknown as { target?: unknown }).target;
      return typeof target === "string" && target.trim().length > 0
        ? target
        : "unknown scope";
    }
    case "recipientSet": {
      const handles = (scope as unknown as { handles?: unknown }).handles;
      if (!Array.isArray(handles)) return "unknown scope";
      const visible = handles.filter(
        (entry): entry is string => typeof entry === "string" && entry.trim().length > 0,
      );
      if (visible.length === 0) return "unknown scope";
      return visible.length === 1 ? visible[0] : `${visible.length} recipients`;
    }
    case "domain": {
      const host = (scope as unknown as { host?: unknown }).host;
      if (typeof host !== "string" || host.trim().length === 0) return "unknown scope";
      const subdomains = (scope as unknown as { subdomains?: unknown }).subdomains;
      return subdomains === true ? `${host} and subdomains` : host;
    }
    case "pathPrefix": {
      const path = (scope as unknown as { path?: unknown }).path;
      return typeof path === "string" && path.trim().length > 0 ? path : "unknown scope";
    }
    case "glob": {
      const pattern = (scope as unknown as { pattern?: unknown }).pattern;
      return typeof pattern === "string" && pattern.trim().length > 0
        ? pattern
        : "unknown scope";
    }
    default:
      return "unknown scope";
  }
}

// Action phrase per tool for the grouped header. A tool outside this map reads
// through a generic verb so a new or renamed tool still renders a clause
// instead of silently dropping its group.
const TOOL_ACTION_PHRASE: Record<string, string> = {
  "email.send": "send email",
  "messages.send": "send text messages",
  "bash.exec": "run shell commands",
  "web.search": "search the web",
  "web.fetch": "fetch web pages",
  "api.request": "make API requests",
  "browser.navigate": "open pages in the browser",
  "browser.act": "drive the browser",
  "files.write": "write files",
  "desktop.action": "control the desktop",
  "media.arr": "manage downloads",
  "goal.create": "create goals",
  "fanout.run": "launch agent workers",
  "calendar.create": "create calendar events",
  "reminders.create": "create reminders",
};

// Send tools treat an exact-target rule as another recipient, so the "N people"
// total counts exact targets alongside recipient-set members rather than
// reading a recipient address as an opaque target string.
function isSendTool(tool: string): boolean {
  return tool === "email.send" || tool === "messages.send";
}

// Reads the combined coverage one tool's active allow rules reach.
function coverageClause(tool: string, scopes: AccessScopeDTO[]): string {
  if (
    scopes.some(
      (scope) =>
        (scope as { kind?: unknown }).kind === "tool" ||
        (scope as { kind?: unknown }).kind === "toolWide",
    )
  )
    return "";
  if (isSendTool(tool)) {
    const recipients = new Set<string>();
    for (const scope of scopes) {
      // The same defensive field reads describeAccessScope uses: a drifted
      // payload naming no readable handle contributes nothing instead of
      // throwing mid-render and blanking the whole landing section.
      if (scope.kind === "recipientSet") {
        const handles = (scope as unknown as { handles?: unknown }).handles;
        if (!Array.isArray(handles)) continue;
        for (const handle of handles) {
          if (typeof handle !== "string") continue;
          const trimmed = handle.trim().toLowerCase();
          if (trimmed) recipients.add(trimmed);
        }
      } else if (scope.kind === "exactTarget") {
        const target = (scope as unknown as { target?: unknown }).target;
        if (typeof target !== "string") continue;
        const trimmed = target.trim().toLowerCase();
        if (trimmed) recipients.add(trimmed);
      }
    }
    const count = recipients.size;
    if (count > 0) return `to ${count} ${count === 1 ? "person" : "people"}`;
    return "to specific recipients";
  }
  const targets = new Set<string>();
  for (const scope of scopes) {
    const kind = (scope as { kind?: unknown }).kind;
    if (kind === "exactTarget") {
      const target = (scope as unknown as { target?: unknown }).target;
      if (typeof target === "string" && target.trim()) targets.add(target.trim());
    } else if (kind === "domain") {
      const host = (scope as unknown as { host?: unknown }).host;
      if (typeof host === "string" && host.trim()) {
        // A widened domain rule names the whole zone, so the wildcard spelling
        // names its coverage instead of reading like one literal host.
        const subdomains = (scope as unknown as { subdomains?: unknown })
          .subdomains;
        targets.add(subdomains === true ? `*.${host.trim()}` : host.trim());
      }
    } else if (kind === "recipientSet") {
      const handles = (scope as unknown as { handles?: unknown }).handles;
      if (Array.isArray(handles)) {
        for (const handle of handles) {
          if (typeof handle === "string" && handle.trim()) targets.add(handle.trim());
        }
      }
    } else if (kind === "pathPrefix") {
      const path = (scope as unknown as { path?: unknown }).path;
      if (typeof path === "string" && path.trim()) targets.add(path.trim());
    } else if (kind === "glob") {
      const pattern = (scope as unknown as { pattern?: unknown }).pattern;
      if (typeof pattern === "string" && pattern.trim()) targets.add(pattern.trim());
    }
  }
  if (targets.size === 1) return `to ${[...targets][0]}`;
  if (targets.size > 1) return `to ${targets.size} specific targets`;
  return "";
}

// Joins clause list into prose: one reads plainly, two use "and", and three or
// more serialize with the Oxford comma so a long sentence stays parseable.
function joinClauses(clauses: string[]): string {
  if (clauses.length === 0) return "";
  if (clauses.length === 1) return clauses[0];
  if (clauses.length === 2) return `${clauses[0]} and ${clauses[1]}`;
  return `${clauses.slice(0, -1).join(", ")}, and ${clauses[clauses.length - 1]}`;
}

// Whether a rule is still in force: a null expiry is the forever tier and a future expiry is still
// active, while a past expiry lapses.
export function isRuleActive(rule: AccessRule, nowMs: number = Date.now()): boolean {
  const expiresAt = parseRuleExpiry(rule.expiresAt);
  return expiresAt === null || expiresAt.getTime() > nowMs;
}

// Derives the plain-English header from the active allow rules grouped by tool.
export function accessRulesHeaderSentence(
  rules: AccessRule[],
  nowMs: number = Date.now(),
): string {
  const activeAllows = rules.filter((rule) => {
    const effect = rule.effect ?? rule.action;
    return effect === "allow" && isRuleActive(rule, nowMs);
  });
  if (activeAllows.length === 0) {
    return "Right now the agent can't act on its own. Every call needs your approval.";
  }
  const scopesByTool = new Map<string, AccessScopeDTO[]>();
  for (const rule of activeAllows) {
    const scopes = scopesByTool.get(rule.toolName) ?? [];
    scopes.push(rule.scope);
    scopesByTool.set(rule.toolName, scopes);
  }
  const clauses: string[] = [];
  for (const tool of [...scopesByTool.keys()].sort()) {
    const phrase = TOOL_ACTION_PHRASE[tool] ?? `use ${tool}`;
    const coverage = coverageClause(tool, scopesByTool.get(tool) ?? []);
    clauses.push(coverage ? `${phrase} ${coverage}` : phrase);
  }
  return `Right now the agent can ${joinClauses(clauses)}.`;
}

// Label for a durable tier in the shared duration vocabulary. An unknown value
// falls back to the raw string so a drifted payload still renders instead of
// blanking the cell.
export function formatRuleDurationLabel(duration: TrustDuration | null | undefined): string {
  if (!duration) return "Forever";
  return (
    trustDurationOptions.find((option) => option.value === duration)?.label ?? duration
  );
}
