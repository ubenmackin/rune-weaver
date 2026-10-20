// Rune Weaver Dashboard — Settings advanced counts helpers.
import {
  DEFAULT_BASH_CPU_SECONDS,
  DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT,
  DEFAULT_BASH_MEMORY_MB,
  DEFAULT_BASH_SANDBOX_MODE,
  DEFAULT_BASH_TIMEOUT_SECONDS,
  DEFAULT_FILES_DENY_PATTERNS_TEXT,
  DEFAULT_GOALS_MAX_ACTIVE_GOALS,
  DEFAULT_GOALS_MAX_STEPS_PER_GOAL,
  DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL,
  DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS,
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_EXCLUDE_PATTERNS,
  DEFAULT_INDEX_MAILBOX_DENY,
  DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
  DEFAULT_SEARCH_SEARXNG_URL,
  DEFAULT_SEARCH_TIMEOUT_SECONDS,
  DEFAULT_WORKSPACE_QUOTA_FILES,
  DEFAULT_WORKSPACE_QUOTA_MB,
  DEFAULT_WORKSPACE_TMP_TTL_DAYS,
  parseDenyPatternsText,
  parseHostAllowPatternsUncapped,
} from "../../api";
import type { EmailEntry, ProviderEntry } from "./settingsTypes";

export const DEFAULT_MEMORY_RECALL_AUTO_LIMIT = 5;
export const DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER = 4;
export const DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT = 0.25;

export const DEFAULT_MEMORY_EMBEDDING_BACKEND = "local";

// Stock engine compaction threshold; EngineTab reset plus slider hint reuse it.
export const DEFAULT_ENGINE_COMPACTION_THRESHOLD = 80;

// Counts non-default provider fields hidden behind Advanced.
export function countProvidersAdvancedChanged(
  providers: ProviderEntry[]
): number {
  let count = 0;
  for (const item of providers) {
    const cfg = item.config;
    if (typeof cfg.apiStyle === "string" && cfg.apiStyle.trim() !== "") count += 1;
    const contextRaw: unknown = cfg.contextLength;
    if (contextRaw !== undefined && contextRaw !== null) {
      if (typeof contextRaw === "string" && contextRaw.trim() === "") {
        // Empty entry counts clean.
      } else {
        const num = Number(contextRaw);
        if (!Number.isFinite(num) || num > 0) count += 1;
      }
    }
    const slotRaw: unknown = cfg.slotCount;
    if (slotRaw !== undefined && slotRaw !== null) {
      if (typeof slotRaw === "string" && slotRaw.trim() === "") {
        // Empty entry counts clean.
      } else {
        const num = Number(slotRaw);
        if (!Number.isFinite(num) || num > 0) count += 1;
      }
    }
    const cacheRaw: unknown = cfg.cachePrompt;
    if (typeof cacheRaw === "boolean") {
      count += 1;
    } else if (typeof cacheRaw === "string") {
      if (cacheRaw.trim() !== "") count += 1;
    } else if (typeof cacheRaw === "number") {
      count += 1;
    }
    const visionRaw: unknown = cfg.supportsVision;
    if (typeof visionRaw === "boolean") {
      count += 1;
    } else if (typeof visionRaw === "string") {
      if (visionRaw.trim() !== "") count += 1;
    } else if (typeof visionRaw === "number") {
      count += 1;
    }
  }
  return count;
}

// Counts non-default persona fields hidden behind Advanced.
export function countPersonaAdvancedChanged(
  avatarDraft: string,
  styleDraft: string,
  defaultAvatar: string
): number {
  let count = 0;
  if ((avatarDraft || "") !== defaultAvatar) count += 1;
  if ((styleDraft || "") !== "") count += 1;
  return count;
}

// Counts non-default email fields hidden behind Advanced.
export function countEmailAdvancedChanged(accounts: EmailEntry[]): number {
  let count = 0;
  for (const item of accounts) {
    const acc = item.account;
    const hostValue: unknown = acc.smtpHost;
    const hostText = typeof hostValue === "string" ? hostValue : "";
    if (hostText.trim() !== "") count += 1;
    const portRaw: unknown = acc.smtpPort;
    if (portRaw !== undefined && portRaw !== null) {
      if (typeof portRaw === "string" && portRaw.trim() === "") {
        // Empty entry counts clean.
      } else {
        const portNum = Number(portRaw);
        if (!Number.isFinite(portNum) || portNum > 0) count += 1;
      }
    }
    const secValue: unknown = acc.smtpSecurity;
    const secText = typeof secValue === "string" ? secValue : "";
    const sec = secText.trim().toLowerCase();
    if (sec !== "" && sec !== "auto") count += 1;
  }
  return count;
}

