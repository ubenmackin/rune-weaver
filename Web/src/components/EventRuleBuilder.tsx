// Rune Weaver Dashboard — Rule builder for multi-source event watcher scheduler jobs.

import { useState } from "react";
import {
  ALLOWED_DIRECT_TOOL_NAMES,
  defaultDirectToolForSource,
  type EventRule,
  type EventRuleAction,
  type EventRuleCondition,
  type EventWatcherSource,
  type GroupChatFilter,
} from "../api";
import { CloseIcon, WrenchIcon } from "./icons";

interface EventRuleBuilderProps {
  source: EventWatcherSource;
  rules: EventRule[];
  onChange: (rules: EventRule[]) => void;
}

function csvToArray(csv?: string[]): string {
  return (csv ?? []).join(", ");
}

function arrayToCsv(text: string): string[] {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

export default function EventRuleBuilder({
  source,
  rules,
  onChange,
}: EventRuleBuilderProps) {
  const [expandedIndex, setExpandedIndex] = useState<number | null>(
    rules.length > 0 ? 0 : null,
  );

  function handleAddRule() {
    // New rules start with the full filter shape for their source so every
    // engine-evaluated field is reachable without hand-editing JSON.
    const defaultCondition: EventRuleCondition =
      source === "email"
        ? {
            senderContains: [],
            subjectContains: [],
            contentContains: [],
            matchAll: false,
          }
        : source === "messages"
          ? {
              senderContains: [],
              contentContains: [],
              groupChatFilter: "all" as GroupChatFilter,
              matchAll: false,
            }
          : {
              titleContains: [],
              calendarNameContains: [],
              contentContains: [],
              locationContains: [],
              excludeAllDay: true,
              matchAll: false,
            };

    const newRule: EventRule = {
      id: crypto.randomUUID(),
      name: `Rule ${rules.length + 1}`,
      enabled: true,
      condition: defaultCondition,
      // Start valid so the wizard can advance to the fallback step; clearing
      // the prompt still fails closed at save time.
      action: { type: "agentPrompt", prompt: "Summarize the triggering event." },
      stopProcessing: true,
    };
    const next = [...rules, newRule];
    onChange(next);
    setExpandedIndex(next.length - 1);
  }

  function handleRemoveRule(index: number) {
    const next = rules.filter((_, i) => i !== index);
    onChange(next);
    if (expandedIndex === index) {
      setExpandedIndex(next.length > 0 ? Math.max(0, index - 1) : null);
    } else if (expandedIndex != null && expandedIndex > index) {
      setExpandedIndex(expandedIndex - 1);
    }
  }

  function handleUpdateRule(index: number, updated: EventRule) {
    const next = [...rules];
    next[index] = updated;
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
    setExpandedIndex(targetIndex);
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
          default prompt. Click "+ Add Rule" to define customized filtering and actions.
        </div>
      ) : (
        <div className="rules-list space-y-3">
          {rules.map((rule, idx) => {
            const isExpanded = expandedIndex === idx;
            const actionType = rule.action.type;

            return (
              <div
                key={rule.id ?? idx}
                className={`rule-card border rounded p-3 bg-card ${
                  rule.enabled === false ? "opacity-60" : ""
                }`}
              >
                {/* Rule Header */}
                <div className="rule-card-header flex items-center justify-between">
                  <div className="flex items-center gap-2 flex-1">
                    <span className="font-mono text-xs text-muted">#{idx + 1}</span>
                    <input
                      type="text"
                      className="rule-name-input text-sm font-semibold"
                      aria-label="Rule Name"
                      value={rule.name}
                      placeholder="Rule Name (e.g. VIP Urgent Alerts)"
                      onChange={(e) =>
                        handleUpdateRule(idx, { ...rule, name: e.target.value })
                      }
                    />
                  </div>

                  <div className="rule-header-actions flex items-center gap-1">
                    <button
                      type="button"
                      className="icon-button text-xs"
                      disabled={idx === 0}
                      onClick={() => handleMoveRule(idx, "up")}
                      title="Move up"
                    >
                      ↑
                    </button>
                    <button
                      type="button"
                      className="icon-button text-xs"
                      disabled={idx === rules.length - 1}
                      onClick={() => handleMoveRule(idx, "down")}
                      title="Move down"
                    >
                      ↓
                    </button>
                    <button
                      type="button"
                      className="icon-button text-xs"
                      onClick={() =>
                        setExpandedIndex(isExpanded ? null : idx)
                      }
                      title={isExpanded ? "Collapse" : "Expand"}
                    >
                      {isExpanded ? "▲" : "▼"}
                    </button>
                    <button
                      type="button"
                      className="icon-button danger text-xs"
                      onClick={() => handleRemoveRule(idx)}
                      title="Delete rule"
                    >
                      <CloseIcon size={14} />
                    </button>
                  </div>
                </div>

                {isExpanded && (
                  <div className="rule-card-body mt-3 pt-3 border-t text-xs space-y-3">
                    {/* Condition Fields */}
                    <div className="rule-section">
                      <strong className="block text-muted mb-1">
                        When Event Matches:
                      </strong>

                      {source === "email" && (
                        <div className="grid grid-cols-2 gap-2">
                          <label className="form-label text-xs">
                            Sender contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. @school.org, boss@company.com"
                              value={csvToArray(rule.condition.senderContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    senderContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Subject contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. Receipt, Invoice, Urgent"
                              value={csvToArray(rule.condition.subjectContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    subjectContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Body contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. invoice total, action required"
                              value={csvToArray(rule.condition.contentContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    contentContains: arrayToCsv(e.target.value),
                                  },
                                })
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
                              value={csvToArray(rule.condition.senderContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    senderContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Text contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. urgent, call me, deadline"
                              value={csvToArray(rule.condition.contentContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    contentContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Chat Scope
                            <select
                              value={rule.condition.groupChatFilter ?? "all"}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    groupChatFilter: e.target.value as GroupChatFilter,
                                  },
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
                              value={csvToArray(rule.condition.titleContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    titleContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Calendar name contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. Work, Personal"
                              value={csvToArray(
                                rule.condition.calendarNameContains,
                              )}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    calendarNameContains: arrayToCsv(
                                      e.target.value,
                                    ),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Location contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. Zoom, Conference Room"
                              value={csvToArray(rule.condition.locationContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    locationContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="form-label text-xs">
                            Notes contains (comma separated)
                            <input
                              type="text"
                              placeholder="e.g. agenda, prep doc"
                              value={csvToArray(rule.condition.contentContains)}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    contentContains: arrayToCsv(e.target.value),
                                  },
                                })
                              }
                            />
                          </label>

                          <label className="flex items-center gap-2 mt-2">
                            <input
                              type="checkbox"
                              checked={rule.condition.excludeAllDay ?? true}
                              onChange={(e) =>
                                handleUpdateRule(idx, {
                                  ...rule,
                                  condition: {
                                    ...rule.condition,
                                    excludeAllDay: e.target.checked,
                                  },
                                })
                              }
                            />
                            <span>Exclude all-day events</span>
                          </label>
                        </div>
                      )}

                      <label className="flex items-center gap-2 mt-2">
                        <input
                          type="checkbox"
                          checked={rule.condition.matchAll ?? false}
                          onChange={(e) =>
                            handleUpdateRule(idx, {
                              ...rule,
                              condition: {
                                ...rule.condition,
                                matchAll: e.target.checked,
                              },
                            })
                          }
                        />
                        <span>Require all condition filters to match (Match All)</span>
                      </label>
                    </div>

                    {/* Action Selection */}
                    <div className="rule-section pt-2 border-t">
                      <strong className="block text-muted mb-1">
                        Take Action:
                      </strong>

                      <div className="flex gap-4 mb-2">
                        <label className="flex items-center gap-2 cursor-pointer">
                          <input
                            type="radio"
                            name={`actionType-${idx}`}
                            checked={actionType === "agentPrompt"}
                            onChange={() => {
                              const prompt =
                                rule.action.type === "agentPrompt"
                                  ? rule.action.prompt
                                  : "";
                              handleUpdateRule(idx, {
                                ...rule,
                                action: { type: "agentPrompt", prompt },
                              });
                            }}
                          />
                          <span>Agent Prompt (AI Reasoning)</span>
                        </label>

                        <label className="flex items-center gap-2 cursor-pointer">
                          <input
                            type="radio"
                            name={`actionType-${idx}`}
                            checked={actionType === "directTool"}
                            onChange={() => {
                              // The fast path bypasses inference, so the default
                              // must already be executable rather than a
                              // placeholder the worker would reject.
                              const defaultTool =
                                defaultDirectToolForSource(source);
                              const defaultArgs =
                                source === "email"
                                  ? '{"destination":"Archive"}'
                                  : "{}";
                              handleUpdateRule(idx, {
                                ...rule,
                                action: {
                                  type: "directTool",
                                  toolName: defaultTool,
                                  argumentsJSON: defaultArgs,
                                },
                              });
                            }}
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
                            placeholder="e.g. Summarize the sender's question and draft a suggested response."
                            value={
                              (
                                rule.action as Extract<
                                  EventRuleAction,
                                  { type: "agentPrompt" }
                                >
                              ).prompt ?? ""
                            }
                            onChange={(e) =>
                              handleUpdateRule(idx, {
                                ...rule,
                                action: { type: "agentPrompt", prompt: e.target.value },
                              })
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
                                const current = rule.action as Extract<
                                  EventRuleAction,
                                  { type: "directTool" }
                                >;
                                return ALLOWED_DIRECT_TOOL_NAMES.includes(
                                  current.toolName,
                                )
                                  ? current.toolName
                                  : "";
                              })()}
                              onChange={(e) => {
                                const current = rule.action as Extract<
                                  EventRuleAction,
                                  { type: "directTool" }
                                >;
                                handleUpdateRule(idx, {
                                  ...rule,
                                  action: {
                                    ...current,
                                    toolName: e.target.value,
                                  },
                                });
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
                              {(() => {
                                const current = rule.action as Extract<
                                  EventRuleAction,
                                  { type: "directTool" }
                                >;
                                const isDisallowedOption =
                                  current.toolName &&
                                  !ALLOWED_DIRECT_TOOL_NAMES.includes(
                                    current.toolName,
                                  );
                                return isDisallowedOption ? (
                                  <option
                                    key={current.toolName}
                                    value={current.toolName}
                                  >
                                    {current.toolName} (not allowed: pick above)
                                  </option>
                                ) : null;
                              })()}
                            </select>
                            <span className="text-muted text-xs">
                              Only allowlisted mutations run without a model
                              turn; anything else must use an agent prompt.
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
                                  rule.action as Extract<
                                    EventRuleAction,
                                    { type: "directTool" }
                                  >
                                ).argumentsJSON
                              }
                              onChange={(e) => {
                                const current = rule.action as Extract<
                                  EventRuleAction,
                                  { type: "directTool" }
                                >;
                                handleUpdateRule(idx, {
                                  ...rule,
                                  action: {
                                    ...current,
                                    argumentsJSON: e.target.value,
                                  },
                                });
                              }}
                            />
                          </label>
                        </div>
                      )}
                    </div>

                    {/* Stop Processing Option */}
                    <div className="pt-2 border-t flex items-center justify-between">
                      <label className="flex items-center gap-2 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={rule.stopProcessing ?? true}
                          onChange={(e) =>
                            handleUpdateRule(idx, {
                              ...rule,
                              stopProcessing: e.target.checked,
                            })
                          }
                        />
                        <span>Stop evaluating subsequent rules if this rule matches</span>
                      </label>
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
