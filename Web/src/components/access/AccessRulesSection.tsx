// Rune Weaver Dashboard — Rules section of the owner access configuration surface.
//
// Purpose: Lists every durable access rule as one row per tool-plus-scope and
// lets the owner revoke or edit one without touching a parked approval. A
// plain-English header, derived from the active allow rules grouped by tool,
// states what the agent may still do on its own; the table underneath carries
// the durable allow and deny rules with their scope, tier, expiry, and usage
// counters, capped so a large store stays scrollable under a sticky header.
// Scope: Reading the rule list, the Add Rule / Edit Rule modal (effect pill
// toggle, approval-tool dropdown with a write-in fallback, tool-wide versus
// specific-target scope builder with adaptive hints, and the duration picker),
// the filter toolbar, live refresh on the access_rules_changed frame plus a
// quiet poll, and the deep-link highlight. A duration-only edit re-arms the
// stored rule in place so its identity and usage counters survive; every other
// edit mints its replacement first and revokes the stored original only after
// that mint succeeds, because a rule's identity is its tool-plus-scope while a
// failed mint must leave the stored rule — a deny above all — exactly as the
// owner left it.
// Whether a rule matches a call and the deny-outranks decision order stay with
// the engine's permission gate; this section only renders and edits owner
// intent, and never re-implements scope comparison.
// Architectural role: the landing section of the Access pane; it reuses the
// shared access-wording helpers so its scope lines, its grouped header, and its
// tier labels read one vocabulary, and refetches on the same 30s cadence the
// counters surface uses.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  createRule,
  listRules,
  parseRuleExpiry,
  rearmRule,
  revokeRule,
  type AccessRule,
  type AccessScopeDTO,
  type NewAccessRuleInput,
  type TrustDuration,
} from "../../api";
import { useSharedWebSocket } from "../../hooks/useSharedWebSocket";
import { formatRelativeAgo, formatRelativeIn } from "../../relativeTime";
import {
  accessRulesHeaderSentence,
  describeAccessScope,
  formatRuleDurationLabel,
} from "./accessWording";
import Modal from "../Modal";
import { AlertTriangleIcon, CloseIcon, EditIcon, PlusIcon, TrashIcon } from "../icons";

// Quiet refresh cadence between frames, matching the counters surface so a
// long-lived tab stays honest while the socket is quiet.
const POLL_INTERVAL_MS = 30_000;

// Render cap so a large rule store never grows the DOM without bound; the
// wrapper scrolls and the header sticks while the count line names the cap.
const MAX_RENDERED_RULES = 200;

// Bound on a rule's tool name so an unbounded write-in never reaches the
// wire. Shipped tool names are far shorter; the cap exists for the modal's
// fail-closed guard, not for anything the engine registers.
const MAX_TOOL_NAME_CHARS = 128;

// Bound on a rule's reason so an unbounded paste never persists to the rule
// store: the reason renders in every table row and rides every denial text
// the agent reads. Shipped reasons are a sentence; the cap exists for the
// modal's fail-closed guard, mirroring the tool and target caps.
const MAX_RULE_REASON_CHARS = 512;

// The durable tiers a standing allow rule can carry: the three dated spans
// plus forever. The ephemeral thisTime/forTask/forSession tiers mint no
// durable rule, so the duration picker never offers them. Deny rules always
// carry forever.
const ALLOW_DURATION_TIERS: TrustDuration[] = [
  "fiveMinutes",
  "oneHour",
  "oneDay",
  "forever",
];

// The two effects a rule can carry, rendered as a segmented pill pair. Allow
// auto-approves a matching call until it lapses; a deny parks it every time,
// outranks every allow, and is removed only by an explicit revoke.
const RULE_EFFECT_OPTIONS: Array<{ value: "allow" | "deny"; label: string; detail: string }> = [
  { value: "allow", label: "Allow", detail: "auto-approve" },
  { value: "deny", label: "Deny", detail: "always park / refuse" },
];

// Human expiry reading for one rule. A null expiry is the forever tier; a
// future expiry counts down; a past expiry reads lapsed so an owner can tell an
// expired rule from a standing one without comparing clocks.
function expiryLabel(rule: AccessRule, nowMs: number): string {
  const expiresAt = parseRuleExpiry(rule.expiresAt);
  if (expiresAt === null) return "Never";
  const remaining = expiresAt.getTime() - nowMs;
  if (remaining <= 0) return "Expired";
  return formatRelativeIn(remaining);
}

// Human last-used reading for one rule. An absent or null clock means the rule
// never fired, so it reads "Never" instead of the epoch.
function lastUsedLabel(rule: AccessRule, nowMs: number): string {
  const usedAt = parseRuleExpiry(rule.lastUsedAt);
  if (usedAt === null) return "Never";
  return formatRelativeAgo(nowMs - usedAt.getTime());
}

// Splits a target into a scope. Blank opens a tool-wide scope (all calls);
// a value narrows to that one exact target.
function scopeFromTarget(target: string): AccessScopeDTO {
  const trimmed = target.trim();
  return trimmed ? { kind: "exactTarget", target: trimmed } : { kind: "tool" };
}

// Prefills the scope builder from a stored rule. Tool-wide reads blank; every
// specific kind reads its naming field so an exotic scope never prefills as a
// blank exact target that would silently convert on save.
function extractTargetValue(scope: AccessScopeDTO): string {
  const kind = (scope as { kind?: unknown }).kind;
  if (kind === "exactTarget") {
    const target = (scope as unknown as { target?: unknown }).target;
    return typeof target === "string" ? target : "";
  }
  if (kind === "domain") {
    const host = (scope as unknown as { host?: unknown }).host;
    return typeof host === "string" ? host : "";
  }
  if (kind === "recipientSet") {
    const handles = (scope as unknown as { handles?: unknown }).handles;
    return Array.isArray(handles)
      ? handles.filter((entry): entry is string => typeof entry === "string").join(", ")
      : "";
  }
  if (kind === "pathPrefix") {
    const path = (scope as unknown as { path?: unknown }).path;
    return typeof path === "string" ? path : "";
  }
  if (kind === "glob") {
    const pattern = (scope as unknown as { pattern?: unknown }).pattern;
    return typeof pattern === "string" ? pattern : "";
  }
  return "";
}

