// Rune Weaver Dashboard — Index Policy configuration panel: sources, effort, and advanced index settings.
import { useCallback, useEffect, useRef, useState } from "react";
import {
  DEFAULT_INDEX_CONFIG,
  DEFAULT_INDEX_EXCLUDE_PATTERNS,
  DEFAULT_INDEX_MAILBOX_DENY,
  DEFAULT_INDEX_MAILBOX_DENY_TEXT,
  DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
  DEFAULT_INDEX_WORKERS,
  DEFAULT_INDEX_PAUSE_ON_BATTERY,
  DEFAULT_INDEX_THERMAL_BACKOFF,
  INDEX_MAX_CUSTOM_WORKERS,
  formatMailboxDenyText,
  getIndexStatus,
  getSettings,
  type IndexConfigData,
} from "../../api";
import { ToastStack } from "../Toast";
import { useToastStack } from "../../hooks/useToastStack";
import { AdvancedDisclosure } from "../settings/AdvancedDisclosure";
import {
  describeEffortReality,
  describeIndexScope,
  findOutsideIndexRoots,
  formatIndexRootsText,
  INDEX_VECTOR_CAP_MAX,
  normalizeIndexEffortPreset,
  parseIndexRootsText,
  resolveAlwaysSkipped,
  resolveEffortWorkers,
  resolveIndexVectorCapValue,
  resolveIndexWorkersValue,
  resolveMachineCores,
  resolveStatusEffort,
} from "./indexPolicyHelpers";
import IndexPolicySourcesFieldset from "./IndexPolicySourcesFieldset";
import IndexPolicyEffortFieldset from "./IndexPolicyEffortFieldset";
import IndexPolicyAdvancedFields from "./IndexPolicyAdvancedFields";
import { SwitchControl } from "../settings/SwitchControl";
import {
  INDEX_ADVANCED_ERROR_KEYWORDS,
  useIndexPolicySave,
} from "./useIndexPolicySave";
import {
  buildIndexPolicySnapshot,
  isIndexPolicySnapshotDirty,
  type IndexPolicySnapshot,
} from "./indexPolicySnapshot";

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
  // Engine core count from GET /index/status for the effort reality line.
  // Null until the status fetch settles so resolveMachineCores falls back to
  // the browser hardwareConcurrency instead of guessing.
  const [policyCoreCount, setPolicyCoreCount] = useState<number | null>(null);
  // Transient save feedback in a top-right stack so the confirmation never blocks the form.
  const { toasts, pushSuccessToast, pushErrorToast, dismissToast } =
    useToastStack();
  // Advanced disclosure state: collapsed by default, auto-expands when an
  // Advanced validation error blocks Save so the offending input stays visible.
  const [advancedOpen, setAdvancedOpen] = useState(false);
  // Mounted guard for the save-and-restart chain: persist, status reads, and
  // toasts settle after awaits, so an unmount mid-save skips every update.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);
  const lastSavedSourcesRef = useRef<{ calendars: boolean; reminders: boolean } | null>(null);
  // Last-saved snapshot for the Save gate: seeded from loadConfig, refreshed
  // from the persist echo so the button returns to disabled after a save.
  // Held in state so snapshot updates re-render the gate without coincidental renders.
  const [loadedSnapshot, setLoadedSnapshot] =
    useState<IndexPolicySnapshot | null>(null);
  // Live mirrors so the echo setters rebuild the snapshot from post-save
  // truth before the echoed state re-renders. Synced in effects so concurrent
  // renders never observe a half-written mirror.
  const configRef = useRef(config);
  const excludeTextRef = useRef(excludeText);
  const mailboxDenyTextRef = useRef(mailboxDenyText);
  const rootsTextRef = useRef(rootsText);
  useEffect(() => {
    configRef.current = config;
  }, [config]);
  useEffect(() => {
    excludeTextRef.current = excludeText;
  }, [excludeText]);
  useEffect(() => {
    mailboxDenyTextRef.current = mailboxDenyText;
  }, [mailboxDenyText]);
  useEffect(() => {
    rootsTextRef.current = rootsText;
  }, [rootsText]);

  // Fresh status read shared by boot load and save-and-restart: the saved policy
  // stays enabled-aware while the running flag settles for the restart decision.
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

  // Rebuilds the snapshot from the live mirrors after each echo write; the
  // sequential echo writes converge on the saved values.
  const refreshSnapshotFromRefs = useCallback(() => {
    setLoadedSnapshot(
      buildIndexPolicySnapshot(
        configRef.current,
        excludeTextRef.current,
        mailboxDenyTextRef.current,
        rootsTextRef.current,
      ),
    );
  }, []);

  // Echo-only setters: user edits go through `updateConfig` and the raw text
  // setters, so only a successful persist moves the snapshot.
  const setConfigFromEcho = useCallback(
    (next: IndexConfigData | ((prev: IndexConfigData) => IndexConfigData)) => {
      const resolved =
        typeof next === "function" ? next(configRef.current) : next;
      configRef.current = resolved;
      setConfig(resolved);
      refreshSnapshotFromRefs();
    },
    [refreshSnapshotFromRefs],
  );
  const setExcludeTextFromEcho = useCallback(
    (next: string | ((prev: string) => string)) => {
      const resolved =
        typeof next === "function" ? next(excludeTextRef.current) : next;
      excludeTextRef.current = resolved;
      setExcludeText(resolved);
      refreshSnapshotFromRefs();
    },
    [refreshSnapshotFromRefs],
  );
  const setMailboxDenyTextFromEcho = useCallback(
    (next: string | ((prev: string) => string)) => {
      const resolved =
        typeof next === "function" ? next(mailboxDenyTextRef.current) : next;
      mailboxDenyTextRef.current = resolved;
      setMailboxDenyText(resolved);
      refreshSnapshotFromRefs();
    },
    [refreshSnapshotFromRefs],
  );
  const setRootsTextFromEcho = useCallback(
    (next: string | ((prev: string) => string)) => {
      const resolved =
        typeof next === "function" ? next(rootsTextRef.current) : next;
      rootsTextRef.current = resolved;
      setRootsText(resolved);
      refreshSnapshotFromRefs();
    },
    [refreshSnapshotFromRefs],
  );

  // Save-and-restart lives in the hook so the panel stays under budget while
  // the Advanced disclosure keeps zero-content wrapping above the footer.
  const {
    saving,
    notice,
    advancedValidationError,
    setAdvancedValidationError,
    handleSave,
  } = useIndexPolicySave({
    config,
    setConfig: setConfigFromEcho,
    excludeText,
    setExcludeText: setExcludeTextFromEcho,
    mailboxDenyText,
    setMailboxDenyText: setMailboxDenyTextFromEcho,
    rootsText,
    setRootsText: setRootsTextFromEcho,
    loadStatus,
    pushSuccessToast,
    pushErrorToast,
    mountedRef,
    lastSavedSourcesRef,
  });

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
        // Seed the Save gate from the loaded policy so pristine reads clean.
        if (mountedRef.current) {
          setLoadedSnapshot(
            buildIndexPolicySnapshot(
              merged,
              merged.exclude.join("\n"),
              formatMailboxDenyText(merged.mailboxDeny),
              formatIndexRootsText(merged.roots),
            ),
          );
        }
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
  const vectorCapMax = INDEX_VECTOR_CAP_MAX;
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

  // Dirty when the draft differs from the last save with trim and Number
  // canonicalization, so formatting-only edits keep Save disabled.
  const savedSnapshot = loadedSnapshot;
  const isDirty =
    savedSnapshot != null &&
    isIndexPolicySnapshotDirty(
      savedSnapshot,
      config,
      excludeText,
      mailboxDenyText,
      rootsText,
    );

  function handleResetIndexAdvanced() {
    updateConfig({
      maxVectorChunksPerDocument: DEFAULT_INDEX_MAX_VECTOR_CHUNKS_PER_DOCUMENT,
      mailVectorWindow: DEFAULT_INDEX_CONFIG.mailVectorWindow,
      iCloudEvicted: DEFAULT_INDEX_CONFIG.iCloudEvicted,
    });
    setExcludeText(DEFAULT_INDEX_EXCLUDE_PATTERNS.join("\n"));
    setMailboxDenyText(DEFAULT_INDEX_MAILBOX_DENY_TEXT);
    setAdvancedValidationError(null);
  }

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
                <p className="m-0 mt-1">
                  Always skipped, even when they are not in the Exclude
                  patterns list:
                </p>
                <p
                  data-testid="index-always-skipped"
                  className="m-0 mt-1"
                >
                  {alwaysSkipped.join(", ")}
                </p>
              </>
            ) : (
              <p className="m-0 mt-1">
                The walker also skips its built-in prune list, even when
                entries are not in the Exclude patterns list.
              </p>
            )}
            <p className="m-0 mt-1">
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

        <SwitchControl
          checked={config.enabled}
          onChange={(event) => updateConfig({ enabled: event.target.checked })}
          label="Enable background indexing"
          hint="Enable background indexing"
        />

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
              className="muted text-xs m-0 mt-1"
              data-testid="index-roots-outside-warning"
            >
              An index root sits outside your Files allow roots: recalled
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
        <AdvancedDisclosure
          tabName="Index"
          open={advancedOpen}
          onOpenChange={setAdvancedOpen}
          testId="advanced-index"
          validationError={advancedValidationError}
          errorKeywords={[...INDEX_ADVANCED_ERROR_KEYWORDS]}
          onReset={handleResetIndexAdvanced}
        >
          <IndexPolicyAdvancedFields
            config={config}
            vectorCap={vectorCap}
            vectorCapMax={vectorCapMax}
            excludeText={excludeText}
            mailboxDenyText={mailboxDenyText}
            updateConfig={(patch) => {
              setAdvancedValidationError(null);
              updateConfig(patch);
            }}
            setExcludeText={(value) => {
              setAdvancedValidationError(null);
              setExcludeText(value);
            }}
            setMailboxDenyText={(value) => {
              setAdvancedValidationError(null);
              setMailboxDenyText(value);
            }}
          />
        </AdvancedDisclosure>
        <div className="settings-footer">
          <button
            type="button"
            className="primary-button save-button"
            onClick={() => void handleSave()}
            disabled={saving || !isDirty}
            title={isDirty ? undefined : "No unsaved changes"}
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
