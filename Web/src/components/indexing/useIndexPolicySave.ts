// Rune Weaver Dashboard — Index save-and-restart hook for IndexPolicyPanel.
import { useCallback, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_MAILBOX_DENY,
  DEFAULT_INDEX_PAUSE_ON_BATTERY,
  DEFAULT_INDEX_THERMAL_BACKOFF,
  DEFAULT_INDEX_WORKERS,
  cancelIndex,
  describeIndexRun,
  formatMailboxDenyText,
  getIndexStatus,
  parseMailboxDenyText,
  requestIndexAccess,
  resolveIndexSourceAccess,
  runIndex,
  updateSettings,
  type IndexConfigData,
  type IndexStatusResponse,
} from "../../api";
import {
  INDEX_VECTOR_CAP_MAX,
  formatIndexRootsText,
  normalizeIndexEffortPreset,
  parseIndexRootsText,
  resolveIndexVectorCapValue,
  resolveIndexWorkersValue,
  validateIndexRootsText,
} from "./indexPolicyHelpers";

// Advanced Index messages the disclosure can focus. `cap` is absent: it
// matched too broadly and stole unrelated errors from the inline link.
export const INDEX_ADVANCED_ERROR_KEYWORDS = [
  "vector",
  "vector cap",
  "exclude",
  "mailbox",
  "mail vector",
  "icloud",
] as const;

export function isIndexAdvancedError(message: string): boolean {
  const lowered = message.toLowerCase();
  return INDEX_ADVANCED_ERROR_KEYWORDS.some((keyword) =>
    lowered.includes(keyword)
  );
}

interface UseIndexPolicySaveArgs {
  config: IndexConfigData;
  setConfig: (next: IndexConfigData | ((prev: IndexConfigData) => IndexConfigData)) => void;
  excludeText: string;
  setExcludeText: (value: string) => void;
  mailboxDenyText: string;
  setMailboxDenyText: (value: string) => void;
  rootsText: string;
  setRootsText: (value: string) => void;
  loadStatus: () => Promise<IndexStatusResponse | null>;
  pushSuccessToast: (message: string) => void;
  pushErrorToast: (message: string) => void;
  mountedRef: { current: boolean };
  lastSavedSourcesRef: {
    current: { calendars: boolean; reminders: boolean } | null;
  };
}