// Effect one row renders from. Either wire spelling is read in precedence order
// so a legacy `action` payload still renders; a payload carrying neither names
// no trust, so it fails closed and reads Deny rather than presenting an
// unreadable rule as auto-approved.
function getRuleEffect(rule: AccessRule): "allow" | "deny" {
  return rule.effect ?? rule.action ?? "deny";
}

// Whether a stored scope outside the builder's own two shapes can still be
// rewritten by it. A recipient set naming exactly one canonical handle is the
// same trust as an exact target to that handle, so it rewrites losslessly;
// every other stored shape (a multi-handle set, a domain with its subdomain
// flag, a path prefix, a glob) carries meaning an exact target cannot
// reproduce, so the builder has to refuse rather than silently drop breadth
// the owner never chose to narrow.
function hasSingleTargetShape(scope: AccessScopeDTO): boolean {
  if (scope.kind !== "recipientSet") return false;
  return scope.handles.filter((handle) => handle.trim().length > 0).length === 1;
}

// The one field a scope kind names, trimmed, or null when the kind names no
// field (tool-wide) or the field is missing. Recipient sets read as a sorted
// copy of their trimmed handles, because the engine's recipient matcher
// normalizes member order and casing, so a reordered set is the same trust.
function scopeNamingField(scope: AccessScopeDTO, kind: string): string | string[] | null {
  const record = scope as unknown as Record<string, unknown>;
  if (kind === "exactTarget") {
    return typeof record.target === "string" ? record.target.trim() : null;
  }
  if (kind === "recipientSet") {
    return Array.isArray(record.handles)
      ? record.handles
          .filter((handle): handle is string => typeof handle === "string")
          .map((handle) => handle.trim())
          .sort()
      : null;
  }
  if (kind === "domain") {
    return typeof record.host === "string" ? record.host.trim() : null;
  }
  if (kind === "pathPrefix") {
    return typeof record.path === "string" ? record.path.trim() : null;
  }
  if (kind === "glob") {
    return typeof record.pattern === "string" ? record.pattern.trim() : null;
  }
  return null;
}

// Structural scope equality: compares the kind plus only the field that kind
// names, so a key reordered in either payload reads as the same scope instead
// of degrading a duration-only edit into a mint-plus-revoke that loses the
// rule's identity and usage counters. Trims each naming field the way the
// sibling target comparison does; the engine keeps exact targets
// byte-for-byte, so no case folding happens here. Tool-wide reads equal under
// either wire spelling (`tool` and the legacy `toolWide`), because both name
// every call of the tool.
function scopesEqual(a: AccessScopeDTO, b: AccessScopeDTO): boolean {
  const kindA = (a as { kind?: unknown }).kind;
  const kindB = (b as { kind?: unknown }).kind;
  const toolWideA = kindA === "tool" || kindA === "toolWide";
  const toolWideB = kindB === "tool" || kindB === "toolWide";
  if (toolWideA || toolWideB) return toolWideA && toolWideB;
  if (kindA !== kindB) return false;
  const fieldA = scopeNamingField(a, kindA as string);
  const fieldB = scopeNamingField(b, kindB as string);
  if (Array.isArray(fieldA) && Array.isArray(fieldB)) {
    if (fieldA.length !== fieldB.length) return false;
    return fieldA.every((handle, index) => handle === fieldB[index]);
  }
  if (Array.isArray(fieldA) || Array.isArray(fieldB)) return false;
  return fieldA === fieldB;
}

// Longest typed recipient the handle classifier accepts, mirroring the engine's
// recipient query bound so an over-long value fails the same way on both sides
// of the wire.
const MAX_HANDLE_QUERY_CHARS = 500;

// Email handle shape: local part, `@`, dotted domain, 2+ letter TLD. Anchored
// and case-insensitive, so a valid address wrapped in trailing junk fails here
// instead of canonicalizing to the junk.
const EMAIL_HANDLE_SHAPE = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Za-z]{2,}$/i;

// Whether a trimmed value spells a phone number: one optional leading `+`,
// then only space, dash, parens, and dot separating 7–15 ASCII digits. A `+`
// anywhere else, a non-ASCII digit, or any other character disqualifies it, so
// a near-miss spelling falls through to name classification rather than
// masquerading as a handle.
function isPhoneHandleShape(value: string): boolean {
  let digitCount = 0;
  for (let index = 0; index < value.length; index += 1) {
    const ch = value.charAt(index);
    if (index === 0 && ch === "+") continue;
    if (ch === " " || ch === "-" || ch === "(" || ch === ")" || ch === ".") continue;
    if (ch < "0" || ch > "9") return false;
    digitCount += 1;
  }
  return digitCount >= 7 && digitCount <= 15;
}

// Canonical phone spelling: leading `+` preserved, every separator dropped.
// Only called for a value that already passed the phone shape, so the
// surviving characters are all ASCII digits within the bound.
function canonicalPhoneHandle(value: string): string {
  const digits = value.replace(/[^0-9]/g, "");
  return value.charAt(0) === "+" ? `+${digits}` : digits;
}

