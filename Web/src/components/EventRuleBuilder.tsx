// Rune Weaver Dashboard — Compact event rule list with editor modal ownership.

import { useState } from "react";
import {
  isEventRuleConditionEmpty,
  type EventRule,
  type EventRuleCondition,
  type EventWatcherSource,
} from "../api";
import InfoTip from "./InfoTip";
import RuleEditorModal from "./RuleEditorModal";
import {
  CopyIcon,
  EditIcon,
  SparklesIcon,
  TrashIcon,
  WrenchIcon,
} from "./icons";

interface EventRuleBuilderProps {
  source: EventWatcherSource;
  rules: EventRule[];
  onChange: (rules: EventRule[]) => void;
}

// Shortens one filter list to a chip label, keeping long values readable.
function joinPreview(list?: string[]): string {
  const cleaned = (list ?? []).filter(
    (entry): entry is string =>
      typeof entry === "string" && entry.trim().length > 0,
  );
  if (cleaned.length <= 2) return cleaned.join(", ");
  return `${cleaned.slice(0, 2).join(", ")} +${cleaned.length - 2}`;
}

function chipsForRule(rule: EventRule): string[] {
  const condition: EventRuleCondition = rule.condition ?? {};
  if (isEventRuleConditionEmpty(condition)) return ["match-all"];
  const chips: string[] = [];
  if ((condition.senderContains ?? []).some((s) => s.trim())) {
    chips.push(`from: ${joinPreview(condition.senderContains)}`);
  }
  if ((condition.subjectContains ?? []).some((s) => s.trim())) {
    chips.push(`subject: ${joinPreview(condition.subjectContains)}`);
  }
  if ((condition.titleContains ?? []).some((s) => s.trim())) {
    chips.push(`title: ${joinPreview(condition.titleContains)}`);
  }
  if ((condition.calendarNameContains ?? []).some((s) => s.trim())) {
    chips.push(`calendar: ${joinPreview(condition.calendarNameContains)}`);
  }
  if ((condition.contentContains ?? []).some((s) => s.trim())) {
    chips.push(`body: ${joinPreview(condition.contentContains)}`);
  }
  if ((condition.locationContains ?? []).some((s) => s.trim())) {
    chips.push(`location: ${joinPreview(condition.locationContains)}`);
  }
  if (condition.groupChatFilter && condition.groupChatFilter !== "all") {
    chips.push(
      condition.groupChatFilter === "directOnly" ? "direct only" : "group only",
    );
  }
  chips.push(condition.matchAll ? "match-all" : "match-any");
  return chips;
}

function defaultConditionForSource(
  source: EventWatcherSource,
): EventRuleCondition {
  if (source === "email") {
    return {
      senderContains: [],
      subjectContains: [],
      contentContains: [],
      matchAll: false,
    };
  }
  if (source === "messages") {
    return {
      senderContains: [],
      contentContains: [],
      groupChatFilter: "all",
      matchAll: false,
    };
  }
  return {
    titleContains: [],
    calendarNameContains: [],
    contentContains: [],
    locationContains: [],
    excludeAllDay: true,
    matchAll: false,
  };
}

