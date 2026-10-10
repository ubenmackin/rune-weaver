// Rune Weaver Dashboard — Upcoming Schedules (Cadence).
//
// Surfaces automated recurring tasks scheduled to run:
// - Schedule frequency (cron / polling)
// - Fast "Run Now" trigger
// - Direct link to SchedulerManager

import { useCallback, useEffect, useState } from "react";
import {
  listJobs,
  runJobNow,
  type SchedulerJob,
} from "../../api";
import { useSharedWebSocket, type WSIncomingFrame } from "../../hooks/useSharedWebSocket";
import { ChevronRightIcon, ClockIcon, PlusIcon } from "../icons";

interface UpcomingSchedulesProps {
  onOpenSchedules?: () => void;
  onJobTriggered?: () => void;
}

export default function UpcomingSchedules({
  onOpenSchedules,
  onJobTriggered,
}: UpcomingSchedulesProps) {
  const [jobs, setJobs] = useState<SchedulerJob[]>([]);
  const [runningJobId, setRunningJobId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fetchJobs = useCallback(async () => {
    try {
      setError(null);
      const res = await listJobs();
      const enabledJobs = (res.jobs || []).filter((j) => j.enabled);
      setJobs(enabledJobs.slice(0, 4));
    } catch (err) {
      console.warn("Failed to fetch scheduled jobs:", err);
    }
  }, []);

  useEffect(() => {
    fetchJobs();
  }, [fetchJobs]);

  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const frameType = (frame as { type?: string }).type;
      if (
        frameType === "run_started" ||
        frameType === "run_completed"
      ) {
        fetchJobs();
      }
    },
    [fetchJobs],
  );

  const handleSocketOpen = useCallback(() => {
    fetchJobs();
  }, [fetchJobs]);

  useSharedWebSocket(handleWSFrame, undefined, handleSocketOpen);

  // Tab visibility resync ensures returning to the tab immediately refreshes schedules
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        fetchJobs();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [fetchJobs]);

  // Periodic heartbeat polling keeps schedule list and cadence updated
  useEffect(() => {
    const interval = setInterval(fetchJobs, 10000);
    return () => clearInterval(interval);
  }, [fetchJobs]);

  async function handleRunNow(job: SchedulerJob) {
    try {
      setRunningJobId(job.id);
      await runJobNow(job.id);
      onJobTriggered?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to run job");
    } finally {
      setRunningJobId(null);
    }
  }

  return (
    <section className="dashboard-section upcoming-schedules-section" aria-label="Upcoming schedules">
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <ClockIcon size={18} className="dashboard-section-icon accent-purple" />
          <h2 className="dashboard-section-title">Upcoming Schedules</h2>
          {jobs.length > 0 ? (
            <span className="dashboard-count-badge">{jobs.length}</span>
          ) : null}
        </div>
        <button
          type="button"
          className="btn-link view-all-link"
          onClick={() => onOpenSchedules?.()}
        >
          <span>View All</span>
          <ChevronRightIcon size={13} />
        </button>
      </div>

      {error && <div className="notice-banner error">{error}</div>}

      {jobs.length === 0 ? (
        <div className="dashboard-empty-card empty-schedules-card">
          <div className="empty-schedules-content">
            <h3 className="empty-schedules-title">No Active Schedules</h3>
            <p className="empty-schedules-desc">
              Schedule recurring jobs to triage inboxes, monitor repositories, or generate daily reports.
            </p>
            <button
              type="button"
              className="btn new-schedule-btn"
              onClick={() => onOpenSchedules?.()}
            >
              <PlusIcon size={14} />
              <span>Add Schedule</span>
            </button>
          </div>
        </div>
      ) : (
        <div className="upcoming-schedules-list">
          {jobs.map((job) => {
            const isBusy = runningJobId === job.id;

            return (
              <article key={job.id} className="schedule-cockpit-card">
                <div className="schedule-cockpit-main">
                  <div className="schedule-cockpit-title-row">
                    <span className="schedule-dot" />
                    <h3 className="schedule-cockpit-title" title={job.name}>
                      {job.name}
                    </h3>
                  </div>
                  <div className="schedule-cockpit-meta">
                    <span className="schedule-cron-chip text-xs">
                      {job.schedule || "recurring"}
                    </span>
                    {job.pollMailbox && (
                      <span className="poll-chip text-xs muted">
                        mailbox: {job.pollMailbox}
                      </span>
                    )}
                  </div>
                </div>

                <div className="schedule-cockpit-actions">
                  <button
                    type="button"
                    className="btn run-now-btn"
                    onClick={() => handleRunNow(job)}
                    disabled={isBusy}
                    aria-label={`Run schedule now: ${job.name}`}
                  >
                    <span>{isBusy ? "Starting…" : "Run Now"}</span>
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
