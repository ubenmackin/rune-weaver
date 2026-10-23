// Rune Weaver Dashboard — Index policy dirty-tracking snapshot helpers.
import {
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_PAUSE_ON_BATTERY,
  DEFAULT_INDEX_THERMAL_BACKOFF,
  DEFAULT_INDEX_WORKERS,
  parseMailboxDenyText,
  type IndexConfigData,
} from "../../api";
import {
  normalizeIndexEffortPreset,
  parseIndexRootsText,
  resolveIndexVectorCapValue,
  resolveIndexWorkersValue,
} from "./indexPolicyHelpers";

// Last-saved snapshot behind the Save gate: canonical values so
// formatting-only textarea edits read clean.
export interface IndexPolicySnapshot {
  enabled: boolean;
  files: boolean;
  mail: boolean;
  messages: boolean;
  calendars: boolean;
  reminders: boolean;
  rootsKey: string;
  excludeKey: string;
  mailboxDenyKey: string;
  maxFileMB: number;
  nightlyBudget: number;
  vectorCap: number;
  mailVectorWindow: string;
  iCloudEvicted: string;
  effort: string;
  workers: number;
  thermalBackoff: boolean;
  pauseOnBattery: boolean;
  dbPath: string;
}

// Presets derive workers on the engine, so only custom carries a count.
export function canonicalIndexWorkers(config: IndexConfigData): number {
  if (normalizeIndexEffortPreset(config.effort) !== "custom") return 0;
  return resolveIndexWorkersValue(config) ?? DEFAULT_INDEX_WORKERS;
}

// Exclude compares as a normalized set: trim, drop blanks, dedupe, sort.
export function canonicalExcludeKey(lines: string[]): string {
  return [...new Set(lines.map((line) => line.trim()).filter(Boolean))]
    .sort()
    .join("\n");
}

export function buildIndexPolicySnapshot(
  config: IndexConfigData,
  excludeText: string,
  mailboxDenyText: string,
  rootsText: string,
): IndexPolicySnapshot {
  return {
    enabled: !!config.enabled,
    files: !!config.files,
    mail: !!config.mail,
    messages: !!config.messages,
    calendars: !!config.calendars,
    reminders: !!config.reminders,
    rootsKey: parseIndexRootsText(rootsText).join("\n"),
    excludeKey: canonicalExcludeKey(excludeText.split("\n")),
    mailboxDenyKey: parseMailboxDenyText(mailboxDenyText).join("\n"),
    maxFileMB: Number(config.maxFileMB),
    nightlyBudget: Number(config.nightlyBudget),
    vectorCap:
      resolveIndexVectorCapValue(config) ??
      (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number),
    mailVectorWindow: config.mailVectorWindow,
    iCloudEvicted: config.iCloudEvicted,
    effort: normalizeIndexEffortPreset(config.effort),
    workers: canonicalIndexWorkers(config),
    thermalBackoff: config.thermalBackoff ?? DEFAULT_INDEX_THERMAL_BACKOFF,
    pauseOnBattery: config.pauseOnBattery ?? DEFAULT_INDEX_PAUSE_ON_BATTERY,
    dbPath: typeof config.dbPath === "string" ? config.dbPath.trim() : "",
  };
}

export function isIndexPolicySnapshotDirty(
  snapshot: IndexPolicySnapshot,
  config: IndexConfigData,
  excludeText: string,
  mailboxDenyText: string,
  rootsText: string,
): boolean {
  const draft = buildIndexPolicySnapshot(
    config,
    excludeText,
    mailboxDenyText,
    rootsText,
  );
  return (
    draft.enabled !== snapshot.enabled ||
    draft.files !== snapshot.files ||
    draft.mail !== snapshot.mail ||
    draft.messages !== snapshot.messages ||
    draft.calendars !== snapshot.calendars ||
    draft.reminders !== snapshot.reminders ||
    draft.rootsKey !== snapshot.rootsKey ||
    draft.excludeKey !== snapshot.excludeKey ||
    draft.mailboxDenyKey !== snapshot.mailboxDenyKey ||
    draft.maxFileMB !== snapshot.maxFileMB ||
    draft.nightlyBudget !== snapshot.nightlyBudget ||
    draft.vectorCap !== snapshot.vectorCap ||
    draft.mailVectorWindow !== snapshot.mailVectorWindow ||
    draft.iCloudEvicted !== snapshot.iCloudEvicted ||
    draft.effort !== snapshot.effort ||
    draft.workers !== snapshot.workers ||
    draft.thermalBackoff !== snapshot.thermalBackoff ||
    draft.pauseOnBattery !== snapshot.pauseOnBattery ||
    draft.dbPath !== snapshot.dbPath
  );
}
