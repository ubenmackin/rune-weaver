// Rune Weaver Dashboard — Index policy effort, machine cores, and roots validation helpers.

import {
  DEFAULT_INDEX_EFFORT,
  DEFAULT_INDEX_WORKERS,
  INDEX_EFFORT_PRESETS,
  INDEX_EFFORT_PRESET_LABELS,
  INDEX_MAX_CUSTOM_WORKERS,
  formatIndexCount,
  formatListToText,
  parseLinesToList,
} from "../../api";

export const INDEX_EFFORT_OPTIONS: Array<{ id: string; label: string }> = [
  ...INDEX_EFFORT_PRESETS.map((id) => ({
    id,
    label: INDEX_EFFORT_PRESET_LABELS[id] ?? id,
  })),
  { id: "custom", label: INDEX_EFFORT_PRESET_LABELS.custom ?? "Custom" },
];

// Normalizes a stored effort token to the canonical preset id, mirroring IndexConfig.allowedEfforts
// (`light`, `balanced`, `performance`, `custom`).
export function normalizeIndexEffortPreset(value: unknown): string {
  if (typeof value !== "string") return DEFAULT_INDEX_EFFORT;
  const token = value.trim().toLowerCase();
  if (
    token === "light" ||
    token === "balanced" ||
    token === "performance" ||
    token === "custom"
  )
    return token;
  if (token === "eco" || token === "low") return "light";
  if (token === "standard") return "balanced";
  if (token === "fast" || token === "high" || token === "max")
    return "performance";
  return DEFAULT_INDEX_EFFORT;
}

// Display label for an effort preset, falling back to the wire token so an
// unknown future preset still renders honestly.
export function indexEffortLabel(preset: string): string {
  const token = typeof preset === "string" ? preset.trim().toLowerCase() : "";
  if (!token) return INDEX_EFFORT_PRESET_LABELS.balanced ?? "Balanced";
  return INDEX_EFFORT_PRESET_LABELS[token] ?? preset;
}

// Machine core count for the effort mapping: the engine `coreCount` when it carries a positive
// finite value, otherwise the browser `hardwareConcurrency`, otherwise null so callers omit the
// of-N-cores suffix instead of guessing.
export function resolveMachineCores(
  statusCores?: number | null | undefined,
): number | null {
  if (
    typeof statusCores === "number" &&
    Number.isFinite(statusCores) &&
    statusCores > 0
  )
    return Math.floor(statusCores);
  if (
    typeof navigator !== "undefined" &&
    typeof navigator.hardwareConcurrency === "number" &&
    Number.isFinite(navigator.hardwareConcurrency) &&
    navigator.hardwareConcurrency > 0
  )
    return Math.floor(navigator.hardwareConcurrency);
  return null;
}

// Resolves effort preset worker counts mirroring IndexConfig.resolvedWorkerCount: light pins 1,
// balanced takes half cores (max 4), performance takes all but 1, and custom clamps to 1..64
// and available cores; unknown core counts default to 1.
export function resolveEffortWorkers(
  preset: string | null | undefined,
  coreCount: number | null | undefined,
  customWorkers?: number | null | undefined,
): number {
  const normalized = normalizeIndexEffortPreset(preset);
  const cores =
    typeof coreCount === "number" &&
    Number.isFinite(coreCount) &&
    coreCount > 0
      ? Math.floor(coreCount)
      : 0;
  const custom =
    typeof customWorkers === "number" &&
    Number.isFinite(customWorkers) &&
    customWorkers >= 1
      ? Math.min(INDEX_MAX_CUSTOM_WORKERS, Math.floor(customWorkers))
      : null;
  if (cores <= 0) {
    if (normalized === "custom")
      return Math.min(
        INDEX_MAX_CUSTOM_WORKERS,
        custom ?? DEFAULT_INDEX_WORKERS,
      );
    // Unknown cores mirror safeCores=max(1,cores): light pins 1, balanced
    // takes half of one clamped to 1, performance takes all but one clamped
    // to 1, so every preset resolves to 1.
    return 1;
  }
  if (normalized === "light") return 1;
  if (normalized === "balanced") return Math.max(1, Math.min(4, Math.floor(cores / 2)));
  if (normalized === "performance") return Math.max(1, cores - 1);
  // Custom clamps the stepper into the static ceiling and the machine so a
  // stale value from a larger machine never asks for more workers than exist
  // here.
  const fallback = Math.max(1, Math.min(4, Math.floor(cores / 2)));
  const wanted = custom ?? fallback;
  return Math.min(cores, Math.min(INDEX_MAX_CUSTOM_WORKERS, Math.max(1, wanted)));
}

