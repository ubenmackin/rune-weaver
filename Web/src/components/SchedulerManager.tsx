// Rune Weaver Dashboard — Scheduler manager for automated jobs with Wizard creation and embedded run history.
// Supports exclusive Recurring Schedules or Email Event Watchers with full run inspection.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  cancelScheduledSend,
  createJob,
  DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS,
  deleteJob,
  formatRunDuration,
  getSettings,
  isActiveRunStatus,
  listJobs,
  listRuns,
  listScheduledSends,
  RUN_LOG_POLL_LIMIT,
  RUN_POLL_INTERVAL_MS,
  runJobNow,
  schedulerJobEffectiveMaxToolIterations,
  schedulerMaxToolIterations,
  TOOL_ROUNDS_MAX,
  TOOL_ROUNDS_MIN,
  updateJob,
  type NewSchedulerJobInput,
  type RunLogEntry,
  type ScheduledSend,
  type SchedulerJob,
  type UpdateSchedulerJobInput,
} from "../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../hooks/useSharedWebSocket";
import { formatRelativeAgo, formatRelativeIn } from "../relativeTime";
import RunDetailModal from "./RunDetailModal";
import ScheduleWizardModal from "./ScheduleWizardModal";
import Modal from "./Modal";
import {
  CalendarIcon,
  ChatIcon,
  ClockIcon,
  CloseIcon,
  EditIcon,
  MailIcon,
  PlusIcon,
  RefreshIcon,
  TrashIcon,
} from "./icons";

