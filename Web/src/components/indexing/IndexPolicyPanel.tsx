// Rune Weaver Dashboard — Index Policy configuration panel: sources, effort, and advanced index settings.
import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_MAILBOX_DENY,
  DEFAULT_INDEX_MAILBOX_DENY_TEXT,
  DEFAULT_INDEX_WORKERS,
  DEFAULT_INDEX_PAUSE_ON_BATTERY,
  DEFAULT_INDEX_THERMAL_BACKOFF,
  INDEX_MAX_CUSTOM_WORKERS,
  cancelIndex,
  describeIndexRun,
  formatMailboxDenyText,
  getIndexStatus,
  getSettings,
  parseMailboxDenyText,
  requestIndexAccess,
  resolveIndexSourceAccess,
  runIndex,
  updateSettings,
  type IndexConfigData,
} from "../../api";
import { ToastStack } from "../Toast";
import { useToastStack } from "../../hooks/useToastStack";
import {
  describeEffortReality,
  describeIndexScope,
  findOutsideIndexRoots,
  formatIndexRootsText,
  normalizeIndexEffortPreset,
  parseIndexRootsText,
  resolveAlwaysSkipped,
  resolveEffortWorkers,
  resolveIndexVectorCapValue,
  resolveIndexWorkersValue,
  resolveMachineCores,
  resolveStatusEffort,
  validateIndexRootsText,
} from "./indexPolicyHelpers";
import IndexPolicySourcesFieldset from "./IndexPolicySourcesFieldset";
import IndexPolicyEffortFieldset from "./IndexPolicyEffortFieldset";
import IndexPolicyAdvancedFields from "./IndexPolicyAdvancedFields";