export default function EventRuleBuilder({
  source,
  rules,
  onChange,
}: EventRuleBuilderProps) {
  const [editingIndex, setEditingIndex] = useState<number | null>(null);

  function handleAddRule() {
    const newRule: EventRule = {
      id: crypto.randomUUID(),
      name: `Rule ${rules.length + 1}`,
      enabled: true,
      condition: defaultConditionForSource(source),
      action: { type: "agentPrompt", prompt: "Summarize the triggering event." },
      stopProcessing: true,
    };
    const next = [...rules, newRule];
    onChange(next);
    setEditingIndex(next.length - 1);
  }

  function handleRemoveRule(index: number) {
    onChange(rules.filter((_, i) => i !== index));
    if (editingIndex === index) setEditingIndex(null);
    else if (editingIndex != null && editingIndex > index) {
      setEditingIndex(editingIndex - 1);
    }
  }

  function handleToggleRule(index: number, enabled: boolean) {
    const next = [...rules];
    next[index] = { ...next[index], enabled };
    onChange(next);
  }

  function handleMoveRule(index: number, direction: "up" | "down") {
    const targetIndex = direction === "up" ? index - 1 : index + 1;
    if (targetIndex < 0 || targetIndex >= rules.length) return;
    const next = [...rules];
    const temp = next[index];
    next[index] = next[targetIndex];
    next[targetIndex] = temp;
    onChange(next);
  }

  function handleDuplicateRule(index: number) {
    const original = rules[index];
    // Fresh identity plus a visible suffix so the copy never collides.
    const copy: EventRule = {
      ...original,
      id: crypto.randomUUID(),
      name: `${original.name} copy`,
      condition: { ...original.condition },
      action:
        original.action.type === "agentPrompt"
          ? { ...original.action }
          : { ...original.action },
    };
    const next = [
      ...rules.slice(0, index + 1),
      copy,
      ...rules.slice(index + 1),
    ];
    onChange(next);
  }

  function handleSaveEdit(updated: EventRule) {
    if (editingIndex == null) return;
    const next = [...rules];
    next[editingIndex] = updated;
    onChange(next);
    setEditingIndex(null);
  }

  return (
    <div className="event-rule-builder mt-4">
      <div className="rule-builder-header flex items-center justify-between mb-2">
        <div>
          <strong className="text-sm">Custom Event Rules</strong>
          <span className="muted text-xs ml-2">
            ({rules.length} configured{rules.length > 0 ? ", evaluated in order" : ""})
          </span>
        </div>
        <button
          type="button"
          className="button small primary"
          onClick={handleAddRule}
        >
          + Add Rule
        </button>
      </div>

      {rules.length === 0 ? (
        <div className="empty-rules-hint p-3 border border-dashed rounded text-xs muted text-center">
          No specific rules configured. All incoming {source} events will trigger the
          default prompt. Click &quot;+ Add Rule&quot; to define customized filtering and actions.
        </div>
      ) : (
        <div className="rule-rows">
          {rules.map((rule, idx) => {
            const enabled = rule.enabled !== false;
            const chips = chipsForRule(rule);
            const isTool = rule.action.type === "directTool";
            return (
              <div
                key={rule.id ?? idx}
                className={`rule-row${enabled ? "" : " rule-row-disabled"}`}
              >
                <span className="rule-index">#{idx + 1}</span>
                <span className="rule-name">{rule.name}</span>
                <div className="rule-chips" aria-label={`Filters for ${rule.name}`}>
                  {chips.map((chip, chipIdx) => (
                    <span key={`${chip}-${chipIdx}`} className="badge badge-blue">
                      {chip}
                    </span>
                  ))}
                </div>
                <span className="rule-action">
                  {isTool ? (
                    <>
                      <WrenchIcon size={12} />
                      <span className="font-mono">
                        {(rule.action as { toolName: string }).toolName}
                      </span>
                    </>
                  ) : (
                    <>
                      <SparklesIcon size={12} />
                      <span>Prompt</span>
                    </>
                  )}
                </span>
                {(rule.stopProcessing ?? true) ? (
                  <span
                    className="rule-stop-dot"
                    role="img"
                    aria-label="Stops processing further rules"
                  />
                ) : null}
                <label className="tool-switch">
                  <input
                    type="checkbox"
                    role="switch"
                    className="tool-switch-input"
                    aria-label={`Enable rule ${rule.name}`}
                    checked={enabled}
                    onChange={(e) => handleToggleRule(idx, e.target.checked)}
                  />
                  <span
                    className="tool-switch-track"
                    data-on={enabled ? "true" : "false"}
                    aria-hidden="true"
                  >
                    <span className="tool-switch-thumb" />
                  </span>
                </label>
                <div className="rule-row-actions">
                  <button
                    type="button"
                    className="icon-button text-xs"
                    disabled={idx === 0}
                    onClick={() => handleMoveRule(idx, "up")}
                    aria-label={`Move ${rule.name} up`}
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    className="icon-button text-xs"
                    disabled={idx === rules.length - 1}
                    onClick={() => handleMoveRule(idx, "down")}
                    aria-label={`Move ${rule.name} down`}
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    className="icon-button text-xs"
                    onClick={() => setEditingIndex(idx)}
                    aria-label={`Edit ${rule.name}`}
                  >
                    <EditIcon size={14} />
                  </button>
                  <button
                    type="button"
                    className="icon-button text-xs"
                    onClick={() => handleDuplicateRule(idx)}
                    aria-label={`Duplicate ${rule.name}`}
                  >
                    <CopyIcon size={14} />
                  </button>
                  <button
                    type="button"
                    className="icon-button danger text-xs"
                    onClick={() => handleRemoveRule(idx)}
                    aria-label={`Delete ${rule.name}`}
                  >
                    <TrashIcon size={14} />
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {editingIndex != null && rules[editingIndex] ? (
        <RuleEditorModal
          key={rules[editingIndex].id ?? editingIndex}
          source={source}
          rule={rules[editingIndex]}
          onSave={handleSaveEdit}
          onClose={() => setEditingIndex(null)}
        />
      ) : null}
      <span className="rule-list-tip">
        <InfoTip
          text="Rules evaluate in order; the stop marker ends evaluation after a match."
          label="About rule order"
        />
      </span>
    </div>
  );
}
