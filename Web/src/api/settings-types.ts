// Rune Weaver Dashboard — Settings configuration data models.

export interface ProviderConfigData {
  enabled: boolean;
  model?: string;
  serverURL?: string;
  apiKeyEnv?: string;
  providerType?: string;
  apiStyle?: string;
  contextLength?: number;
  // llama.cpp prefix-reuse knobs round-tripped through SettingsResponse providers. Dual snake/camel
  // aliases mirror the existing provider pattern so file-configured values survive a dashboard
  // PUT instead of being stripped to nil. Absent stays unset (server auto-assign / always-on hint).
  slotCount?: number;
  cachePrompt?: boolean;
  supportsVision?: boolean;
}

export interface EmailAccountData {
  name: string;
  type: string;
  host: string;
  port: number;
  username: string;
  // Optional SMTP overrides persisted as smtpHost/smtpPort/smtpSecurity.
  // Camel-case aliases mirror the provider pattern so older dashboards keep
  // round-tripping without dropping overrides.
  smtpHost?: string;
  smtpPort?: number;
  smtpSecurity?: string;
}

// One self-hosted Arr instance (Sonarr for TV, Radarr for movies).
export interface ArrServiceConfigData {
  enabled: boolean;
  url?: string;
  apiKeyEnv?: string;
  defaultQualityProfile?: string;
  defaultRootFolder?: string;
}

// Sonarr (TV) section of [media]; an alias so call sites keep the service
// name while sharing the single Arr shape above.
export type SonarrConfigData = ArrServiceConfigData;

// Radarr (movies) section of [media]; same shared shape as Sonarr.
export type RadarrConfigData = ArrServiceConfigData;

export interface MediaConfigData {
  sonarr: SonarrConfigData;
  radarr: RadarrConfigData;
  timeoutSeconds?: number;
}

// Local background indexer policy mirroring the engine `IndexConfig`
// (Sources/RuneWeaverCore/Config.swift).
export interface IndexConfigData {
  enabled: boolean;
  files: boolean;
  mail: boolean;
  messages: boolean;
  calendars: boolean;
  reminders: boolean;
  roots: string[];
  exclude: string[];
  maxFileMB: number;
  mailVectorWindow: string;
  iCloudEvicted: string;
  nightlyBudget: number;
  dbPath: string;
  // Indexing effort preset (`light`, `balanced`, `performance`, or `custom`).
  // Optional for back-compat with older engines that predate the knob; absent
  // degrades to the balanced default instead of failing.
  effort?: string;
  // Custom worker count used only when `effort` is `custom`. Canonical wire
  // key is `workers`, mirroring the engine `IndexConfig.workers`; absent
  // degrades to the default stepper value.
  workers?: number;
  // Whether the run backs off when the machine reports thermal pressure.
  // Optional for back-compat; absent degrades to the default.
  thermalBackoff?: boolean;
  // Whether scheduled and on-demand runs pause while on battery power.
  // Optional for back-compat; absent degrades to the default.
  pauseOnBattery?: boolean;
  // Maximum vector chunks stored per document, bounding per-document
  // embedding work; chunks beyond the cap stay keyword-only. Optional for
  // back-compat; absent degrades to the engine default instead of failing.
  maxVectorChunksPerDocument?: number;
  // Trash-class mailbox denylist skipped without dialing. Optional for
  // back-compat; absent degrades to the engine default instead of failing.
  mailboxDeny?: string[];
  // Directory and file names the walker always skips, even when absent from `exclude`. Read-only:
  // populated by the engine from the walker's prune list and ignored on write.
  alwaysSkipped?: string[];
}

// Partial index patch for `PUT /settings`, mirroring the engine `IndexSettingsUpdate`.
export interface IndexSettingsUpdate {
  enabled?: boolean;
  files?: boolean;
  mail?: boolean;
  messages?: boolean;
  calendars?: boolean;
  reminders?: boolean;
  roots?: string[];
  exclude?: string[];
  maxFileMB?: number;
  mailVectorWindow?: string;
  iCloudEvicted?: string;
  nightlyBudget?: number;
  dbPath?: string;
  effort?: string;
  workers?: number;
  thermalBackoff?: boolean;
  pauseOnBattery?: boolean;
  maxVectorChunksPerDocument?: number;
  mailboxDeny?: string[];
}

// Native desktop vision and gated control policy mirroring the engine `DesktopConfig`
// (Sources/RuneWeaverCore/Config.swift).
export interface DesktopConfigData {
  maxImageDimension: number;
  jpegQuality: number;
  blockedApps: string[];
}

