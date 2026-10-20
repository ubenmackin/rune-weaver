// Rune Weaver Dashboard — Shared Access settings loader for Bash and Files drafts.
import {
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS_TEXT,
  formatAllowRootsText,
  formatDenyPatternsText,
  getSettings,
  type SettingsResponse,
} from "../../api";
import {
  applyBashConfigToDraft,
  bashDraftFromLoaded,
  bashLoadedFromDraft,
  type BashDraft,
  type BashLoadedSnapshot,
} from "./accessBashDraft";
import {
  normalizeFilesWriteMode,
  readLoadedWritePathRules,
  type FilesLoadedSnapshot,
} from "./accessFilesRules";

// In-flight shared fetch so pane-level Advanced hooks plus section bodies
// mounted together read one GET /settings instead of two identical payloads.
let inflightAccessSettings: Promise<SettingsResponse> | null = null;

export function fetchSharedAccessSettings(): Promise<SettingsResponse> {
  if (inflightAccessSettings) return inflightAccessSettings;
  const pending = getSettings();
  // Clear on settle so the next mount reads fresh settings; comparing to
  // the wrapped promise would never match and would pin the first payload.
  inflightAccessSettings = pending.finally(() => {
    inflightAccessSettings = null;
  }) as Promise<SettingsResponse>;
  return inflightAccessSettings;
}

// Single Bash normalizer for the section body plus the Advanced hook: one
// settings payload maps to one draft plus loaded snapshot so the two owners
// can never drift on the same keys.
export function resolveBashDraftAndLoaded(
  settings: SettingsResponse | null | undefined,
  prevLoaded: BashLoadedSnapshot
): { draft: BashDraft; loaded: BashLoadedSnapshot } | null {
  const bash = settings?.bash;
  if (!bash) return null;
  const draft = applyBashConfigToDraft(bashDraftFromLoaded(prevLoaded), bash);
  const loaded = bashLoadedFromDraft(draft);
  return { draft, loaded };
}

// Single Files normalizer for the section body plus the Advanced hook: one
// settings payload maps to one loaded snapshot covering mode, rules, deny
// patterns, allow roots, and approval on deny.
export function resolveFilesLoadedSnapshot(
  settings: SettingsResponse | null | undefined
): FilesLoadedSnapshot | null {
  if (!settings) return null;
  return {
    writeMode: normalizeFilesWriteMode(settings.filesWriteMode),
    writePathRules: readLoadedWritePathRules(settings),
    denyPatternsText: Array.isArray(settings.filesDenyPatterns)
      ? formatDenyPatternsText(settings.filesDenyPatterns)
      : DEFAULT_FILES_DENY_PATTERNS_TEXT,
    allowRootsText: Array.isArray(settings.filesAllowRoots)
      ? formatAllowRootsText(settings.filesAllowRoots)
      : formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS),
    requireApprovalOnDeny: settings.filesRequireApprovalOnDeny ?? true,
  };
}
