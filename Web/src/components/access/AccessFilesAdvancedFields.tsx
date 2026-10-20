// Rune Weaver Dashboard — Advanced-only Files fields: deny patterns plus the write-path table.
import { PlusIcon, RefreshIcon, TrashIcon } from "../icons";
import {
  FILES_WRITE_PATH_RULE_MAX_COUNT,
  FILES_WRITE_PATH_RULE_MAX_PATH_CHARS,
  FILES_WRITE_POSTURE_OPTIONS,
  writePostureConsequence,
  type WritePathRule,
} from "./accessFilesRules";

export interface FilesDenyPatternsFieldProps {
  denyText: string;
  denyPatternCount: number;
  onDenyTextChange: (text: string) => void;
  onResetRequest: () => void;
}

// Blocked paths stay in Advanced beside the per-path rules because both widen
// or narrow write authority, while the Simple surface keeps the root boundary
// plus the approval switch visible.
export function FilesDenyPatternsField({
  denyText,
  denyPatternCount,
  onDenyTextChange,
  onResetRequest,
}: FilesDenyPatternsFieldProps) {
  return (
    <>
      <div className="settings-subsection-header">
        <div className="settings-section-title-group">
          <h4 style={{ margin: "0 0 4px 0" }}>Blocked Paths</h4>
          <p className="settings-section-hint">
            One glob per line. Denied paths escalate or fail per the approval toggle in Simple.
          </p>
        </div>
        <div className="row">
          <button type="button" className="ghost icon-text-btn" onClick={onResetRequest}>
            <RefreshIcon size={14} />
            <span>Reset to Defaults</span>
          </button>
        </div>
      </div>

      <div className="form-group" style={{ marginTop: "8px" }}>
        <label htmlFor="deny-patterns-textarea">
          Deny patterns{" "}
          <span className="muted text-sm">
            ({denyPatternCount} {denyPatternCount === 1 ? "pattern" : "patterns"})
          </span>
        </label>
        <textarea
          id="deny-patterns-textarea"
          className="input-field deny-patterns-textarea"
          aria-label="Deny patterns, one per line"
          value={denyText}
          onChange={(event) => onDenyTextChange(event.target.value)}
          placeholder="e.g. .env*, *.pem, .ssh/*"
          rows={8}
        />
        <span className="form-group-hint">
          Glob-like patterns: `*` matches within a name, directory prefixes like
          `.ssh/*` guard a whole subtree. `..` escapes are rejected with line
          numbers; blank lines are ignored.
        </span>
        {denyPatternCount === 0 ? (
          <span className="form-group-hint">
            No deny patterns configured. File tools will allow all in-scope paths.
          </span>
        ) : null}
      </div>
    </>
  );
}

export interface FilesAdvancedFieldsProps {
  rules: WritePathRule[];
  onRulePathChange: (index: number, raw: string) => void;
  onRulePostureChange: (index: number, next: string) => void;
  onRemoveRule: (index: number) => void;
  onAddRule: () => void;
  idPrefix?: string;
}