export default function SchedulerManager() {
  const [jobs, setJobs] = useState<SchedulerJob[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [schedulerDefault, setSchedulerDefault] = useState<number | null>(null);
  const [schedulerBudgetsLoading, setSchedulerBudgetsLoading] = useState(true);

  // Wizard state
  const [wizardOpen, setWizardOpen] = useState(false);
  const [editingJob, setEditingJob] = useState<SchedulerJob | null>(null);

  // Action states
  const [runningJobId, setRunningJobId] = useState<string | null>(null);
  const [togglingJobId, setTogglingJobId] = useState<string | null>(null);
  // Non-blocking delete confirmation: the pending job renders an inline
  // confirm dialog instead of a blocking native prompt.
  const [pendingDelete, setPendingDelete] = useState<SchedulerJob | null>(null);
  const [deletingJobId, setDeletingJobId] = useState<string | null>(null);

  // Job run history inspection
  const [expandedRunsJobId, setExpandedRunsJobId] = useState<string | null>(null);
  const [jobRuns, setJobRuns] = useState<Record<string, RunLogEntry[]>>({});
  const [loadingRunsJobId, setLoadingRunsJobId] = useState<string | null>(null);
  const [selectedRun, setSelectedRun] = useState<RunLogEntry | null>(null);

  // Booked delayed sends pending their fire time. Terminal rows settle in run
  // history, so only queued/sending rows stay visible here.
  const [sends, setSends] = useState<ScheduledSend[]>([]);
  const [sendsLoading, setSendsLoading] = useState(false);
  const [cancellingSendId, setCancellingSendId] = useState<string | null>(null);

  const refreshSends = useCallback(async () => {
    setSendsLoading(true);
    try {
      const response = await listScheduledSends();
      const pending = (response.sends || [])
        .filter((send) => send.status === "queued" || send.status === "sending")
        .sort((a, b) => {
          const aMs = new Date(a.fireAt).getTime();
          const bMs = new Date(b.fireAt).getTime();
          if (!Number.isFinite(aMs) && !Number.isFinite(bMs)) return 0;
          if (!Number.isFinite(aMs)) return 1;
          if (!Number.isFinite(bMs)) return -1;
          return aMs - bMs;
        });
      setSends(pending);
    } catch {
      // Fail-soft like the jobs list: keep the retained rows on a bad read.
    } finally {
      setSendsLoading(false);
    }
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listJobs();
      setJobs(response.jobs);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Schedules failed");
    } finally {
      setLoading(false);
    }
    void refreshSends();
  }, [refreshSends]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    listJobs()
      .then((response) => {
        if (!cancelled) setJobs(response.jobs);
      })
      .catch((failure) => {
        if (!cancelled) {
          setError(failure instanceof ApiError ? failure.message : "Schedules failed");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    // Check for in-progress runs on mount to restore "Running..." state across page navigation
    listRuns(RUN_LOG_POLL_LIMIT)
      .then((res) => {
        if (cancelled) return;
        const running = res.runs.find((r) => isActiveRunStatus(r.status) && r.jobID);
        if (running && running.jobID) {
          setRunningJobId(running.jobID);
        }
      })
      .catch(() => {});

    // Live scheduler budget rides GET /settings so the header and row badges
    // track the stored section default without a restart.
    getSettings()
      .then((settings) => {
        if (!cancelled) setSchedulerDefault(schedulerMaxToolIterations(settings));
      })
      .catch(() => {
        if (!cancelled) setSchedulerDefault(null);
      })
      .finally(() => {
        if (!cancelled) setSchedulerBudgetsLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    void refreshSends();
  }, [refreshSends]);

  const handleSendsFrame = useCallback(
    (frame: WSIncomingFrame) => {
      if ((frame as { type?: string }).type === "run_completed") {
        void refreshSends();
      }
    },
    [refreshSends],
  );

  const handleSendsSocketOpen = useCallback(() => {
    void refreshSends();
  }, [refreshSends]);

  useSharedWebSocket(handleSendsFrame, undefined, handleSendsSocketOpen);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        void refreshSends();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [refreshSends]);

  // Poll while a job is running to detect completion and refresh runs
  useEffect(() => {
    if (!runningJobId) return;

    const interval = setInterval(() => {
      listRuns(RUN_LOG_POLL_LIMIT)
        .then((res) => {
          const isStillRunning = res.runs.some(
            (r) => isActiveRunStatus(r.status) && r.jobID === runningJobId
          );
          if (!isStillRunning) {
            setRunningJobId(null);
            if (expandedRunsJobId) {
              void fetchJobRuns(expandedRunsJobId);
            }
          }
        })
        .catch(() => {});
    }, RUN_POLL_INTERVAL_MS);

    return () => clearInterval(interval);
  }, [runningJobId, expandedRunsJobId]);

  // Keep selected modal updated if its run changes
  useEffect(() => {
    if (!selectedRun) return;
    const currentList = selectedRun.jobID ? jobRuns[selectedRun.jobID] : undefined;
    if (currentList) {
      const updated = currentList.find((r) => r.id === selectedRun.id);
      if (updated && (updated.status !== selectedRun.status || updated.response !== selectedRun.response)) {
        setSelectedRun(updated);
      }
    }
  }, [jobRuns, selectedRun]);

  async function handleToggle(job: SchedulerJob) {
    setTogglingJobId(job.id);
    setError(null);
    try {
      const updated = await updateJob(job.id, { enabled: !job.enabled });
      setJobs((prev) => prev.map((j) => (j.id === job.id ? updated : j)));
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Toggle failed");
    } finally {
      setTogglingJobId(null);
    }
  }

  async function confirmDelete() {
    if (!pendingDelete) return;
    const job = pendingDelete;
    setDeletingJobId(job.id);
    try {
      await deleteJob(job.id);
      setJobs((prev) => prev.filter((j) => j.id !== job.id));
      // Dropping the owning schedule orphans its drawer state, so collapse
      // the embedded history and dismiss a detail view bound to its runs.
      if (expandedRunsJobId === job.id) {
        setExpandedRunsJobId(null);
      }
      if (selectedRun?.jobID === job.id) {
        setSelectedRun(null);
      }
      setJobRuns((prev) => {
        if (!(job.id in prev)) return prev;
        const next = { ...prev };
        delete next[job.id];
        return next;
      });
      setPendingDelete(null);
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Delete failed");
    } finally {
      setDeletingJobId(null);
    }
  }

  function cancelDelete() {
    setPendingDelete(null);
  }

  async function handleCancelSend(send: ScheduledSend) {
    setCancellingSendId(send.id);
    setError(null);
    setNotice(null);
    try {
      await cancelScheduledSend(send.id);
      setNotice(`Cancelled send to ${send.recipient}`);
      await refreshSends();
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Cancel failed");
    } finally {
      setCancellingSendId(null);
    }
  }

  async function handleRunNow(job: SchedulerJob) {
    setRunningJobId(job.id);
    setError(null);
    setNotice(null);
    try {
      const response = await runJobNow(job.id);
      const preview =
        response.text.length > 160
          ? `${response.text.slice(0, 160)}…`
          : response.text;
      setNotice(`Ran "${job.name}": ${preview || "Completed successfully"}`);

      // Refresh job history if open
      if (expandedRunsJobId === job.id) {
        void fetchJobRuns(job.id);
      }
    } catch (failure) {
      setError(failure instanceof ApiError ? failure.message : "Run failed");
    } finally {
      setRunningJobId(null);
    }
  }

  async function fetchJobRuns(jobID: string) {
    setLoadingRunsJobId(jobID);
    try {
      const res = await listRuns(20, jobID);
      setJobRuns((prev) => ({ ...prev, [jobID]: res.runs }));
    } catch {
      // Ignore
    } finally {
      setLoadingRunsJobId(null);
    }
  }

  function toggleJobRuns(jobID: string) {
    if (expandedRunsJobId === jobID) {
      setExpandedRunsJobId(null);
    } else {
      setExpandedRunsJobId(jobID);
      void fetchJobRuns(jobID);
    }
  }

  async function handleSaveWizard(
    input: NewSchedulerJobInput | UpdateSchedulerJobInput,
    id?: string,
  ) {
    if (id) {
      // Tool-budget clear flows through untouched: an edit-to-blank wizard payload carries
      // clearToolBudget:true alongside null budget keys so the engine returns to inherit.
      const updated = await updateJob(id, input as UpdateSchedulerJobInput);
      setJobs((prev) => prev.map((j) => (j.id === id ? updated : j)));
    } else {
      const created = await createJob(input as NewSchedulerJobInput);
      setJobs((prev) => [created, ...prev]);
    }
    setWizardOpen(false);
    setEditingJob(null);
  }

  return (
    <section className="panel" aria-label="Scheduler manager">
      <div className="panel-header-row">
        <div>
          <h2>Schedules & Automated Jobs</h2>
          <p className="muted text-sm">
            Create repeating cron schedules or event-triggered automated tasks (Email, Messages, Calendar).
          </p>
        </div>

        <div className="row">
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => void refresh()}
            disabled={loading}
          >
            <RefreshIcon size={14} className={loading ? "spin" : ""} />
            <span>{loading ? "Refreshing…" : "Refresh"}</span>
          </button>
          <span className="muted text-sm">{jobs.length} jobs</span>

          <button
            type="button"
            className="primary icon-text-btn"
            onClick={() => {
              setEditingJob(null);
              setWizardOpen(true);
            }}
          >
            <PlusIcon size={14} />
            <span>Create Schedule</span>
          </button>
        </div>
      </div>

      {schedulerBudgetsLoading ? (
        <p className="settings-field-hint">Loading run budgets.</p>
      ) : (
        <p className="settings-field-hint">{`Each run uses ${schedulerDefault ?? DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS} consecutive tool rounds by default (per-job override below, range ${TOOL_ROUNDS_MIN}-${TOOL_ROUNDS_MAX}). Budget-exceeded runs synthesize a summary; only jobs with on_tool_limit set to park request continuation.`}</p>
      )}

      {error ? <p className="error">{error}</p> : null}
      {notice ? <div className="notice-banner">{notice}</div> : null}

      {jobs.length === 0 && !loading ? (
        <div className="empty-state-box">
          <h3>No scheduled jobs yet</h3>
          <p className="muted">
            Automate recurring digests, event watchers (Email, Messages, Calendar), and background analysis.
          </p>
          <button
            type="button"
            className="primary mt-3"
            onClick={() => {
              setEditingJob(null);
              setWizardOpen(true);
            }}
          >
            Create Your First Schedule
          </button>
        </div>
      ) : null}

      <div className="job-cards-list">
        {jobs.map((job) => {
          const watcherSource =
            job.watcherSource || (job.pollAccount ? "email" : undefined);
          const ruleCount = job.rules?.length ?? 0;
          const isExpanded = expandedRunsJobId === job.id;
          const runsForThisJob = jobRuns[job.id] || [];
          const effectiveBudget = schedulerJobEffectiveMaxToolIterations(
            job,
            schedulerDefault,
          );
          const hasBudgetOverride =
            job.maxToolIterations != null || job.onToolLimit != null;
          // Surface the interruption policy alongside the rounds so a park override
          // reads distinctly from an inherited synthesize default.
          const budgetPolicySuffix =
            job.onToolLimit === "park"
              ? " · park"
              : job.onToolLimit
                ? ` · ${job.onToolLimit}`
                : "";

          return (
            <div
              key={job.id}
              className={`schedule-card ${job.enabled ? "active" : "disabled"}`}
            >
              <div className="schedule-card-top">
                <div className="schedule-card-identity">
                  <div className="schedule-card-title-row">
                    <strong className="schedule-card-name">{job.name}</strong>
                    <span className="schedule-card-state-text muted text-xs">
                      {job.enabled ? "enabled" : "disabled"}
                    </span>
                    {watcherSource === "messages" ? (
                      <span className="trigger-badge poll messages">
                        <ChatIcon size={12} />
                        <span>Messages Watcher{ruleCount > 0 ? ` (${ruleCount} rule${ruleCount === 1 ? "" : "s"})` : ""}</span>
                      </span>
                    ) : watcherSource === "calendar" ? (
                      <span className="trigger-badge poll calendar">
                        <CalendarIcon size={12} />
                        <span>Calendar Watcher{ruleCount > 0 ? ` (${ruleCount} rule${ruleCount === 1 ? "" : "s"})` : ""}</span>
                      </span>
                    ) : watcherSource === "email" ? (
                      <span className="trigger-badge poll email">
                        <MailIcon size={12} />
                        <span>
                          Email Watcher{job.pollAccount ? ` (${job.pollAccount})` : ""}
                          {ruleCount > 0 ? ` · ${ruleCount} rule${ruleCount === 1 ? "" : "s"}` : ""}
                        </span>
                      </span>
                    ) : (
                      // Single-line cron badge: the visible text truncates with
                      // ellipsis via CSS while title preserves the full schedule
                      // for hover and assistive reading. Empty schedules fall
                      // back to the "Cron" label so the badge never renders blank.
                      <span
                        className="trigger-badge cron font-mono"
                        title={job.schedule || "Cron"}
                      >
                        <ClockIcon size={12} />
                        <span>{job.schedule || "Cron"}</span>
                      </span>
                    )}
                    <span className="trigger-badge budget">
                      {hasBudgetOverride
                        ? job.maxToolIterations != null
                          ? `${effectiveBudget} rounds${budgetPolicySuffix}`
                          : `Default (${effectiveBudget})${budgetPolicySuffix}`
                        : `Default (${effectiveBudget})`}
                    </span>
                  </div>

                  <div className="schedule-card-details muted text-xs">
                    {watcherSource === "messages" ? (
                      <span>
                        watches Apple Messages every {job.pollIntervalSeconds || 300}s
                        {ruleCount > 0 ? ` · ${ruleCount} rule${ruleCount === 1 ? "" : "s"} configured` : ""}
                      </span>
                    ) : watcherSource === "calendar" ? (
                      <span>
                        watches upcoming meetings ({job.calendarLeadTimeMinutes ?? 15}m lead time) every {job.pollIntervalSeconds || 300}s
                        {job.calendarNames && job.calendarNames.length > 0 ? ` · [${job.calendarNames.join(", ")}]` : ""}
                        {ruleCount > 0 ? ` · ${ruleCount} rule${ruleCount === 1 ? "" : "s"} configured` : ""}
                      </span>
                    ) : watcherSource === "email" ? (
                      <span>
                        watches {job.pollAccount || "email"} · mailbox <code>{job.pollMailbox || "INBOX"}</code>{" "}
                        every {job.pollIntervalSeconds || 300}s
                        {job.pollQuery ? ` · query "${job.pollQuery}"` : ""}
                        {ruleCount > 0 ? ` · ${ruleCount} rule${ruleCount === 1 ? "" : "s"} configured` : ""}
                      </span>
                    ) : (
                      <span>Recurring time-based cron schedule</span>
                    )}
                  </div>
                </div>

                <div className="schedule-card-actions">
                  <button
                    type="button"
                    className={`status-toggle-btn ${
                      job.enabled ? "enabled" : "disabled"
                    }`}
                    onClick={() => void handleToggle(job)}
                    disabled={togglingJobId === job.id}
                    aria-label={job.enabled ? "Disable" : "Enable"}
                  >
                    {togglingJobId === job.id
                      ? "Updating…"
                      : job.enabled
                      ? "Disable"
                      : "Enable"}
                  </button>

                  <button
                    type="button"
                    className="ghost run-now-btn"
                    onClick={() => void handleRunNow(job)}
                    disabled={runningJobId === job.id || !job.enabled}
                    title="Execute this job immediately"
                    aria-label="Run now"
                  >
                    {runningJobId === job.id ? "Running…" : "Run now"}
                  </button>

                  <button
                    type="button"
                    className="icon-button"
                    onClick={() => {
                      setEditingJob(job);
                      setWizardOpen(true);
                    }}
                    title="Edit schedule"
                    aria-label="Edit schedule"
                  >
                    <EditIcon size={15} />
                  </button>

                  <button
                    type="button"
                    className="icon-button danger"
                    onClick={() => setPendingDelete(job)}
                    title="Delete schedule"
                    aria-label="Delete"
                  >
                    <TrashIcon size={15} />
                  </button>
                </div>
              </div>

              {/* Prompt Preview */}
              <div className="schedule-card-prompt">
                <span className="prompt-label">Task:</span>
                <span className="prompt-text">
                  {job.prompt
                    ? job.prompt
                    : ruleCount > 0
                      ? `${ruleCount} rule${ruleCount === 1 ? "" : "s"} configured (${job.rules?.map((r) => r.name).join(", ")})`
                      : "No prompt specified"}
                </span>
              </div>

              {/* Run History Toggle */}
              <div className="schedule-card-footer">
                <button
                  type="button"
                  className="view-history-btn"
                  onClick={() => toggleJobRuns(job.id)}
                >
                  {isExpanded
                    ? "Hide Past Runs"
                    : "View Past Runs"}
                </button>
              </div>

              {/* Embedded Run History Drawer */}
              {isExpanded && (
                <div className="embedded-history-drawer">
                  <h4>Past Runs for "{job.name}"</h4>
                  {loadingRunsJobId === job.id && runsForThisJob.length === 0 ? (
                    <p className="muted text-xs">Loading execution history…</p>
                  ) : null}

                  {runsForThisJob.length === 0 && loadingRunsJobId !== job.id ? (
                    <p className="muted text-xs">
                      No recorded runs yet for this job. Click "Run Now" to test.
                    </p>
                  ) : null}

                  <div className="embedded-runs-list">
                    {runsForThisJob.map((run) => {
                      const duration = formatRunDuration(run.durationMs);
                      return (
                        <div className="embedded-run-item" key={run.id}>
                          <div className="embedded-run-meta">
                            <span className={`status-pill small ${run.status}`}>
                              {run.status === "running" ? "IN PROGRESS" : run.status.toUpperCase()}
                            </span>
                            <span className="text-xs muted">
                              {new Date(run.timestamp).toLocaleString()}
                            </span>
                            {duration ? (
                              <span className="text-xs muted">• {duration}</span>
                            ) : null}
                          </div>

                          {run.response ? (
                            <div className="embedded-run-response">
                              {run.response.slice(0, 180)}
                              {run.response.length > 180 ? "…" : ""}
                            </div>
                          ) : (
                            <div className="embedded-run-response muted">
                              {run.status === "skipped"
                                ? "Skipped (already running)"
                                : run.message}
                            </div>
                          )}

                          <button
                            type="button"
                            className="ghost text-xs view-run-btn"
                            onClick={() => setSelectedRun(run)}
                          >
                            Full Details
                          </button>
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>

      <div className="scheduled-sends-section" aria-label="Scheduled sends">
        <div className="panel-header-row">
          <div>
            <h2>Scheduled sends</h2>
            <p className="muted text-sm">
              Pending delayed sends booked through agent approvals. To change a
              send, cancel it here and ask the agent in chat to re-schedule it.
            </p>
          </div>
          <span className="muted text-sm">
            {sendsLoading ? "Loading…" : `${sends.length} pending`}
          </span>
        </div>

        {sends.length === 0 && !sendsLoading ? (
          <p className="muted text-sm">No scheduled sends</p>
        ) : null}

        <div className="scheduled-sends-list">
          {sends.map((send) => {
            const fireMs = new Date(send.fireAt).getTime();
            const hasFireTime = Number.isFinite(fireMs);
            const relative = hasFireTime
              ? fireMs - Date.now() >= 0
                ? formatRelativeIn(fireMs - Date.now())
                : `${formatRelativeAgo(Date.now() - fireMs)} (overdue)`
              : null;
            return (
              <div key={send.id} className="schedule-card scheduled-send-row">
                <div className="schedule-card-top">
                  <div className="schedule-card-identity">
                    <div className="schedule-card-title-row">
                      {send.channel === "email" ? (
                        <span className="trigger-badge poll email">
                          <MailIcon size={12} />
                          <span>Email</span>
                        </span>
                      ) : (
                        <span className="trigger-badge poll messages">
                          <ChatIcon size={12} />
                          <span>Messages</span>
                        </span>
                      )}
                      <strong className="schedule-card-name">{send.recipient}</strong>
                      <span className="trigger-badge budget">{send.status}</span>
                    </div>
                    <div className="schedule-card-details muted text-xs">
                      {hasFireTime ? (
                        <span>
                          {new Date(send.fireAt).toLocaleString()}
                          {relative ? ` · ${relative}` : ""}
                        </span>
                      ) : (
                        <span>{send.fireAt}</span>
                      )}
                    </div>
                  </div>
                  <div className="schedule-card-actions">
                    <button
                      type="button"
                      className="ghost"
                      onClick={() => void handleCancelSend(send)}
                      disabled={cancellingSendId === send.id}
                      aria-label={`Cancel send to ${send.recipient}`}
                    >
                      {cancellingSendId === send.id ? "Cancelling…" : "Cancel"}
                    </button>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      {/* Creation / Edit Wizard Modal */}
      {wizardOpen && (
        <ScheduleWizardModal
          jobToEdit={editingJob}
          sectionDefault={
            schedulerDefault ?? DEFAULT_SCHEDULER_MAX_TOOL_ITERATIONS
          }
          onSave={handleSaveWizard}
          onClose={() => {
            setWizardOpen(false);
            setEditingJob(null);
          }}
        />
      )}

      {/* Full Run Details Modal */}
      {selectedRun && (
        <RunDetailModal
          run={selectedRun}
          onClose={() => setSelectedRun(null)}
        />
      )}

      {/* Non-blocking delete confirmation via the shared modal so the
          dialog portals above page stacking contexts with Escape support. */}
      {pendingDelete && (
        <Modal
          label="Confirm delete schedule"
          onClose={() => {
            if (deletingJobId === pendingDelete.id) return;
            cancelDelete();
          }}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete schedule?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelDelete}
              disabled={deletingJobId === pendingDelete.id}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted" style={{ margin: 0 }}>
              Delete schedule &quot;{pendingDelete.name}&quot;? This cannot be
              undone.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelDelete}
              disabled={deletingJobId === pendingDelete.id}
            >
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmDelete()}
              disabled={deletingJobId === pendingDelete.id}
              aria-label="Confirm delete"
            >
              {deletingJobId === pendingDelete.id ? "Deleting…" : "Delete"}
            </button>
          </div>
        </Modal>
      )}
    </section>
  );
}
