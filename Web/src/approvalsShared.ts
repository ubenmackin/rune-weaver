// Rune Weaver Dashboard — Shared decision-surface approvals vocabulary.

import {
  trustDurationOptions,
  type PermissionRequest,
  type TrustDuration,
} from "./api";
import { isRecord } from "./typeGuards";

// Egress-parked requests support the full shared duration vocabulary:
// thisTime (once), forTask, forSession, timed rules (5m/1h/24h), and forever.
export const EGRESS_DURATIONS: TrustDuration[] = [
  "thisTime",
  "forTask",
  "forSession",
  "fiveMinutes",
  "oneHour",
  "oneDay",
  "forever",
];

// Mirror of EgressWideningPolicy.multiPartPublicSuffixes in Core: the
// parity test pins both sets equal so widenings agree.
const MULTI_PART_PUBLIC_SUFFIXES: ReadonlySet<string> = new Set([
  "co.uk",
  "org.uk",
  "gov.uk",
  "ac.uk",
  "me.uk",
  "net.uk",
  "ltd.uk",
  "plc.uk",
  "sch.uk",
  "com.au",
  "net.au",
  "org.au",
  "edu.au",
  "gov.au",
  "asn.au",
  "id.au",
  "co.jp",
  "ne.jp",
  "or.jp",
  "ac.jp",
  "go.jp",
  "ed.jp",
  "gr.jp",
  "lg.jp",
  "co.nz",
  "net.nz",
  "org.nz",
  "ac.nz",
  "com.br",
  "net.br",
  "org.br",
  "gov.br",
  "edu.br",
  "co.in",
  "net.in",
  "org.in",
  "firm.in",
  "gen.in",
  "ind.in",
  "com.sg",
  "com.hk",
  "co.kr",
  "co.za",
  "net.sg",
  "org.sg",
  "edu.sg",
  "net.hk",
  "org.hk",
  "edu.hk",
  "net.za",
  "org.za",
  "com.mx",
  "com.ar",
  "com.tr",
  "com.tw",
  "com.cn",
  "net.cn",
  "org.cn",
  "gov.cn",
  "edu.cn",
  "net.mx",
  "org.mx",
  "edu.mx",
  "net.ar",
  "org.ar",
  "edu.ar",
  "gov.ar",
  "net.tr",
  "org.tr",
  "edu.tr",
  "gov.tr",
  "com.co",
  "com.do",
  "com.ec",
  "com.eg",
  "com.gt",
  "com.ly",
  "com.my",
  "com.ng",
  "com.pe",
  "com.ph",
  "com.pk",
  "com.py",
  "com.sv",
  "com.ua",
  "com.uy",
  "com.ve",
  "net.ly",
  "org.ly",
  "net.my",
  "org.my",
  "co.at",
  "co.id",
  "co.il",
  "co.ke",
  "co.th",
  "co.tz",
  "co.ug",
  "co.ve",
  // Multi-tenant suffixes share one parent across tenants, so the base
  // needs three labels to avoid widening onto a sibling tenant.
  "github.io",
  "gitlab.io",
  "vercel.app",
  "netlify.app",
  "github.dev",
  "githubusercontent.com",
  "googleusercontent.com",
  "herokuapp.com",
  "appspot.com",
  "blogspot.com",
  "wordpress.com",
  "tumblr.com",
  "myshopify.com",
  "azurewebsites.net",
  "cloudfront.net",
  "amazonaws.com",
  "s3.amazonaws.com",
  "elasticbeanstalk.com",
  "firebaseapp.com",
  "pages.dev",
  "web.app",
  "workers.dev",
  "deno.dev",
  "onrender.com",
  "fly.dev",
  "glitch.me",
  "replit.app",
  "repl.co",
  "repl.run",
  "supabase.co",
  "duckdns.org",
  "ngrok.io",
  "trycloudflare.com",
]);

// Parses one resolver-accepted IPv4 part in decimal, octal, or hex.
// Returns null for non-numeric or out-of-range parts.
function parseIPv4NumericPart(part: string): number | null {
  if (!part) return null;
  if (part.startsWith("0x") || part.startsWith("0X")) {
    const hex = part.slice(2);
    if (!hex || hex.length > 8 || !/^[0-9a-fA-F]+$/.test(hex)) return null;
    const value = parseInt(hex, 16);
    return Number.isSafeInteger(value) && value <= 0xffffffff ? value : null;
  }
  if (part.length > 1 && part.startsWith("0") && /^[0-9]+$/.test(part)) {
    // Leading-zero parts resolve as octal when possible, decimal otherwise,
    // matching the engine resolver the widening mirror must agree with.
    const radix = /^[0-7]+$/.test(part) ? 8 : 10;
    const value = parseInt(part, radix);
    return Number.isSafeInteger(value) && value <= 0xffffffff ? value : null;
  }
  if (!/^[0-9]+$/.test(part)) return null;
  const value = parseInt(part, 10);
  return Number.isSafeInteger(value) && value <= 0xffffffff ? value : null;
}

