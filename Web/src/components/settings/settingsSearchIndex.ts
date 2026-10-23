// Rune Weaver Dashboard — Settings item search index and highlight helper.

import { SETTINGS_TABS, type SettingsTab } from "./settingsTypes";

export interface SettingsSearchItem {
  id: string;
  tab: SettingsTab;
  label: string;
  keywords: string;
  targetId: string;
}

export const SETTINGS_SEARCH_ITEMS: readonly SettingsSearchItem[] = [
  {
    id: "access-rules",
    tab: "access",
    label: "Access rules",
    keywords: "access rules allow deny standing trust scope duration",
    targetId: "access-tab-rules",
  },
  {
    id: "access-bash-shell",
    tab: "access",
    label: "Bash and shell policy",
    keywords: "access bash shell sandbox tier rules default action network",
    targetId: "access-tab-bash",
  },
  {
    id: "access-network",
    tab: "access",
    label: "Network policy",
    keywords: "access network section rail policy egress domains allow",
    targetId: "access-tab-network",
  },
  {
    id: "providers-default",
    tab: "providers",
    label: "Default provider",
    keywords: "providers llm default routing model chat",
    targetId: "default-provider",
  },
  {
    id: "providers-fallback",
    tab: "providers",
    label: "Fallback provider",
    keywords: "providers llm fallback backup routing model",
    targetId: "fallback-provider",
  },
  {
    id: "providers-add",
    tab: "providers",
    label: "Add Provider",
    keywords: "providers add new configure llm name routing",
    targetId: "providers-add-button",
  },
  {
    id: "persona-assistant-name",
    tab: "persona",
    label: "Assistant name",
    keywords: "persona assistant name identity",
    targetId: "persona-assistant-name",
  },
  {
    id: "persona-tone",
    tab: "persona",
    label: "Persona tone",
    keywords: "persona tone posture voice style",
    targetId: "persona-tone",
  },
  {
    id: "persona-user-name",
    tab: "persona",
    label: "Your Name",
    keywords: "persona user name address clause",
    targetId: "persona-user-name",
  },
  {
    id: "persona-style",
    tab: "persona",
    label: "Style Guidance",
    keywords: "persona style guidance free-form identity",
    targetId: "persona-style",
  },
  {
    id: "persona-avatar",
    tab: "persona",
    label: "Avatar Accent",
    keywords: "persona avatar accent color sprite client",
    targetId: "persona-avatar-grid",
  },
  {
    id: "voice-stt",
    tab: "voice",
    label: "Speech-to-text provider",
    keywords: "voice stt provider whisper speech transcription",
    targetId: "stt-provider",
  },
  {
    id: "voice-tts",
    tab: "voice",
    label: "Text-to-speech provider",
    keywords: "voice tts provider speech synthesis system",
    targetId: "tts-provider",
  },
  {
    id: "voice-whisper-model",
    tab: "voice",
    label: "Whisper Model",
    keywords: "voice whisper model stt transcription size tiny base small",
    targetId: "whisper-model",
  },
  {
    id: "memory-backend",
    tab: "memory",
    label: "Embedding backend",
    keywords: "memory embedding backend local provider none vectors metal",
    targetId: "embedding-backend",
  },
  {
    id: "memory-episodes-path",
    tab: "memory",
    label: "Episodes database path",
    keywords: "memory episodes db path storage persistence sqlite",
    targetId: "episodes-path",
  },
  {
    id: "memory-recall-limit",
    tab: "memory",
    label: "Recall Limit",
    keywords: "memory recall auto limit hits context depth",
    targetId: "recall-auto-limit",
  },
  {
    id: "memory-doc-pool",
    tab: "memory",
    label: "Document Pool Multiplier",
    keywords: "memory recall doc pool multiplier candidate widening",
    targetId: "recall-doc-pool",
  },
  {
    id: "memory-episodic-weight",
    tab: "memory",
    label: "Episodic Weight",
    keywords: "memory recall episodic weight rank scale",
    targetId: "recall-episodic-weight",
  },
  {
    id: "memory-vector-path",
    tab: "memory",
    label: "Vector Storage Path",
    keywords: "memory vector db path storage persistence",
    targetId: "vector-path",
  },
  {
    id: "goals-enabled",
    tab: "goals",
    label: "Enable goal pursuit",
    keywords: "goals enable pursuit cadence background proactive",
    targetId: "goals-enabled",
  },
  {
    id: "ideas-enabled",
    tab: "goals",
    label: "Enable proactive ideas",
    keywords: "goals ideas enable proactive suggestions next moves accept dismiss",
    targetId: "ideas-enabled",
  },
  {
    id: "goals-cadence",
    tab: "goals",
    label: "Default Cadence (minutes)",
    keywords: "goals cadence step interval minutes daily schedule",
    targetId: "goals-step-interval",
  },
  {
    id: "goals-max-active",
    tab: "goals",
    label: "Max Active Goals",
    keywords: "goals max active cap state unplanned",
    targetId: "goals-max-active",
  },
  {
    id: "goals-max-steps",
    tab: "goals",
    label: "Max Steps Per Goal",
    keywords: "goals max steps plan length per goal",
    targetId: "goals-max-steps",
  },
  {
    id: "goals-plan-timeout",
    tab: "goals",
    label: "Planning Timeout",
    keywords: "goals plan timeout planning decomposition seconds",
    targetId: "goals-plan-timeout",
  },
  {
    id: "goals-max-triggers",
    tab: "goals",
    label: "Max Triggers Per Goal",
    keywords: "goals max triggers event wake-up budget",
    targetId: "goals-max-triggers",
  },
  {
    id: "ideas-max-per-cycle",
    tab: "goals",
    label: "Max Ideas Per Cycle",
    keywords: "goals ideas max per cycle proactive suggestions generation",
    targetId: "ideas-max-per-cycle",
  },
  {
    id: "ideas-timeout",
    tab: "goals",
    label: "Idea Review Timeout (seconds)",
    keywords: "goals ideas timeout review generation seconds",
    targetId: "ideas-timeout-seconds",
  },
  {
    id: "tools-plugins-dir",
    tab: "tools",
    label: "Plugins directory",
    keywords: "tools plugins directory runes packages scan marketplace",
    targetId: "plugins-dir",
  },
  {
    id: "tools-workspace-quota",
    tab: "tools",
    label: "Quota (MB)",
    keywords: "tools workspace quota storage mb files prune tmp",
    targetId: "workspace-quota-mb",
  },
  {
    id: "tools-marketplace",
    tab: "tools",
    label: "Marketplace Index URL",
    keywords: "tools marketplace catalog remote url community runes endpoint",
    targetId: "marketplace-url",
  },
  {
    id: "tools-autorescan",
    tab: "tools",
    label: "Automatically scan plugins directory on startup",
    keywords: "tools autorescan plugins startup scan directory",
    targetId: "plugins-autorescan",
  },
  {
    id: "tools-workspace-files",
    tab: "tools",
    label: "Max files",
    keywords: "tools workspace quota files prune storage tmp",
    targetId: "workspace-quota-files",
  },
  {
    id: "tools-workspace-tmp",
    tab: "tools",
    label: "Tmp TTL (days)",
    keywords: "tools workspace tmp ttl retention days prune storage",
    targetId: "workspace-tmp-ttl",
  },
  {
    id: "indexing-roots",
    tab: "indexing",
    label: "Index roots",
    keywords: "indexing roots folders walk boundary allow files",
    targetId: "index-roots",
  },
  {
    id: "indexing-vector-cap",
    tab: "indexing",
    label: "Vector cap per document",
    keywords: "indexing vector cap chunks per document embeddings limit",
    targetId: "index-vector-cap",
  },
  {
    id: "indexing-exclude",
    tab: "indexing",
    label: "Exclude Patterns",
    keywords: "indexing exclude patterns glob skip scan",
    targetId: "index-excludes",
  },
  {
    id: "indexing-mailbox-deny",
    tab: "indexing",
    label: "Denied Mailboxes",
    keywords: "indexing mailbox deny trash skip mail",
    targetId: "index-mailbox-deny",
  },
  {
    id: "indexing-mail-window",
    tab: "indexing",
    label: "Mail vector window",
    keywords: "indexing mail vector window all embeddings search recall",
    targetId: "index-mail-window",
  },
  {
    id: "indexing-icloud",
    tab: "indexing",
    label: "iCloud files with evicted bytes",
    keywords: "indexing icloud evicted bytes download skip files",
    targetId: "index-icloud",
  },
  {
    id: "indexing-effort",
    tab: "indexing",
    label: "Indexing Effort",
    keywords: "indexing effort workers preset thermal battery cores",
    targetId: "index-effort-fieldset",
  },
  {
    id: "search-max-results",
    tab: "search",
    label: "Max results",
    keywords: "search max results provider pick browser web",
    targetId: "search-max-results",
  },
  {
    id: "search-searxng-url",
    tab: "search",
    label: "SearXNG URL",
    keywords: "search searxng url endpoint override browser container",
    targetId: "search-searxng-url",
  },
  {
    id: "search-timeout",
    tab: "search",
    label: "Search Timeout",
    keywords: "search timeout seconds searxng request browser",
    targetId: "search-timeout",
  },
  {
    id: "email-accounts",
    tab: "email",
    label: "Email accounts",
    keywords: "email accounts imap mailboxes monitoring schedules",
    targetId: "email-pane",
  },
  {
    id: "email-add-account",
    tab: "email",
    label: "Add email account",
    keywords: "email add account imap configure nickname",
    targetId: "email-add-account",
  },
  {
    id: "email-smtp",
    tab: "email",
    label: "SMTP Security",
    keywords: "email smtp security starttls ssl auto host port delivery override derived",
    targetId: "email-smtp-section",
  },
  {
    id: "security-memory",
    tab: "security",
    label: "Memory (MB)",
    keywords: "security containers memory mb budget sandbox spawn",
    targetId: "containers-memory-mb",
  },
  {
    id: "security-concurrency",
    tab: "security",
    label: "Max concurrent containers",
    keywords: "security containers concurrent capacity ttl idle reclamation",
    targetId: "containers-max-concurrent",
  },
  {
    id: "security-ttl",
    tab: "security",
    label: "Idle TTL (minutes)",
    keywords: "security containers ttl idle reclamation lifetime minutes",
    targetId: "containers-ttl-minutes",
  },
  {
    id: "network-bind",
    tab: "network",
    label: "Bind interface",
    keywords: "network server hostname bind interface loopback lan",
    targetId: "server-hostname-select",
  },
  {
    id: "network-bind-address",
    tab: "network",
    label: "Bind address",
    keywords: "network server hostname bind custom address loopback lan interface",
    targetId: "server-bind-row",
  },
  {
    id: "network-port",
    tab: "network",
    label: "Port",
    keywords: "network server port tcp bind restart",
    targetId: "server-port",
  },
  {
    id: "network-allowed-hosts",
    tab: "network",
    label: "Allowed Hosts",
    keywords: "network allowed hosts exact host header gate",
    targetId: "server-allowed-hosts-textarea",
  },
  {
    id: "engine-name",
    tab: "engine",
    label: "Engine name",
    keywords: "engine name identity daemon log",
    targetId: "engine-name",
  },
  {
    id: "engine-log-level",
    tab: "engine",
    label: "Log level",
    keywords: "engine log level verbosity trace debug info",
    targetId: "log-level",
  },
  {
    id: "engine-max-tool-iterations",
    tab: "engine",
    label: "Max Tool Rounds per Turn (Chats)",
    keywords: "engine max tool rounds per turn chats budget approval continue",
    targetId: "max-tool-iterations",
  },
  {
    id: "engine-compaction",
    tab: "engine",
    label: "Context Compaction Threshold",
    keywords: "engine compaction threshold context usage limit overflow",
    targetId: "compaction-threshold",
  },
  {
    id: "engine-proactive-mode",
    tab: "engine",
    label: "Proactivity Mode",
    keywords: "engine proactive mode interruption background milestones guarded off",
    targetId: "proactive-mode",
  },
  {
    id: "engine-judge-timeout",
    tab: "engine",
    label: "Judge Timeout",
    keywords: "engine judge timeout guarded gate seconds proactive",
    targetId: "proactive-judge-timeout",
  },
];

