// Rune Weaver Dashboard — Scheduler manager for CRUD and manual execution of recurring and poll jobs.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  DEFAULT_POLL_INTERVAL_SECONDS,
  createJob,
  deleteJob,
  listJobs,
  runJobNow,
  updateJob,
  type SchedulerJob,
} from "../api";

function emptyForm() {
  return {
    name: "",
    schedule: "",
    prompt: "",
    enabled: true,
    pollAccount: "",
    pollQuery: "",
    pollMailbox: "",
    pollIntervalSeconds: "",
    pollLimit: "",
  };
}

type PositiveIntParseResult =
  | { kind: "empty" }
  | { kind: "valid"; value: number }
  | { kind: "invalid" };

function parsePositiveInt(text: string): PositiveIntParseResult {
  const trimmed = text.trim();
  if (!trimmed) return { kind: "empty" };
  // Strict decimal only: reject hex/octal/scientific/float spellings that
  // Number() would otherwise accept ("1e3", "0x10", "1.0").
  if (!/^\d+$/.test(trimmed)) return { kind: "invalid" };
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value) || value <= 0) return { kind: "invalid" };
  return { kind: "valid", value };
}

export default function SchedulerManager() {
  const [jobs, setJobs] = useState<SchedulerJob[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [toggling, setToggling] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);
  const [running, setRunning] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await listJobs();
      setJobs(response.jobs);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Schedules failed",
      );
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
          setError(
            failure instanceof ApiError ? failure.message : "Schedules failed",
          );
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function startEdit(job: SchedulerJob) {
    setEditingId(job.id);
    setError(null);
    setNotice(null);
    setForm({
      name: job.name,
      schedule: job.schedule ?? "",
      prompt: job.prompt,
      enabled: job.enabled,
      pollAccount: job.pollAccount ?? "",
      pollQuery: job.pollQuery ?? "",
      pollMailbox: job.pollMailbox ?? "",
      pollIntervalSeconds:
        job.pollIntervalSeconds == null
          ? ""
          : String(job.pollIntervalSeconds),
      pollLimit: job.pollLimit == null ? "" : String(job.pollLimit),
    });
  }

  function cancelEdit() {
    setEditingId(null);
    setForm(emptyForm());
    setError(null);
  }

  async function submit() {
    const name = form.name.trim();
    const schedule = form.schedule.trim();
    const prompt = form.prompt.trim();
    const pollAccount = form.pollAccount.trim();
    if (!name || !prompt) {
      setError("Name and prompt are required.");
      return;
    }
    if (!schedule && !pollAccount) {
      setError("Add a cron schedule or an event rule poll account.");
      return;
    }
    // Single strict parse per submit; reuse intervalParse/limitParse below
    // instead of re-parsing the same strings.
    const intervalParse = parsePositiveInt(form.pollIntervalSeconds);
    if (intervalParse.kind === "invalid") {
      setError("Poll interval must be a positive integer number of seconds.");
      return;
    }
    const interval =
      intervalParse.kind === "valid" ? intervalParse.value : undefined;
    const limitParse = parsePositiveInt(form.pollLimit);
    if (limitParse.kind === "invalid") {
      setError("Poll limit must be a positive integer.");
      return;
    }
    const limit = limitParse.kind === "valid" ? limitParse.value : undefined;
    // Atomic poll validation: poll query/mailbox/interval/limit without a
    // trimmed account would 400 server-side (`*_requires poll_account`);
    // reject client-side so no partial poll payload reaches the server.
    const pollQuery = form.pollQuery.trim();
    const pollMailbox = form.pollMailbox.trim();
    if (
      !pollAccount &&
      (pollQuery || pollMailbox || interval !== undefined || limit !== undefined)
    ) {
      setError("Poll query, mailbox, interval, and limit require a poll account.");
      return;
    }
    setSaving(true);
    setError(null);
    setNotice(null);
    try {
      if (editingId) {
        // Blank poll strings clear to null server-side ("" → null
        // normalization). A cleared interval or limit field (empty) preserves
        // the stored value (omitted = nil = no-change), so edits never
        // silently reset e.g. 600 → 300; a cron-only edit (empty account)
        // sends clearPoll to drop the whole trigger.
        const clearingPoll = !pollAccount;
        const updated = await updateJob(editingId, {
          name,
          schedule,
          prompt,
          enabled: form.enabled,
          pollAccount,
          pollQuery: pollQuery ? pollQuery : "",
          pollMailbox: pollMailbox ? pollMailbox : "",
          ...(clearingPoll
            ? { clearPoll: true }
            : {
                // Interval/limit preservation: omitted leaves the stored
                // value alone; only a valid entry overwrites it.
                ...(interval !== undefined
                  ? { pollIntervalSeconds: interval }
                  : {}),
                ...(limit !== undefined ? { pollLimit: limit } : {}),
              }),
        });
        setJobs((previous) =>
          previous.map((job) => (job.id === updated.id ? updated : job)),
        );
        setNotice(`Saved "${updated.name}".`);
      } else {
        const created = await createJob({
          name,
          schedule,
          prompt,
          enabled: form.enabled,
          ...(pollAccount ? { pollAccount } : {}),
          ...(pollQuery ? { pollQuery } : {}),
          ...(pollMailbox ? { pollMailbox } : {}),
          ...(interval === undefined ? {} : { pollIntervalSeconds: interval }),
          ...(limit === undefined ? {} : { pollLimit: limit }),
        });
        setJobs((previous) => [...previous, created]);
        setNotice(`Created "${created.name}".`);
      }
      setEditingId(null);
      setForm(emptyForm());
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Save failed",
      );
    } finally {
      setSaving(false);
    }
  }

  async function toggleEnabled(job: SchedulerJob) {
    setToggling(job.id);
    setError(null);
    try {
      const updated = await updateJob(job.id, { enabled: !job.enabled });
      setJobs((previous) =>
        previous.map((entry) => (entry.id === updated.id ? updated : entry)),
      );
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Toggle failed",
      );
    } finally {
      setToggling(null);
    }
  }

  async function remove(job: SchedulerJob) {
    setDeleting(job.id);
    setError(null);
    try {
      await deleteJob(job.id);
      setJobs((previous) => previous.filter((entry) => entry.id !== job.id));
      if (editingId === job.id) {
        setEditingId(null);
        setForm(emptyForm());
      }
      setNotice(`Deleted "${job.name}".`);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Delete failed",
      );
    } finally {
      setDeleting(null);
    }
  }

  async function runNow(job: SchedulerJob) {
    setRunning(job.id);
    setError(null);
    setNotice(null);
    try {
      const response = await runJobNow(job.id);
      const preview =
        response.text.length > 160
          ? `${response.text.slice(0, 160)}…`
          : response.text;
      setNotice(`Ran "${job.name}": ${preview || "ok"}`);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Run failed",
      );
    } finally {
      setRunning(null);
    }
  }

  const isEditing = editingId !== null;

  return (
    <section className="panel" aria-label="Scheduler manager">
      <h2>Schedules</h2>
      <div className="row">
        <button
          type="button"
          className="ghost"
          onClick={() => void refresh()}
          disabled={loading}
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
        <span className="muted">{jobs.length} jobs</span>
      </div>
      {error ? <p className="error">{error}</p> : null}
      {notice ? <p className="muted">{notice}</p> : null}

      <div className="card" aria-label="Job form">
        <h3>{isEditing ? "Edit job" : "New job"}</h3>
        <div className="column">
          <label>
            Name{" "}
            <input
              type="text"
              aria-label="Job name"
              placeholder="morning digest"
              value={form.name}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  name: event.target.value,
                }))
              }
            />
          </label>
          <label>
            Cron schedule{" "}
            <input
              type="text"
              aria-label="Cron schedule"
              placeholder="0 8 * * *  (empty for poll-only jobs)"
              value={form.schedule}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  schedule: event.target.value,
                }))
              }
            />
          </label>
          <p className="muted">
            Five fields (minute hour day month weekday) or @hourly, @daily,
            @weekly. Leave empty for poll-only event jobs.
          </p>
          <label>
            Prompt{" "}
            <textarea
              aria-label="Job prompt"
              placeholder="Summarize new mail since yesterday"
              value={form.prompt}
              rows={3}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  prompt: event.target.value,
                }))
              }
            />
          </label>
          <label className="row">
            <input
              type="checkbox"
              aria-label="Job enabled"
              checked={form.enabled}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  enabled: event.target.checked,
                }))
              }
            />
            <span>Enabled</span>
          </label>
          <h4>Event rule (email poll)</h4>
          <p className="muted">
            Optional trigger that watches one mail account for new arrivals. A
            job fires on either trigger when both are set.
          </p>
          <label>
            Poll account{" "}
            <input
              type="text"
              aria-label="Poll account"
              placeholder="icloud (empty for cron-only jobs)"
              value={form.pollAccount}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  pollAccount: event.target.value,
                }))
              }
            />
          </label>
          <label>
            Poll query{" "}
            <input
              type="text"
              aria-label="Poll query"
              placeholder="from:alerts (blank means most-recent)"
              value={form.pollQuery}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  pollQuery: event.target.value,
                }))
              }
            />
          </label>
          <label>
            Poll mailbox{" "}
            <input
              type="text"
              aria-label="Poll mailbox"
              placeholder="INBOX (blank means every mailbox)"
              value={form.pollMailbox}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  pollMailbox: event.target.value,
                }))
              }
            />
          </label>
          <label>
            Poll interval seconds{" "}
            <input
              type="text"
              aria-label="Poll interval seconds"
              placeholder={String(DEFAULT_POLL_INTERVAL_SECONDS)}
              value={form.pollIntervalSeconds}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  pollIntervalSeconds: event.target.value,
                }))
              }
            />
          </label>
          <label>
            Poll limit{" "}
            <input
              type="text"
              aria-label="Poll limit"
              placeholder="10"
              value={form.pollLimit}
              onChange={(event) =>
                setForm((previous) => ({
                  ...previous,
                  pollLimit: event.target.value,
                }))
              }
            />
          </label>
          <div className="row">
            <button
              type="button"
              className="primary"
              disabled={saving}
              onClick={() => void submit()}
            >
              {saving
                ? "Saving…"
                : isEditing
                  ? "Save changes"
                  : "Create job"}
            </button>
            {isEditing ? (
              <button
                type="button"
                className="ghost"
                disabled={saving}
                onClick={cancelEdit}
              >
                Cancel
              </button>
            ) : null}
          </div>
        </div>
      </div>

      {jobs.length === 0 && !loading ? (
        <p className="muted">
          No scheduled jobs yet. Create one above without touching config
          files.
        </p>
      ) : null}
      {jobs.map((job) => (
        <div className="card" key={job.id}>
          <div>
            <strong>{job.name}</strong>{" "}
            <span className="muted">
              {job.enabled ? "enabled" : "disabled"}
            </span>
          </div>
          <div className="muted">
            {job.schedule ? `cron ${job.schedule}` : "poll-only"}
            {job.pollAccount
              ? ` · watches ${job.pollAccount}${job.pollQuery ? ` matching "${job.pollQuery}"` : ""}${job.pollMailbox ? ` in ${job.pollMailbox}` : ""}${job.pollIntervalSeconds ? ` every ${job.pollIntervalSeconds}s` : ""}${job.pollLimit != null ? ` limit ${job.pollLimit}` : ""}`
              : ""}
          </div>
          <div>{job.prompt}</div>
          <div className="row">
            <button
              type="button"
              className="ghost"
              onClick={() => startEdit(job)}
            >
              Edit
            </button>
            <button
              type="button"
              className="ghost"
              disabled={toggling === job.id}
              onClick={() => void toggleEnabled(job)}
            >
              {job.enabled ? "Disable" : "Enable"}
            </button>
            <button
              type="button"
              className="ghost"
              disabled={running === job.id || !job.enabled}
              onClick={() => void runNow(job)}
              title={
                job.enabled ? "Run this job now" : "Enable the job to run it"
              }
            >
              {running === job.id ? "Running…" : "Run now"}
            </button>
            <button
              type="button"
              className="danger"
              disabled={deleting === job.id}
              onClick={() => void remove(job)}
            >
              Delete
            </button>
          </div>
        </div>
      ))}
    </section>
  );
}