export function IndexPolicyPanel() {
  const [config, setConfig] = useState<IndexConfigData>(DEFAULT_INDEX_CONFIG);
  const [excludeText, setExcludeText] = useState<string>(
    DEFAULT_INDEX_CONFIG.exclude.join("\n"),
  );
  const [mailboxDenyText, setMailboxDenyText] = useState<string>(
    DEFAULT_INDEX_MAILBOX_DENY_TEXT,
  );
  // Index roots textarea state, seeded from the loaded `config.roots` so the walk boundary edits
  // without TOML hand-edits.
  const [rootsText, setRootsText] = useState<string>(
    DEFAULT_INDEX_CONFIG.roots.join("\n"),
  );
  // Loaded files allow roots from GET /settings for the outside-roots
  // informational warning. Null until the settings fetch settles so the
  // warning never fires on a default guess before the engine answers.
  const [filesAllowRoots, setFilesAllowRoots] = useState<string[] | null>(
    null,
  );
  const [saving, setSaving] = useState(false);
  // Engine core count from GET /index/status for the effort reality line.
  // Null until the status fetch settles so resolveMachineCores falls back to
  // the browser hardwareConcurrency instead of guessing.
  const [policyCoreCount, setPolicyCoreCount] = useState<number | null>(null);
  // Transient save feedback in a top-right stack so the confirmation never blocks the form.
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast } =
    useToastStack();
  // Save-and-restart inputs come from the fresh post-PUT status read in handleSave, never from a
  // cached flag, so a run started between boot and save still counts and a disable-then-save never
  // restarts.
  const [notice, setNotice] = useState<string | null>(null);
  // Mounted guard for the save-and-restart chain: persist, status reads, the cancel/poll/run
  // sequence, and the toasts all settle after awaits, so an unmount mid-save must skip every state
  // update instead of writing into a retired tree.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);
  const lastSavedSourcesRef = useRef<{ calendars: boolean; reminders: boolean } | null>(null);

  // Fresh status read shared by the boot load and the save-and-restart flow: the saved policy stays
  // enabled-aware while the running flag settles, so the restart decision always observes the engine
  // rather than a stale flag.
  const loadStatus = useCallback(async () => {
    try {
      const response = await getIndexStatus();
      if (!mountedRef.current) return response;
      setPolicyCoreCount(resolveStatusEffort(response).coreCount);
      return response;
    } catch {
      return null;
    }
  }, []);

  // Loads the [index] section through the shared settings read so the editable form starts from the
  // stored policy. An older engine without the section leaves the local defaults in place instead of
  // blanking the form.
  const loadConfig = useCallback(async () => {
    try {
      const settings = await getSettings();
      const index = settings?.index;
      // Loaded files allow roots for the outside-roots warning: kept when the
      // engine sends an array so the warning compares live roots against the
      // live guard, otherwise cleared so no warning fires on a guess.
      const allowRoots = (settings as { filesAllowRoots?: unknown })
        ?.filesAllowRoots;
      if (mountedRef.current) {
        if (Array.isArray(allowRoots)) {
          setFilesAllowRoots(
            allowRoots
              .filter((entry): entry is string => typeof entry === "string")
              .map((entry) => entry.trim())
              .filter(Boolean),
          );
        } else {
          setFilesAllowRoots(null);
        }
      }
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
          // Read-only walker list: kept when the engine sends an array so the
          // detail block names exactly what the next run will skip, otherwise
          // left absent so older engines render generic copy without names.
          alwaysSkipped: Array.isArray(
            (index as IndexConfigData).alwaysSkipped,
          )
            ? (index as IndexConfigData).alwaysSkipped
            : undefined,
          effort: normalizeIndexEffortPreset(
            (index as IndexConfigData).effort ?? DEFAULT_INDEX_CONFIG.effort,
          ),
          // Worker count with fallback to DEFAULT_INDEX_WORKERS (not the 0 wire
          // default) so a custom preset with no stored value still opens on a
          // valid stepper count; preset saves send 0 regardless.
          workers:
            resolveIndexWorkersValue(index as IndexConfigData) ??
            DEFAULT_INDEX_WORKERS,
          thermalBackoff:
            typeof (index as IndexConfigData).thermalBackoff === "boolean"
              ? (index as IndexConfigData).thermalBackoff
              : DEFAULT_INDEX_CONFIG.thermalBackoff,
          pauseOnBattery:
            typeof (index as IndexConfigData).pauseOnBattery === "boolean"
              ? (index as IndexConfigData).pauseOnBattery
              : DEFAULT_INDEX_CONFIG.pauseOnBattery,
          maxVectorChunksPerDocument:
            resolveIndexVectorCapValue(index as IndexConfigData) ??
            (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number),
        };
        setConfig(merged);
        setExcludeText(merged.exclude.join("\n"));
        setMailboxDenyText(
          formatMailboxDenyText(merged.mailboxDeny),
        );
        // Seed the roots textarea from the loaded `config.roots` so edits
        // start from stored truth and reload without TOML hand-edits.
        setRootsText(formatIndexRootsText(merged.roots));
        lastSavedSourcesRef.current = {
          calendars: !!merged.calendars,
          reminders: !!merged.reminders,
        };
      }
    } catch {
      // A settings read failure leaves the local defaults; the save path
      // surfaces transport errors so the form stays usable.
    }
    // Status snapshot for the effort reality line and the save-and-restart
    // decision: the shared loader keeps the running flag fresh while a status
    // failure leaves the browser fallback in place.
    await loadStatus();
  }, [loadStatus]);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  // Persists the [index] patch and returns the saved enabled flag from the PUT response (falling
  // back to the pre-save closure only when the engine omits the section), so handleSave restarts
  // solely from post-save truth.
  const persistConfig = useCallback(async (): Promise<boolean> => {
    const exclude = excludeText
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    // Denied mailboxes mirror the excludes editor: one glob per line,
    // trimmed, blanks dropped so an emptied editor opts every mailbox back
    // in instead of persisting whitespace rows.
    const mailboxDeny = parseMailboxDenyText(mailboxDenyText);
    // Index roots mirror the excludes editor: one root per line, trimmed with blanks dropped, saved
    // through the existing `roots` key with no API shape change.
    const roots = parseIndexRootsText(rootsText);
    const effort = normalizeIndexEffortPreset(config.effort);
    // Presets derive workers on the engine so they must save 0; only custom carries an explicit
    // 1..64 count.
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
        setConfig(merged);
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
  }, [config, excludeText, mailboxDenyText, rootsText]);

  // Sole owner of save-and-restart: the settings patch never auto-starts a run, so a policy saved
  // mid-scan must stop the old generation and start a fresh one with the new roots/excludes/caps.
  const handleSave = async () => {
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
        pushErrorToast(rootsValidationError);
        return;
      }
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
          // Because the start request only answers `running` or `skipped`, terminal outcome settles
          // through the post-restart status probe, rendering the fresh last-run summary on the restart
          // outcome line using the same probe-driven settle every other run path uses.
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
      pushErrorToast(
        failure instanceof ApiError ? failure.message : "Failed to save index settings",
      );
    } finally {
      if (mountedRef.current) setSaving(false);
    }
  };

  // Flips one toggle in local state; the change persists only on Save so a
  // stray click never writes policy without review.
  const updateConfig = (patch: Partial<IndexConfigData>) => {
    setConfig((previous) => ({ ...previous, ...patch }));
  };

  // Effort control state: the preset plus the custom stepper and the two thermal/power toggles.
  const effortPreset = normalizeIndexEffortPreset(config.effort);
  const machineCores = resolveMachineCores(policyCoreCount);
  // Stepper fallback stays DEFAULT_INDEX_WORKERS (not the 0 wire default)
  // so custom opens on a valid count before the first fetch.
  const customWorkers =
    resolveIndexWorkersValue(config) ?? DEFAULT_INDEX_WORKERS;
  const resolvedEffortWorkers = resolveEffortWorkers(
    effortPreset,
    machineCores,
    customWorkers,
  );
  const effortReality = describeEffortReality(
    effortPreset,
    resolvedEffortWorkers,
    machineCores,
  );
  // Static ceiling shared with the engine validation bound; the live core
  // count narrows it further so the stepper never offers more workers than
  // the machine can meet.
  const customMax =
    machineCores != null && machineCores > 0
      ? Math.min(machineCores, INDEX_MAX_CUSTOM_WORKERS)
      : INDEX_MAX_CUSTOM_WORKERS;
  // Per-document vector chunk cap: bounds embedding work so one text-dense document cannot fan an
  // outsized batch; chunks beyond the cap stay keyword-only.
  const vectorCap =
    resolveIndexVectorCapValue(config) ??
    (DEFAULT_INDEX_CONFIG.maxVectorChunksPerDocument as number);
  const vectorCapMax = 4096;
  // Root-scoped coverage plus the walker prune list: the subtitle reads the live roots textarea so
  // it names exactly what the next run will cover with no hardcoded home names, while the prune list
  // stays read from the loaded [index] payload.
  const liveRoots = parseIndexRootsText(rootsText);
  const scopeSubtitle = describeIndexScope(liveRoots);
  const alwaysSkipped = resolveAlwaysSkipped(config);
  // Informational outside-allow-roots warning: any live index root outside the loaded files allow
  // roots means recalled content from there may not be readable by live file tools.
  const outsideRoots = findOutsideIndexRoots(liveRoots, filesAllowRoots);

  const thermalBackoff =
    config.thermalBackoff ?? DEFAULT_INDEX_THERMAL_BACKOFF;
  const pauseOnBattery =
    config.pauseOnBattery ?? DEFAULT_INDEX_PAUSE_ON_BATTERY;

  return (
    <section className="panel indexing-panel" aria-label="Index Policy">
      <div className="panel-header-row">
        <div>
          <h2>Index Policy</h2>
          <p className="muted text-sm" data-testid="index-scope-subtitle">
            {scopeSubtitle}
          </p>
          <div
            className="muted text-xs"
            data-testid="index-always-skipped-block"
          >
            {/* Walker prune list renders solely from the `alwaysSkipped` payload so the copy
                cannot drift from FilesIndexer.alwaysSkippedPatterns; the file-access deny
                list stays generic and never enumerates patterns here. */}
            {alwaysSkipped.length > 0 ? (
              <>
                <p style={{ marginTop: 4, marginBottom: 0 }}>
                  Always skipped, even when they are not in the Exclude
                  patterns list:
                </p>
                <p
                  data-testid="index-always-skipped"
                  style={{ marginTop: 4, marginBottom: 0 }}
                >
                  {alwaysSkipped.join(", ")}
                </p>
              </>
            ) : (
              <p style={{ marginTop: 4, marginBottom: 0 }}>
                The walker also skips its built-in prune list, even when
                entries are not in the Exclude patterns list.
              </p>
            )}
            <p style={{ marginTop: 4, marginBottom: 0 }}>
              Credential and key files blocked by your file access rules are
              never indexed either. Paths denied under Security Files and
              Access are never indexed.
            </p>
          </div>
        </div>
      </div>

      <ToastStack toasts={toasts} onDismiss={dismissToast} />
      {notice ? <p className="muted text-sm">{notice}</p> : null}

      <div className="index-policy-section">
        <h3>Policy</h3>

        <label className="toggle-label">
          <input
            type="checkbox"
            checked={config.enabled}
            onChange={(event) => updateConfig({ enabled: event.target.checked })}
          />
          <span>Enable background indexing</span>
        </label>

        <IndexPolicySourcesFieldset config={config} updateConfig={updateConfig} />

        {/* Index roots editor: the file-walk boundary over IndexConfig.roots. One root per
            line, trimmed with blanks dropped on save; an emptied editor and `..` escapes fail
            closed with line numbers in handleSave; the deny filter honors deny patterns only. */}
        <div className="form-group">
          <label htmlFor="index-roots">Index roots (one per line)</label>
          <textarea
            id="index-roots"
            aria-label="Index roots"
            rows={3}
            value={rootsText}
            onChange={(event) => setRootsText(event.target.value)}
          />
          <p className="muted text-xs">
            Folders the file walk covers. One root per line. Blank lines are
            ignored. Paths denied under Security Files and Access are never
            indexed.
          </p>
          {/* Informational outside-allow-roots warning: renders exactly when a live index root
              sits outside the loaded files allow roots, since recalled content from there may
              not be readable by live file tools. The save still persists regardless. */}
          {outsideRoots.length > 0 ? (
            <p
              className="muted text-xs"
              data-testid="index-roots-outside-warning"
              style={{ marginTop: 4, marginBottom: 0 }}
            >
              An index root sits outside your Files allow roots — recalled
              content from there may not be readable by live file tools. Keep
              index roots inside Security Files and Access allow roots, or
              broaden those allow roots.
            </p>
          ) : null}
        </div>

        {/* Effort control: the three scaling presets plus a custom worker
            stepper, with the resolved reality against the machine's core count
            on top and the thermal/power toggles below. Persisted only on Save
            like every other policy knob. */}
        <IndexPolicyEffortFieldset
          effortReality={effortReality}
          effortPreset={effortPreset}
          customWorkers={customWorkers}
          customMax={customMax}
          thermalBackoff={thermalBackoff}
          pauseOnBattery={pauseOnBattery}
          updateConfig={updateConfig}
        />
        <IndexPolicyAdvancedFields
          config={config}
          vectorCap={vectorCap}
          vectorCapMax={vectorCapMax}
          excludeText={excludeText}
          mailboxDenyText={mailboxDenyText}
          updateConfig={updateConfig}
          setExcludeText={setExcludeText}
          setMailboxDenyText={setMailboxDenyText}
        />
        <div className="settings-footer">
          <button
            type="button"
            className="primary-button save-button"
            onClick={() => void handleSave()}
            disabled={saving}
          >
            {saving ? "Saving…" : "Save Index Settings"}
          </button>
        </div>
      </div>
    </section>
  );
}

// Auto-start notice for a run broadcast that this panel did not initiate: a launch-triggered
// nightly or catch-up pass announces itself by display label so a missed nightly window names the
// catch-up explicitly instead of reading as a generic index run.

export default IndexPolicyPanel;