// Canonical handle for one typed recipient, or null when the value names a
// person rather than a handle. Mirrors the engine's recipient classifier so the
// form refuses a send target the engine would reject; the engine stays the
// single owner of the rule this echoes.
function canonicalMessageHandle(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed || trimmed.length > MAX_HANDLE_QUERY_CHARS) return null;
  if (EMAIL_HANDLE_SHAPE.test(trimmed)) return trimmed;
  if (isPhoneHandleShape(trimmed)) return canonicalPhoneHandle(trimmed);
  return null;
}

// Whether one specific-target value may back a durable `messages.send` rule.
// Mirrors the engine's mintable-send-scope invariant: a wildcard pattern
// persists, and every other target must itself spell a canonical handle, so a
// display name is refused in the form before any network write rather than
// failing afterward against a rule the edit already touched. Validation only —
// scope matching stays with the engine's permission gate.
function isMintableSendTarget(target: string): boolean {
  if (target.includes("*") || target.includes("?")) return true;
  return canonicalMessageHandle(target) === target;
}

const APPROVAL_REQUIRING_TOOLS = [
  { value: "email.send", label: "Email (email.send)" },
  { value: "messages.send", label: "Messages & SMS (messages.send)" },
  { value: "bash.exec", label: "Bash & Shell (bash.exec)" },
  { value: "files.write", label: "Files Write (files.write)" },
  { value: "browser.act", label: "Browser Action (browser.act)" },
  { value: "web.fetch", label: "Web Fetch (web.fetch)" },
  { value: "api.request", label: "Outbound API (api.request)" },
  { value: "desktop.action", label: "Desktop Action (desktop.action)" },
] as const;

function getTargetFieldInfo(tool: string) {
  if (tool === "email.send") {
    return {
      label: "Recipient / Pattern",
      placeholder: "e.g. someone@example.com or *@example.com",
      hint: "Target email address or wildcard pattern.",
    };
  }
  if (tool === "messages.send") {
    return {
      label: "Recipient / Pattern",
      placeholder: "e.g. +15551234567 or +1555*",
      hint: "Target phone number or prefix pattern.",
    };
  }
  if (tool === "bash.exec") {
    return {
      label: "Command / Pattern",
      placeholder: "e.g. git status, npm test, rm *",
      hint: "Command name or argument pattern.",
    };
  }
  if (tool === "files.write") {
    return {
      label: "Path Prefix / Pattern",
      placeholder: "e.g. ~/Documents/* or /tmp/*",
      hint: "File path, directory prefix, or wildcard pattern.",
    };
  }
  if (tool === "api.request") {
    return {
      label: "Method & URL Pattern",
      placeholder: "e.g. GET https://api.kraken.com/* or * https://*.kraken.com/*",
      hint: "HTTP method and URL pattern. Use '*' for any method or path.",
    };
  }
  if (tool === "web.fetch") {
    return {
      label: "URL Pattern",
      placeholder: "e.g. https://api.kraken.com/* or https://*.kraken.com/*",
      hint: "Target URL or wildcard pattern.",
    };
  }
  if (tool === "browser.act") {
    return {
      label: "Action & URL Pattern",
      placeholder: "e.g. * @ https://example.com/* or click *",
      hint: "Action selector and URL pattern.",
    };
  }
  return {
    label: "Target / Pattern (optional)",
    placeholder: "e.g. target identifier or wildcard pattern",
    hint: "Target parameter or value to match (supports wildcards).",
  };
}

// Mints the replacement rule for an edit, resolving only once the engine has
// stored it. The mint's success is the stored write rather than the echoed
// rule — the section discards the echo because it refetches the list once the
// edit settles — so a 2xx answer whose body the client cannot read as a rule
// still proves the replacement landed. A rejection that proves nothing was
// stored rethrows so the caller's catch surfaces the refusal and leaves the
// stored rule standing: revoking behind a mint that never landed would trade a
// live rule for one that never existed.
async function mintReplacement(input: NewAccessRuleInput): Promise<void> {
  try {
    await createRule(input);
  } catch (err: unknown) {
    if (!mintStoredDespite(err)) throw err;
  }
}

// Whether a rejected mint still proves the engine stored the replacement. A
// 2xx status carries that proof for a body the client could not normalize. The
// bodyless-204 generation of POST /approvals/rules reaches the caller as a
// statusless ApiError from api.ts's fail-closed response guard, so its
// response-shape wording carries the same proof. Every other rejection — the
// gate's non-2xx refusal, a request the client refused to send before the
// wire, a transport failure — proves the replacement never stored.
function mintStoredDespite(error: unknown): boolean {
  if (!(error instanceof ApiError)) return false;
  if (error.status >= 200 && error.status < 300) return true;
  return error.status === 0 && /response/i.test(error.message);
}

export interface AccessRulesSectionProps {
  // Rule id a deep link asked to preselect and highlight, or null. The matching
  // row is marked so an owner following a link lands on the exact rule.
  highlightRuleId?: string | null;
}