// Counts non-default memory fields hidden behind Advanced.
// Only recall knobs live behind Advanced; the embedding backend
// select stays in Simple so it remains excluded from the chip.
export function countMemoryAdvancedChanged(
  docPoolMultiplier: number | string,
  episodicWeight: number | string,
  autoLimit?: number | string
): number {
  let count = 0;
  const docNum = Number(docPoolMultiplier);
  if (!Number.isFinite(docNum) || docNum !== DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER)
    count += 1;
  const weightNum = Number(episodicWeight);
  if (!Number.isFinite(weightNum) || weightNum !== DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT)
    count += 1;
  if (autoLimit !== undefined) {
    if (typeof autoLimit === "string" && autoLimit.trim() === "") {
      // Empty entry counts clean.
    } else {
      const autoNum = Number(autoLimit);
      if (!Number.isFinite(autoNum) || autoNum !== DEFAULT_MEMORY_RECALL_AUTO_LIMIT)
        count += 1;
    }
  }
  return count;
}

// Counts only the editable compaction knob; scheduler plus goal
// budgets render read-only text so they never affect the chip.
export function countEngineAdvancedChanged(
  compactionThresholdPercent: number | string
): number {
  let count = 0;
  if (typeof compactionThresholdPercent === "string" && compactionThresholdPercent.trim() === "") {
    return count;
  }
  const thresholdNum = Number(compactionThresholdPercent);
  if (!Number.isFinite(thresholdNum) || thresholdNum !== DEFAULT_ENGINE_COMPACTION_THRESHOLD)
    count += 1;
  return count;
}

// Counts non-default goals fields hidden behind Advanced.
export function countGoalsAdvancedChanged(
  maxActiveGoals: number | string,
  maxStepsPerGoal: number | string,
  planTimeoutSeconds: number | string,
  maxTriggersPerGoal: number | string
): number {
  let count = 0;
  if (typeof maxActiveGoals !== "string" || maxActiveGoals.trim() !== "") {
    const num = Number(maxActiveGoals);
    if (!Number.isFinite(num) || num !== DEFAULT_GOALS_MAX_ACTIVE_GOALS) count += 1;
  }
  if (typeof maxStepsPerGoal !== "string" || maxStepsPerGoal.trim() !== "") {
    const num = Number(maxStepsPerGoal);
    if (!Number.isFinite(num) || num !== DEFAULT_GOALS_MAX_STEPS_PER_GOAL) count += 1;
  }
  if (typeof planTimeoutSeconds !== "string" || planTimeoutSeconds.trim() !== "") {
    const num = Number(planTimeoutSeconds);
    if (!Number.isFinite(num) || num !== DEFAULT_GOALS_PLAN_TIMEOUT_SECONDS)
      count += 1;
  }
  if (typeof maxTriggersPerGoal !== "string" || maxTriggersPerGoal.trim() !== "") {
    const num = Number(maxTriggersPerGoal);
    if (!Number.isFinite(num) || num !== DEFAULT_GOALS_MAX_TRIGGERS_PER_GOAL)
      count += 1;
  }
  return count;
}

// Stock Tools Advanced values; ToolsTab reset reuses these so the
// count plus the reset cannot drift.
export const DEFAULT_TOOLS_PLUGINS_DIR = "~/.runeweaver/plugins";
export const DEFAULT_TOOLS_MARKETPLACE_INDEX_URL =
  "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json";
export const DEFAULT_TOOLS_AUTO_RESCAN = true;

// Counts Tools Advanced edits; machine configMatch stays out since it remains
// server-derived with no setter plus would strand the chip after reset.
export function countToolsAdvancedChanged(
  pluginsDir: string,
  marketplaceIndexURL: string,
  autoRescan: boolean,
  workspaceQuotaMB?: number | string,
  workspaceQuotaFiles?: number | string,
  workspaceTmpTTLDays?: number | string
): number {
  let count = 0;
  if ((pluginsDir || "").trim() !== DEFAULT_TOOLS_PLUGINS_DIR) count += 1;
  if (
    (marketplaceIndexURL || "").trim() !== DEFAULT_TOOLS_MARKETPLACE_INDEX_URL
  )
    count += 1;
  if (autoRescan !== DEFAULT_TOOLS_AUTO_RESCAN) count += 1;
  if (workspaceQuotaMB !== undefined) {
    if (typeof workspaceQuotaMB !== "string" || workspaceQuotaMB.trim() !== "") {
      const quotaMBNum = Number(workspaceQuotaMB);
      if (!Number.isFinite(quotaMBNum) || quotaMBNum !== DEFAULT_WORKSPACE_QUOTA_MB)
        count += 1;
    }
  }
  if (workspaceQuotaFiles !== undefined) {
    if (typeof workspaceQuotaFiles !== "string" || workspaceQuotaFiles.trim() !== "") {
      const quotaFilesNum = Number(workspaceQuotaFiles);
      if (!Number.isFinite(quotaFilesNum) || quotaFilesNum !== DEFAULT_WORKSPACE_QUOTA_FILES)
        count += 1;
    }
  }
  if (workspaceTmpTTLDays !== undefined) {
    if (typeof workspaceTmpTTLDays !== "string" || workspaceTmpTTLDays.trim() !== "") {
      const tmpTTLNum = Number(workspaceTmpTTLDays);
      if (!Number.isFinite(tmpTTLNum) || tmpTTLNum !== DEFAULT_WORKSPACE_TMP_TTL_DAYS)
        count += 1;
    }
  }
  return count;
}

