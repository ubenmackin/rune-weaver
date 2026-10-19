// Rune Weaver Dashboard — Inbox session grouping and severity ordering.

import type { ImpactSeverity, PermissionRequest } from "../api";
import { isSystemNoticeTool } from "../approvalsShared";
import {
  approvalSessionID,
  normalizeSessionID,
} from "../approvalsSession";

// Watchdog brake card identity, mirroring the engine's brake tool name: the
// one card whose complete decision is releasing the parked turns.
export const BRAKE_TOOL_NAME = "behavior.brake";

// Group key and header for the system notices: engine-filed items carry no
// session, so they read under System instead of Unattributed.
export const SYSTEM_NOTICE_KEY = "__system__";
export const SYSTEM_NOTICE_TITLE = "System";

// Group key and header for requests no session claims: the brake card, older
// payloads without a session tag, and headless filings all read here.
export const UNATTRIBUTED_KEY = "__unattributed__";
export const UNATTRIBUTED_TITLE = "Unattributed";

export interface ApprovalGroup {
  key: string;
  title: string;
  requests: PermissionRequest[];
  // Newest filing position inside the group, kept as the stable tiebreak
  // between groups of equal maximum severity.
  newestIndex: number;
}

// One ordering scale shared by cards and groups: dangerous over moderate over
// safe, so a consequential card never sinks below a quieter one.
export function severityRank(severity: ImpactSeverity): number {
  switch (severity) {
    case "dangerous":
      return 3;
    case "moderate":
      return 2;
    default:
      return 1;
  }
}

// A nil assessment is the pending state and sorts as moderate, so an
// unassessed card never outranks a valued dangerous one nor sinks below a
// valued safe one while background enrichment is still in flight.
export function requestSeverity(request: PermissionRequest): ImpactSeverity {
  return request.assessment?.severity ?? "moderate";
}

// System notices file under their own System header, the brake card parks every running turn
// rather than one session's call so it always reads under Unattributed even when the watchdog
// tagged a session, and everything else groups by its owning session.
export function groupKeyFor(request: PermissionRequest): string {
  if (isSystemNoticeTool(request.toolName)) return SYSTEM_NOTICE_KEY;
  if (request.toolName === BRAKE_TOOL_NAME) return UNATTRIBUTED_KEY;
  return normalizeSessionID(approvalSessionID(request)) || UNATTRIBUTED_KEY;
}

// The wire carries no filing timestamp, so payload position is the filing signal: the engine lists
// pending entries oldest-first, which makes a later position the more recent filing.
export function buildGroups(
  approvals: PermissionRequest[],
  titles: Map<string, string>,
): ApprovalGroup[] {
  const buckets = new Map<
    string,
    {
      rawID: string;
      entries: Array<{ request: PermissionRequest; index: number }>;
    }
  >();
  approvals.forEach((request, index) => {
    const key = groupKeyFor(request);
    const bucket = buckets.get(key);
    if (bucket) {
      bucket.entries.push({ request, index });
      if (!bucket.rawID) bucket.rawID = (approvalSessionID(request) ?? "").trim();
      return;
    }
    buckets.set(key, {
      rawID: (approvalSessionID(request) ?? "").trim(),
      entries: [{ request, index }],
    });
  });

  const groups: ApprovalGroup[] = [];
  for (const [key, bucket] of buckets) {
    const ordered = [...bucket.entries].sort((a, b) => {
      const bySeverity =
        severityRank(requestSeverity(b.request)) -
        severityRank(requestSeverity(a.request));
      return bySeverity !== 0 ? bySeverity : b.index - a.index;
    });
    const titled = titles.get(key);
    groups.push({
      key,
      title:
        key === SYSTEM_NOTICE_KEY
          ? SYSTEM_NOTICE_TITLE
          : key === UNATTRIBUTED_KEY
            ? UNATTRIBUTED_TITLE
            : titled || bucket.rawID || UNATTRIBUTED_TITLE,
      requests: ordered.map((entry) => entry.request),
      newestIndex: Math.max(...bucket.entries.map((entry) => entry.index)),
    });
  }

  return groups.sort((a, b) => {
    const bySeverity =
      maxSeverityRank(b.requests) - maxSeverityRank(a.requests);
    return bySeverity !== 0 ? bySeverity : b.newestIndex - a.newestIndex;
  });
}

export function maxSeverityRank(requests: PermissionRequest[]): number {
  return requests.reduce(
    (highest, request) =>
      Math.max(highest, severityRank(requestSeverity(request))),
    0,
  );
}