// Reports whether a cleaned host is an IPv4 literal under resolver rules.
// Single-numeric and short-dotted forms count, so 127.1 matches the engine.
function isIPv4Literal(cleaned: string): boolean {
  const parts = cleaned.split(".");
  if (parts.length < 1 || parts.length > 4) return false;
  const values: number[] = [];
  for (const part of parts) {
    const value = parseIPv4NumericPart(part);
    if (value === null) return false;
    values.push(value);
  }
  if (values.length === 2) return values[0] <= 255 && values[1] <= 0xffffff;
  if (values.length === 3) {
    return values[0] <= 255 && values[1] <= 255 && values[2] <= 0xffff;
  }
  if (values.length === 4) return values.every((v) => v <= 255);
  return true;
}

// Reports whether every dot-separated label is digits, so invalid-octet quads
// like 1.2.3.999 refuse the same widening the engine's guard refuses.
function isNumericDottedHost(cleaned: string): boolean {
  const labels = cleaned.split(".");
  return (
    labels.length >= 2 && labels.every((label) => /^[0-9]+$/.test(label))
  );
}

// Computes the registrable base domain for a host so the user can widen
// `api.example.com` to `*.example.com`. Returns null for IPv4/IPv6 or numeric
// dotted literals, localhost, single-label hosts, and bare public suffixes.
export function widenableBaseDomain(
  rawHost: string | null | undefined,
): string | null {
  if (typeof rawHost !== "string") return null;
  let cleaned = rawHost.trim().toLowerCase();
  while (cleaned.endsWith(".")) {
    cleaned = cleaned.slice(0, -1);
  }
  if (!cleaned || cleaned.includes(":") || cleaned.includes("*")) return null;
  // Any localhost suffix resolves locally, so no parent wildcard may cover it.
  if (cleaned === "localhost" || cleaned.endsWith(".localhost")) return null;
  if (isIPv4Literal(cleaned)) return null;
  if (isNumericDottedHost(cleaned)) return null;
  const labels = cleaned.split(".");
  if (labels.length < 2 || labels.some((label) => label.length === 0)) {
    return null;
  }
  const lastTwo = `${labels[labels.length - 2]}.${labels[labels.length - 1]}`;
  if (MULTI_PART_PUBLIC_SUFFIXES.has(lastTwo)) {
    if (labels.length < 3) return null;
    return `${labels[labels.length - 3]}.${lastTwo}`;
  }
  return lastTwo;
}

// Fixed tool names the engine files system notices under: surfacing-only items that resolve
// through their mapped remedy, never through an approve/deny decision. The parity test pins this
// list to the engine's exact registry spellings (SystemNoticeTools.toolNames).
export const SYSTEM_NOTICE_TOOL_NAMES: string[] = [
  "sovereign.mismatch",
  "security.probe",
];

// Reports whether a request is an engine-filed system notice.
export function isSystemNoticeTool(toolName: string): boolean {
  return SYSTEM_NOTICE_TOOL_NAMES.includes(toolName);
}

// Visible target length before the shared ellipsis cut. Rendering truncates
// here with the full value on the title tooltip while the full arguments
// stay in the View arguments disclosure.
const MAX_TARGET_LENGTH = 80;

// Argument keys target derivation reads, in priority order, so the preview
// line names the same thing a stored rule would cover.
const TARGET_ARGUMENT_KEYS = [
  "to",
  "recipient",
  "email",
  "target",
  "path",
  "url",
  "address",
  "destination",
];

// Reports whether a request is egress-parked: a non-blank host tag means the
// call dialed an unlisted network host under the full seven-tier vocabulary
// (thisTime/forTask/forSession/fiveMinutes/oneHour/oneDay/forever).
function isEgressParked(request: PermissionRequest): boolean {
  return (
    typeof request.egressHost === "string" &&
    request.egressHost.trim().length > 0
  );
}

// Picks the durations one request offers: the full shared vocabulary for both
// ordinary and egress-parked requests.
export function durationOptionsFor(
  request: PermissionRequest,
): Array<{ value: TrustDuration; label: string }> {
  if (!isEgressParked(request)) return trustDurationOptions;
  return EGRESS_DURATIONS.map((value) =>
    trustDurationOptions.find((option) => option.value === value),
  ).filter(
    (option): option is { value: TrustDuration; label: string } =>
      option !== undefined,
  );
}

// Reads one trimmed string field from a parsed arguments record. Blank and
// non-string shapes name no target and fall through to the next key.
function trimmedArg(record: Record<string, unknown>, key: string): string | null {
  const value = record[key];
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

// Best-effort preview of the request's own target. The stored displayTarget wins when present;
// older payloads predating the field fall back to the egress host first, then the bash command, then
// the argument key scan.
export function deriveRequestTarget(
  request: PermissionRequest,
): string | null {
  const stored = request.displayTarget;
  if (typeof stored === "string" && stored.trim().length > 0) {
    return stored.trim();
  }
  if (isEgressParked(request)) {
    return (request.egressHost as string).trim();
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(request.input?.argumentsJSON ?? "");
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (request.toolName === "bash.exec") {
    const command = trimmedArg(parsed, "command");
    if (command) return command;
  }
  for (const key of TARGET_ARGUMENT_KEYS) {
    const value = trimmedArg(parsed, key);
    if (value) return value;
  }
  return null;
}

// Truncates a target for one-line rendering. Values at or under the bound
// pass through untouched; longer values cut at the bound with an ellipsis.
export function truncateTarget(value: string): string {
  if (typeof value !== "string" || value.length <= MAX_TARGET_LENGTH) {
    return value;
  }
  return `${value.slice(0, MAX_TARGET_LENGTH)}…`;
}
