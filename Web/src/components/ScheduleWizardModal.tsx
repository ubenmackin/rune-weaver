// Rune Weaver Dashboard — Guided creation wizard for recurring time-based and event-based scheduler jobs.

import { useState } from "react";
import {
  CALENDAR_LEAD_TIME_MINUTES_MAX,
  CALENDAR_LEAD_TIME_MINUTES_MIN,
  DEFAULT_POLL_INTERVAL_SECONDS,
  POLL_LIMIT_MAX,
  POLL_LIMIT_MIN,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
  normalizeEventRule,
  schedulerJobEffectiveMaxToolIterations,
  validateCalendarLeadTimeMinutes,
  validateEventRules,
  validatePollLimit,
  type EventRule,
  type NewSchedulerJobInput,
  type SchedulerJob,
  type UpdateSchedulerJobInput,
} from "../api";
import EventRuleBuilder from "./EventRuleBuilder";
import { CalendarIcon, ChatIcon, ClockIcon, CloseIcon, MailIcon } from "./icons";

interface ScheduleWizardModalProps {
  jobToEdit?: SchedulerJob | null;
  sectionDefault: number;
  onSave: (
    input: NewSchedulerJobInput | UpdateSchedulerJobInput,
    id?: string,
  ) => Promise<void>;
  onClose: () => void;
}

type TriggerType = "cron" | "email" | "messages" | "calendar";

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

