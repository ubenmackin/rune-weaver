// Rune Weaver Dashboard — Guided creation wizard for recurring time-based and event-based scheduler jobs.
// Guarantees clean separation: a job is strictly Scheduled (Cron) OR Event (Email Poll).

import { useState } from "react";
import {
  DEFAULT_POLL_INTERVAL_SECONDS,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
  schedulerJobEffectiveMaxToolIterations,
  type NewSchedulerJobInput,
  type SchedulerJob,
  type UpdateSchedulerJobInput,
} from "../api";
import { ClockIcon, CloseIcon, MailIcon } from "./icons";

interface ScheduleWizardModalProps {
  jobToEdit?: SchedulerJob | null;
  sectionDefault: number;
  onSave: (
    input: NewSchedulerJobInput | UpdateSchedulerJobInput,
    id?: string,
  ) => Promise<void>;
  onClose: () => void;
}

type TriggerType = "cron" | "poll";

interface CronPreset {
  id: string;
  label: string;
  cron: string;
  description: string;
}

const CRON_PRESETS: CronPreset[] = [
  {
    id: "15m",
    label: "Every 15 Minutes",
    cron: "*/15 * * * *",
    description: "Fires repeatedly every 15 minutes throughout the day.",
  },
  {
    id: "hourly",
    label: "Hourly",
    cron: "0 * * * *",
    description: "Fires at the top of every hour.",
  },
  {
    id: "daily-8am",
    label: "Daily at 8:00 AM",
    cron: "0 8 * * *",
    description: "Fires once a day every morning at 8:00 AM local time.",
  },
  {
    id: "weekdays-9am",
    label: "Weekdays at 9:00 AM",
    cron: "0 9 * * 1-5",
    description: "Fires Monday through Friday at 9:00 AM.",
  },
  {
    id: "weekly-mon",
    label: "Weekly (Monday 8 AM)",
    cron: "0 8 * * 1",
    description: "Fires once per week every Monday morning at 8:00 AM.",
  },
  {
    id: "custom",
    label: "Custom Cron",
    cron: "",
    description: "Specify any standard 5-field cron expression.",
  },
];

const POLL_INTERVAL_PRESETS = [60, 300, 900, 1800, 3600];

const PROMPT_TEMPLATES = [  {
    label: "Inbox Summary",
    prompt:
      "Summarize all new emails received since the last run, categorized by sender and importance.",
  },
  {
    label: "Action Items Digest",
    prompt:
      "Scan incoming messages for required follow-ups, pending questions, or deadlines, and list them clearly.",
  },
  {
    label: "System Status Brief",
    prompt:
      "Check recent system alerts and logs, and provide a brief status overview of service health.",
  },
];