// Partial desktop patch for `PUT /settings`, mirroring the engine `DesktopSettingsUpdate`.
export interface DesktopSettingsUpdate {
  maxImageDimension?: number;
  jpegQuality?: number;
  blockedApps?: string[];
}

// Steady goal pursuit policy mirroring the engine `GoalsConfig`
// (Sources/RuneWeaverCore/Config.swift).
export interface GoalsConfigData {
  enabled: boolean;
  stepIntervalMinutes?: number;
  maxActiveGoals?: number;
  maxStepsPerGoal?: number;
  planTimeoutSeconds?: number;
  maxTriggersPerGoal?: number;
  maxToolIterations?: number;
}

// Partial goals patch for `PUT /settings`, mirroring the engine `GoalsUpdate`.
export interface GoalsSettingsUpdate {
  enabled?: boolean;
  stepIntervalMinutes?: number;
  maxActiveGoals?: number;
  maxStepsPerGoal?: number;
  planTimeoutSeconds?: number;
  maxTriggersPerGoal?: number;
}

// Scheduled-run tool budget mirroring the engine `SchedulerConfig`
// (Sources/RuneWeaverCore/Scheduler.swift). The section default bounds
// consecutive tool rounds per scheduled run; a per-job override wins.
export interface SchedulerConfigData {
  maxToolIterations?: number | null;
}

// Default scheduled-run tool rounds mirroring SchedulerConfig.
export const DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS = 25;

// Default interactive-chat tool rounds mirroring EngineConfig
// (Sources/RuneWeaverCore/Config.swift).
export const DEFAULT_ENGINE_MAX_TOOL_ITERATIONS = 10;

// Shared tool-round bounds for every max_tool_iterations budget; the engine owns the 1-100 range.
export const TOOL_ROUNDS_MIN = 1;
export const TOOL_ROUNDS_MAX = 100;

// Shared tool-round clamp for every max_tool_iterations budget: a finite number floors to an
// integer and clamps into the engine-owned 1-100 range, while absent or drifted shapes degrade to
// the caller-supplied fallback.
export function clampToolRounds(raw: unknown, fallback: number): number {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    const floored = Math.floor(raw);
    if (floored < TOOL_ROUNDS_MIN) return TOOL_ROUNDS_MIN;
    if (floored > TOOL_ROUNDS_MAX) return TOOL_ROUNDS_MAX;
    return floored;
  }
  return fallback;
}


export interface ProactiveConfigData {
  mode: string;
  judgeTimeoutSeconds: number;
}

// Partial proactive patch for `PUT /settings`, mirroring the engine
// `ProactiveUpdate`. Every field is optional so a request carrying one key
// leaves the rest of the stored `[proactive]` section untouched.
export interface ProactiveSettingsUpdate {
  mode?: string;
  judgeTimeoutSeconds?: number;
}

// Proactive Wayfinder suggestion policy mirroring the engine `IdeasConfig`
// (Sources/RuneWeaverCore/Config.swift).
export interface IdeasConfigData {
  enabled: boolean;
  maxPerCycle?: number;
  timeoutSeconds?: number;
}

// Partial ideas patch for `PUT /settings`, mirroring the engine `IdeasUpdate`.
export interface IdeasSettingsUpdate {
  enabled?: boolean;
  maxPerCycle?: number;
  timeoutSeconds?: number;
}

// Manual mirror of the IdeasConfig default so a fresh form matches the boundary
// the engine enforces before the first settings fetch.
export const DEFAULT_IDEAS_ENABLED = false;

// Manual mirrors of GoalsConfig defaults so a fresh form matches the boundary
// the engine enforces before the first settings fetch.
export const DEFAULT_GOALS_ENABLED = false;
export const DEFAULT_GOALS_STEP_INTERVAL_MINUTES = 1440;
export const DEFAULT_GOALS_MAX_ACTIVE_GOALS = 10;

// Default goal-run tool rounds mirroring GoalsConfig.
export const DEFAULT_GOALS_MAX_TOOL_ITERATIONS = 35;


// Cadence choices offered by the New Goal form.
export const GOAL_CADENCE_OPTIONS: Array<{ value: number; label: string }> = [
  { value: 60, label: "Hourly" },
  { value: 240, label: "Every 4 hours" },
  { value: 720, label: "Every 12 hours" },
  { value: DEFAULT_GOALS_STEP_INTERVAL_MINUTES, label: "Daily" },
  { value: 10080, label: "Weekly" },
];

