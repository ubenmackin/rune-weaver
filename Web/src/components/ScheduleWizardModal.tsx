// Rune Weaver Dashboard — Guided creation wizard for recurring time-based and event-based scheduler jobs.
import { useCallback, useEffect, useState } from "react";
import {
  CALENDAR_LEAD_TIME_MINUTES_MAX,
  CALENDAR_LEAD_TIME_MINUTES_MIN,
  DEFAULT_POLL_INTERVAL_SECONDS,
  MAX_POLL_PREDICATES,
  POLL_LIMIT_MAX,
  POLL_LIMIT_MIN,
  POLL_SINCE_DAYS_MAX,
  POLL_SINCE_DAYS_MIN,
  POLL_SINCE_PRESETS,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
  getSettings,
  normalizeEventRule,
  pollPredicatePreview,
  predicatesFromJob,
  predicatesToPayload,
  schedulerJobEffectiveMaxToolIterations,
  validateCalendarLeadTimeMinutes,
  validateEventRules,
  validatePollLimit,
  validatePollPredicates,
  type EventRule,
  type NewSchedulerJobInput,
  type PollPredicate,
  type SchedulerJob,
  type UpdateSchedulerJobInput,
} from "../api";
import {
  calendarCacheAgeMs,
  fetchCalendars,
  fetchMailboxes,
  mailboxCacheAgeMs,
  readCachedCalendars,
  readCachedMailboxes,
  type CalendarLookup,
} from "../api/lookups";
import EventRuleBuilder from "./EventRuleBuilder";
import InfoTip from "./InfoTip";
import { CalendarIcon, ChatIcon, ClockIcon, CloseIcon, MailIcon } from "./icons";
import {
  CHECK_INTERVAL_MAX_SECONDS,
  CHECK_INTERVAL_MIN_SECONDS,
  CRON_PRESETS,
  POLL_INTERVAL_PRESETS,
  PROMPT_TEMPLATES,
  effectiveCron,
  formatCacheAge,
  parsePollIntervalSeconds,
  validateCheckInterval,
} from "./scheduleWizardConfig";
import type { TriggerType } from "./scheduleWizardConfig";

