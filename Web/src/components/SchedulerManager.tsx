// Rune Weaver Dashboard — Scheduler manager for automated jobs with Wizard creation and embedded run history.
// Supports exclusive Recurring Schedules or Email Event Watchers with full run inspection.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  createJob,
  deleteJob,
  isActiveRunStatus,
  listJobs,
  listRuns,
  RUN_LOG_POLL_LIMIT,
  RUN_POLL_INTERVAL_MS,
  runJobNow,
  updateJob,
  type NewSchedulerJobInput,
  type RunLogEntry,
  type SchedulerJob,
  type UpdateSchedulerJobInput,
} from "../api";
import RunDetailModal from "./RunDetailModal";
import ScheduleWizardModal from "./ScheduleWizardModal";
import Modal from "./Modal";
import {
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
  }, []);

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

    return () => {
      cancelled = true;
    };
  }, []);

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
            Create repeating cron schedules or email-triggered automated agent tasks.
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

      {error ? <p className="error">{error}</p> : null}
      {notice ? <div className="notice-banner">{notice}</div> : null}

      {jobs.length === 0 && !loading ? (
        <div className="empty-state-box">
          <h3>No scheduled jobs yet</h3>
          <p className="muted">
            Automate recurring digests, email watchers, and background analysis.
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
          const isPollJob = Boolean(job.pollAccount);
          const isExpanded = expandedRunsJobId === job.id;
          const runsForThisJob = jobRuns[job.id] || [];

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
                    {isPollJob ? (
                      <span className="trigger-badge poll">
                        <MailIcon size={12} />
                        <span>Email Watcher ({job.pollAccount})</span>
                      </span>
                    ) : (
                      <span className="trigger-badge cron font-mono">
                        <ClockIcon size={12} />
                        <span>{job.schedule || "Cron"}</span>
                      </span>
                    )}
                  </div>

                  <div className="schedule-card-details muted text-xs">
                    {isPollJob ? (
                      <span>
                        watches {job.pollAccount} · mailbox <code>{job.pollMailbox || "INBOX"}</code>{" "}
                        every {job.pollIntervalSeconds || 300}s
                        {job.pollQuery ? ` · query "${job.pollQuery}"` : ""}
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
                <span className="prompt-text">{job.prompt}</span>
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
                    {runsForThisJob.map((run) => (
                      <div className="embedded-run-item" key={run.id}>
                        <div className="embedded-run-meta">
                          <span className={`status-pill small ${run.status}`}>
                            {run.status === "running" ? "IN PROGRESS" : run.status.toUpperCase()}
                          </span>
                          <span className="text-xs muted">
                            {new Date(run.timestamp).toLocaleString()}
                          </span>
                          {run.durationMs != null ? (
                            <span className="text-xs muted">
                              • {run.durationMs >= 1000 ? `${(run.durationMs / 1000).toFixed(1)}s` : `${run.durationMs}ms`}
                            </span>
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
                    ))}
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Creation / Edit Wizard Modal */}
      {wizardOpen && (
        <ScheduleWizardModal
          jobToEdit={editingJob}
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