// Reads the custom worker count from an index payload. Non-finite or
// out-of-range values degrade to null so callers apply their own default
// instead of guessing.
export function resolveIndexWorkersValue(
  data: { workers?: unknown } | null | undefined,
): number | null {
  if (!data || typeof data !== "object") return null;
  const candidate =
    typeof data.workers === "number" && Number.isFinite(data.workers)
      ? data.workers
      : null;
  if (candidate == null || candidate < 1) return null;
  return Math.floor(candidate);
}

// Reads the per-document vector chunk cap from an index payload. Non-finite
// or out-of-range values degrade to null so callers apply the engine default
// instead of rendering a drifted figure.
export function resolveIndexVectorCapValue(
  data: { maxVectorChunksPerDocument?: unknown } | null | undefined,
): number | null {
  if (!data || typeof data !== "object") return null;
  const candidate = (data as { maxVectorChunksPerDocument?: unknown })
    .maxVectorChunksPerDocument;
  if (typeof candidate !== "number" || !Number.isFinite(candidate)) return null;
  if (candidate < 1) return null;
  return Math.floor(candidate);
}

// Resolved effort signal from a status payload, reading the canonical nested `effort` block
// (`preset`/`resolvedWorkers`/`activeProcessors`).
export function resolveStatusEffort(status: unknown): {
  preset: string | null;
  resolvedWorkers: number | null;
  coreCount: number | null;
} {
  if (!status || typeof status !== "object") {
    return { preset: null, resolvedWorkers: null, coreCount: null };
  }
  const record = status as {
    effort?: unknown;
  };
  const nested =
    record.effort && typeof record.effort === "object"
      ? (record.effort as {
          preset?: unknown;
          resolvedWorkers?: unknown;
          activeProcessors?: unknown;
        })
      : null;
  const rawPreset =
    typeof nested?.preset === "string" && nested.preset.trim()
      ? nested.preset.trim()
      : null;
  // Preserve unknown future presets verbatim while mapping aliases
  // onto canonical ids so an upgraded engine still renders honestly.
  let preset: string | null = null;
  if (rawPreset != null) {
    const lowered = rawPreset.toLowerCase();
    if (
      lowered === "light" ||
      lowered === "balanced" ||
      lowered === "performance" ||
      lowered === "custom"
    ) {
      preset = lowered;
    } else if (lowered === "eco" || lowered === "low") {
      preset = "light";
    } else if (lowered === "standard") {
      preset = "balanced";
    } else if (lowered === "fast" || lowered === "high" || lowered === "max") {
      preset = "performance";
    } else {
      preset = lowered;
    }
  }
  const nestedResolved =
    typeof nested?.resolvedWorkers === "number" &&
    Number.isFinite(nested.resolvedWorkers) &&
    (nested.resolvedWorkers as number) > 0
      ? Math.floor(nested.resolvedWorkers as number)
      : null;
  const nestedCores =
    typeof nested?.activeProcessors === "number" &&
    Number.isFinite(nested.activeProcessors) &&
    (nested.activeProcessors as number) > 0
      ? Math.floor(nested.activeProcessors as number)
      : null;
  return {
    preset,
    resolvedWorkers: nestedResolved,
    coreCount: nestedCores,
  };
}

// Resolved-reality copy for the effort control: preset label plus the worker resolution against the
// machine (`Balanced - using 4 of 10 cores`).
export function describeEffortReality(
  preset: string | null | undefined,
  resolvedWorkers: number | null | undefined,
  coreCount: number | null | undefined,
): string {
  const label = indexEffortLabel(normalizeIndexEffortPreset(preset));
  const resolved =
    typeof resolvedWorkers === "number" &&
    Number.isFinite(resolvedWorkers) &&
    resolvedWorkers > 0
      ? Math.floor(resolvedWorkers)
      : null;
  const cores =
    typeof coreCount === "number" &&
    Number.isFinite(coreCount) &&
    coreCount > 0
      ? Math.floor(coreCount)
      : null;
  if (resolved != null && cores != null) {
    const coreNoun = cores === 1 ? "core" : "cores";
    return `${label} - using ${formatIndexCount(resolved)} of ${formatIndexCount(cores)} ${coreNoun}`;
  }
  if (resolved != null) {
    const workerNoun = resolved === 1 ? "worker" : "workers";
    return `${label} - using ${formatIndexCount(resolved)} ${workerNoun}`;
  }
  return label;
}