const MAX_SEARCH_RESULTS = 20;
const HIGHLIGHT_CLASS = "settings-search-highlight";
const HIGHLIGHT_MS = 2400;
const HIGHLIGHT_POLL_MS = 50;
const HIGHLIGHT_MAX_ATTEMPTS = 20;

// Tab promotion order shared with the sidenav rail: results group by tab
// order first, then label-vs-keyword score, then label.
const TAB_ORDER = new Map<SettingsTab, number>(
  SETTINGS_TABS.map((tab, index) => [tab, index] as const),
);

let highlightTimeout: ReturnType<typeof setTimeout> | null = null;
let activeHighlight: Element | null = null;

export function searchSettingsItems(query: string): SettingsSearchItem[] {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return [];
  const tokens = normalized.split(/\s+/).filter(Boolean);
  const scored: Array<{ item: SettingsSearchItem; score: number }> = [];
  for (const item of SETTINGS_SEARCH_ITEMS) {
    const labelLower = item.label.toLowerCase();
    const keywordsLower = item.keywords.toLowerCase();
    const allInLabel = tokens.every((token) => labelLower.includes(token));
    if (allInLabel) {
      scored.push({ item, score: 0 });
      continue;
    }
    const allInEither = tokens.every(
      (token) => labelLower.includes(token) || keywordsLower.includes(token),
    );
    if (allInEither) scored.push({ item, score: 1 });
  }
  scored.sort((a, b) => {
    const tabOrder =
      (TAB_ORDER.get(a.item.tab) ?? SETTINGS_TABS.length) -
      (TAB_ORDER.get(b.item.tab) ?? SETTINGS_TABS.length);
    if (tabOrder !== 0) return tabOrder;
    if (a.score !== b.score) return a.score - b.score;
    return a.item.label.localeCompare(b.item.label);
  });
  return scored.slice(0, MAX_SEARCH_RESULTS).map((entry) => entry.item);
}