export default function ScheduleWizardModal({
  jobToEdit,
  sectionDefault,
  onSave,
  onClose,
}: ScheduleWizardModalProps) {
  const [step, setStep] = useState<1 | 2 | 3 | 4>(1);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Form State
  const [triggerType, setTriggerType] = useState<TriggerType>(() => {
    if (jobToEdit?.pollAccount) return "poll";
    return "cron";
  });

  const [name, setName] = useState(jobToEdit?.name ?? "");
  const [enabled, setEnabled] = useState(jobToEdit?.enabled ?? true);
  const [prompt, setPrompt] = useState(jobToEdit?.prompt ?? "");

  // Cron State
  const [selectedPreset, setSelectedPreset] = useState<string>(() => {
    if (!jobToEdit?.schedule) return "daily-8am";
    const match = CRON_PRESETS.find((p) => p.cron === jobToEdit.schedule);
    return match ? match.id : "custom";
  });
  const [customCron, setCustomCron] = useState(
    jobToEdit?.schedule && !CRON_PRESETS.some((p) => p.cron === jobToEdit.schedule)
      ? jobToEdit.schedule
      : "0 8 * * *",
  );

  // Poll State
  const [pollAccount, setPollAccount] = useState(jobToEdit?.pollAccount ?? "icloud");
  const [pollMailbox, setPollMailbox] = useState(jobToEdit?.pollMailbox ?? "INBOX");
  const [pollQuery, setPollQuery] = useState(jobToEdit?.pollQuery ?? "");
  // Free-form seconds text: presets below are shortcuts, while any
  // positive whole number (e.g. 600) is accepted like the server.
  const [pollIntervalText, setPollIntervalText] = useState(
    String(jobToEdit?.pollIntervalSeconds ?? DEFAULT_POLL_INTERVAL_SECONDS),
  );
  const [pollLimit, setPollLimit] = useState<number>(jobToEdit?.pollLimit ?? 10);
  const [maxToolRoundsText, setMaxToolRoundsText] = useState<string>(
    jobToEdit?.maxToolIterations != null
      ? String(jobToEdit.maxToolIterations)
      : "",
  );
  const [onToolLimit, setOnToolLimit] = useState<string>(
    jobToEdit?.onToolLimit ?? "",
  );

  // Strict decimal whole seconds; null means the input is not submittable.
  function parsedPollIntervalSeconds(): number | null {
    const trimmed = pollIntervalText.trim();
    if (!/^\d+$/.test(trimmed)) return null;
    const value = Number(trimmed);
    if (!Number.isSafeInteger(value) || value <= 0) return null;
    return value;
  }

  function getEffectiveCron(): string {
    if (selectedPreset === "custom") {
      return customCron.trim();
    }
    const preset = CRON_PRESETS.find((p) => p.id === selectedPreset);
    return preset?.cron ?? "0 8 * * *";
  }

  function handleNext() {
    setError(null);
    if (step === 1) {
      if (!name.trim()) {
        setError("Please enter a name for the job.");
        return;
      }
      setStep(2);
    } else if (step === 2) {
      if (triggerType === "cron") {
        const cronStr = getEffectiveCron();
        if (!cronStr) {
          setError("Please specify a valid cron schedule.");
          return;
        }
      } else {
        if (!pollAccount.trim()) {
          setError("Please provide a poll account name (e.g. 'icloud').");
          return;
        }
        if (parsedPollIntervalSeconds() == null) {
          setError("Check Interval must be a positive whole number of seconds.");
          return;
        }
      }
      setStep(3);
    } else if (step === 3) {
      if (!prompt.trim()) {
        setError("Please enter prompt instructions for the agent.");
        return;
      }
      setStep(4);
    }
  }

  async function handleFinalSubmit() {
    setError(null);
    setSaving(true);
    try {
      const trimmedBudget = maxToolRoundsText.trim();
      let maxToolIterations: number | null;
      if (trimmedBudget === "") {
        maxToolIterations = null;
      } else {
        if (!/^\d+$/.test(trimmedBudget)) {
          setError(
            `Max tool rounds must be between ${TOOL_ROUNDS_MIN} and ${TOOL_ROUNDS_MAX}.`,
          );
          setSaving(false);
          return;
        }
        const parsed = Number(trimmedBudget);
        if (
          !Number.isSafeInteger(parsed) ||
          parsed < TOOL_ROUNDS_MIN ||
          parsed > TOOL_ROUNDS_MAX
        ) {
          setError(
            `Max tool rounds must be between ${TOOL_ROUNDS_MIN} and ${TOOL_ROUNDS_MAX}.`,
          );
          setSaving(false);
          return;
        }
        maxToolIterations = parsed;
      }
      const onToolLimitValue = onToolLimit === "" ? null : onToolLimit;
      // Edit clear-vs-omit contract (mirrors UpdateSchedulerJob on the engine): omitted (null)
      // leaves the budget alone, so an edit that blanks a previously set budget must send
      // clearToolBudget:true to return to inherit (nil) before re-applying any non-nil fields.
      const isEdit = jobToEdit != null;
      const shouldClearToolBudget =
        isEdit && (trimmedBudget === "" || onToolLimit === "");
      if (triggerType === "cron") {
        const payload = {
          name: name.trim(),
          schedule: getEffectiveCron(),
          prompt: prompt.trim(),
          enabled,
          clearPoll: true,
          maxToolIterations,
          onToolLimit: onToolLimitValue,
          ...(shouldClearToolBudget ? { clearToolBudget: true } : {}),
        };
        await onSave(payload, jobToEdit?.id);
      } else {
        const pollIntervalSeconds = parsedPollIntervalSeconds();
        if (pollIntervalSeconds == null) {
          setError("Check Interval must be a positive whole number of seconds.");
          setSaving(false);
          return;
        }
        const payload = {
          name: name.trim(),
          schedule: "", // empty for poll-only jobs
          prompt: prompt.trim(),
          enabled,
          pollAccount: pollAccount.trim(),
          pollMailbox: pollMailbox.trim() || null,
          pollQuery: pollQuery.trim() || null,
          pollIntervalSeconds,
          pollLimit,
          maxToolIterations,
          onToolLimit: onToolLimitValue,
          ...(shouldClearToolBudget ? { clearToolBudget: true } : {}),
        };
        await onSave(payload, jobToEdit?.id);
      }
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to save schedule.");
    } finally {
      setSaving(false);
    }
  }

  const budgetTrimmed = maxToolRoundsText.trim();
  // Blank inherits the live section default through the same clamped resolver
  // the list uses, so the review never shows an unclamped raw default.
  const budgetBlankEffective = schedulerJobEffectiveMaxToolIterations(
    null,
    sectionDefault,
  );
  // Non-numeric input can never submit (Number would be NaN and fall back to
  // the section default), so surface the validation state instead of a
  // misleading effective budget.
  const budgetIsNonNumeric =
    budgetTrimmed !== "" && !/^\d+$/.test(budgetTrimmed);
  const budgetEffective = schedulerJobEffectiveMaxToolIterations(
    {
      maxToolIterations:
        budgetTrimmed === "" || budgetIsNonNumeric
          ? null
          : Number(budgetTrimmed),
    } as SchedulerJob,
    sectionDefault,
  );
  const budgetReviewText =
    budgetTrimmed === ""
      ? `Uses schedule default (${budgetBlankEffective})`
      : budgetIsNonNumeric
        ? `Max tool rounds must be between ${TOOL_ROUNDS_MIN} and ${TOOL_ROUNDS_MAX}.`
        : `${budgetEffective} rounds — ${onToolLimit === "park" ? "parks" : "synthesizes"}`;

  return (
    <div className="modal-backdrop" onClick={onClose} role="dialog" aria-modal="true">
      <div
        className="modal-container wizard-modal"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Wizard Header */}
        <div className="modal-header">
          <div>
            <h3>{jobToEdit ? "Edit Schedule" : "Schedule Wizard"}</h3>
            <span className="wizard-step-indicator">
              Step {step} of 4:{" "}
              {step === 1 && "Trigger Type & Name"}
              {step === 2 && (triggerType === "cron" ? "Time Schedule" : "Email Watcher")}
              {step === 3 && "Agent Instructions"}
              {step === 4 && "Review & Confirm"}
            </span>
          </div>
          <button
            type="button"
            className="icon-button"
            onClick={onClose}
            aria-label="Close modal"
          >
            <CloseIcon size={18} />
          </button>
        </div>

        {/* Wizard Progress Bar */}
        <div className="wizard-progress-track">
          <div
            className="wizard-progress-bar"
            style={{ width: `${(step / 4) * 100}%` }}
          />
        </div>

        <div className="modal-body wizard-body">
          {error ? <div className="error-banner">{error}</div> : null}

          {/* STEP 1: Type & Name */}
          {step === 1 && (
            <div className="wizard-step">
              <label className="form-label">
                Job Name
                <input
                  type="text"
                  aria-label="Job Name"
                  placeholder="e.g. Morning Inbox Summary"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  autoFocus
                />
              </label>

              <div className="form-label mt-4">Select Trigger Type</div>
              <div className="trigger-card-grid">
                <div
                  className={`trigger-card ${triggerType === "cron" ? "selected" : ""}`}
                  onClick={() => setTriggerType("cron")}
                  role="button"
                  tabIndex={0}
                >
                  <div className="trigger-card-header">
                    <ClockIcon size={20} className="trigger-icon" />
                    <strong>Scheduled Time</strong>
                  </div>
                  <p>
                    Runs automatically on a repeating timer, hourly, daily, or
                    custom cron schedule.
                  </p>
                </div>

                <div
                  className={`trigger-card ${triggerType === "poll" ? "selected" : ""}`}
                  onClick={() => setTriggerType("poll")}
                  role="button"
                  tabIndex={0}
                >
                  <div className="trigger-card-header">
                    <MailIcon size={20} className="trigger-icon" />
                    <strong>Email Event Watcher</strong>
                  </div>
                  <p>
                    Runs automatically whenever new matching emails arrive in your
                    inbox.
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* STEP 2: Trigger Details */}
          {step === 2 && triggerType === "cron" && (
            <div className="wizard-step">
              <h4>Choose Recurring Schedule</h4>
              <div className="preset-grid">
                {CRON_PRESETS.map((preset) => {
                  const isSelected = selectedPreset === preset.id;
                  return (
                    <div
                      key={preset.id}
                      className={`preset-card ${isSelected ? "selected" : ""}`}
                      onClick={() => setSelectedPreset(preset.id)}
                    >
                      <div className="preset-card-title">{preset.label}</div>
                      <div className="preset-card-desc">{preset.description}</div>
                      {preset.cron ? (
                        <div className="preset-cron-tag font-mono">{preset.cron}</div>
                      ) : null}
                    </div>
                  );
                })}
              </div>

              {selectedPreset === "custom" && (
                <label className="form-label mt-4">
                  Custom Cron Expression
                  <input
                    type="text"
                    aria-label="Custom Cron Expression"
                    placeholder="0 8 * * *"
                    value={customCron}
                    onChange={(e) => setCustomCron(e.target.value)}
                    className="font-mono"
                  />
                  <span className="muted text-xs">
                    5-field syntax: (minute hour day-of-month month day-of-week)
                  </span>
                </label>
              )}
            </div>
          )}

          {step === 2 && triggerType === "poll" && (
            <div className="wizard-step">
              <h4>Configure Email Watcher</h4>
              <div className="form-grid">
                <label className="form-label">
                  Mail Account
                  <input
                    type="text"
                    aria-label="Mail Account"
                    placeholder="e.g. icloud"
                    value={pollAccount}
                    onChange={(e) => setPollAccount(e.target.value)}
                  />
                </label>

                <label className="form-label">
                  Mailbox
                  <input
                    type="text"
                    aria-label="Mailbox"
                    placeholder="INBOX"
                    value={pollMailbox}
                    onChange={(e) => setPollMailbox(e.target.value)}
                  />
                </label>

                <label className="form-label">
                  Filter Query (optional)
                  <input
                    type="text"
                    aria-label="Filter Query"
                    placeholder="e.g. from:alerts or unread"
                    value={pollQuery}
                    onChange={(e) => setPollQuery(e.target.value)}
                  />
                </label>

                <label className="form-label">
                  Check Interval (seconds)
                  <div className="template-pill-group">
                    {POLL_INTERVAL_PRESETS.map((preset) => (
                      <button
                        key={preset}
                        type="button"
                        className="template-pill"
                        aria-pressed={pollIntervalText.trim() === String(preset)}
                        onClick={() => setPollIntervalText(String(preset))}
                      >
                        {preset >= 3600
                          ? `${preset / 3600}h`
                          : preset >= 60
                          ? `${preset / 60}m`
                          : `${preset}s`}
                      </button>
                    ))}
                  </div>
                  <input
                    type="text"
                    inputMode="numeric"
                    aria-label="Check Interval"
                    placeholder="300"
                    value={pollIntervalText}
                    onChange={(e) => setPollIntervalText(e.target.value)}
                  />
                  <span className="muted text-xs">
                    Positive whole seconds (e.g. 600 for every 10 minutes).
                  </span>
                </label>

                <label className="form-label">
                  Batch Limit
                  <input
                    type="number"
                    aria-label="Batch Limit"
                    min={1}
                    max={100}
                    value={pollLimit}
                    onChange={(e) => setPollLimit(Number(e.target.value))}
                  />
                </label>
              </div>
            </div>
          )}

          {/* STEP 3: Agent Task Prompt */}
          {step === 3 && (
            <div className="wizard-step">
              <label className="form-label">
                Agent Task Instructions
                <textarea
                  rows={4}
                  aria-label="Agent Task Instructions"
                  placeholder="What should the agent do each time this schedule fires?"
                  value={prompt}
                  onChange={(e) => setPrompt(e.target.value)}
                  autoFocus
                />
              </label>

              <details>
                <summary>Advanced: tool budget</summary>
                <label className="form-label">
                  Max tool rounds
                  <input
                    type="number"
                    aria-label="Max tool rounds (blank uses schedule default)"
                    min={TOOL_ROUNDS_MIN}
                    max={TOOL_ROUNDS_MAX}
                    step={1}
                    value={maxToolRoundsText}
                    onChange={(e) => setMaxToolRoundsText(e.target.value)}
                  />
                </label>
                <label className="form-label">
                  On tool limit
                  <select
                    aria-label="On tool limit"
                    value={onToolLimit}
                    onChange={(e) => setOnToolLimit(e.target.value)}
                  >
                    <option value="">Use default (synthesize)</option>
                    <option value="fail">Synthesize summary (fail)</option>
                    <option value="park">Park for approval (park)</option>
                  </select>
                </label>
              </details>

              <div className="prompt-template-section">
                <span className="muted text-xs">Suggested templates:</span>
                <div className="template-pill-group">
                  {PROMPT_TEMPLATES.map((tmpl) => (
                    <button
                      key={tmpl.label}
                      type="button"
                      className="template-pill"
                      onClick={() => setPrompt(tmpl.prompt)}
                    >
                      {tmpl.label}
                    </button>
                  ))}
                </div>
              </div>

              <label className="checkbox-row mt-4">
                <input
                  type="checkbox"
                  checked={enabled}
                  onChange={(e) => setEnabled(e.target.checked)}
                />
                <span>Enable this schedule immediately</span>
              </label>
            </div>
          )}

          {/* STEP 4: Review & Confirm */}
          {step === 4 && (
            <div className="wizard-step">
              <h4>Review Schedule Details</h4>
              <div className="review-card">
                <div className="review-row">
                  <span className="review-label">Job Name:</span>
                  <strong>{name}</strong>
                </div>
                <div className="review-row">
                  <span className="review-label">Type:</span>
                  <span>
                    {triggerType === "cron" ? "Scheduled Time" : "Email Watcher"}
                  </span>
                </div>
                <div className="review-row">
                  <span className="review-label">Trigger:</span>
                  <span className="font-mono">
                    {triggerType === "cron"
                      ? getEffectiveCron()
                      : `Watches ${pollAccount} (${pollMailbox}) every ${pollIntervalText.trim() || "…"}s`}
                  </span>
                </div>
                <div className="review-row">
                  <span className="review-label">Status:</span>
                  <span>{enabled ? "Active (Enabled)" : "Paused (Disabled)"}</span>
                </div>
                <div className="review-row">
                  <span className="review-label">Tool budget:</span>
                  <span>{budgetReviewText}</span>
                </div>
                <div className="review-section mt-3">
                  <span className="review-label">Agent Prompt:</span>
                  <div className="prompt-preview-box">{prompt}</div>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Wizard Footer */}
        <div className="modal-footer wizard-footer">
          {step > 1 ? (
            <button
              type="button"
              className="ghost"
              onClick={() => setStep((s) => (s - 1) as 1 | 2 | 3 | 4)}
              disabled={saving}
            >
              Back
            </button>
          ) : (
            <div />
          )}

          {step < 4 ? (
            <button
              type="button"
              className="primary"
              onClick={handleNext}
              disabled={saving}
            >
              Continue
            </button>
          ) : (
            <button
              type="button"
              className="primary"
              onClick={() => void handleFinalSubmit()}
              disabled={saving}
            >
              {saving
                ? "Saving…"
                : jobToEdit
                ? "Update Schedule"
                : "Save Schedule"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