interface ScheduleWizardModalProps {
  jobToEdit?: SchedulerJob | null;
  sectionDefault: number;
  onSave: (
    input: NewSchedulerJobInput | UpdateSchedulerJobInput,
    id?: string,
  ) => Promise<void>;
  onClose: () => void;
}

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
  const [pollAccount, setPollAccount] = useState(jobToEdit?.pollAccount ?? "");
  const [pollMailbox, setPollMailbox] = useState(jobToEdit?.pollMailbox ?? "");
  const [predicates, setPredicates] = useState<PollPredicate[]>(() =>
    jobToEdit ? predicatesFromJob(jobToEdit) : [],
  );
  const [pollIntervalText, setPollIntervalText] = useState(
    String(jobToEdit?.pollIntervalSeconds ?? DEFAULT_POLL_INTERVAL_SECONDS),
  );
  const [pollLimit, setPollLimit] = useState<number>(jobToEdit?.pollLimit ?? 10);

  // Lookup State (settings accounts, live mailboxes, live calendars).
  const [emailAccountNames, setEmailAccountNames] = useState<string[]>([]);
  const [accountsLoading, setAccountsLoading] = useState(true);
  const [mailboxes, setMailboxes] = useState<string[]>([]);
  const [mailboxLoading, setMailboxLoading] = useState(false);
  const [mailboxError, setMailboxError] = useState<string | null>(null);
  const [mailboxStale, setMailboxStale] = useState(false);
  const [mailboxStaleAgeMs, setMailboxStaleAgeMs] = useState<number | null>(null);
  const [calendars, setCalendars] = useState<CalendarLookup[]>(() => {
    try {
      return readCachedCalendars() ?? [];
    } catch {
      return [];
    }
  });
  const [calendarLoading, setCalendarLoading] = useState(false);
  const [calendarError, setCalendarError] = useState<string | null>(null);
  const [calendarStale, setCalendarStale] = useState(false);
  const [calendarStaleAgeMs, setCalendarStaleAgeMs] = useState<number | null>(null);

  // Calendar State
  const [calendarLeadTimeMinutes, setCalendarLeadTimeMinutes] = useState<number>(
    jobToEdit?.calendarLeadTimeMinutes ?? 15,
  );
  const [selectedCalendars, setSelectedCalendars] = useState<string[]>(
    jobToEdit?.calendarNames ?? [],
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

  // Loads the sorted account names once so the watcher select mirrors settings.
  useEffect(() => {
    let cancelled = false;
    setAccountsLoading(true);
    getSettings()
      .then((settings) => {
        if (cancelled) return;
        const raw = Array.isArray(settings.emailAccounts)
          ? settings.emailAccounts
          : [];
        const names = raw
          .map((entry) =>
            typeof entry?.name === "string" ? entry.name.trim() : "",
          )
          .filter((entry) => entry.length > 0)
          .sort((a, b) => a.localeCompare(b));
        setEmailAccountNames(names);
      })
      .catch(() => {
        if (!cancelled) setEmailAccountNames([]);
      })
      .finally(() => {
        if (!cancelled) setAccountsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Shared live-with-stale-cache mailbox fetch so the account effect
  // and the Retry button follow one identical path.
  const loadMailboxes = useCallback(
    (account: string, isCancelled?: () => boolean) => {
      setMailboxLoading(true);
      setMailboxError(null);
      fetchMailboxes(account)
        .then((live) => {
          if (isCancelled?.()) return;
          setMailboxes(live);
          setMailboxStale(false);
          setMailboxStaleAgeMs(null);
          setMailboxError(null);
        })
        .catch((failure) => {
          if (isCancelled?.()) return;
          const cached = readCachedMailboxes(account);
          if (cached) {
            setMailboxes(cached);
            setMailboxStale(true);
            setMailboxStaleAgeMs(mailboxCacheAgeMs(account));
            setMailboxError(null);
          } else {
            setMailboxes([]);
            setMailboxStale(false);
            setMailboxStaleAgeMs(null);
            setMailboxError(
              failure instanceof Error
                ? failure.message
                : "Mailbox list is unavailable.",
            );
          }
        })
        .finally(() => {
          if (!isCancelled?.()) setMailboxLoading(false);
        });
    },
    [],
  );

  // Refetches mailboxes whenever the account changes; stale cache keeps the
  // select usable while an uncached failure blocks advance.
  useEffect(() => {
    if (!pollAccount) {
      setMailboxes([]);
      setMailboxError(null);
      setMailboxStale(false);
      setMailboxStaleAgeMs(null);
      setMailboxLoading(false);
      return;
    }
    let cancelled = false;
    loadMailboxes(pollAccount, () => cancelled);
    return () => {
      cancelled = true;
    };
  }, [pollAccount, loadMailboxes]);

  function reloadMailboxes() {
    const account = pollAccount;
    if (!account) return;
    loadMailboxes(account);
  }

  // Shared live-with-stale-cache calendar fetch so the watcher effect
  // and the Retry button follow one identical path.
  const loadCalendars = useCallback((isCancelled?: () => boolean) => {
    setCalendarLoading(true);
    setCalendarError(null);
    fetchCalendars()
      .then((live) => {
        if (isCancelled?.()) return;
        setCalendars(live);
        setCalendarStale(false);
        setCalendarStaleAgeMs(null);
        setCalendarError(null);
      })
      .catch((failure) => {
        if (isCancelled?.()) return;
        const cached = readCachedCalendars();
        if (cached) {
          setCalendars(cached);
          setCalendarStale(true);
          setCalendarStaleAgeMs(calendarCacheAgeMs());
          setCalendarError(null);
        } else {
          setCalendars([]);
          setCalendarStale(false);
          setCalendarStaleAgeMs(null);
          setCalendarError(
            failure instanceof Error
              ? failure.message
              : "Calendar list is unavailable.",
          );
        }
      })
      .finally(() => {
        if (!isCancelled?.()) setCalendarLoading(false);
      });
  }, []);

  // Loads calendars when the calendar watcher opens; cached titles keep the
  // list usable while an uncached failure blocks advance.
  useEffect(() => {
    if (triggerType !== "calendar") return;
    let cancelled = false;
    loadCalendars(() => cancelled);
    return () => {
      cancelled = true;
    };
  }, [triggerType, loadCalendars]);

  function reloadCalendars() {
    loadCalendars();
  }

  const hasNoAccounts = !accountsLoading && emailAccountNames.length === 0;

  function handleAddPredicate() {
    if (predicates.length >= MAX_POLL_PREDICATES) return;
    setPredicates([...predicates, { kind: "contains", value: "" }]);
  }

  function handleRemovePredicate(index: number) {
    setPredicates(predicates.filter((_, i) => i !== index));
  }

  function handlePredicateKindChange(index: number, kind: PollPredicate["kind"]) {
    setPredicates(
      predicates.map((row, i) => {
        if (i !== index) return row;
        if (kind === "unread") return { kind: "unread" };
        if (kind === "sinceDays") return { kind: "sinceDays", days: 7 };
        return { kind, value: typeof row.value === "string" ? row.value : "" };
      }),
    );
  }

  function handleNext() {
    setError(null);
    if (step === 1) {
      if (!name.trim()) {
        setError("Please enter a name for the job.");
        return;
      }
      if (triggerType === "email" && hasNoAccounts) {
        setError("Mail Account is unavailable. Configure a mail account in Settings first.");
        return;
      }
      setStep(2);
    } else if (step === 2) {
      if (triggerType === "cron") {
        const cronStr = effectiveCron(selectedPreset, customCron);
        if (!cronStr) {
          setError("Please specify a valid cron schedule.");
          return;
        }
      } else if (triggerType === "email") {
        if (!pollAccount.trim()) {
          setError("Mail Account is required. Select an account.");
          return;
        }
        // "*" polls every account, so blank means every mailbox and only
        // a narrowed mailbox must prove membership in the union list.
        const allAccounts = pollAccount.trim() === "*";
        if (!allAccounts) {
          if (mailboxLoading) {
            setError("Mailbox list is still loading. Wait, then retry.");
            return;
          }
          if (mailboxes.length === 0 && mailboxError) {
            setError(`Mailbox list is unavailable for this account. ${mailboxError}`);
            return;
          }
          if (!pollMailbox.trim()) {
            setError("Mailbox is required. Select a mailbox.");
            return;
          }
          if (mailboxes.length > 0 && !mailboxes.includes(pollMailbox.trim())) {
            setError("Selected mailbox is no longer available. Choose a mailbox from the live list.");
            return;
          }
        } else {
          if (mailboxLoading) {
            setError("Mailbox list is still loading. Wait, then retry.");
            return;
          }
          if (pollMailbox.trim()) {
            if (mailboxes.length === 0 && mailboxError) {
              setError(`Mailbox list is unavailable for this account. ${mailboxError}`);
              return;
            }
            if (mailboxes.length > 0 && !mailboxes.includes(pollMailbox.trim())) {
              setError("Selected mailbox is no longer available. Choose a mailbox from the live list.");
              return;
            }
          }
        }
        const predicateError = validatePollPredicates(predicates);
        if (predicateError) {
          setError(predicateError);
          return;
        }
        const intervalError = validateCheckInterval(pollIntervalText);
        if (intervalError) {
          setError(intervalError);
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
        const intervalError = validateCheckInterval(pollIntervalText);
        if (intervalError) {
          setError(intervalError);
          return;
        }
      } else if (triggerType === "calendar") {
        if (calendarLoading) {
          setError("Calendars are still loading. Wait, then retry.");
          return;
        }
        if (calendars.length === 0 && calendarError) {
          setError(`Calendars are unavailable. ${calendarError}`);
          return;
        }
        // Fail-closed lead-time window so prep fires close enough to be
        // useful without sweeping months of meetings on a typo.
        const leadTimeError = validateCalendarLeadTimeMinutes(
          calendarLeadTimeMinutes,
        );
        if (leadTimeError) {
          setError(leadTimeError);
          return;
        }
        // Stale edit titles never save: every selected calendar must
        // still appear in the live list, or the step blocks fail-closed.
        if (calendars.length > 0) {
          const liveTitles = new Set(calendars.map((entry) => entry.title));
          const unknown = selectedCalendars.filter((title) => !liveTitles.has(title));
          if (unknown.length > 0) {
            setError(`Selected calendar${unknown.length > 1 ? "s" : ""} no longer available: ${unknown.join(", ")}. Choose from the live list.`);
            return;
          }
        } else if (selectedCalendars.length > 0) {
          setError("Selected calendars are no longer available. Choose from the live list.");
          return;
        }
        const intervalError = validateCheckInterval(pollIntervalText);
        if (intervalError) {
          setError(intervalError);
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
        if (calendars.length === 0 && calendarError) {
          setError(`Calendars are unavailable. ${calendarError}`);
          setSaving(false);
          return;
        }
        if (calendars.length > 0) {
          const liveTitles = new Set(calendars.map((entry) => entry.title));
          const unknown = selectedCalendars.filter((title) => !liveTitles.has(title));
          if (unknown.length > 0) {
            setError(`Selected calendar${unknown.length > 1 ? "s" : ""} no longer available: ${unknown.join(", ")}. Choose from the live list.`);
            setSaving(false);
            return;
          }
        } else if (selectedCalendars.length > 0) {
          setError("Selected calendars are no longer available. Choose from the live list.");
          setSaving(false);
          return;
        }
        const intervalError = validateCheckInterval(pollIntervalText);
        if (intervalError) {
          setError(intervalError);
          setSaving(false);
          return;
        }
      }
      if (triggerType === "email") {
        if (!pollAccount.trim()) {
          setError("Mail Account is required. Select an account.");
          setSaving(false);
          return;
        }
        const allAccounts = pollAccount.trim() === "*";
        if (!allAccounts) {
          if (mailboxes.length === 0 && mailboxError) {
            setError(`Mailbox list is unavailable for this account. ${mailboxError}`);
            setSaving(false);
            return;
          }
          if (!pollMailbox.trim()) {
            setError("Mailbox is required. Select a mailbox.");
            setSaving(false);
            return;
          }
          if (mailboxes.length > 0 && !mailboxes.includes(pollMailbox.trim())) {
            setError("Selected mailbox is no longer available. Choose a mailbox from the live list.");
            setSaving(false);
            return;
          }
        } else if (pollMailbox.trim()) {
          if (mailboxes.length === 0 && mailboxError) {
            setError(`Mailbox list is unavailable for this account. ${mailboxError}`);
            setSaving(false);
            return;
          }
          if (mailboxes.length > 0 && !mailboxes.includes(pollMailbox.trim())) {
            setError("Selected mailbox is no longer available. Choose a mailbox from the live list.");
            setSaving(false);
            return;
          }
        }
        const predicateError = validatePollPredicates(predicates);
        if (predicateError) {
          setError(predicateError);
          setSaving(false);
          return;
        }
      }
      if (triggerType === "email" || triggerType === "messages" || triggerType === "calendar") {
        const intervalError = validateCheckInterval(pollIntervalText);
        if (intervalError) {
          setError(intervalError);
          setSaving(false);
          return;
        }
      }
      const canonicalRules = rules.map((rule) => normalizeEventRule(rule));

      if (triggerType === "cron") {
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: effectiveCron(selectedPreset, customCron),
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
        const pollIntervalSeconds = parsePollIntervalSeconds(pollIntervalText);
        if (
          pollIntervalSeconds == null ||
          pollIntervalSeconds < CHECK_INTERVAL_MIN_SECONDS ||
          pollIntervalSeconds > CHECK_INTERVAL_MAX_SECONDS
        ) {
          setError(
            `Check Interval must be between ${CHECK_INTERVAL_MIN_SECONDS} and ${CHECK_INTERVAL_MAX_SECONDS} seconds.`,
          );
          setSaving(false);
          return;
        }
        const pollLimitError = validatePollLimit(pollLimit);
        if (pollLimitError) {
          setError(pollLimitError);
          setSaving(false);
          return;
        }
        const predicatePayload = predicatesToPayload(predicates);
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: "",
          prompt: prompt.trim(),
          enabled,
          // Email edits reset the whole poll trigger first so removed rows
          // clear instead of lingering; present rows re-apply below.
          clearPoll: true,
          watcherSource: "email",
          rules: canonicalRules.length > 0 ? canonicalRules : null,
          pollAccount: pollAccount.trim(),
          pollMailbox: pollMailbox.trim(),
          pollContains: predicatePayload.pollContains,
          pollFrom: predicatePayload.pollFrom,
          pollSubject: predicatePayload.pollSubject,
          pollUnreadOnly: predicatePayload.pollUnreadOnly,
          pollSinceDays: predicatePayload.pollSinceDays,
          pollQuery: predicatePayload.pollQuery,
          pollIntervalSeconds,
          pollLimit,
          maxToolIterations,
          onToolLimit: onToolLimitValue,
          ...(shouldClearToolBudget ? { clearToolBudget: true } : {}),
        };
        await onSave(payload, jobToEdit?.id);
      } else if (triggerType === "messages") {
        const pollIntervalSeconds =
          parsePollIntervalSeconds(pollIntervalText) ?? CHECK_INTERVAL_MIN_SECONDS;
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
        const pollIntervalSeconds =
          parsePollIntervalSeconds(pollIntervalText) ?? CHECK_INTERVAL_MIN_SECONDS;
        const payload: NewSchedulerJobInput | UpdateSchedulerJobInput = {
          name: name.trim(),
          schedule: "",
          prompt: prompt.trim(),
          enabled,
          watcherSource: "calendar",
          rules: canonicalRules.length > 0 ? canonicalRules : null,
          calendarLeadTimeMinutes,
          calendarNames: selectedCalendars.length > 0 ? selectedCalendars : null,
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

  const predicatePreview = pollPredicatePreview(predicates);

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
        <div className="progress-track">
          <div
            className="progress-fill"
            style={{ width: `${(step / 4) * 100}%` }}
          />
        </div>

        <div className="modal-body wizard-body">
          {error ? <div className="error-banner">{error}</div> : null}

          {/* STEP 1: Type & Name */}
          {step === 1 && (
            <div className="wizard-step">
              <div className="form-label">
                Job Name <InfoTip text="Name shown in the schedules list. Must not be empty." label="Naming guidance" />
                <input
                  type="text"
                  aria-label="Job Name"
                  placeholder="e.g. Morning Inbox Summary"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  autoFocus
                />
              </div>

              <div className="form-label mt-4">
                <span>Select Trigger Type <InfoTip text="Time runs on a cron schedule. Watchers poll mail, messages, or calendars." label="Trigger guidance" /></span>
              </div>
              <div className="trigger-card-grid">
                <button
                  type="button"
                  className={`trigger-card ${triggerType === "cron" ? "selected" : ""}`}
                  onClick={() => setTriggerType("cron")}
                  aria-pressed={triggerType === "cron"}
                >
                  <div className="trigger-card-header">
                    <ClockIcon size={20} className="trigger-icon" />
                    <strong>Scheduled Time</strong>
                  </div>
                  <p>
                    Runs automatically on a repeating timer, hourly, daily, or
                    custom cron schedule.
                  </p>
                </button>

                {hasNoAccounts ? (
                  <div
                    className="trigger-card disabled"
                    aria-disabled="true"
                    data-disabled="true"
                  >
                    <div className="trigger-card-header">
                      <MailIcon size={20} className="trigger-icon" />
                      <strong>Email Event Watcher</strong>
                      <InfoTip
                        text="No mail accounts are configured. Add one in Settings to enable email watching."
                        label="Unavailable watcher info"
                      />
                    </div>
                    <p>
                      Watches inbox for incoming emails and dispatches custom rules or
                      agent actions.
                    </p>
                    <span className="muted text-xs">
                      No mail accounts configured.
                    </span>
                  </div>
                ) : (
                  <button
                    type="button"
                    className={`trigger-card ${triggerType === "email" ? "selected" : ""}`}
                    onClick={() => setTriggerType("email")}
                    aria-pressed={triggerType === "email"}
                  >
                    <div className="trigger-card-header">
                      <MailIcon size={20} className="trigger-icon" />
                      <strong>Email Event Watcher</strong>
                    </div>
                    <p>
                      Watches inbox for incoming emails and dispatches custom rules or
                      agent actions.
                    </p>
                  </button>
                )}

                <button
                  type="button"
                  className={`trigger-card ${triggerType === "messages" ? "selected" : ""}`}
                  onClick={() => setTriggerType("messages")}
                  aria-pressed={triggerType === "messages"}
                >
                  <div className="trigger-card-header">
                    <ChatIcon size={20} className="trigger-icon" />
                    <strong>Messages Watcher</strong>
                  </div>
                  <p>
                    Watches Apple Messages for new inbound texts or group chats.
                  </p>
                </button>

                <button
                  type="button"
                  className={`trigger-card ${triggerType === "calendar" ? "selected" : ""}`}
                  onClick={() => setTriggerType("calendar")}
                  aria-pressed={triggerType === "calendar"}
                >
                  <div className="trigger-card-header">
                    <CalendarIcon size={20} className="trigger-icon" />
                    <strong>Calendar Watcher</strong>
                  </div>
                  <p>
                    Monitors upcoming meetings with lead time for meeting prep and briefs.
                  </p>
                </button>
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
                    <button
                      key={preset.id}
                      type="button"
                      className={`preset-card ${isSelected ? "selected" : ""}`}
                      onClick={() => setSelectedPreset(preset.id)}
                      aria-pressed={isSelected}
                    >
                      <div className="preset-card-title">{preset.label}</div>
                      <div className="preset-card-desc">{preset.description}</div>
                      {preset.cron ? (
                        <div className="preset-cron-tag font-mono">{preset.cron}</div>
                      ) : null}
                    </button>
                  );
                })}
              </div>

              {selectedPreset === "custom" && (
                <div className="form-label mt-4">
                  Custom Cron Expression <InfoTip text="Five-field cron: minute hour day month weekday." label="Cron format guidance" />
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
                </div>
              )}
            </div>
          )}

          {step === 2 && triggerType === "email" && (
            <div className="wizard-step">
              <h4>Configure Email Watcher</h4>
              <div className="form-grid">
                <div className="form-label">
                  Mail Account <InfoTip text="Configured mail account to watch. Choose All accounts to poll every account." label="Account selection guidance" />
                  <select
                    aria-label="Mail Account"
                    value={pollAccount}
                    disabled={accountsLoading}
                    onChange={(e) => {
                      // Clearing the mailbox keeps a stale folder from
                      // following the account switch.
                      setPollAccount(e.target.value);
                      setPollMailbox("");
                    }}
                    required
                  >
                    <option value="*">All accounts</option>
                    {emailAccountNames.map((accountName) => (
                      <option key={accountName} value={accountName}>
                        {accountName}
                      </option>
                    ))}
                  </select>
                  {accountsLoading ? (
                    <span className="muted text-xs">Loading accounts…</span>
                  ) : null}
                </div>

                <div className="form-label">
                  Mailbox <InfoTip text="Mailbox to poll. Required unless All accounts, where blank polls every mailbox." label="Folder selection guidance" />
                  <select
                    aria-label="Mailbox"
                    value={pollMailbox}
                    disabled={!pollAccount || mailboxLoading}
                    onChange={(e) => setPollMailbox(e.target.value)}
                    required={pollAccount.trim() !== "*"}
                  >
                    <option value="">{pollAccount.trim() === "*" ? "Every mailbox (all)" : "Select a mailbox…"}</option>
                    {mailboxes.map((mailboxName) => (
                      <option key={mailboxName} value={mailboxName}>
                        {mailboxName}
                      </option>
                    ))}
                  </select>
                  {mailboxLoading ? (
                    <span className="muted text-xs">Loading mailboxes…</span>
                  ) : null}
                  {mailboxStale ? (
                    <span className="badge badge-amber">
                      Stale cache {formatCacheAge(mailboxStaleAgeMs)}
                    </span>
                  ) : null}
                  {mailboxStale || (mailboxError && mailboxes.length > 0) ? (
                    <span className="muted text-xs">
                      Showing cached mailboxes.{" "}
                      <button type="button" className="ghost" onClick={reloadMailboxes}>
                        Retry
                      </button>
                    </span>
                  ) : null}
                  {mailboxError && mailboxes.length === 0 ? (
                    <span className="muted text-xs">
                      {mailboxError}{" "}
                      <button type="button" className="ghost" onClick={reloadMailboxes}>
                        Retry
                      </button>
                    </span>
                  ) : null}
                </div>
              </div>

              <div className="form-label mt-4">
                <span>
                  Filter predicates <InfoTip text="Optional mail filters combined with AND. Leave empty to match all mail." label="Filter guidance" />
                </span>
                <div className="predicate-list">
                  {predicates.map((predicate, index) => (
                    <div key={index} className="row predicate-row">
                      <select
                        aria-label={`Predicate ${index + 1} operator`}
                        value={predicate.kind}
                        onChange={(e) =>
                          handlePredicateKindChange(
                            index,
                            e.target.value as PollPredicate["kind"],
                          )
                        }
                      >
                        <option value="contains">Contains</option>
                        <option value="from">From</option>
                        <option value="subject">Subject</option>
                        <option value="unread">Unread-only</option>
                        <option value="sinceDays">Since-days</option>
                      </select>
                      {predicate.kind === "unread" ? null : predicate.kind ===
                        "sinceDays" ? (
                        <span className="row">
                          <span className="template-pill-group">
                            {POLL_SINCE_PRESETS.map((preset) => (
                              <button
                                key={preset}
                                type="button"
                                className="template-pill"
                                aria-pressed={predicate.days === preset}
                                onClick={() =>
                                  setPredicates(
                                    predicates.map((row, i) =>
                                      i === index
                                        ? { kind: "sinceDays", days: preset }
                                        : row,
                                    ),
                                  )
                                }
                              >
                                {preset}d
                              </button>
                            ))}
                          </span>
                          <input
                            type="number"
                            aria-label={`Predicate ${index + 1} days`}
                            min={POLL_SINCE_DAYS_MIN}
                            max={POLL_SINCE_DAYS_MAX}
                            value={predicate.days ?? 7}
                            onChange={(e) =>
                              setPredicates(
                                predicates.map((row, i) =>
                                  i === index
                                    ? {
                                        kind: "sinceDays",
                                        days: Number(e.target.value),
                                      }
                                    : row,
                                ),
                              )
                            }
                          />
                        </span>
                      ) : (
                        <input
                          type="text"
                          aria-label={`Predicate ${index + 1} value`}
                          placeholder={
                            predicate.kind === "from"
                              ? "e.g. alerts@example.com"
                              : predicate.kind === "subject"
                                ? "e.g. Invoice"
                                : "e.g. invoice"
                          }
                          value={predicate.value ?? ""}
                          onChange={(e) =>
                            setPredicates(
                              predicates.map((row, i) =>
                                i === index
                                  ? { ...row, value: e.target.value }
                                  : row,
                              ),
                            )
                          }
                        />
                      )}
                      <button
                        type="button"
                        className="ghost"
                        aria-label={`Remove predicate ${index + 1}`}
                        onClick={() => handleRemovePredicate(index)}
                      >
                        Remove
                      </button>
                    </div>
                  ))}
                </div>
                <div className="row mt-2">
                  <button
                    type="button"
                    className="ghost"
                    onClick={handleAddPredicate}
                    disabled={predicates.length >= MAX_POLL_PREDICATES}
                  >
                    Add predicate
                  </button>
                  <span className="muted text-xs">
                    {predicates.length}/{MAX_POLL_PREDICATES} predicates. Preview: {predicatePreview}
                  </span>
                </div>
              </div>

              <div className="form-grid mt-4">
                <div className="form-label">
                  Check Interval <InfoTip text="Seconds between mailbox polls. Must be 60 to 86400." label="Email timing guidance" />
                  <span className="template-pill-group">
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
                  </span>
                  <input
                    type="number"
                    aria-label="Check Interval"
                    min={CHECK_INTERVAL_MIN_SECONDS}
                    max={CHECK_INTERVAL_MAX_SECONDS}
                    placeholder="300"
                    value={pollIntervalText}
                    onChange={(e) => setPollIntervalText(e.target.value)}
                  />
                  <span className="muted text-xs">
                    Seconds between polls. Must be between {CHECK_INTERVAL_MIN_SECONDS} and {CHECK_INTERVAL_MAX_SECONDS} seconds.
                  </span>
                </div>

                <div className="form-label">
                  Batch Limit <InfoTip text="Maximum emails per check, 1 to 50. Extra matches are skipped until the next check." label="Batch size guidance" />
                  <input
                    type="number"
                    aria-label="Batch Limit"
                    min={POLL_LIMIT_MIN}
                    max={POLL_LIMIT_MAX}
                    value={pollLimit}
                    onChange={(e) => setPollLimit(Number(e.target.value))}
                  />
                  <span className="muted text-xs">
                    Maximum emails per check, {POLL_LIMIT_MIN} to {POLL_LIMIT_MAX}. Extra matches are skipped until the next check.
                  </span>
                </div>
              </div>

              <EventRuleBuilder source="email" rules={rules} onChange={setRules} />
            </div>
          )}

          {step === 2 && triggerType === "messages" && (
            <div className="wizard-step">
              <h4>Configure Messages Watcher</h4>
              <div className="form-grid">
                <div className="form-label">
                  Check Interval <InfoTip text="Seconds between Messages polls. Must be 60 to 86400." label="Messages timing guidance" />
                  <span className="template-pill-group">
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
                  </span>
                  <input
                    type="number"
                    aria-label="Check Interval"
                    min={CHECK_INTERVAL_MIN_SECONDS}
                    max={CHECK_INTERVAL_MAX_SECONDS}
                    placeholder="60"
                    value={pollIntervalText}
                    onChange={(e) => setPollIntervalText(e.target.value)}
                  />
                  <span className="muted text-xs">
                    Seconds between polls. Must be between {CHECK_INTERVAL_MIN_SECONDS} and {CHECK_INTERVAL_MAX_SECONDS} seconds.
                  </span>
                </div>
              </div>

              <EventRuleBuilder source="messages" rules={rules} onChange={setRules} />
            </div>
          )}

          {step === 2 && triggerType === "calendar" && (
            <div className="wizard-step">
              <h4>Configure Calendar Watcher</h4>
              <div className="form-grid">
                <div className="form-label">
                  Meeting Lead Time <InfoTip text="Minutes before a meeting to trigger prep. Must be 5 to 120." label="Prep timing guidance" />
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
                </div>

                <div className="form-label">
                  <span>
                    Calendars <InfoTip text="Calendars to watch. Leave all unchecked to watch all calendars." label="Calendar selection guidance" />
                  </span>
                  {calendarLoading ? (
                    <span className="muted text-xs">Loading calendars…</span>
                  ) : calendarError && calendars.length === 0 ? (
                    <span className="muted text-xs">
                      {calendarError}{" "}
                      <button type="button" className="ghost" onClick={reloadCalendars}>
                        Retry
                      </button>
                    </span>
                  ) : calendars.length === 0 ? (
                    <span className="muted text-xs">No calendars found.</span>
                  ) : (
                    <span className="calendar-checkbox-list">
                      {calendars.map((calendar) => (
                        <span key={calendar.id} className="checkbox-row">
                          <input
                            type="checkbox"
                            aria-label={calendar.title}
                            checked={selectedCalendars.includes(calendar.title)}
                            onChange={(e) => {
                              if (e.target.checked) {
                                setSelectedCalendars([...selectedCalendars, calendar.title]);
                              } else {
                                setSelectedCalendars(
                                  selectedCalendars.filter((title) => title !== calendar.title),
                                );
                              }
                            }}
                          />
                          <span>{calendar.title}</span>
                        </span>
                      ))}
                    </span>
                  )}
                  {calendarStale ? (
                    <span className="badge badge-amber">
                      Stale cache {formatCacheAge(calendarStaleAgeMs)}
                    </span>
                  ) : null}
                  {calendarStale ? (
                    <span className="muted text-xs">
                      Showing cached calendars.{" "}
                      <button type="button" className="ghost" onClick={reloadCalendars}>
                        Retry
                      </button>
                    </span>
                  ) : null}
                  <span className="muted text-xs">
                    Leave all unchecked to watch all calendars.
                  </span>
                </div>

                <div className="form-label">
                  Check Interval <InfoTip text="Seconds between calendar checks. Must be 60 to 86400." label="Calendar timing guidance" />
                  <span className="template-pill-group">
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
                  </span>
                  <input
                    type="number"
                    aria-label="Check Interval"
                    min={CHECK_INTERVAL_MIN_SECONDS}
                    max={CHECK_INTERVAL_MAX_SECONDS}
                    placeholder="60"
                    value={pollIntervalText}
                    onChange={(e) => setPollIntervalText(e.target.value)}
                  />
                  <span className="muted text-xs">
                    Seconds between checks. Must be between {CHECK_INTERVAL_MIN_SECONDS} and {CHECK_INTERVAL_MAX_SECONDS} seconds.
                  </span>
                </div>
              </div>

              <EventRuleBuilder source="calendar" rules={rules} onChange={setRules} />
            </div>
          )}

          {/* STEP 3: Agent Task Prompt */}
          {step === 3 && (
            <div className="wizard-step">
              <div className="form-label">
                {rules.length > 0 ? (
                  <span>
                    Fallback Agent Prompt (Optional) <InfoTip text="Runs when an event matches no rule. Leave empty to ignore unmatched events." label="Fallback guidance" />
                    <span className="muted text-xs block font-normal mt-0.5">
                      Runs when an incoming event arrives but does not match any configured rule.
                      Leave empty to ignore unmatched events.
                    </span>
                  </span>
                ) : (
                  <span>
                    Agent Task Instructions <InfoTip text="What the agent should do each time this schedule fires." label="Task guidance" />
                    <span className="muted text-xs block font-normal mt-0.5">
                      What should the agent do each time this schedule fires?
                    </span>
                  </span>
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
              </div>

              <details className="mt-3">
                <summary>Advanced: tool budget</summary>
                <div className="mt-2 space-y-2">
                  <div className="form-label">
                    Max tool rounds <InfoTip text="Maximum tool rounds per run. Blank uses the schedule default." label="Budget guidance" />
                    <input
                      type="number"
                      aria-label="Max tool rounds (blank uses schedule default)"
                      min={TOOL_ROUNDS_MIN}
                      max={TOOL_ROUNDS_MAX}
                      step={1}
                      value={maxToolRoundsText}
                      onChange={(e) => setMaxToolRoundsText(e.target.value)}
                    />
                  </div>
                  <div className="form-label">
                    On tool limit <InfoTip text="What happens when the tool budget is exhausted. Park asks for approval." label="Limit handling guidance" />
                    <select
                      aria-label="On tool limit"
                      value={onToolLimit}
                      onChange={(e) => setOnToolLimit(e.target.value)}
                    >
                      <option value="">Use default (synthesize)</option>
                      <option value="fail">Synthesize summary (fail)</option>
                      <option value="park">Park for approval (park)</option>
                    </select>
                  </div>
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

              <div className="checkbox-row mt-4">
                <input
                  type="checkbox"
                  id="wizard-enable-schedule"
                  checked={enabled}
                  onChange={(e) => setEnabled(e.target.checked)}
                />
                <label htmlFor="wizard-enable-schedule">
                  <span>Enable this schedule immediately </span>
                </label>
                <InfoTip text="Turn on to run immediately after saving. Off saves paused." label="Enabling guidance" />
              </div>
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
                      ? effectiveCron(selectedPreset, customCron)
                      : triggerType === "email"
                      ? `Watches ${pollAccount || "…"} (${pollMailbox || (pollAccount.trim() === "*" ? "every mailbox" : "…")}) every ${pollIntervalText.trim() || "…"}s`
                      : triggerType === "messages"
                      ? `Watches Messages every ${pollIntervalText.trim() || "…"}s`
                      : `Watches Calendar (lead time ${calendarLeadTimeMinutes}m)`}
                  </span>
                </div>
                {triggerType === "email" ? (
                  <div className="review-row">
                    <span className="review-label">Filters:</span>
                    <span>{predicatePreview}</span>
                  </div>
                ) : null}
                {triggerType === "calendar" ? (
                  <div className="review-row">
                    <span className="review-label">Calendars:</span>
                    <span>
                      {selectedCalendars.length > 0
                        ? selectedCalendars.join(", ")
                        : "All calendars"}
                    </span>
                  </div>
                ) : null}
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