// Rules section of the access pane: the durable allow and deny rules with the
// Add Rule / Edit Rule modal, the revoke confirmation, and the filter toolbar.
// Every rail section mounts on demand, so the component is always rendered
// against a live table rather than a stashed body.
export function AccessRulesSection({
  highlightRuleId = null,
}: AccessRulesSectionProps) {
  const [rules, setRules] = useState<AccessRule[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  // Whether the first list read has settled, so the plain-English header never
  // asserts a coverage the fetch has not answered yet. Once true it stays
  // true: a later poll failure keeps the last known reading beside the error
  // banner instead of blanking the sentence back to "no trust at all".
  const [hasLoadedRules, setHasLoadedRules] = useState<boolean>(false);

  // Revoke modal state. The pending rule stays beside its own error so a
  // refusal surfaces inside that modal and never leaks to a sibling, while
  // busyRuleId locks only the row whose action is in flight.
  const [pendingRevoke, setPendingRevoke] = useState<AccessRule | null>(null);
  const [revokeError, setRevokeError] = useState<string | null>(null);
  const [busyRuleId, setBusyRuleId] = useState<string | null>(null);

  // Add & Edit rule modal state: the effect pill toggle, the approval-tool
  // dropdown plus its write-in fallback, the tool-wide versus specific-target
  // scope builder, the duration picker, and the optional reason.
  const [isAddModalOpen, setIsAddModalOpen] = useState<boolean>(false);
  const [editingRule, setEditingRule] = useState<AccessRule | null>(null);
  const [ruleEffect, setRuleEffect] = useState<"allow" | "deny">("allow");
  const [selectedTool, setSelectedTool] = useState<string>("email.send");
  const [customTool, setCustomTool] = useState<string>("");
  const [scopeKind, setScopeKind] = useState<"tool" | "exactTarget">("exactTarget");
  const [targetValue, setTargetValue] = useState<string>("");
  const [durationValue, setDurationValue] = useState<TrustDuration>("forever");
  const [ruleReason, setRuleReason] = useState<string>("");
  const [ruleSubmitting, setRuleSubmitting] = useState<boolean>(false);
  const [ruleFormError, setRuleFormError] = useState<string | null>(null);

  // Table filter state
  const [filterEffect, setFilterEffect] = useState<"all" | "allow" | "deny">("all");

  // Row a deep link names, held so the reveal effect below can scroll it into
  // view: the table caps at 200 rows inside a scroll wrapper, so a marked row
  // far down the list would land invisibly where the link pointed.
  const highlightedRowRef = useRef<HTMLTableRowElement | null>(null);
  // Which linked rule the reveal already covered, so a later refresh cannot
  // yank the owner back to a row they deliberately scrolled away from.
  const scrolledHighlightRef = useRef<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const response = await listRules();
      setRules(Array.isArray(response.rules) ? response.rules : []);
      setHasLoadedRules(true);
    } catch (err: unknown) {
      setLoadError(err instanceof ApiError ? err.message : "Failed to load access rules.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Frame plus poll: any rule write broadcasts access_rules_changed so every
  // open dashboard refetches, and the quiet poll keeps the counters honest when
  // the socket is silent. Both call the same refresh so there is one read path.
  const handleFrame = useCallback(
    (frame: unknown) => {
      if ((frame as { type?: string }).type === "access_rules_changed") {
        void refresh();
      }
    },
    [refresh],
  );

  useSharedWebSocket(handleFrame);

  useEffect(() => {
    const interval = setInterval(() => {
      void refresh();
    }, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [refresh]);

  // Reveals the deep-linked rule once the fetched list renders it: the table
  // caps at 200 rows inside a scroll wrapper, so a marked row far down the
  // list would be invisible exactly where the link landed. The reveal fires
  // once per linked rule so a refresh cannot steal the scroll position back;
  // the existence guard covers a fetch still in flight, and the scrollIntoView
  // guard covers hosts that do not implement it.
  useEffect(() => {
    if (!highlightRuleId || scrolledHighlightRef.current === highlightRuleId) return;
    const row = highlightedRowRef.current;
    if (!row) return;
    scrolledHighlightRef.current = highlightRuleId;
    if (typeof row.scrollIntoView !== "function") return;
    row.scrollIntoView({ block: "nearest" });
  }, [highlightRuleId, rules]);

  // Rows list the durable allows first and then the durable denies, keeping the
  // server order stable inside each group so a refresh never reshuffles rows.
  const allowRules = rules.filter((rule) => getRuleEffect(rule) === "allow");
  const denyRules = rules.filter((rule) => getRuleEffect(rule) === "deny");
  const orderedRules = [...allowRules, ...denyRules];
  // The filter picks one grouping directly: the groupings are rebuilt every
  // render, so a memo here would never hit and would only obscure the read.
  const displayedRules =
    filterEffect === "allow"
      ? allowRules
      : filterEffect === "deny"
        ? denyRules
        : orderedRules;
  // Cap the rendered rows so the table stays scrollable with a sticky header.
  const renderedRules = displayedRules.slice(0, MAX_RENDERED_RULES);
  const nowMs = Date.now();

  function openRevoke(rule: AccessRule) {
    setRevokeError(null);
    setPendingRevoke(rule);
  }

  function cancelRevoke() {
    if (busyRuleId && pendingRevoke && busyRuleId === pendingRevoke.id) return;
    setPendingRevoke(null);
    setRevokeError(null);
  }

  async function confirmRevoke() {
    if (!pendingRevoke) return;
    const id = pendingRevoke.id;
    setBusyRuleId(id);
    setRevokeError(null);
    try {
      await revokeRule(id);
      await refresh();
      setPendingRevoke(null);
    } catch (err: unknown) {
      setRevokeError(err instanceof ApiError ? err.message : "Failed to revoke the rule.");
    } finally {
      setBusyRuleId(null);
    }
  }

  function openAddRule() {
    setEditingRule(null);
    setRuleFormError(null);
    setRuleEffect("allow");
    setSelectedTool("email.send");
    setCustomTool("");
    setScopeKind("exactTarget");
    setTargetValue("");
    setDurationValue("forever");
    setRuleReason("");
    setIsAddModalOpen(true);
  }

  function openEdit(rule: AccessRule) {
    setEditingRule(rule);
    setRuleFormError(null);
    setRuleEffect(getRuleEffect(rule));
    setSelectedTool(rule.toolName || "email.send");
    setCustomTool("");
    const editingScopeKind = (rule.scope as { kind?: unknown }).kind;
    const isToolWide = editingScopeKind === "tool" || editingScopeKind === "toolWide";
    setScopeKind(isToolWide ? "tool" : "exactTarget");
    setTargetValue(extractTargetValue(rule.scope));
    setDurationValue((rule.duration as TrustDuration) ?? "forever");
    setRuleReason(rule.reason ?? "");
    setIsAddModalOpen(true);
  }

  function closeRuleModal() {
    if (ruleSubmitting) return;
    setIsAddModalOpen(false);
    setEditingRule(null);
    setRuleFormError(null);
  }

  // Mints or updates an access rule (allow or deny) from the Rule modal.
  async function submitAddRule() {
    const effectiveTool = (customTool.trim() || selectedTool).trim();
    if (!effectiveTool) {
      setRuleFormError("Select a tool.");
      return;
    }
    // A tool name carrying control characters or newlines names no registered
    // tool, so the write-in fails closed instead of minting a rule the gate
    // can never match; the cap keeps an unbounded paste off the wire.
    if (
      Array.from(effectiveTool).some((ch) => {
        const code = ch.charCodeAt(0);
        return code < 32 || code === 127;
      })
    ) {
      setRuleFormError("Tool name must not contain control characters or newlines.");
      return;
    }
    if (effectiveTool.length > MAX_TOOL_NAME_CHARS) {
      setRuleFormError(`Tool name must be at most ${MAX_TOOL_NAME_CHARS} characters.`);
      return;
    }
    // A specific-target scope with no target names nothing, so it fails here
    // instead of silently widening to tool-wide.
    if (scopeKind === "exactTarget" && !targetValue.trim()) {
      setRuleFormError("Enter a target or choose tool-wide scope.");
      return;
    }
    const trimmedTarget = targetValue.trim();
    if (scopeKind === "exactTarget" && trimmedTarget.length > 1024) {
      setRuleFormError("Target must be at most 1024 characters.");
      return;
    }
    // Control characters and newlines name no repeatable target, so the modal
    // fails closed instead of minting a rule the gate cannot match.
    if (
      scopeKind === "exactTarget" &&
      Array.from(trimmedTarget).some((ch) => {
        const code = ch.charCodeAt(0);
        return code < 32 || code === 127;
      })
    ) {
      setRuleFormError("Target must not contain control characters or newlines.");
      return;
    }
    // A send rule with no recipient would trust every recipient, so tool-wide
    // send scope fails closed here.
    if (effectiveTool === "messages.send" && scopeKind === "tool") {
      setRuleFormError("Messages send rules must name a recipient or pattern.");
      return;
    }
    // Send trust keys to the exact canonical handle the owner authorized, so a
    // display-name target fails here mirroring the engine's mintable-send-scope
    // invariant instead of reaching the wire, where it would be refused only
    // after the edit had already touched the stored rule.
    if (
      effectiveTool === "messages.send" &&
      scopeKind === "exactTarget" &&
      !isMintableSendTarget(trimmedTarget)
    ) {
      setRuleFormError(
        "Messages send rules must name a canonical phone number or email address, or a wildcard pattern.",
      );
      return;
    }
    // Deny rules persist until explicitly revoked, so any non-forever deny
    // tier is refused rather than coerced.
    if (ruleEffect === "deny" && durationValue !== "forever") {
      setRuleFormError("Deny rules never expire: duration must be Forever.");
      return;
    }
    if (ruleEffect === "allow" && !ALLOW_DURATION_TIERS.includes(durationValue)) {
      setRuleFormError("Allow rules need a duration of 5 minutes, 1 hour, 1 day, or Forever.");
      return;
    }
    const scope: AccessScopeDTO =
      scopeKind === "tool" ? { kind: "tool" } : scopeFromTarget(targetValue);
    const duration: TrustDuration = ruleEffect === "deny" ? "forever" : durationValue;
    const reason = ruleReason.trim();
    // The reason renders in every table row and rides every denial text the
    // agent reads, so an unbounded paste fails closed here mirroring the tool
    // and target caps instead of persisting a wall of text to the store.
    if (reason.length > MAX_RULE_REASON_CHARS) {
      setRuleFormError(`Reason must be at most ${MAX_RULE_REASON_CHARS} characters.`);
      return;
    }

    const payload: NewAccessRuleInput & { reason?: string } = {
      tool: effectiveTool,
      toolName: effectiveTool,
      effect: ruleEffect,
      action: ruleEffect,
      scope,
      duration,
      ...(reason ? { reason } : {}),
    };

    setRuleSubmitting(true);
    setRuleFormError(null);
    try {
      if (editingRule) {
        const editingKind = (editingRule.scope as { kind?: unknown }).kind;
        const prevDuration = (editingRule.duration ?? "forever") as TrustDuration;
        const prevReason = editingRule.reason ?? "";
        // The builder writes only a tool-wide or a specific-target scope, so a
        // stored shape it cannot reproduce keeps its own: only an allow duration
        // change applies in place. A single-handle recipient set is the one
        // exception, because that is the same trust as the exact target it
        // rewrites to, so it flows through the ordinary edit path below.
        const builderOwnsStoredScope =
          editingKind === "tool" ||
          editingKind === "toolWide" ||
          editingKind === "exactTarget" ||
          hasSingleTargetShape(editingRule.scope);
        if (!builderOwnsStoredScope) {
          const scopeTouched =
            effectiveTool !== (editingRule.toolName || "") ||
            ruleEffect !== getRuleEffect(editingRule) ||
            reason !== prevReason ||
            scopeKind !== "exactTarget" ||
            targetValue.trim() !== extractTargetValue(editingRule.scope).trim();
          if (scopeTouched) {
            setRuleFormError("This rule's scope needs revoke and a new rule to change.");
            return;
          }
          if (ruleEffect === "allow" && duration !== prevDuration) {
            await rearmRule(editingRule.id, duration);
            setIsAddModalOpen(false);
            setEditingRule(null);
            await refresh();
            return;
          }
          setRuleFormError("No changes to save.");
          return;
        }
        // Structural equality instead of a serialized string: key order in
        // either payload must not read as a scope change, or a duration-only
        // edit silently degrades to mint-plus-revoke and loses the rule's
        // identity and usage counters.
        const scopeUnchanged = scopesEqual(scope, editingRule.scope);
        const toolUnchanged = (editingRule.toolName || "") === effectiveTool;
        const effectUnchanged = getRuleEffect(editingRule) === ruleEffect;
        if (scopeUnchanged && toolUnchanged && effectUnchanged && reason === prevReason) {
          if (duration === prevDuration) {
            setRuleFormError("No changes to save.");
            return;
          }
          // Duration-only change stays in place so identity and counters survive.
          if (ruleEffect === "allow") {
            await rearmRule(editingRule.id, duration);
            setIsAddModalOpen(false);
            setEditingRule(null);
            await refresh();
            return;
          }
        }
        // Mint the replacement before retiring the stored rule: a durable deny
        // outranks every allow and is removed only by an explicit revoke, so an
        // edit the owner never committed must never be what deletes the old
        // row. Only a mint the engine stored revokes the original; a mint that
        // was refused or never landed leaves the stored rule standing for a
        // retry.
        await mintReplacement(payload);
        await revokeRule(editingRule.id);
      } else {
        await createRule(payload);
      }
      setIsAddModalOpen(false);
      setEditingRule(null);
      setTargetValue("");
      setCustomTool("");
      setRuleReason("");
      await refresh();
    } catch (err: unknown) {
      setRuleFormError(
        err instanceof ApiError
          ? err.message
          : `Failed to ${editingRule ? "update" : "add"} the access rule.`,
      );
    } finally {
      setRuleSubmitting(false);
    }
  }

  const headerSentence = accessRulesHeaderSentence(rules, nowMs);
  const targetInfo = getTargetFieldInfo((customTool.trim() || selectedTool).trim() || selectedTool);

  return (
    <section
      className="panel access-rules-section"
      aria-label="Access rules"
      data-testid="access-rules-section"
    >
      <div className="panel-header-row">
        <div>
          <h2>Rules</h2>
          <p className="muted text-sm">
            Standing rules that persist across turns. An allow rule auto-approves a
            matching call; a deny rule parks it every time and never expires.
          </p>
        </div>
        <div className="row" style={{ gap: "8px" }}>
          <button
            type="button"
            className="primary icon-text-btn"
            data-testid="access-add-rule-btn"
            onClick={openAddRule}
          >
            <PlusIcon size={14} />
            <span>Add Rule</span>
          </button>
        </div>
      </div>

      {hasLoadedRules ? (
        <p
          className="access-rules-header-sentence"
          data-testid="access-rules-header"
          aria-live="polite"
        >
          {headerSentence}
        </p>
      ) : !loadError ? (
        // The sentence asserts what the agent may do on its own, so it waits
        // for the first read to settle instead of briefly reading as no trust
        // at all while the list is still in flight. A failed first read shows
        // the error banner alone, since the coverage is genuinely unknown.
        <p className="muted text-sm" data-testid="access-rules-loading">
          Loading standing rules…
        </p>
      ) : null}

      {loadError ? (
        <div
          className="error-banner"
          data-testid="access-rules-load-error"
          style={{ marginBottom: "12px" }}
        >
          <AlertTriangleIcon size={16} />
          <span>{loadError}</span>
        </div>
      ) : null}

      <div className="access-rules-toolbar">
        <div className="access-rules-filter-group" role="group" aria-label="Filter rules">
          <button
            type="button"
            className={`access-filter-btn${filterEffect === "all" ? " active" : ""}`}
            data-testid="access-filter-all"
            onClick={() => setFilterEffect("all")}
          >
            All ({orderedRules.length})
          </button>
          <button
            type="button"
            className={`access-filter-btn${filterEffect === "allow" ? " active" : ""}`}
            data-testid="access-filter-allow"
            onClick={() => setFilterEffect("allow")}
          >
            Allow ({allowRules.length})
          </button>
          <button
            type="button"
            className={`access-filter-btn${filterEffect === "deny" ? " active" : ""}`}
            data-testid="access-filter-deny"
            onClick={() => setFilterEffect("deny")}
          >
            Deny ({denyRules.length})
          </button>
        </div>
      </div>

      {rules.length === 0 && !loading && !loadError ? (
        <p className="muted text-sm" data-testid="access-rules-empty">
          No standing rules yet. Approve a call with a dated or Forever tier to
          mint one, or add an allow or deny rule above.
        </p>
      ) : null}

      {displayedRules.length > MAX_RENDERED_RULES ? (
        <p className="muted text-sm" data-testid="access-rules-capped">
          Showing {MAX_RENDERED_RULES} of {displayedRules.length} rules.
        </p>
      ) : null}

      {renderedRules.length > 0 ? (
        <div className="access-rules-table-wrapper">
          <table className="access-rules-table" data-testid="access-rules-table">
            <thead>
              <tr>
                <th>Tool</th>
                <th>Scope</th>
                <th>Duration</th>
                <th>Expires</th>
                <th>Used</th>
                <th>Last used</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {renderedRules.map((rule) => {
                const highlighted = highlightRuleId === rule.id;
                const busy = busyRuleId === rule.id;
                return (
                  <tr
                    key={rule.id}
                    ref={highlighted ? highlightedRowRef : undefined}
                    className={`access-rule-row${highlighted ? " highlighted" : ""}`}
                    data-testid={`access-rule-row-${rule.id}`}
                    data-highlighted={highlighted ? "true" : undefined}
                  >
                    <td>
                      <span className="badge access-rule-tool-badge">{rule.toolName}</span>
                      <span
                        className={`badge access-rule-effect-badge effect-${getRuleEffect(rule)}`}
                      >
                        {getRuleEffect(rule) === "allow" ? "Allow" : "Deny"}
                      </span>
                    </td>
                    <td className="access-rule-scope">
                      <div className="access-rule-scope-desc">{describeAccessScope(rule.scope)}</div>
                      {rule.reason ? (
                        <div
                          className="access-rule-reason muted text-xs"
                          data-testid={`access-rule-reason-${rule.id}`}
                          style={{ marginTop: "4px" }}
                        >
                          <span style={{ opacity: 0.75 }}>Reason:</span> {rule.reason}
                        </div>
                      ) : null}
                    </td>
                    <td>{formatRuleDurationLabel(rule.duration)}</td>
                    <td>{expiryLabel(rule, nowMs)}</td>
                    <td>{rule.useCount ?? 0}</td>
                    <td>{lastUsedLabel(rule, nowMs)}</td>
                    <td className="access-rule-actions">
                      <button
                        type="button"
                        className="icon-button"
                        data-testid={`access-rule-edit-${rule.id}`}
                        title="Edit rule"
                        aria-label="Edit rule"
                        disabled={busy}
                        onClick={() => openEdit(rule)}
                      >
                        <EditIcon size={14} />
                      </button>
                      <button
                        type="button"
                        className="icon-button danger danger-hover"
                        data-testid={`access-rule-revoke-${rule.id}`}
                        title="Revoke rule"
                        aria-label="Revoke rule"
                        disabled={busy}
                        onClick={() => openRevoke(rule)}
                      >
                        <TrashIcon size={14} />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : null}

      {/* Add / Edit Rule Modal */}
      {isAddModalOpen ? (
        <Modal
          label={editingRule ? "Edit access rule" : "Add access rule"}
          onClose={closeRuleModal}
        >
          <div className="modal-header">
            <h3>{editingRule ? "Edit Access Rule" : "Add Access Rule"}</h3>
            <button
              type="button"
              className="icon-button"
              onClick={closeRuleModal}
              disabled={ruleSubmitting}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            {/* Effect selection */}
            <div className="form-group" style={{ marginBottom: "16px" }}>
              <label style={{ fontSize: "0.85rem", fontWeight: 600, display: "block", marginBottom: "6px" }}>
                Rule Effect
              </label>
              <div
                role="radiogroup"
                aria-label="Rule Effect"
                style={{ display: "flex", gap: "8px", flexWrap: "wrap" }}
              >
                {RULE_EFFECT_OPTIONS.map((option) => {
                  const selected = ruleEffect === option.value;
                  return (
                    <label
                      key={option.value}
                      className={`access-rule-effect-pill${selected ? ` active effect-${option.value}` : ""}`}
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: "6px",
                        padding: "8px 14px",
                        borderRadius: "999px",
                        border: `1px solid ${selected ? "var(--accent-purple)" : "var(--border-color)"}`,
                        background: selected
                          ? "rgba(147, 51, 234, 0.15)"
                          : "var(--bg-card)",
                        color: selected ? "#ffffff" : "var(--text-muted)",
                        fontWeight: selected ? 600 : 500,
                        cursor: "pointer",
                      }}
                    >
                      <input
                        type="radio"
                        name="ruleEffect"
                        value={option.value}
                        data-testid={`access-rule-effect-${option.value}`}
                        checked={selected}
                        onChange={() => setRuleEffect(option.value)}
                      />
                      <span>
                        {option.label} ({option.detail})
                      </span>
                    </label>
                  );
                })}
              </div>
            </div>

            {/* Tool Selection */}
            <div className="form-group" style={{ marginBottom: "16px" }}>
              <label htmlFor="access-rule-tool-select" style={{ fontSize: "0.85rem", fontWeight: 600, display: "block", marginBottom: "4px" }}>
                Tool
              </label>
              <select
                id="access-rule-tool-select"
                className="input-field"
                data-testid="access-rule-tool-select"
                value={selectedTool}
                onChange={(e) => {
                  setSelectedTool(e.target.value);
                }}
              >
                {!APPROVAL_REQUIRING_TOOLS.some((t) => t.value === selectedTool) && (
                  <option value={selectedTool}>{selectedTool}</option>
                )}
                {APPROVAL_REQUIRING_TOOLS.map((t) => (
                  <option key={t.value} value={t.value}>
                    {t.label}
                  </option>
                ))}
              </select>
              <label htmlFor="access-rule-tool-custom" style={{ fontSize: "0.82rem", display: "block", marginTop: "8px", marginBottom: "4px" }}>
                Custom tool (write-in)
              </label>
              <input
                id="access-rule-tool-custom"
                className="input-field"
                data-testid="access-rule-tool-custom"
                value={customTool}
                onChange={(e) => setCustomTool(e.target.value)}
                placeholder="e.g. my.custom.tool"
              />
              <span className="form-group-hint">
                {customTool.trim()
                  ? `Custom tool "${customTool.trim()}" overrides the dropdown above.`
                  : "Leave blank to use the dropdown selection."}
              </span>
            </div>

            {/* Scope Selection */}
            <div className="form-group" style={{ marginBottom: "16px" }}>
              <label style={{ fontSize: "0.85rem", fontWeight: 600, display: "block", marginBottom: "6px" }}>
                Scope
              </label>
              <div
                role="radiogroup"
                aria-label="Scope"
                style={{ display: "flex", gap: "16px", marginBottom: "8px", flexWrap: "wrap" }}
              >
                <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
                  <input
                    type="radio"
                    name="ruleScopeKind"
                    value="exactTarget"
                    checked={scopeKind === "exactTarget"}
                    onChange={() => setScopeKind("exactTarget")}
                  />
                  <span>Specific target or pattern</span>
                </label>
                <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
                  <input
                    type="radio"
                    name="ruleScopeKind"
                    value="tool"
                    checked={scopeKind === "tool"}
                    onChange={() => setScopeKind("tool")}
                  />
                  <span>All calls to this tool (tool-wide)</span>
                </label>
              </div>
              {scopeKind === "exactTarget" ? (
                <div>
                  <label htmlFor="access-deny-target" style={{ fontSize: "0.82rem", display: "block", marginBottom: "4px" }}>
                    {targetInfo.label}
                  </label>
                  <input
                    id="access-deny-target"
                    className="input-field"
                    data-testid="access-deny-target"
                    value={targetValue}
                    onChange={(e) => setTargetValue(e.target.value)}
                    placeholder={targetInfo.placeholder}
                  />
                  <span className="form-group-hint" style={{ display: "block", marginBottom: "6px" }}>{targetInfo.hint}</span>
                  <div
                    style={{
                      fontSize: "0.78rem",
                      color: "var(--color-text-secondary, #6b7280)",
                      background: "var(--color-bg-subtle, rgba(0, 0, 0, 0.03))",
                      padding: "6px 10px",
                      borderRadius: "6px",
                      border: "1px solid var(--color-border-subtle, rgba(0, 0, 0, 0.08))",
                    }}
                  >
                    💡 <strong>Wildcards:</strong> Use <code>*</code> to match any characters (e.g. <code>* https://api.kraken.com/*</code>, <code>GET https://*.kraken.com/*</code>, <code>*@example.com</code>, <code>/tmp/*</code>).
                  </div>
                </div>
              ) : null}
            </div>

            {/* Duration Selection (only for Allow) */}
            {ruleEffect === "allow" ? (
              <div className="form-group" style={{ marginBottom: "16px" }}>
                <label style={{ fontSize: "0.85rem", fontWeight: 600, display: "block", marginBottom: "6px" }}>
                  Duration
                </label>
                <div
                  role="radiogroup"
                  aria-label="Duration"
                  style={{ display: "flex", gap: "12px", flexWrap: "wrap" }}
                >
                  {ALLOW_DURATION_TIERS.map((tier) => (
                    <label
                      key={tier}
                      style={{ display: "flex", alignItems: "center", gap: "4px", cursor: "pointer" }}
                    >
                      <input
                        type="radio"
                        name="ruleDuration"
                        value={tier}
                        checked={durationValue === tier}
                        onChange={() => setDurationValue(tier)}
                      />
                      <span>{formatRuleDurationLabel(tier)}</span>
                    </label>
                  ))}
                </div>
              </div>
            ) : (
              <p className="form-group-hint" style={{ marginBottom: "16px" }}>
                Deny rules never expire and outrank every allow rule.
                {durationValue === "forever"
                  ? ""
                  : " A deny cannot carry a dated tier — switch back to Allow, choose Forever, then select Deny."}
              </p>
            )}

            {/* Reason */}
            <div className="form-group" style={{ marginBottom: "16px" }}>
              <label htmlFor="access-deny-reason" style={{ fontSize: "0.82rem", display: "block", marginBottom: "4px" }}>
                Reason (optional)
              </label>
              <input
                id="access-deny-reason"
                className="input-field"
                data-testid="access-deny-reason"
                value={ruleReason}
                onChange={(e) => setRuleReason(e.target.value)}
                placeholder={
                  ruleEffect === "deny"
                    ? "e.g. Production database — changes must go through CI/CD"
                    : "Why this rule is being created"
                }
              />
              <span className="form-group-hint">
                {ruleEffect === "deny"
                  ? "On tool denial, this explanation is returned directly to the agent so it knows why the action was refused."
                  : "Recorded for operator context and auditing."}
              </span>
            </div>

            {ruleFormError ? (
              <p className="error" role="alert" data-testid="access-deny-error" style={{ marginBottom: "12px" }}>
                {ruleFormError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={closeRuleModal}
              disabled={ruleSubmitting}
            >
              Cancel
            </button>
            <button
              type="button"
              className="primary icon-text-btn"
              data-testid="access-deny-submit"
              disabled={ruleSubmitting}
              onClick={() => void submitAddRule()}
            >
              {editingRule ? (
                <>
                  <EditIcon size={14} />
                  <span>{ruleSubmitting ? "Saving…" : "Save changes"}</span>
                </>
              ) : (
                <>
                  <PlusIcon size={14} />
                  <span>
                    {ruleSubmitting
                      ? "Adding…"
                      : `Add ${ruleEffect === "allow" ? "allow" : "deny"} rule`}
                  </span>
                </>
              )}
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingRevoke ? (
        <Modal label="Revoke rule" onClose={cancelRevoke}>
          <div className="modal-header">
            <h3>Revoke rule</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelRevoke}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted text-sm" style={{ margin: 0 }}>
              Revoke the {getRuleEffect(pendingRevoke) === "allow" ? "allow" : "deny"} rule
              for <code>{pendingRevoke.toolName}</code> (
              {describeAccessScope(pendingRevoke.scope)})? Revocation stops future
              matches only — calls already allowed stay in history.
            </p>
            {revokeError ? (
              <p className="error" role="alert" data-testid="access-revoke-error">
                {revokeError}
              </p>
            ) : null}
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelRevoke}
              disabled={busyRuleId === pendingRevoke.id}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              data-testid="access-revoke-confirm"
              onClick={() => void confirmRevoke()}
              disabled={busyRuleId === pendingRevoke.id}
            >
              {busyRuleId === pendingRevoke.id ? "Revoking…" : "Revoke"}
            </button>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}

export default AccessRulesSection;
