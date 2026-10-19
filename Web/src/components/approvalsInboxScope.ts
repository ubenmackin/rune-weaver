// Rune Weaver Dashboard — Inbox custom-scope editor vocabulary.

import type { AccessScopeDTO, PermissionRequest } from "../api";
import { deriveRequestTarget } from "../approvalsShared";
import { resolveEgressHost } from "./InlineApprovalBanner";

// Engine recipient-set bound, mirrored so the editor refuses a set the rule
// store would reject instead of failing at the wire.
export const MAX_RECIPIENT_SET_MEMBERS = 50;

// Editor shape a custom scope takes, keyed to what the wire scope vocabulary can carry for the
// tool: a recipient set for the send tools, one host for an egress-parked request, and a single
// exact-target string for path, pattern, and generic calls.
export type ScopeEditorKind = "recipients" | "hosts" | "paths" | "pattern";

export const SCOPE_EDITOR_COPY: Record<
  ScopeEditorKind,
  { label: string; hint: string }
> = {
  recipients: {
    label: "Recipients",
    hint: "One canonical recipient per line. Every listed recipient is covered.",
  },
  hosts: {
    label: "Hosts / domains",
    hint: "One host or domain per line. The first entry becomes the rule's host.",
  },
  paths: {
    label: "Paths",
    hint: "One path per line. The first entry becomes the rule's target.",
  },
  pattern: {
    label: "Pattern",
    hint: "One pattern or exact target per line. The first entry becomes the rule's target.",
  },
};

export function scopeEditorKind(request: PermissionRequest): ScopeEditorKind {
  if (resolveEgressHost(request)) return "hosts";
  if (request.toolName === "messages.send" || request.toolName === "email.send") {
    return "recipients";
  }
  if (request.toolName === "bash.exec") return "pattern";
  if (request.toolName.startsWith("files.")) return "paths";
  return "pattern";
}

// Editor prefill: the request's own target for the kind that can carry it, so
// narrowing starts from what is about to run. Everything else opens blank.
export function scopePrefill(request: PermissionRequest): string {
  switch (scopeEditorKind(request)) {
    case "hosts":
      return resolveEgressHost(request) ?? "";
    default:
      return deriveRequestTarget(request) ?? "";
  }
}

// Splits editor text into deduplicated, non-blank entries. The
// case-insensitive dedupe matches the recipient normalization the rule store
// applies, so a repeated spelling never reads as two members.
export function splitScopeEntries(text: string): string[] {
  const seen = new Set<string>();
  const entries: string[] = [];
  for (const rawLine of text.split("\n")) {
    const trimmed = rawLine.trim();
    if (!trimmed) continue;
    const key = trimmed.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    entries.push(trimmed);
  }
  return entries;
}

// Builds the wire scope from editor text.
export function buildCustomScope(
  kind: ScopeEditorKind,
  text: string,
): AccessScopeDTO | null {
  const entries = splitScopeEntries(text);
  if (entries.length === 0) return null;
  switch (kind) {
    case "recipients":
      return { kind: "recipientSet", handles: entries };
    case "hosts":
      return { kind: "domain", host: entries[0] };
    default:
      return { kind: "exactTarget", target: entries[0] };
  }
}

// Editor text for a staged scope, so reopening the modal shows exactly what
// the next decision would ship.
export function scopeToText(scope: AccessScopeDTO): string {
  switch (scope.kind) {
    case "tool":
      return "";
    case "exactTarget":
      return scope.target;
    case "recipientSet":
      return scope.handles.join("\n");
    case "domain":
      return scope.host;
  }
}

// One-line reading of a staged scope for the card summary.
export function describeScope(scope: AccessScopeDTO): string {
  switch (scope.kind) {
    case "tool":
      return "all targets";
    case "exactTarget":
      return scope.target;
    case "recipientSet":
      return `${scope.handles.length} recipients`;
    case "domain":
      return scope.host;
  }
}

export type ScopeChoice = "thisTarget" | "allTargets" | "custom";

export interface ScopeDraft {
  id: string;
  kind: ScopeEditorKind;
  text: string;
}