// Display string for the configured file roots: the home shorthand gains its parenthetical so a
// stock `~` reads as the home directory instead of a bare sigil, while custom roots join verbatim so
// the subtitle names exactly what the walker covers.
export function formatIndexScopeRoots(roots: unknown): string {
  if (!Array.isArray(roots)) return "~ (your home directory)";
  const cleaned = roots
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (cleaned.length === 0) return "no configured roots";
  return cleaned
    .map((root) => (root === "~" ? "~ (your home directory)" : root))
    .join(", ");
}

// Root-scoped coverage subtitle for the Index Policy panel: names the
// configured roots and states that nothing outside them is ever scanned, so
// the owner sees the walk boundary without opening the config file.
export function describeIndexScope(roots: unknown): string {
  return `Builds a local search index of ${formatIndexScopeRoots(roots)}. Nothing outside the configured roots is ever scanned.`;
}

// Parses the index-roots textarea into the wire shape: one root per line, trimmed, with blank lines
// dropped so an emptied editor reads as an explicit empty list instead of persisting whitespace
// rows.
export function parseIndexRootsText(text: string | undefined | null): string[] {
  if (typeof text !== "string") return [];
  return parseLinesToList(text ?? "", []);
}

// Formats an index-roots array for the multiline editor, joining one root per line so the textarea
// and the stored array stay symmetric.
export function formatIndexRootsText(
  roots: string[] | undefined | null,
): string {
  return formatListToText(roots, "");
}

// Validates the index-roots textarea before any network write: blank lines collapse on save, an
// emptied editor is rejected, and `..` escapes are rejected with line numbers so a traversal escape
// points at its editor row.
export function validateIndexRootsText(
  text: string | undefined | null,
): string | null {
  const raw = typeof text === "string" ? text : "";
  const lines = raw.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (!trimmed) continue;
    if (trimmed.includes("..")) {
      return `Line ${index + 1}: Index root must not contain '..': "${trimmed}".`;
    }
  }
  if (parseIndexRootsText(text).length === 0) {
    return "Index roots cannot be empty.";
  }
  return null;
}

// Normalizes one root for the outside-allow-roots comparison: trims and drops
// trailing slashes so `~/Docs/` and `~/Docs` compare equal without changing
// the stored value. `~` keeps its sigil so home containment reads honestly.
function normalizeIndexRootForCompare(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "~" || trimmed === "/") return trimmed;
  return trimmed.replace(/\/+$/, "");
}

// Reports whether one index root sits inside one files allow root: an exact match or a child path
// under the allow root counts as inside, so `~/Docs/Sub` stays inside `~/Docs` and `~` contains
// every `~/...` entry.
export function isIndexRootInsideAllowRoot(
  indexRoot: string,
  allowRoot: string,
): boolean {
  const index = normalizeIndexRootForCompare(indexRoot);
  const allow = normalizeIndexRootForCompare(allowRoot);
  if (!index || !allow) return false;
  if (index === allow) return true;
  if (allow === "~") {
    return index === "~" || index.startsWith("~/");
  }
  return index.startsWith(allow.endsWith("/") ? allow : `${allow}/`);
}

// Lists the index roots sitting outside every loaded files allow root, so the policy form can warn
// that recalled content from there may not be readable by live file tools.
export function findOutsideIndexRoots(
  indexRoots: unknown,
  allowRoots: unknown,
): string[] {
  if (!Array.isArray(indexRoots) || !Array.isArray(allowRoots)) return [];
  const cleanedAllow = allowRoots
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (cleanedAllow.length === 0) return [];
  const cleanedIndex = indexRoots
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter(Boolean);
  return cleanedIndex.filter(
    (root) => !cleanedAllow.some((allow) => isIndexRootInsideAllowRoot(root, allow)),
  );
}

// Always-skipped names from the index settings payload: the engine's `alwaysSkipped` array
// populated from the walker's prune list.
export function resolveAlwaysSkipped(index: unknown): string[] {
  if (!index || typeof index !== "object") return [];
  const raw = (index as { alwaysSkipped?: unknown }).alwaysSkipped;
  if (!Array.isArray(raw)) return [];
  return raw.filter(
    (entry): entry is string =>
      typeof entry === "string" && entry.trim().length > 0,
  );
}

