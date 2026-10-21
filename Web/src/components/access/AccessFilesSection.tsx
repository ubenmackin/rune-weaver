// Rune Weaver Dashboard — File write-posture section of the owner configuration surface.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_FILES_ALLOW_ROOTS,
  DEFAULT_FILES_DENY_PATTERNS_TEXT,
  formatAllowRootsText,
  parseAllowRootsText,
  parseDenyPatternsText,
  updateSettings,
  type SettingsResponse,
  type UpdateSettingsInput,
} from "../../api";
import { AlertTriangleIcon, RefreshIcon } from "../icons";
import { AdvancedDisclosure } from "../settings/AdvancedDisclosure";
import {
  FilesAdvancedFields,
  FilesDenyPatternsField,
} from "./AccessFilesAdvancedFields";
import {
  FilesResetModals,
  FilesSectionFooter,
  FilesWriteModeRadios,
} from "./AccessFilesFormParts";
import {
  buildFilesWritePatch,
  defaultFilesWritePathRules,
  normalizeFilesWriteMode,
  validateFilesSimpleFields,
  type FilesLoadedSnapshot,
  type FilesWriteMode,
} from "./accessFilesRules";
import {
  fetchSharedAccessSettings,
  resolveFilesLoadedSnapshot,
} from "./accessSettingsLoader";
import type { UseFilesAdvancedResult } from "./useAccessAdvanced";

// Advanced Files validation messages the disclosure can focus. Shared by the
// panel prop and the server-error router so one message never prints twice.
const FILES_ADVANCED_ERROR_KEYWORDS = [
  "write path rule",
  "deny pattern",
  "blocked path",
] as const;

function isFilesAdvancedError(message: string): boolean {
  const lowered = message.toLowerCase();
  return FILES_ADVANCED_ERROR_KEYWORDS.some((keyword) =>
    lowered.includes(keyword)
  );
}