export function highlightSettingTarget(targetId: string): void {
  if (typeof document === "undefined") return;
  if (!targetId) return;
  const target = document.getElementById(targetId);
  if (!target) return;
  // Open every collapsed ancestor disclosure: the target may sit behind
  // nested details (e.g. an advanced panel inside a section group).
  let ancestor: Element | null = target.parentElement;
  while (ancestor !== null) {
    if (ancestor instanceof HTMLDetailsElement && !ancestor.open) {
      ancestor.open = true;
      // Toggle-aware open: AdvancedDisclosure panels are React-controlled
      // (`open` prop plus `onToggle`), so a bare DOM mutation would revert
      // on the next render. Firing the observed toggle event lets the owner
      // sync its state and keep the panel open.
      ancestor.dispatchEvent(new Event("toggle"));
    }
    ancestor = ancestor.parentElement;
  }
  try {
    const scroller = target.scrollIntoView;
    if (typeof scroller === "function") {
      scroller.call(target, { behavior: "smooth", block: "center" });
    }
  } catch {
    // jsdom and background tabs may lack smooth scrolling; highlight still applies.
  }
  const highlightEl = target.closest(".form-group") ?? target;
  if (highlightTimeout !== null) {
    clearTimeout(highlightTimeout);
    highlightTimeout = null;
  }
  if (activeHighlight !== null && activeHighlight !== highlightEl) {
    activeHighlight.classList.remove(HIGHLIGHT_CLASS);
  }
  activeHighlight = highlightEl;
  highlightEl.classList.add(HIGHLIGHT_CLASS);
  const focusable = target as HTMLElement;
  if (typeof focusable.focus === "function") {
    const tag = focusable.tagName;
    const isTagFocusable =
      tag === "INPUT" ||
      tag === "SELECT" ||
      tag === "TEXTAREA" ||
      tag === "BUTTON" ||
      (tag === "A" && focusable.hasAttribute("href"));
    if (isTagFocusable || focusable.tabIndex >= 0 || focusable.isContentEditable) {
      try {
        focusable.focus({ preventScroll: true });
      } catch {
        try {
          focusable.focus();
        } catch {
          // Non-focusable targets keep the visual pulse without focus.
        }
      }
    }
  }
  highlightTimeout = setTimeout(() => {
    highlightEl.classList.remove(HIGHLIGHT_CLASS);
    if (activeHighlight === highlightEl) activeHighlight = null;
    highlightTimeout = null;
  }, HIGHLIGHT_MS);
}

// Tab switches commit asynchronously, so the pane for a freshly selected
// result may not be mounted yet. Double rAF lets React commit the new tab
// and paint the pane, then a bounded poll resolves the target and
// highlights exactly once instead of losing the pulse when the pane lags.
export function highlightSettingTargetWhenReady(
  targetId: string,
  maxAttempts = HIGHLIGHT_MAX_ATTEMPTS,
): void {
  if (typeof document === "undefined" || !targetId) return;
  if (document.getElementById(targetId) !== null) {
    highlightSettingTarget(targetId);
    return;
  }
  const poll = (remaining: number): void => {
    if (document.getElementById(targetId) !== null) {
      highlightSettingTarget(targetId);
      return;
    }
    if (remaining <= 0) return;
    setTimeout(() => poll(remaining - 1), HIGHLIGHT_POLL_MS);
  };
  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => poll(maxAttempts));
    });
  } else {
    setTimeout(() => poll(maxAttempts), 0);
  }
}