// Counts non-default web fields hidden behind Advanced.
export function countWebAdvancedChanged(
  searxngURL: string,
  timeoutSeconds: number | string
): number {
  let count = 0;
  if ((searxngURL || "").trim() !== DEFAULT_SEARCH_SEARXNG_URL) count += 1;
  if (typeof timeoutSeconds !== "string" || timeoutSeconds.trim() !== "") {
    const timeoutNum = Number(timeoutSeconds);
    if (!Number.isFinite(timeoutNum) || timeoutNum !== DEFAULT_SEARCH_TIMEOUT_SECONDS)
      count += 1;
  }
  return count;
}

// Default whisper model; Advanced holds this knob alone.
export const DEFAULT_VOICE_WHISPER_MODEL = "base";

// Counts only the whisper model hidden behind Advanced; STT plus TTS
// providers stay in Simple so they never affect the chip.
export function countVoiceAdvancedChanged(whisperModel: string): number {
  return (whisperModel || "").trim() !== DEFAULT_VOICE_WHISPER_MODEL ? 1 : 0;
}

// Default per-path write posture list mirroring the Files editor boundary:
// personal directories request approval while working directories stage.
export type FilesWritePosture = "live" | "stage" | "ask" | "deny";

export const DEFAULT_FILES_POSTURE: FilesWritePosture = "ask";

// Write-path rule shape shared by the Access counters plus the Files editor.
export interface AdvancedWritePathRule {
  path: string;
  posture: FilesWritePosture;
}

export const DEFAULT_FILES_WRITE_PATH_RULES: ReadonlyArray<AdvancedWritePathRule> = [
  { path: "~/Library", posture: "ask" },
  { path: "~/Photos", posture: "ask" },
  { path: "~/Documents", posture: "stage" },
  { path: "~/Desktop", posture: "stage" },
  { path: "~/Downloads", posture: "stage" },
];

// Normalizes one loaded posture into the closed set. An unknown or absent
// token fails closed to ask — the posture that parks an approval request —
// instead of silently widening write authority.
export function normalizeFilesWritePosture(value: unknown): FilesWritePosture {
  const normalized =
    typeof value === "string" ? value.trim().toLowerCase() : "";
  if (normalized === "live" || normalized === "stage" || normalized === "deny") {
    return normalized;
  }
  return "ask";
}

// Normalizes a rule list into trimmed paths plus closed-set postures.
// Non-object rows plus rows without a string path drop out so an
// emptied editor reads empty rather than persisting whitespace rows.
export function normalizeWritePathRules(rules: unknown): Array<AdvancedWritePathRule> {
  if (!Array.isArray(rules)) return [];
  const out: Array<AdvancedWritePathRule> = [];
  for (const entry of rules) {
    if (typeof entry !== "object" || entry === null) continue;
    if (!("path" in entry)) continue;
    const pathValue: unknown = entry.path;
    if (typeof pathValue !== "string") continue;
    let postureValue: unknown = undefined;
    if ("posture" in entry) {
      postureValue = entry.posture;
    }
    out.push({
      path: pathValue.trim(),
      posture: normalizeFilesWritePosture(postureValue),
    });
  }
  return out;
}

// True when a current rule list differs from its baseline by length or entry.
export function writePathRulesDiffer(
  current: unknown,
  baseline: ReadonlyArray<AdvancedWritePathRule>
): boolean {
  const normalized = normalizeWritePathRules(current);
  if (normalized.length !== baseline.length) return true;
  for (let index = 0; index < normalized.length; index += 1) {
    const cur = normalized[index];
    const base = baseline[index];
    if (cur === undefined || base === undefined) return true;
    if (cur.path !== base.path || cur.posture !== base.posture) return true;
  }
  return false;
}

