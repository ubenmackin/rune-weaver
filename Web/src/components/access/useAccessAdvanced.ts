// Rune Weaver Dashboard — Per-section Access advanced hooks for Bash and Files drafts.
import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  formatDenyPatternsText,
  parseDenyPatternsText,
  parseHostAllowPatternsUncapped,
  type BashSettingsUpdate,
  type SettingsResponse,
  type UpdateSettingsInput,
} from "../../api";
import {
  countBashAdvancedChanged,
  countFilesAdvancedChanged,
  writePathRulesDiffer,
} from "../settings/settingsAdvancedCounts";
import {
  bashLoadedFromDraft,
  bashDraftFromLoaded,
  freshBashDraft,
  freshBashLoaded,
  normalizeBashSandboxMode,
  normalizeHostAllowPatternsText,
  validateBashBudgets,
  validateBashConfinementFields,
  type BashLoadedSnapshot,
} from "./accessBashDraft";
import {
  canonicalWritePathRules,
  defaultFilesWritePathRules,
  normalizeFilesWritePosture,
  validateFilesAdvancedFields,
  type FilesLoadedSnapshot,
  type WritePathRule,
} from "./accessFilesRules";
import {
  fetchSharedAccessSettings,
  resolveBashDraftAndLoaded,
  resolveFilesLoadedSnapshot,
} from "./accessSettingsLoader";

export interface UseBashAdvancedResult {
  loading: boolean;
  loadError: string | null;
  saveError: string | null;
  open: boolean;
  changed: boolean;
  changedCount: number;
  timeoutSeconds: number | string;
  cpuSeconds: number | string;
  memoryMB: number | string;
  sandboxMode: string;
  hostAllowPatternsText: string;
  setOpen: (open: boolean) => void;
  setSaveError: (message: string | null) => void;
  handleTimeoutChange: (raw: string) => void;
  handleCpuChange: (raw: string) => void;
  handleMemoryChange: (raw: string) => void;
  handleSandboxModeChange: (mode: string) => void;
  handleHostAllowPatternsChange: (text: string) => void;
  validate: () => string | null;
  buildPatch: () => UpdateSettingsInput;
  applySaved: (updated: SettingsResponse) => void;
  reset: () => void;
}

export interface UseFilesAdvancedResult {
  loading: boolean;
  loadError: string | null;
  saveError: string | null;
  open: boolean;
  changed: boolean;
  changedCount: number;
  filesRules: WritePathRule[];
  denyPatternsText: string;
  setOpen: (open: boolean) => void;
  setSaveError: (message: string | null) => void;
  setDenyPatternsText: (text: string) => void;
  handleFilesRulePathChange: (index: number, raw: string) => void;
  handleFilesRulePostureChange: (index: number, next: string) => void;
  handleAddFilesRule: () => void;
  handleRemoveFilesRule: (index: number) => void;
  validate: () => string | null;
  buildPatch: () => UpdateSettingsInput;
  applySaved: (updated: SettingsResponse) => void;
  reset: () => void;
}

function sameStringList(left: readonly string[], right: readonly string[]): boolean {
  if (left.length !== right.length) return false;
  return left.every((entry, index) => entry === right[index]);
}

