// Rune Weaver Dashboard — Draft editor modal for a single event watcher rule.

import { useState } from "react";
import {
  ALLOWED_DIRECT_TOOL_NAMES,
  defaultDirectToolForSource,
  normalizeEventRule,
  validateEventRule,
  type EventRule,
  type EventRuleAction,
  type EventWatcherSource,
  type GroupChatFilter,
} from "../api";
import InfoTip from "./InfoTip";
import Modal from "./Modal";
import { CloseIcon, WrenchIcon } from "./icons";

interface RuleEditorModalProps {
  source: EventWatcherSource;
  rule: EventRule;
  onSave: (rule: EventRule) => void;
  onClose: () => void;
}

function csvToArray(text: string): string[] {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function csvFromList(list?: string[]): string {
  return (list ?? []).join(", ");
}

export default function RuleEditorModal({
  source,
  rule,
  onSave,
  onClose,
}: RuleEditorModalProps) {
  const [draft, setDraft] = useState<EventRule>(() => ({
    ...rule,
    condition: { ...rule.condition },
    action:
      rule.action.type === "agentPrompt"
        ? { ...rule.action }
        : { ...rule.action },
  }));
  const [error, setError] = useState<string | null>(null);

  const actionType = draft.action.type;

  function updateCondition(patch: Partial<EventRule["condition"]>) {
    setDraft((prev) => ({
      ...prev,
      condition: { ...prev.condition, ...patch },
    }));
  }

  function handleActionTypeChange(next: EventRuleAction["type"]) {
    if (next === "agentPrompt") {
      const prompt =
        draft.action.type === "agentPrompt" ? draft.action.prompt : "";
      setDraft((prev) => ({ ...prev, action: { type: "agentPrompt", prompt } }));
    } else {
      // Fast path must start executable, never a placeholder the worker rejects.
      const defaultTool = defaultDirectToolForSource(source);
      const defaultArgs =
        source === "email" ? '{"destination":"Archive"}' : "{}";
      setDraft((prev) => ({
        ...prev,
        action: {
          type: "directTool",
          toolName: defaultTool,
          argumentsJSON: defaultArgs,
        },
      }));
    }
  }

  function handleSave() {
    const candidate = normalizeEventRule({
      ...draft,
      name: draft.name,
    });
    const failure = validateEventRule(candidate, 0);
    if (failure) {
      setError(failure);
      return;
    }
    setError(null);
    onSave(candidate);
  }

  return (
    <Modal
      label={`Edit rule ${rule.name}`}
      onClose={onClose}
      onConfirm={handleSave}
      containerClassName="modal-container rule-editor-modal"
      testId="rule-editor-modal"
    >
      <div className="modal-header">
        <h3>Edit Rule</h3>
        <button
          type="button"
          className="icon-button"
          onClick={onClose}
          aria-label="Close rule editor"
        >
          <CloseIcon size={16} />
        </button>
      </div>

      <div className="modal-body">
        {error ? <div className="error-banner">{error}</div> : null}

        <label className="form-label">
          Rule Name
          <input
            type="text"
            aria-label="Rule Name"
            placeholder="Rule Name (e.g. VIP Urgent Alerts)"
            value={draft.name}
            onChange={(e) => setDraft((prev) => ({ ...prev, name: e.target.value }))}
          />
        </label>

        <div className="rule-section">
          <strong className="block text-muted mb-1">When Event Matches:</strong>

          {source === "email" && (
            <div className="grid grid-cols-2 gap-2">
              <label className="form-label text-xs">
                Sender contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. @school.org, boss@company.com"
                  value={csvFromList(draft.condition.senderContains)}
                  onChange={(e) =>
                    updateCondition({ senderContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Subject contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. Receipt, Invoice, Urgent"
                  value={csvFromList(draft.condition.subjectContains)}
                  onChange={(e) =>
                    updateCondition({ subjectContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Body contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. invoice total, action required"
                  value={csvFromList(draft.condition.contentContains)}
                  onChange={(e) =>
                    updateCondition({ contentContains: csvToArray(e.target.value) })
                  }
                />
              </label>
            </div>
          )}

          {source === "messages" && (
            <div className="grid grid-cols-2 gap-2">
              <label className="form-label text-xs">
                Sender contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. Mom, +15551234567"
                  value={csvFromList(draft.condition.senderContains)}
                  onChange={(e) =>
                    updateCondition({ senderContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Text contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. urgent, call me, deadline"
                  value={csvFromList(draft.condition.contentContains)}
                  onChange={(e) =>
                    updateCondition({ contentContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Chat Scope
                <select
                  value={draft.condition.groupChatFilter ?? "all"}
                  onChange={(e) =>
                    updateCondition({
                      groupChatFilter: e.target.value as GroupChatFilter,
                    })
                  }
                >
                  <option value="all">All Messages (Direct & Group)</option>
                  <option value="directOnly">Direct Messages Only</option>
                  <option value="groupOnly">Group Chats Only</option>
                </select>
              </label>
            </div>
          )}

          {source === "calendar" && (
            <div className="grid grid-cols-2 gap-2">
              <label className="form-label text-xs">
                Title contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. 1:1, Sync, Client"
                  value={csvFromList(draft.condition.titleContains)}
                  onChange={(e) =>
                    updateCondition({ titleContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Calendar name contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. Work, Personal"
                  value={csvFromList(draft.condition.calendarNameContains)}
                  onChange={(e) =>
                    updateCondition({
                      calendarNameContains: csvToArray(e.target.value),
                    })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Location contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. Zoom, Conference Room"
                  value={csvFromList(draft.condition.locationContains)}
                  onChange={(e) =>
                    updateCondition({ locationContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="form-label text-xs">
                Notes contains (comma separated)
                <input
                  type="text"
                  placeholder="e.g. agenda, prep doc"
                  value={csvFromList(draft.condition.contentContains)}
                  onChange={(e) =>
                    updateCondition({ contentContains: csvToArray(e.target.value) })
                  }
                />
              </label>
              <label className="flex items-center gap-2 mt-2">
                <input
                  type="checkbox"
                  checked={draft.condition.excludeAllDay ?? true}
                  onChange={(e) =>
                    updateCondition({ excludeAllDay: e.target.checked })
                  }
                />
                <span>Exclude all-day events</span>
              </label>
            </div>
          )}

          <div className="rule-editor-check">
            <input
              id="rule-match-all"
              type="checkbox"
              checked={draft.condition.matchAll ?? false}
              onChange={(e) => updateCondition({ matchAll: e.target.checked })}
            />
            <label htmlFor="rule-match-all">
              Require all condition filters to match (Match All)
            </label>
            <InfoTip
              text="When enabled every filter must match; otherwise any single matching filter triggers the rule."
              label="About match all"
            />
          </div>
        </div>

        <div className="rule-section pt-2 border-t">
          <div className="rule-editor-action-label">
            <strong className="block text-muted mb-1">Take Action:</strong>
            <InfoTip
              text="Agent prompts reason over the event with full context; direct tools run instantly without a model turn."
              label="About action choice"
            />
          </div>

          <div className="flex gap-4 mb-2">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="rule-action-type"
                checked={actionType === "agentPrompt"}
                onChange={() => handleActionTypeChange("agentPrompt")}
              />
              <span>Agent Prompt (AI Reasoning)</span>
            </label>
            <label className="flex items-center gap-1 cursor-pointer">
              <input
                type="radio"
                name="rule-action-type"
                checked={actionType === "directTool"}
                onChange={() => handleActionTypeChange("directTool")}
              />
              <span className="flex items-center gap-1 font-medium text-purple-400">
                <WrenchIcon size={12} />
                Direct Tool Action (Zero Tokens)
              </span>
            </label>
          </div>

          {actionType === "agentPrompt" && (
            <label className="form-label text-xs">
              Agent Prompt Instructions
              <textarea
                rows={2}
                aria-label="Agent Prompt Instructions"
                placeholder="e.g. Summarize the sender's question and draft a suggested response."
                value={
                  (
                    draft.action as Extract<
                      EventRuleAction,
                      { type: "agentPrompt" }
                    >
                  ).prompt ?? ""
                }
                onChange={(e) =>
                  setDraft((prev) => ({
                    ...prev,
                    action: { type: "agentPrompt", prompt: e.target.value },
                  }))
                }
              />
              <span className="text-muted text-xs">
                The incoming event details (sender, subject, text/snippet) are automatically injected into the turn.
              </span>
            </label>
          )}

          {actionType === "directTool" && (
            <div className="grid grid-cols-2 gap-2">
              <label className="form-label text-xs">
                Tool Name (allowlisted fast path only)
                <select
                  aria-label="Direct Tool Name"
                  value={(() => {
                    const current = draft.action as Extract<
                      EventRuleAction,
                      { type: "directTool" }
                    >;
                    return ALLOWED_DIRECT_TOOL_NAMES.includes(current.toolName)
                      ? current.toolName
                      : "";
                  })()}
                  onChange={(e) => {
                    const current = draft.action as Extract<
                      EventRuleAction,
                      { type: "directTool" }
                    >;
                    setDraft((prev) => ({
                      ...prev,
                      action: { ...current, toolName: e.target.value },
                    }));
                  }}
                >
                  <option value="" disabled>
                    Select an allowlisted tool…
                  </option>
                  {ALLOWED_DIRECT_TOOL_NAMES.map((name) => (
                    <option key={name} value={name}>
                      {name}
                    </option>
                  ))}
                </select>
                <span className="text-muted text-xs">
                  Only allowlisted mutations run without a model turn; anything else must use an agent prompt.
                </span>
              </label>
              <label className="form-label text-xs">
                Arguments (JSON)
                <input
                  type="text"
                  className="font-mono"
                  placeholder='e.g. {"destination": "Receipts"}'
                  value={
                    (
                      draft.action as Extract<
                        EventRuleAction,
                        { type: "directTool" }
                      >
                    ).argumentsJSON
                  }
                  onChange={(e) => {
                    const current = draft.action as Extract<
                      EventRuleAction,
                      { type: "directTool" }
                    >;
                    setDraft((prev) => ({
                      ...prev,
                      action: { ...current, argumentsJSON: e.target.value },
                    }));
                  }}
                />
              </label>
            </div>
          )}
        </div>

        <div className="pt-2 border-t rule-editor-check">
          <input
            id="rule-stop-processing"
            type="checkbox"
            checked={draft.stopProcessing ?? true}
            onChange={(e) =>
              setDraft((prev) => ({ ...prev, stopProcessing: e.target.checked }))
            }
          />
          <label htmlFor="rule-stop-processing">
            Stop evaluating subsequent rules if this rule matches
          </label>
          <InfoTip
            text="When enabled later rules are skipped after this rule matches; disable to let multiple rules fire on one event."
            label="About stop processing"
          />
        </div>
      </div>

      <div className="modal-footer">
        <button type="button" className="ghost" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="primary" onClick={handleSave}>
          Save
        </button>
      </div>
    </Modal>
  );
}