// Owns the Index save-and-restart chain so the panel stays under budget. The
// settings patch never auto-starts a run; a policy saved mid-scan stops the
// old generation and starts a fresh one with the new roots and caps.
export function useIndexPolicySave({
  config,
  setConfig,
  excludeText,
  setExcludeText,
  mailboxDenyText,
  setMailboxDenyText,
  rootsText,
  setRootsText,
  loadStatus,
  pushSuccessToast,
  pushErrorToast,
  mountedRef,
  lastSavedSourcesRef,
}: UseIndexPolicySaveArgs) {
  const [saving, setSaving] = useState(false);
  // Save-and-restart inputs come from the fresh post-PUT status read in
  // handleSave, never from a cached flag, so a run started between boot and
  // save still counts and a disable-then-save never restarts.
  const [notice, setNotice] = useState<string | null>(null);
  // Advanced disclosure state for fail-closed validation. Collapsed by
  // default, auto-expands when an Advanced error blocks Save.
  const [advancedValidationError, setAdvancedValidationError] = useState<
    string | null
  >(null);

  // Persists the [index] patch and returns the saved enabled flag from the PUT
  // response, falling back to the pre-save closure only when the engine omits
  // the section, so handleSave restarts solely from post-save truth.
  const persistConfig = useCallback(async (): Promise<boolean> => {
    const exclude = excludeText
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    // Denied mailboxes mirror the excludes editor: one glob per line,
    // trimmed, blanks dropped so an emptied editor opts every mailbox back
    // in instead of persisting whitespace rows.
    const mailboxDeny = parseMailboxDenyText(mailboxDenyText);
    // Index roots mirror the excludes editor: one root per line, trimmed with
    // blanks dropped, saved through the existing `roots` key with no shape change.
    const roots = parseIndexRootsText(rootsText);
    const effort = normalizeIndexEffortPreset(config.effort);
    // Presets derive workers on the engine so they must save 0; only custom
    // carries an explicit 1..64 count.
    const customWorkers =
      resolveIndexWorkersValue(config) ?? DEFAULT_INDEX_WORKERS;
    const workers = effort === "custom" ? customWorkers : 0;
    const vectorCap =
      resolveIndexVectorCapValue(config) ??
      (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number);
    const saved = await updateSettings({
      index: {
        enabled: config.enabled,
        files: config.files,
        mail: config.mail,
        messages: config.messages,
        calendars: config.calendars,
        reminders: config.reminders,
        roots,
        exclude,
        maxFileMB: config.maxFileMB,
        mailVectorWindow: config.mailVectorWindow,
        iCloudEvicted: config.iCloudEvicted,
        nightlyBudget: config.nightlyBudget,
        dbPath: config.dbPath.trim(),
        effort,
        workers,
        thermalBackoff: config.thermalBackoff ?? DEFAULT_INDEX_THERMAL_BACKOFF,
        pauseOnBattery:
          config.pauseOnBattery ?? DEFAULT_INDEX_PAUSE_ON_BATTERY,
        maxVectorChunksPerDocument: vectorCap,
        mailboxDeny: mailboxDeny,
      },
    });
    const index = saved?.index;
    if (index) {
      const merged: IndexConfigData = {
        ...DEFAULT_INDEX_CONFIG,
        ...index,
        roots: Array.isArray(index.roots) ? index.roots : DEFAULT_INDEX_CONFIG.roots,
        exclude: Array.isArray(index.exclude)
          ? index.exclude
          : DEFAULT_INDEX_CONFIG.exclude,
        mailboxDeny: Array.isArray(
          (index as IndexConfigData).mailboxDeny,
        )
          ? ((index as IndexConfigData).mailboxDeny as string[])
          : [...DEFAULT_INDEX_MAILBOX_DENY],
        alwaysSkipped: Array.isArray(
          (index as IndexConfigData).alwaysSkipped,
        )
          ? (index as IndexConfigData).alwaysSkipped
          : undefined,
      };
      if (mountedRef.current) {
        setConfig(merged as IndexConfigData);
        setExcludeText(merged.exclude.join("\n"));
        setMailboxDenyText(
          formatMailboxDenyText(merged.mailboxDeny),
        );
        // Keep the textarea synced to the saved echo so save-plus-reload
        // stays honest without TOML hand-edits.
        setRootsText(formatIndexRootsText(merged.roots));
      }
    }
    // Saved enabled truth for the restart gate: the engine echo wins so a
    // disable-then-save never restarts from a stale pre-save closure.
    return typeof index?.enabled === "boolean" ? index.enabled : config.enabled;
  }, [config, excludeText, mailboxDenyText, rootsText, mountedRef, setConfig, setExcludeText, setMailboxDenyText, setRootsText]);

  // Sole owner of save-and-restart: the settings patch never auto-starts a run,
  // so a policy saved mid-scan must stop the old generation and start a fresh
  // one with the new roots, excludes, and caps.
  const handleSave = useCallback(async () => {
    if (saving) return;
    setSaving(true);
    // A stale restart line must never survive a new save: an idle save would
    // otherwise keep rendering the previous run under the fresh toast.
    setNotice(null);
    try {
      // Roots validate before any network write: an emptied editor and `..`
      // escapes fail closed here with line numbers, mirroring the files guard,
      // so a bad walk boundary never persists to config.toml.
      const rootsValidationError = validateIndexRootsText(rootsText);
      if (rootsValidationError) {
        if (!mountedRef.current) return;
        setNotice(null);
        setAdvancedValidationError(null);
        pushErrorToast(rootsValidationError);
        return;
      }
      // Advanced vector cap fails closed before any network write so a bad
      // cap never persists; the disclosure auto-expands and focuses the error.
      const vectorCapForSave =
        resolveIndexVectorCapValue(config) ??
        (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number);
      if (
        !Number.isInteger(vectorCapForSave) ||
        vectorCapForSave < 1 ||
        vectorCapForSave > INDEX_VECTOR_CAP_MAX
      ) {
        if (!mountedRef.current) return;
        const message = `Invalid index vector cap: must be between 1 and ${INDEX_VECTOR_CAP_MAX} (got ${String(vectorCapForSave)}).`;
        setAdvancedValidationError(message);
        setNotice(null);
        pushErrorToast(message);
        return;
      }
      setAdvancedValidationError(null);
      const savedEnabled = await persistConfig();
      if (!mountedRef.current) return;
      const editedCalendars = config.calendars;
      const editedReminders = config.reminders;
      const prevSources = lastSavedSourcesRef.current;
      lastSavedSourcesRef.current = {
        calendars: !!editedCalendars,
        reminders: !!editedReminders,
      };
      const fresh = await loadStatus();
      if (!mountedRef.current) return;
      {
        const newlyEnabled: string[] = [];
        if (savedEnabled) {
          // A save before the first loadConfig settles leaves prev null; treat
          // it as disabled so a newly-enabled toggle still prompts once.
          const prevCalendars = prevSources?.calendars ?? false;
          const prevReminders = prevSources?.reminders ?? false;
          if (!prevCalendars && editedCalendars) newlyEnabled.push("calendars");
          if (!prevReminders && editedReminders) newlyEnabled.push("reminders");
        }
        for (const kind of newlyEnabled) {
          const row = fresh?.sources?.find((entry) => entry.kind === kind);
          if (!row || resolveIndexSourceAccess(row) !== "notDetermined") continue;
          if (!mountedRef.current) return;
          try {
            await requestIndexAccess(kind);
          } catch {
            // Save stays successful; pills surface the current posture on poll.
          }
          if (!mountedRef.current) return;
        }
        if (newlyEnabled.length > 0) {
          await loadStatus();
          if (!mountedRef.current) return;
        }
      }
      const wasRunning = fresh?.running === true;
      if (wasRunning && savedEnabled) {
        try {
          // Explicit cancel outcome: 404 means no run to stop so the restart
          // continues; any other failure aborts before polling instead of
          // silently continuing over a half-stopped generation.
          try {
            await cancelIndex();
          } catch (failure) {
            if (!(failure instanceof ApiError && failure.status === 404)) {
              throw failure;
            }
          }
          if (!mountedRef.current) return;
          let settled = false;
          for (let attempt = 0; attempt < 10; attempt += 1) {
            const polled = await getIndexStatus();
            if (!mountedRef.current) return;
            if (polled?.running === false) {
              settled = true;
              break;
            }
            if (attempt < 9) {
              await new Promise((resolve) => setTimeout(resolve, 500));
              if (!mountedRef.current) return;
            }
          }
          // Single-flight guard: never start a second generation over a
          // still-running one (the engine answers 409); abort honestly with
          // an error toast instead of dialing.
          if (!settled) {
            if (!mountedRef.current) return;
            setNotice(null);
            pushErrorToast(
              "Failed to restart index run: previous scan is still running.",
            );
            return;
          }
          // Because the start request only answers `running` or `skipped`,
          // terminal outcome settles through the post-restart status probe,
          // rendering the fresh last-run summary on the restart outcome line.
          await runIndex();
          const restarted = await loadStatus();
          if (!mountedRef.current) return;
          if (restarted?.lastRun) {
            setNotice(describeIndexRun(restarted.lastRun));
          }
          pushSuccessToast(
            "Index settings saved. Restarted the running scan so new settings apply.",
          );
        } catch (failure) {
          if (!mountedRef.current) return;
          setNotice(null);
          pushErrorToast(
            failure instanceof ApiError ? failure.message : "Failed to restart index run",
          );
        }
      } else {
        if (!mountedRef.current) return;
        setNotice(null);
        pushSuccessToast("Index settings saved.");
      }
    } catch (failure) {
      if (!mountedRef.current) return;
      setNotice(null);
      const message =
        failure instanceof ApiError ? failure.message : "Failed to save index settings";
      // Surface Advanced failures inside the disclosure so a collapsed panel
      // auto-expands and focuses the error link.
      if (isIndexAdvancedError(message)) {
        setAdvancedValidationError(message);
      }
      pushErrorToast(message);
    } finally {
      if (mountedRef.current) setSaving(false);
    }
  }, [config, loadStatus, mountedRef, lastSavedSourcesRef, persistConfig, pushErrorToast, pushSuccessToast, rootsText, saving]);

  return {
    saving,
    notice,
    setNotice,
    advancedValidationError,
    setAdvancedValidationError,
    handleSave,
  };
}