// Owns the Bash Advanced slice only: numeric budgets plus execution tier plus
// host allowlist. Simple owns default action, rules, and allow-network so
// Reset advanced never touches them.
export function useAccessBashAdvanced(): UseBashAdvancedResult {
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const initial = freshBashDraft();
  const [timeoutSeconds, setTimeoutSeconds] = useState<number | string>(
    initial.timeoutSeconds
  );
  const [cpuSeconds, setCpuSeconds] = useState<number | string>(initial.cpuSeconds);
  const [memoryMB, setMemoryMB] = useState<number | string>(initial.memoryMB);
  const [sandboxMode, setSandboxMode] = useState<string>(initial.sandboxMode);
  const [hostAllowPatternsText, setHostAllowPatternsText] = useState<string>(
    initial.hostAllowPatternsText
  );
  const loadedRef = useRef<BashLoadedSnapshot>(freshBashLoaded());

  const loadAdvanced = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const data = await fetchSharedAccessSettings();
      const resolved = resolveBashDraftAndLoaded(data, loadedRef.current);
      if (resolved) {
        loadedRef.current = resolved.loaded;
        setTimeoutSeconds(resolved.loaded.timeoutSeconds);
        setCpuSeconds(resolved.loaded.cpuSeconds);
        setMemoryMB(resolved.loaded.memoryMb);
        setSandboxMode(resolved.loaded.sandboxMode);
        setHostAllowPatternsText(
          normalizeHostAllowPatternsText(resolved.loaded.hostAllowPatterns)
        );
      }
    } catch (err: unknown) {
      setLoadError(
        err instanceof ApiError ? err.message : "Failed to load advanced access settings."
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadAdvanced();
  }, [loadAdvanced]);

  const buildPatch = useCallback((): UpdateSettingsInput => {
    const loaded = loadedRef.current;
    const bashPatch: BashSettingsUpdate = {};
    if (Number(timeoutSeconds) !== loaded.timeoutSeconds) {
      bashPatch.timeoutSeconds = Number(timeoutSeconds);
    }
    if (Number(cpuSeconds) !== loaded.cpuSeconds) {
      bashPatch.cpuSeconds = Number(cpuSeconds);
    }
    if (Number(memoryMB) !== loaded.memoryMb) {
      bashPatch.memoryMb = Number(memoryMB);
    }
    if (sandboxMode !== loaded.sandboxMode) {
      bashPatch.sandboxMode = sandboxMode;
    }
    const hostPatterns = parseHostAllowPatternsUncapped(hostAllowPatternsText);
    if (!sameStringList(hostPatterns, loaded.hostAllowPatterns)) {
      bashPatch.hostAllowPatterns = hostPatterns;
    }
    return Object.keys(bashPatch).length > 0 ? { bash: bashPatch } : {};
  }, [cpuSeconds, hostAllowPatternsText, memoryMB, sandboxMode, timeoutSeconds]);

  const patch = buildPatch();
  const changed = Object.keys(patch).length > 0;
  const changedCount = countBashAdvancedChanged(
    timeoutSeconds,
    cpuSeconds,
    memoryMB,
    sandboxMode,
    hostAllowPatternsText
  );

  function validate(): string | null {
    const tuningError = validateBashBudgets(
      timeoutSeconds,
      cpuSeconds,
      memoryMB
    );
    if (tuningError) return tuningError;
    return validateBashConfinementFields(sandboxMode, hostAllowPatternsText);
  }

  function applySaved(updated: SettingsResponse): void {
    const bash = updated.bash;
    if (bash) {
      const loaded = bashLoadedFromDraft({
        ...bashDraftFromLoaded(loadedRef.current),
        timeoutSeconds:
          typeof bash.timeoutSeconds === "number"
            ? bash.timeoutSeconds
            : Number(timeoutSeconds),
        cpuSeconds:
          typeof bash.cpuSeconds === "number"
            ? bash.cpuSeconds
            : Number(cpuSeconds),
        memoryMB:
          typeof bash.memoryMb === "number" ? bash.memoryMb : Number(memoryMB),
        sandboxMode: normalizeBashSandboxMode(
          typeof bash.sandboxMode === "string" ? bash.sandboxMode : sandboxMode
        ),
        hostAllowPatternsText: Array.isArray(bash.hostAllowPatterns)
          ? normalizeHostAllowPatternsText(bash.hostAllowPatterns)
          : hostAllowPatternsText,
      });
      loadedRef.current = loaded;
      setTimeoutSeconds(loaded.timeoutSeconds);
      setCpuSeconds(loaded.cpuSeconds);
      setMemoryMB(loaded.memoryMb);
      setSandboxMode(loaded.sandboxMode);
      setHostAllowPatternsText(normalizeHostAllowPatternsText(loaded.hostAllowPatterns));
    }
    setSaveError(null);
  }

  function reset(): void {
    const fresh = freshBashDraft();
    setTimeoutSeconds(fresh.timeoutSeconds);
    setCpuSeconds(fresh.cpuSeconds);
    setMemoryMB(fresh.memoryMB);
    setSandboxMode(fresh.sandboxMode);
    setHostAllowPatternsText(fresh.hostAllowPatternsText);
    setSaveError(null);
  }

  return {
    loading,
    loadError,
    saveError,
    open,
    changed,
    changedCount,
    timeoutSeconds,
    cpuSeconds,
    memoryMB,
    sandboxMode,
    hostAllowPatternsText,
    setOpen,
    setSaveError,
    handleTimeoutChange(raw) {
      setTimeoutSeconds(raw === "" ? "" : Number(raw));
      setSaveError(null);
    },
    handleCpuChange(raw) {
      setCpuSeconds(raw === "" ? "" : Number(raw));
      setSaveError(null);
    },
    handleMemoryChange(raw) {
      setMemoryMB(raw === "" ? "" : Number(raw));
      setSaveError(null);
    },
    handleSandboxModeChange(mode) {
      setSandboxMode(normalizeBashSandboxMode(mode));
      setSaveError(null);
    },
    handleHostAllowPatternsChange(text) {
      setHostAllowPatternsText(text);
      setSaveError(null);
    },
    validate,
    buildPatch,
    applySaved,
    reset,
  };
}