export function FilesAdvancedFields({
  rules,
  onRulePathChange,
  onRulePostureChange,
  onRemoveRule,
  onAddRule,
  idPrefix = "files-adv",
}: FilesAdvancedFieldsProps) {
  const atBound = rules.length >= FILES_WRITE_PATH_RULE_MAX_COUNT;
  return (
    <>
      <div className="settings-subsection-header" style={{ marginTop: "16px" }}>
        <div className="settings-section-title-group">
          <h4 style={{ margin: "0 0 4px 0" }}>Write Path Rules</h4>
          <p className="settings-section-hint">
            One path per row. The longest matching rule wins; a path outside
            every allow root asks.
          </p>
        </div>
        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={onAddRule}
            disabled={atBound}
          >
            <PlusIcon size={14} />
            <span>Add Rule</span>
          </button>
        </div>
      </div>

      <div className="files-explainer-card" data-testid={`${idPrefix}-write-explainer`}>
        <h5>About Write Path Rules</h5>
        <p>
          Write path rules define folder-specific write postures, overriding the global write mode above for matching directories. The longest matching path wins:
        </p>
        <ul>
          <li><strong>Stage</strong>: Writes wait in Staged Changes for your review; no prompt needed.</li>
          <li><strong>Ask</strong>: Parks an approval request in your Inbox before anything is written.</li>
          <li><strong>Live</strong>: Writes directly to disk with an automatic rollback backup.</li>
          <li><strong>Deny</strong>: Refuses writes outright. Deny rules are locked for safety.</li>
        </ul>
        <p className="muted text-sm" style={{ marginBottom: 0 }}>
          Deny outranks every other posture and persists until the rule is removed.
        </p>
      </div>

      <span className="form-group-hint" data-testid={`${idPrefix}-write-rules-bounds`}>
        Up to {FILES_WRITE_PATH_RULE_MAX_COUNT} rules, each path up to{" "}
        {FILES_WRITE_PATH_RULE_MAX_PATH_CHARS} characters.{" "}
        <span className="muted text-sm">
          ({rules.length} {rules.length === 1 ? "rule" : "rules"})
        </span>
      </span>

      {rules.length === 0 ? (
        <p className="muted text-sm" style={{ marginTop: "12px" }}>
          No write-path rules. Every write falls through to the mode above,
          and anything outside the allowed roots asks.
        </p>
      ) : null}

      {rules.length > 0 ? (
        <div
          className="files-write-table-wrapper"
          data-testid={`${idPrefix}-write-table-scroll`}
          style={{ maxHeight: "320px", overflowY: "auto" }}
        >
          <table className="files-write-table" data-testid={`${idPrefix}-write-rules-table`}>
            <thead style={{ position: "sticky", top: 0, zIndex: 1 }}>
              <tr>
                <th style={{ width: "35%", position: "sticky", top: 0 }}>Path</th>
                <th style={{ width: "160px", position: "sticky", top: 0 }}>Posture</th>
                <th style={{ position: "sticky", top: 0 }}>Consequence</th>
                <th style={{ width: "50px", textAlign: "center", position: "sticky", top: 0 }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {rules.map((rule, index) => {
                const ruleNumber = index + 1;
                const pathId = `${idPrefix}-write-rule-path-${index}`;
                const postureId = `${idPrefix}-write-rule-posture-${index}`;
                const locked = rule.posture === "deny";
                return (
                  <tr
                    key={`${idPrefix}-write-rule-${index}`}
                    data-testid={`${idPrefix}-write-rule-${index}`}
                  >
                    <td>
                      <input
                        id={pathId}
                        aria-label={`Rule ${ruleNumber} path`}
                        className="input-field"
                        value={rule.path}
                        onChange={(event) => onRulePathChange(index, event.target.value)}
                        placeholder="~/Documents/Secrets"
                        style={{ margin: 0, width: "100%" }}
                      />
                    </td>
                    <td>
                      <select
                        id={postureId}
                        aria-label={`Rule ${ruleNumber} posture`}
                        className="input-field"
                        value={rule.posture}
                        onChange={(event) => onRulePostureChange(index, event.target.value)}
                        disabled={locked}
                        title={locked ? "A deny rule cannot be softened here" : undefined}
                        style={{ margin: 0, width: "100%" }}
                      >
                        {FILES_WRITE_POSTURE_OPTIONS.map((option) => (
                          <option key={option.value} value={option.value}>
                            {option.label}
                          </option>
                        ))}
                      </select>
                    </td>
                    <td>
                      <span
                        className="form-group-hint"
                        data-testid={`${idPrefix}-write-rule-${index}-consequence`}
                        style={{ margin: 0, display: "inline-block" }}
                      >
                        {writePostureConsequence(rule.posture)}
                        {locked ? (
                          <span data-testid={`${idPrefix}-write-rule-${index}-lock`}>
                            {" "}
                            Deny is locked: this refusal can be widened only by
                            removing the rule.
                          </span>
                        ) : null}
                      </span>
                    </td>
                    <td style={{ textAlign: "center" }}>
                      <button
                        type="button"
                        className="icon-button"
                        aria-label={`Remove rule ${ruleNumber}`}
                        data-testid={`${idPrefix}-write-rule-${index}-remove`}
                        onClick={() => onRemoveRule(index)}
                        title={`Remove rule ${ruleNumber}`}
                      >
                        <TrashIcon size={14} />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : null}
    </>
  );
}