// File access and write-posture configuration for the settings Access surface. Keeps the
// single draft, the changed-only save, and the live-apply banner; the engine
// stays the sole evaluator of the posture a write actually takes.
export function AccessFilesSection({
  simpleOnly = false,
  advanced,
}: {
  simpleOnly?: boolean;
  advanced?: UseFilesAdvancedResult | null;
} = {}) {
  // simpleOnly is the sole path; the standalone File Write Posture section was
  // removed so one card holds Advanced above its footer.
  void simpleOnly;
  const [loading, setLoading] = useState<boolean>(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [writeMode, setWriteMode] = useState<FilesWriteMode>("model");
  const [filesDenyText, setFilesDenyText] = useState<string>(
    DEFAULT_FILES_DENY_PATTERNS_TEXT
  );
  const [filesAllowRootsText, setFilesAllowRootsText] = useState<string>(
    formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS)
  );
  const [filesRequireApprovalOnDeny, setFilesRequireApprovalOnDeny] =
    useState<boolean>(true);
  const [pendingResetDeny, setPendingResetDeny] = useState<boolean>(false);
  const [pendingResetRoots, setPendingResetRoots] = useState<boolean>(false);

  const [saved, setSaved] = useState(false);
  const [saveLoading, setSaveLoading] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const loadedRef = useRef<FilesLoadedSnapshot>({
    writeMode: "model",
    writePathRules: defaultFilesWritePathRules(),
    denyPatternsText: DEFAULT_FILES_DENY_PATTERNS_TEXT,
    allowRootsText: formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS),
    requireApprovalOnDeny: true,
  });

  const activeDenyText = advanced ? advanced.denyPatternsText : filesDenyText;
  const denyPatternCount = parseDenyPatternsText(activeDenyText).length;
  const allowRootsCount = parseAllowRootsText(filesAllowRootsText).length;

  // The pane-level Advanced hook owns write-path rules plus deny patterns, so
  // Simple dirty tracking mutes them to keep one owner.
  const changed =
    writeMode !== loadedRef.current.writeMode ||
    filesAllowRootsText !== loadedRef.current.allowRootsText ||
    filesRequireApprovalOnDeny !== loadedRef.current.requireApprovalOnDeny;
  const advancedChanged = advanced?.changed ?? false;

  // An Advanced edit clears the section's saved confirmation too, so a stale
  // success never covers a draft the advanced hook now owns.
  useEffect(() => {
    if (advancedChanged) setSaved(false);
  }, [advancedChanged]);

  // Copies one loaded snapshot into both editors, reseeding the loaded ref and dirty check.
  // The shared loader owns the mapping so the section plus the Advanced hook
  // read identical snapshots from one payload.
  const applyLoadedConfig = useCallback((settings: SettingsResponse | null | undefined) => {
    const snapshot = resolveFilesLoadedSnapshot(settings);
    if (!snapshot) return;
    loadedRef.current = snapshot;
    setWriteMode(snapshot.writeMode);
    setFilesDenyText(snapshot.denyPatternsText);
    setFilesAllowRootsText(snapshot.allowRootsText);
    setFilesRequireApprovalOnDeny(snapshot.requireApprovalOnDeny);
    setSaved(false);
  }, []);

  const loadFilesWriteSettings = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      applyLoadedConfig(await fetchSharedAccessSettings());
    } catch (err: unknown) {
      setLoadError(
        err instanceof ApiError
          ? err.message
          : "Failed to load file settings."
      );
    } finally {
      setLoading(false);
    }
  }, [applyLoadedConfig]);

  useEffect(() => {
    void loadFilesWriteSettings();
  }, [loadFilesWriteSettings]);

  // Any edit clears the saved confirmation so a stale success never reads as
  // covering the current draft.
  function markEdited() {
    setSaved(false);
  }

  function handleWriteModeChange(next: string) {
    setWriteMode(normalizeFilesWriteMode(next));
    markEdited();
  }

  function applyDenyText(next: string) {
    if (advanced) {
      advanced.setDenyPatternsText(next);
    } else {
      setFilesDenyText(next);
    }
    markEdited();
  }

  // Saves the changed-only [files] patch through PUT /settings. Only the edited keys travel, and
  // the mode plus the rule list ride one payload. The pane-level Advanced
  // patch joins the same request so one save has one truth.
  const handleSave = async (): Promise<void> => {
    if (advanced) {
      const advError = advanced.validate();
      if (advError) {
        advanced.setSaveError(advError);
        return;
      }
    }
    const validationError = validateFilesSimpleFields(writeMode, filesAllowRootsText);
    if (validationError) {
      setSaveError(validationError);
      return;
    }
    setSaveLoading(true);
    setSaveError(null);
    try {
      const rulesForPatch = loadedRef.current.writePathRules;
      const patch: UpdateSettingsInput = buildFilesWritePatch(
        writeMode,
        rulesForPatch,
        loadedRef.current
      );
      if (filesAllowRootsText !== loadedRef.current.allowRootsText) {
        patch.filesAllowRoots = parseAllowRootsText(filesAllowRootsText);
      }
      if (filesRequireApprovalOnDeny !== loadedRef.current.requireApprovalOnDeny) {
        patch.filesRequireApprovalOnDeny = filesRequireApprovalOnDeny;
      }
      if (advanced) {
        Object.assign(patch, advanced.buildPatch());
      }
      const updated = await updateSettings(patch);
      // Repopulate first so the accepted snapshot re-seeds both the loaded ref
      // and the dirty comparison; the banner then flips on after it, because
      // the repopulate clears the flag for the plain load path.
      applyLoadedConfig(updated);
      advanced?.applySaved(updated);
      setSaved(true);
    } catch (err: unknown) {
      const message =
        err instanceof ApiError
          ? err.message
          : "Failed to save file settings";
      if (advanced && isFilesAdvancedError(message)) {
        advanced.setSaveError(message);
      } else {
        setSaveError(message);
      }
    } finally {
      setSaveLoading(false);
    }
  };

  return (
    <div className="access-files-pane" data-testid="files-pane">
      {/* SECTION 1: Files & Access */}
      <section
        className="settings-section card"
        aria-label="Files & Access"
        data-testid="files-access-pane"
        style={{ marginBottom: "20px" }}
      >
        <div className="settings-section-title-group">
          <h3>Files & Access</h3>
          <p className="settings-section-hint">
            Allow roots bound file tools, email attachment saves, bash working directories, and staged-file review: those surfaces can only reach paths inside the allowed roots. Denied paths are skipped everywhere including the document index, while allow roots do not affect index coverage.
          </p>
          <p className="settings-section-hint">
            This is the system-boundary allowed-roots and blocked-paths surface in
            Access → Files. Fine-grained write-path posture (Stage, Ask,
            Live, Deny per path) lives in Access → Files below.
          </p>
        </div>

        <p className="settings-section-hint" data-testid="files-blocked-paths-summary">
          Blocked paths are edited in Advanced Files settings below, beside the
          write-path rules they override.
        </p>

        <div className="settings-subsection-header" style={{ marginTop: "20px" }}>
          <div className="settings-section-title-group">
            <h4 style={{ margin: "0 0 4px 0" }}>Allowed Roots</h4>
            <p className="settings-section-hint">
              Home containment boundary (`~` expands to the home directory). Paths outside
              these roots escalate to approval.
            </p>
          </div>
          <div className="row">
            <button
              type="button"
              className="ghost icon-text-btn"
              onClick={() => setPendingResetRoots(true)}
            >
              <RefreshIcon size={14} />
              <span>Reset Roots</span>
            </button>
          </div>
        </div>

        <div className="form-group" style={{ marginTop: "8px" }}>
          <label htmlFor="allow-roots-textarea">
            Allowed roots, one per line{" "}
            <span className="muted text-sm">
              ({allowRootsCount} {allowRootsCount === 1 ? "root" : "roots"})
            </span>
          </label>
          <textarea
            id="allow-roots-textarea"
            className="input-field allow-roots-textarea"
            aria-label="Allowed roots, one per line"
            value={filesAllowRootsText}
            onChange={(e) => {
              setFilesAllowRootsText(e.target.value);
              markEdited();
            }}
            placeholder="e.g. ~"
            rows={6}
          />
          <span className="form-group-hint">
            One root per line. `~` expands to the home directory for home containment.
            Blank lines are ignored. Order is display-only and never changes the access decision.
          </span>
        </div>

        <div className="form-group checkbox-group" style={{ marginTop: "16px" }}>
          <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
            <input
              id="files-require-approval"
              type="checkbox"
              checked={filesRequireApprovalOnDeny}
              onChange={(e) => {
                setFilesRequireApprovalOnDeny(e.target.checked);
                markEdited();
              }}
            />
            <span>Require approval on deny</span>
          </label>
          <span className="form-group-hint">
            When on, denied paths escalate to the approvals inbox instead of failing silently.
          </span>
        </div>

        <>
          {loading ? (
            <p className="muted text-sm" data-testid="files-write-loading">
              Loading file write settings…
            </p>
          ) : null}
            {loadError ? (
              <div
                className="error-banner"
                data-testid="files-write-load-error"
                style={{ marginBottom: "12px" }}
              >
                <AlertTriangleIcon size={16} />
                <span>{loadError}</span>
              </div>
            ) : null}
            {!loading && !loadError ? (
              <>
                {saveError ? (
                  <div
                    className="error-banner"
                    data-testid="files-write-error"
                    style={{ marginBottom: "12px" }}
                  >
                    <AlertTriangleIcon size={16} />
                    <span>{saveError}</span>
                  </div>
                ) : null}
                {saved ? (
                  <div
                    data-testid="files-write-saved"
                    style={{
                      padding: "8px 12px",
                      borderRadius: "6px",
                      backgroundColor: "rgba(16, 185, 129, 0.15)",
                      color: "#10b981",
                      fontSize: "0.85rem",
                      marginBottom: "12px",
                    }}
                  >
                    File write settings saved. Changes apply immediately with no
                    restart.
                  </div>
                ) : null}
                <p className="muted text-sm" style={{ marginBottom: "16px" }} data-testid="files-write-precedence">
                  Deny patterns refuse first. The longest matching write-path rule
                  below decides next: a rule covers its path and everything inside it,
                  so a deeper rule outranks a broader one. Otherwise the write mode
                  above applies inside the allowed roots, and a path outside every
                  allowed root asks.
                </p>
                <FilesWriteModeRadios
                  writeMode={writeMode}
                  onChange={handleWriteModeChange}
                />
                {advanced ? (
                <AdvancedDisclosure
                  tabName="Files"
                  changedCount={advanced.changedCount}
                  summary={
                    advanced.changedCount > 0
                      ? `${advanced.changedCount} advanced files ${advanced.changedCount === 1 ? "setting" : "settings"} changed`
                      : undefined
                  }
                  open={advanced.open}
                  onOpenChange={advanced.setOpen}
                  testId="advanced-files"
                  validationError={advanced.saveError}
                  errorKeywords={[...FILES_ADVANCED_ERROR_KEYWORDS]}
                  onReset={advanced.reset}
                >
                  {advanced.loading ? (
                    <p className="muted text-sm" data-testid="advanced-files-loading">Loading advanced files settings…</p>
                  ) : null}
                  {advanced.loadError ? (
                    <div className="error-banner" data-testid="advanced-files-load-error" style={{ marginBottom: "12px" }}>
                      <AlertTriangleIcon size={16} />
                      <span>{advanced.loadError}</span>
                    </div>
                  ) : null}
                  {!advanced.loading && !advanced.loadError ? (
                    <>
                      <FilesDenyPatternsField
                        denyText={advanced.denyPatternsText}
                        denyPatternCount={parseDenyPatternsText(advanced.denyPatternsText).length}
                        onDenyTextChange={advanced.setDenyPatternsText}
                        onResetRequest={() => setPendingResetDeny(true)}
                      />
                      <FilesAdvancedFields
                        rules={advanced.filesRules}
                        onRulePathChange={advanced.handleFilesRulePathChange}
                        onRulePostureChange={advanced.handleFilesRulePostureChange}
                        onRemoveRule={advanced.handleRemoveFilesRule}
                        onAddRule={advanced.handleAddFilesRule}
                        idPrefix="adv-files"
                      />
                    </>
                  ) : null}
                </AdvancedDisclosure>
                ) : null}
                <FilesSectionFooter
                  changed={changed}
                  advancedChanged={advancedChanged}
                  saveLoading={saveLoading}
                  onSave={() => void handleSave()}
                />
              </>
            ) : null}
        </>
      </section>

      <FilesResetModals
        pendingResetDeny={pendingResetDeny}
        pendingResetRoots={pendingResetRoots}
        denyPatternCount={denyPatternCount}
        allowRootsCount={allowRootsCount}
        onCloseDeny={() => setPendingResetDeny(false)}
        onConfirmDeny={() => {
          applyDenyText(DEFAULT_FILES_DENY_PATTERNS_TEXT);
          setPendingResetDeny(false);
          markEdited();
        }}
        onCloseRoots={() => setPendingResetRoots(false)}
        onConfirmRoots={() => {
          setFilesAllowRootsText(formatAllowRootsText(DEFAULT_FILES_ALLOW_ROOTS));
          setPendingResetRoots(false);
          markEdited();
        }}
      />
    </div>
  );
}

export default AccessFilesSection;