// Owns the Files Advanced slice only: write-path rules plus deny patterns. The
// mode, allowed roots, and approval switch stay in Simple.
export function useAccessFilesAdvanced(): UseFilesAdvancedResult {
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [filesRules, setFilesRules] = useState<WritePathRule[]>(() =>
    defaultFilesWritePathRules()
  );
  const [denyPatternsText, setDenyPatternsText] = useState<string>(
    formatDenyPatternsText(undefined)
  );
  const loadedRef = useRef<FilesLoadedSnapshot>({
    writeMode: "model",
    writePathRules: defaultFilesWritePathRules(),
    denyPatternsText: formatDenyPatternsText(undefined),
    allowRootsText: "~",
    requireApprovalOnDeny: true,
  });

  const loadAdvanced = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const data = await fetchSharedAccessSettings();
      const snapshot = resolveFilesLoadedSnapshot(data);
      if (snapshot) {
        loadedRef.current = {
          ...loadedRef.current,
          writePathRules: snapshot.writePathRules.map((rule) => ({ ...rule })),
          denyPatternsText: snapshot.denyPatternsText,
        };
        setFilesRules(snapshot.writePathRules.map((rule) => ({ ...rule })));
        setDenyPatternsText(snapshot.denyPatternsText);
      }
    } catch (err: unknown) {
      setLoadError(
        err instanceof ApiError ? err.message : "Failed to load advanced access settings."
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadAdvanced();
  }, [loadAdvanced]);

  const buildPatch = useCallback((): UpdateSettingsInput => {
    const loaded = loadedRef.current;
    const patch: UpdateSettingsInput = {};
    const canonical = canonicalWritePathRules(filesRules);
    if (writePathRulesDiffer(canonical, loaded.writePathRules)) {
      patch.filesWritePathRules = canonical.map((rule) => ({
        path: rule.path,
        posture: rule.posture,
      }));
    }
    if (denyPatternsText !== loaded.denyPatternsText) {
      patch.filesDenyPatterns = parseDenyPatternsText(denyPatternsText);
    }
    return patch;
  }, [denyPatternsText, filesRules]);

  const patch = buildPatch();
  const changed = Object.keys(patch).length > 0;
  const changedCount = countFilesAdvancedChanged(filesRules, denyPatternsText);

  function validate(): string | null {
    return validateFilesAdvancedFields(filesRules, denyPatternsText);
  }

  function applySaved(updated: SettingsResponse): void {
    const snapshot = resolveFilesLoadedSnapshot(updated);
    const rules = snapshot
      ? snapshot.writePathRules
      : canonicalWritePathRules(filesRules);
    const denyText = snapshot ? snapshot.denyPatternsText : denyPatternsText;
    loadedRef.current = {
      ...loadedRef.current,
      writePathRules: rules.map((rule) => ({ ...rule })),
      denyPatternsText: denyText,
    };
    setFilesRules(rules.map((rule) => ({ ...rule })));
    setDenyPatternsText(denyText);
    setSaveError(null);
  }

  function reset(): void {
    setFilesRules(defaultFilesWritePathRules());
    setDenyPatternsText(formatDenyPatternsText(undefined));
    setSaveError(null);
  }

  return {
    loading,
    loadError,
    saveError,
    open,
    changed,
    changedCount,
    filesRules,
    denyPatternsText,
    setOpen,
    setSaveError,
    setDenyPatternsText(text) {
      setDenyPatternsText(text);
      setSaveError(null);
    },
    handleFilesRulePathChange(index, raw) {
      setFilesRules((prev) =>
        prev.map((rule, position) =>
          position === index ? { ...rule, path: raw } : rule
        )
      );
      setSaveError(null);
    },
    handleFilesRulePostureChange(index, next) {
      setFilesRules((prev) =>
        prev.map((rule, position) =>
          position === index
            ? { ...rule, posture: normalizeFilesWritePosture(next) }
            : rule
        )
      );
      setSaveError(null);
    },
    handleAddFilesRule() {
      setFilesRules((prev) => [...prev, { path: "", posture: "ask" }]);
      setSaveError(null);
    },
    handleRemoveFilesRule(index) {
      setFilesRules((prev) => prev.filter((_, position) => position !== index));
      setSaveError(null);
    },
    validate,
    buildPatch,
    applySaved,
    reset,
  };
}

export default useAccessBashAdvanced;