// Friendly label for one cadence value so goal cards and example cards speak in
// the same words the create form offers. Unknown values (a hand-edited config)
// fall back to a plain interval so nothing renders blank.
export function goalCadenceLabel(minutes: number): string {
  return (
    GOAL_CADENCE_OPTIONS.find((option) => option.value === minutes)?.label ??
    `every ${minutes}m`
  );
}

// Goals cadence bounds mirroring GoalsConfig.minStepIntervalMinutes and
// maxStepIntervalMinutes; the server owns the 5-20160 range and this mirror is
// the single source for the client validator.
export const GOALS_STEP_INTERVAL_MIN_MINUTES = 5;
export const GOALS_STEP_INTERVAL_MAX_MINUTES = 20160;

// Active-goal cap bounds mirroring GoalsConfig.minActiveGoalsBound and
// maxActiveGoalsBound; the server owns the 1-50 range.
export const GOALS_MAX_ACTIVE_MIN = 1;
export const GOALS_MAX_ACTIVE_MAX = 50;

// Closed set of valid proactive surfacing modes, mirroring ProactiveMode on
// the engine. Single source for the client validator and the Proactivity
// select so the two cannot drift.
export const PROACTIVE_MODES = ["all", "milestones", "guarded", "off"] as const;

// Canonical proactive mode spelling carried on the wire and in the select.
export type ProactiveModeName = (typeof PROACTIVE_MODES)[number];

// Normalizes a proactive mode to its canonical lowercase spelling so the dashboard accepts the same
// values the file loader does.
export function normalizeProactiveMode(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

// Reports whether a value names a proactive surfacing mode, ignoring case
// and surrounding whitespace to match the file loader. Single source for the
// settings validator and populate path so both agree with the engine.
export function isValidProactiveMode(value: unknown): boolean {
  return (PROACTIVE_MODES as readonly string[]).includes(
    normalizeProactiveMode(value),
  );
}

// Manual mirrors of ProactiveConfig defaults; the server owns `all` plus the
// 15-second judge budget and the contract test pins both ends.
export const DEFAULT_PROACTIVE_MODE = "all";
export const DEFAULT_PROACTIVE_JUDGE_TIMEOUT_SECONDS = 15;

// Judge timeout bounds mirroring ProactiveConfig.minJudgeTimeoutSeconds and
// maxJudgeTimeoutSeconds; the server owns the 1-120 range.
export const PROACTIVE_JUDGE_TIMEOUT_MIN_SECONDS = 1;
export const PROACTIVE_JUDGE_TIMEOUT_MAX_SECONDS = 120;


// Single client mirror of the engine `WorkspaceConfig` bounds
// (Sources/RuneWeaverCore/Config.swift).
export const DEFAULT_WORKSPACE_QUOTA_MB = 500;
export const DEFAULT_WORKSPACE_QUOTA_FILES = 10000;
export const DEFAULT_WORKSPACE_TMP_TTL_DAYS = 7;
export const WORKSPACE_QUOTA_MB_MIN = 10;
export const WORKSPACE_QUOTA_MB_MAX = 10240;
export const WORKSPACE_QUOTA_FILES_MIN = 100;
export const WORKSPACE_QUOTA_FILES_MAX = 100000;
export const WORKSPACE_TMP_TTL_MIN_DAYS = 0;
export const WORKSPACE_TMP_TTL_MAX_DAYS = 90;

// Full workspace snapshot on `GET /settings`, mirroring the engine `WorkspaceConfig`.
// The canonical wire keys are camelCase only.
export interface WorkspaceConfigData {
  quotaMB: number;
  quotaFiles: number;
  tmpTTLDays: number;
}

// Partial workspace patch for `PUT /settings`, mirroring the engine `WorkspaceUpdate`.
export interface WorkspaceSettingsUpdate {
  quotaMB?: number;
  quotaFiles?: number;
  tmpTTLDays?: number;
}

// Combined workspace default mirroring WorkspaceConfig. The fresh Tools form
// seeds from this so the quota editors match the boundary the engine enforces
// before the first settings fetch.
export const DEFAULT_WORKSPACE_CONFIG: WorkspaceConfigData = {
  quotaMB: DEFAULT_WORKSPACE_QUOTA_MB,
  quotaFiles: DEFAULT_WORKSPACE_QUOTA_FILES,
  tmpTTLDays: DEFAULT_WORKSPACE_TMP_TTL_DAYS,
};