const PROMPT_TEMPLATES = [
  {
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
    label: "Pre-Meeting Prep",
    prompt:
      "Review the attendees, agenda notes, and relevant recent history to generate a comprehensive pre-meeting brief.",
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
    if (jobToEdit?.watcherSource === "messages") return "messages";
    if (jobToEdit?.watcherSource === "calendar") return "calendar";
    if (jobToEdit?.watcherSource === "email" || jobToEdit?.pollAccount) return "email";
    return "cron";
  });

  const [name, setName] = useState(jobToEdit?.name ?? "");
  const [enabled, setEnabled] = useState(jobToEdit?.enabled ?? true);
  const [prompt, setPrompt] = useState(jobToEdit?.prompt ?? "");
  const [rules, setRules] = useState<EventRule[]>(() =>
    (jobToEdit?.rules ?? []).map((rule) => normalizeEventRule(rule)),
  );

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

  // Poll / Watcher State
  const [pollAccount, setPollAccount] = useState(jobToEdit?.pollAccount ?? "icloud");
  const [pollMailbox, setPollMailbox] = useState(jobToEdit?.pollMailbox ?? "INBOX");
  const [pollQuery, setPollQuery] = useState(jobToEdit?.pollQuery ?? "");
  const [pollIntervalText, setPollIntervalText] = useState(
    String(jobToEdit?.pollIntervalSeconds ?? DEFAULT_POLL_INTERVAL_SECONDS),
  );
  const [pollLimit, setPollLimit] = useState<number>(jobToEdit?.pollLimit ?? 10);

  // Calendar State
  const [calendarLeadTimeMinutes, setCalendarLeadTimeMinutes] = useState<number>(
    jobToEdit?.calendarLeadTimeMinutes ?? 15,
  );
  const [calendarNamesText, setCalendarNamesText] = useState<string>(
    (jobToEdit?.calendarNames ?? []).join(", "),
  );

  // Budget State
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
      } else if (triggerType === "email") {
        if (!pollAccount.trim()) {
          setError("Please provide a mail account name (e.g. 'icloud' or '*').");
          return;
        }
        if (parsedPollIntervalSeconds() == null) {
          setError("Check Interval must be a positive whole number of seconds.");
          return;
        }
        // Fail-closed batch window pinned to the engine maxLimit so the
        // wizard refuses what persistence would silently clamp.
        const pollLimitError = validatePollLimit(pollLimit);
        if (pollLimitError) {
          setError(pollLimitError);
          return;
        }
      } else if (triggerType === "messages") {
        if (parsedPollIntervalSeconds() == null) {
          setError("Check Interval must be a positive whole number of seconds.");
          return;
        }
      } else if (triggerType === "calendar") {
        // Fail-closed lead-time window so prep fires close enough to be
        // useful without sweeping months of meetings on a typo.
        const leadTimeError = validateCalendarLeadTimeMinutes(
          calendarLeadTimeMinutes,
        );
        if (leadTimeError) {
          setError(leadTimeError);
          return;
        }
        if (parsedPollIntervalSeconds() == null) {
          setError("Check Interval must be a positive whole number of seconds.");
          return;
        }
      }
      // Fail-closed rule check before leaving the watcher step so a nameless,
      // filterless, or off-allowlist rule surfaces where it is edited. Cron
      // jobs discard rules on save, so only watcher triggers validate here.
      if (triggerType !== "cron") {
        const rulesError = validateEventRules(rules);
        if (rulesError) {
          setError(rulesError);
          return;
        }
      }
      setStep(3);
    } else if (step === 3) {
      if (rules.length === 0 && !prompt.trim()) {
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
      const isEdit = jobToEdit != null;
      const shouldClearToolBudget =
        isEdit && (trimmedBudget === "" || onToolLimit === "");

      // Fail-closed resubmission guard: the step-2 check already rejects bad
      // rules, but the final save revalidates so no path bypasses it.
      if (triggerType !== "cron") {
        const rulesError = validateEventRules(rules);
        if (rulesError) {
          setError(rulesError);
          setSaving(false);
          return;
        }
      }
      if (triggerType === "calendar") {
        const leadTimeError = validateCalendarLeadTimeMinutes(
          calendarLeadTimeMinutes,
        );
        if (leadTimeError) {
          setError(leadTimeError);
          setSaving(false);
          return;
        }
      }
      const canonicalRules = rules.map((rule) => normalizeEventRule(rule));

      if (triggerType === "cron") {
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: getEffectiveCron(),
          prompt: prompt.trim(),
          enabled,
          clearPoll: true,
          clearWatcher: true,
          clearRules: true,
          maxToolIterations,
          onToolLimit: onToolLimitValue,
          ...(shouldClearToolBudget ? { clearToolBudget: true } : {}),
        };
        await onSave(payload, jobToEdit?.id);
      } else if (triggerType === "email") {
        const pollIntervalSeconds = parsedPollIntervalSeconds();
        if (pollIntervalSeconds == null) {
          setError("Check Interval must be a positive whole number of seconds.");
          setSaving(false);
          return;
        }
        const pollLimitError = validatePollLimit(pollLimit);
        if (pollLimitError) {
          setError(pollLimitError);
          setSaving(false);
          return;
        }
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: "",
          prompt: prompt.trim(),
          enabled,
          watcherSource: "email",
          rules: canonicalRules.length > 0 ? canonicalRules : null,
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
      } else if (triggerType === "messages") {
        const pollIntervalSeconds = parsedPollIntervalSeconds() ?? 60;
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: "",
          prompt: prompt.trim(),
          enabled,
          watcherSource: "messages",
          rules: canonicalRules.length > 0 ? canonicalRules : null,
          pollIntervalSeconds,
          clearPoll: true,
          maxToolIterations,
          onToolLimit: onToolLimitValue,
          ...(shouldClearToolBudget ? { clearToolBudget: true } : {}),
        };
        await onSave(payload, jobToEdit?.id);
      } else if (triggerType === "calendar") {
        const pollIntervalSeconds = parsedPollIntervalSeconds() ?? 60;
        const calendarNames = calendarNamesText
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: "",
          prompt: prompt.trim(),
          enabled,
          watcherSource: "calendar",
          rules: canonicalRules.length > 0 ? canonicalRules : null,
          calendarLeadTimeMinutes,
          calendarNames: calendarNames.length > 0 ? calendarNames : null,
          pollIntervalSeconds,
          clearPoll: true,
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
  const budgetBlankEffective = schedulerJobEffectiveMaxToolIterations(
    null,
    sectionDefault,
  );
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
      : `${budgetEffective} rounds (${onToolLimit === "park" ? "parks" : "synthesizes"})`;

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
              {step === 2 && (triggerType === "cron" ? "Time Schedule" : "Watcher & Rules")}
              {step === 3 && (rules.length > 0 ? "Fallback Prompt" : "Agent Instructions")}
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
                  className={`trigger-card ${triggerType === "email" ? "selected" : ""}`}
                  onClick={() => setTriggerType("email")}
                  role="button"
                  tabIndex={0}
                >
                  <div className="trigger-card-header">
                    <MailIcon size={20} className="trigger-icon" />
                    <strong>Email Event Watcher</strong>
                  </div>
                  <p>
                    Watches inbox for incoming emails and dispatches custom rules or
                    agent actions.
                  </p>
                </div>

                <div
                  className={`trigger-card ${triggerType === "messages" ? "selected" : ""}`}
                  onClick={() => setTriggerType("messages")}
                  role="button"
                  tabIndex={0}
                >
                  <div className="trigger-card-header">
                    <ChatIcon size={20} className="trigger-icon" />
                    <strong>Messages Watcher</strong>
                  </div>
                  <p>
                    Watches Apple Messages for new inbound texts or group chats.
                  </p>
                </div>

                <div
                  className={`trigger-card ${triggerType === "calendar" ? "selected" : ""}`}
                  onClick={() => setTriggerType("calendar")}
                  role="button"
                  tabIndex={0}
                >
                  <div className="trigger-card-header">
                    <CalendarIcon size={20} className="trigger-icon" />
                    <strong>Calendar Watcher</strong>
                  </div>
                  <p>
                    Monitors upcoming meetings with lead time for meeting prep and briefs.
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

          {step === 2 && triggerType === "email" && (
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
                </label>

                <label className="form-label">
                  Batch Limit
                  <input
                    type="number"
                    aria-label="Batch Limit"
                    min={POLL_LIMIT_MIN}
                    max={POLL_LIMIT_MAX}
                    value={pollLimit}
                    onChange={(e) => setPollLimit(Number(e.target.value))}
                  />
                </label>
              </div>

              <EventRuleBuilder source="email" rules={rules} onChange={setRules} />
            </div>
          )}

          {step === 2 && triggerType === "messages" && (
            <div className="wizard-step">
              <h4>Configure Messages Watcher</h4>
              <div className="form-grid">
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
                    placeholder="60"
                    value={pollIntervalText}
                    onChange={(e) => setPollIntervalText(e.target.value)}
                  />
                  <span className="muted text-xs">
                    How frequently to poll macOS Messages for new arrivals.
                  </span>
                </label>
              </div>

              <EventRuleBuilder source="messages" rules={rules} onChange={setRules} />
            </div>
          )}

          {step === 2 && triggerType === "calendar" && (
            <div className="wizard-step">
              <h4>Configure Calendar Watcher</h4>
              <div className="form-grid">
                <label className="form-label">
                  Meeting Lead Time (minutes)
                  <input
                    type="number"
                    min={CALENDAR_LEAD_TIME_MINUTES_MIN}
                    max={CALENDAR_LEAD_TIME_MINUTES_MAX}
                    aria-label="Meeting Lead Time"
                    placeholder="15"
                    value={calendarLeadTimeMinutes}
                    onChange={(e) => setCalendarLeadTimeMinutes(Number(e.target.value))}
                  />
                  <span className="muted text-xs">
                    Triggers pre-meeting actions this many minutes before the meeting begins.
                  </span>
                </label>

                <label className="form-label">
                  Calendar Names (optional, comma-separated)
                  <input
                    type="text"
                    placeholder="e.g. Work, Client Meetings"
                    value={calendarNamesText}
                    onChange={(e) => setCalendarNamesText(e.target.value)}
                  />
                  <span className="muted text-xs">
                    Leave blank to search all available device calendars.
                  </span>
                </label>

                <label className="form-label">
                  Check Interval (seconds)
                  <input
                    type="text"
                    inputMode="numeric"
                    placeholder="60"
                    value={pollIntervalText}
                    onChange={(e) => setPollIntervalText(e.target.value)}
                  />
                </label>
              </div>

              <EventRuleBuilder source="calendar" rules={rules} onChange={setRules} />
            </div>
          )}

          {/* STEP 3: Agent Task Prompt */}
          {step === 3 && (
            <div className="wizard-step">
              <label className="form-label">
                {rules.length > 0 ? (
                  <>
                    Fallback Agent Prompt (Optional)
                    <span className="muted text-xs block font-normal mt-0.5">
                      Runs when an incoming event arrives but does not match any configured rule.
                      Leave empty to ignore unmatched events.
                    </span>
                  </>
                ) : (
                  <>
                    Agent Task Instructions
                    <span className="muted text-xs block font-normal mt-0.5">
                      What should the agent do each time this schedule fires?
                    </span>
                  </>
                )}
                <textarea
                  rows={4}
                  aria-label="Agent Task Instructions"
                  placeholder={
                    rules.length > 0
                      ? "Optional fallback instructions for unmatched events..."
                      : "What should the agent do each time this schedule fires?"
                  }
                  value={prompt}
                  onChange={(e) => setPrompt(e.target.value)}
                  autoFocus
                />
              </label>

              <details className="mt-3">
                <summary>Advanced: tool budget</summary>
                <div className="mt-2 space-y-2">
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
                </div>
              </details>

              <div className="prompt-template-section mt-3">
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
                    {triggerType === "cron"
                      ? "Scheduled Time"
                      : triggerType === "email"
                      ? "Email Watcher"
                      : triggerType === "messages"
                      ? "Messages Watcher"
                      : "Calendar Watcher"}
                  </span>
                </div>
                <div className="review-row">
                  <span className="review-label">Trigger:</span>
                  <span className="font-mono">
                    {triggerType === "cron"
                      ? getEffectiveCron()
                      : triggerType === "email"
                      ? `Watches ${pollAccount} (${pollMailbox}) every ${pollIntervalText.trim() || "…"}s`
                      : triggerType === "messages"
                      ? `Watches Messages every ${pollIntervalText.trim() || "…"}s`
                      : `Watches Calendar (lead time ${calendarLeadTimeMinutes}m)`}
                  </span>
                </div>
                {rules.length > 0 && (
                  <div className="review-row">
                    <span className="review-label">Rules:</span>
                    <span>
                      {rules.length} custom rules ({rules.map((r) => r.name).join(", ")})
                    </span>
                  </div>
                )}
                <div className="review-row">
                  <span className="review-label">Status:</span>
                  <span>{enabled ? "Active (Enabled)" : "Paused (Disabled)"}</span>
                </div>
                <div className="review-row">
                  <span className="review-label">Tool budget:</span>
                  <span>{budgetReviewText}</span>
                </div>
                <div className="review-section mt-3">
                  <span className="review-label">
                    {rules.length > 0 ? "Fallback Prompt:" : "Agent Prompt:"}
                  </span>
                  <div className="prompt-preview-box">
                    {prompt || (rules.length > 0 ? "(None configured: unmatched events ignored)" : "(Empty)")}
                  </div>
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