// Normalizes a textarea value into trimmed non-blank entries.
function normalizeAdvancedList(value: string | string[] | null | undefined): string[] {
  if (Array.isArray(value)) {
    const out: string[] = [];
    for (const entry of value) {
      if (typeof entry !== "string") continue;
      const trimmed = entry.trim();
      if (trimmed) out.push(trimmed);
    }
    return out;
  }
  if (typeof value !== "string") return [];
  const lines = value.split("\n");
  const out: string[] = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed) out.push(trimmed);
  }
  return out;
}

// True when a current list differs from its defaults by length or entry.
function advancedListDiffers(
  current: string | string[] | null | undefined,
  defaults: readonly string[]
): boolean {
  const normalized = normalizeAdvancedList(current);
  if (normalized.length !== defaults.length) return true;
  for (let index = 0; index < normalized.length; index += 1) {
    if (normalized[index] !== defaults[index]) return true;
  }
  return false;
}

// Counts Bash Advanced tuning only: numeric budgets plus the execution tier
// plus host allowlist. Binding controls stay in Simple so the chip stays
// honest while collapsed.
export function countBashAdvancedChanged(
  timeoutSeconds: number | string,
  cpuSeconds: number | string,
  memoryMb: number | string,
  sandboxMode: string,
  hostAllowPatternsText: string
): number {
  let count = 0;
  if (typeof timeoutSeconds !== "string" || timeoutSeconds.trim() !== "") {
    const timeoutNum = Number(timeoutSeconds);
    if (!Number.isFinite(timeoutNum) || timeoutNum !== DEFAULT_BASH_TIMEOUT_SECONDS)
      count += 1;
  }
  if (typeof cpuSeconds !== "string" || cpuSeconds.trim() !== "") {
    const cpuNum = Number(cpuSeconds);
    if (!Number.isFinite(cpuNum) || cpuNum !== DEFAULT_BASH_CPU_SECONDS)
      count += 1;
  }
  if (typeof memoryMb !== "string" || memoryMb.trim() !== "") {
    const memoryNum = Number(memoryMb);
    if (!Number.isFinite(memoryNum) || memoryNum !== DEFAULT_BASH_MEMORY_MB)
      count += 1;
  }
  const trimmedMode = typeof sandboxMode === "string" ? sandboxMode.trim() : "";
  if (trimmedMode !== DEFAULT_BASH_SANDBOX_MODE) {
    count += 1;
  }
  if (
    advancedListDiffers(
      hostAllowPatternsText,
      parseHostAllowPatternsUncapped(DEFAULT_BASH_HOST_ALLOW_PATTERNS_TEXT)
    )
  ) {
    count += 1;
  }
  return count;
}

// Counts Files Advanced edits: write-path rules plus deny patterns. Write mode,
// allowed roots, and the approval switch stay in Simple.
export function countFilesAdvancedChanged(
  writePathRules: unknown,
  denyPatternsText: string
): number {
  let count = 0;
  if (writePathRulesDiffer(writePathRules, DEFAULT_FILES_WRITE_PATH_RULES)) count += 1;
  if (
    advancedListDiffers(
      denyPatternsText,
      parseDenyPatternsText(DEFAULT_FILES_DENY_PATTERNS_TEXT)
    )
  ) {
    count += 1;
  }
  return count;
}

// Counts non-default Index Advanced values: vector cap plus exclude patterns
// plus mailbox deny plus mail window plus iCloud eviction. Each deviating
// control counts once so the trigger reads honest while collapsed.
export function countIndexAdvancedChanged(
  vectorCap: number | string,
  exclude: string | string[],
  mailboxDeny: string | string[],
  mailVectorWindow: string,
  iCloudEvicted: string
): number {
  let count = 0;
  if (typeof vectorCap !== "string" || vectorCap.trim() !== "") {
    const capNum = Number(vectorCap);
    if (!Number.isFinite(capNum) || capNum !== DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT)
      count += 1;
  }
  if (advancedListDiffers(exclude, DEFAULT_INDEX_EXCLUDE_PATTERNS)) count += 1;
  if (advancedListDiffers(mailboxDeny, DEFAULT_INDEX_MAILBOX_DENY)) count += 1;
  if (
    (mailVectorWindow || "").trim() !==
    (DEFAULT_INDEX_CONFIG.mailVectorWindow || "").trim()
  )
    count += 1;
  if (
    (iCloudEvicted || "").trim() !== (DEFAULT_INDEX_CONFIG.iCloudEvicted || "").trim()
  )
    count += 1;
  return count;
}
