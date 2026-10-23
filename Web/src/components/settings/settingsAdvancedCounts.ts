// Rune Weaver Dashboard — Settings advanced defaults and write-posture helpers.

export const DEFAULT_MEMORY_RECALL_AUTO_LIMIT = 5;
export const DEFAULT_MEMORY_RECALL_DOC_POOL_MULTIPLIER = 4;
export const DEFAULT_MEMORY_RECALL_EPISODIC_WEIGHT = 0.25;

export const DEFAULT_MEMORY_EMBEDDING_BACKEND = "local";

// Stock engine compaction threshold; EngineTab reset plus slider hint reuse it.
export const DEFAULT_ENGINE_COMPACTION_THRESHOLD = 80;

// Stock Tools Advanced values; ToolsTab reset reuses these.
export const DEFAULT_TOOLS_PLUGINS_DIR = "~/.runeweaver/plugins";
export const DEFAULT_TOOLS_MARKETPLACE_INDEX_URL =
  "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json";
export const DEFAULT_TOOLS_AUTO_RESCAN = true;

// Default whisper model; Advanced holds this knob alone.
export const DEFAULT_VOICE_WHISPER_MODEL = "base";

// Default per-path write posture list mirroring the Files editor boundary:
// personal directories request approval while working directories stage.
export type FilesWritePosture = "live" | "stage" | "ask" | "deny";

export const DEFAULT_FILES_POSTURE: FilesWritePosture = "ask";

// Write-path rule shape shared by the Files editor.
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
