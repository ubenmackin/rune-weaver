// Rune Weaver Dashboard — Resolved approval decision history.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ApiError,
  clearApprovalHistory,
  listApprovalHistory,
  parseRunTimestamp,
  type ApprovalHistoryAction,
  type ApprovalHistoryEntry,
} from "../api";
import { truncateTarget } from "../approvalsShared";
import { formatRelativeAgo } from "../relativeTime";
import { useSharedWebSocket, type WSIncomingFrame } from "../hooks/useSharedWebSocket";
import Modal from "./Modal";
import { CloseIcon } from "./icons";

type ActionFilter = "all" | ApprovalHistoryAction;

// Deep link into the Settings → Access pane that owns standing rules.
const STANDING_RULES_HREF = "#settings?access=rules";

// One-line reading of a recorded scope split into kind plus data.
function describeHistoryScope(
  scopeKind: string | null | undefined,
  scopeData: string | null | undefined,
): string {
  const data = typeof scopeData === "string" ? scopeData.trim() : "";
  switch (scopeKind) {
    case "tool":
    case "toolWide":
      return "all targets";
    case "exactTarget":
    case "domain":
    case "pathPrefix":
    case "glob":
      return data || scopeKind;
    case "recipientSet": {
      if (!data) return scopeKind;
      const members = data
        .split(",")
        .map((entry) => entry.trim())
        .filter(Boolean);
      return members.length > 0 ? `${members.length} recipients` : scopeKind;
    }
    default:
      if (data) return scopeKind ? `${scopeKind}: ${data}` : data;
      return scopeKind || "-";
  }
}

// Relative decided label for one history row. An unreadable timestamp reads as
// a hyphen so a drifted row never renders a bogus countdown.
function decidedLabel(decidedAt: ApprovalHistoryEntry["decidedAt"]): string {
  const decidedMs = parseRunTimestamp(decidedAt).getTime();
  if (!Number.isFinite(decidedMs) || decidedMs <= 0) return "-";
  return formatRelativeAgo(Date.now() - decidedMs);
}

export default function ApprovalHistory() {
  const [entries, setEntries] = useState<ApprovalHistoryEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [toolFilter, setToolFilter] = useState("");
  const [actionFilter, setActionFilter] = useState<ActionFilter>("all");
  // Applied copies of the filters: the committed values that drive the list
  // read while the inputs above keep typing.
  const [appliedTool, setAppliedTool] = useState("");
  const [appliedAction, setAppliedAction] = useState<ActionFilter>("all");
  const [refreshKey, setRefreshKey] = useState(0);
  const [clearOpen, setClearOpen] = useState(false);
  const [clearing, setClearing] = useState(false);
  // Monotonic request token so the debounced commit and the post-clear refetch
  // race through the same gate: a slower earlier response can never overwrite the view with rows
  // that disagree with the committed filters, and a response outliving the pane is discarded too.
  const requestSeq = useRef(0);

  // Invalidate every in-flight read on unmount so a late response cannot
  // touch state after the pane is gone.
  useEffect(() => {
    return () => {
      requestSeq.current += 1;
    };
  }, []);

  // Filters commit on a 300ms settle: a burst of keystrokes into the tool input (or a select flip)
  // collapses into one filtered read instead of refetching per character, because every change
  // resets the pending timer.
  useEffect(() => {
    const timer = window.setTimeout(() => {
      setAppliedTool(toolFilter);
      setAppliedAction(actionFilter);
    }, 300);
    return () => window.clearTimeout(timer);
  }, [toolFilter, actionFilter]);

  // Every read carries the committed filters as query params: a blank tool stays omitted so the
  // default call reads the recent window, and the All decision omits the action rather than sending
  // a pseudo-tier the engine would reject.
  const fetchHistory = useCallback(async (tool: string, action: ActionFilter) => {
    const seq = ++requestSeq.current;
    setLoading(true);
    setError(null);
    try {
      const trimmedTool = tool.trim();
      const response = await listApprovalHistory({
        ...(trimmedTool ? { tool: trimmedTool } : {}),
        ...(action === "allowed" || action === "denied" ? { action } : {}),
      });
      // A superseded read (a newer filter commit or a clear refetch already
      // in flight) is dropped whole: rows, error, and the loading flag all
      // stay owned by the newest request.
      if (seq !== requestSeq.current) return;
      setEntries(Array.isArray(response.entries) ? response.entries : []);
    } catch (failure) {
      if (seq !== requestSeq.current) return;
      setEntries([]);
      setError(
        failure instanceof ApiError ? failure.message : "History failed",
      );
    } finally {
      if (seq === requestSeq.current) setLoading(false);
    }
  }, []);

  // Initial load plus every committed filter change: the list always reflects the query params
  // above instead of filtering client-side. The refresh key re-runs an identical read after a
  // clear so the emptied list refetches without a filter change.
  useEffect(() => {
    void fetchHistory(appliedTool, appliedAction);
  }, [fetchHistory, appliedTool, appliedAction, refreshKey]);

  // Mirror of the committed filters so the live refresh paths below re-run the
  // exact read the list effect serves without re-subscribing per commit.
  const appliedRef = useRef({ tool: "", action: "all" as ActionFilter });
  useEffect(() => {
    appliedRef.current = { tool: appliedTool, action: appliedAction };
  }, [appliedTool, appliedAction]);

  const resync = useCallback(() => {
    void fetchHistory(appliedRef.current.tool, appliedRef.current.action);
  }, [fetchHistory]);

  // Resolution frames are the one live refresh path: only an approval_decided or
  // approval_resolved frame proves a history row was written, so a new-prompt
  // approval frame leaves the list alone instead of triggering a wasted read.
  const handleWSFrame = useCallback(
    (frame: WSIncomingFrame) => {
      const type = (frame as { type?: string }).type;
      if (type === "approval_decided" || type === "approval_resolved") {
        resync();
      }
    },
    [resync],
  );

  // Socket reopen is the second path: a decision recorded while the shared
  // connection was down lands on the next dial instead of a manual refresh.
  useSharedWebSocket(handleWSFrame, undefined, resync);

  // Visibility resync is the third: returning to the tab refetches the log so
  // decisions made elsewhere appear without waiting for the next live frame.
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") {
        resync();
      }
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () =>
      document.removeEventListener("visibilitychange", handleVisibility);
  }, [resync]);

  async function confirmClear() {
    setClearing(true);
    setError(null);
    try {
      await clearApprovalHistory();
      setClearOpen(false);
      setRefreshKey((key) => key + 1);
    } catch (failure) {
      setError(
        failure instanceof ApiError ? failure.message : "Clear failed",
      );
    } finally {
      setClearing(false);
    }
  }

  function cancelClear() {
    if (!clearing) setClearOpen(false);
  }

  return (
    <div
      className="approval-history"
      data-testid="approval-history"
      aria-label="Approval history"
    >
      <p
        className="muted text-sm"
        data-testid="approval-history-audit-banner"
      >
        History is an audit trail retained after expiry. Active-timed shows
        live timed trust. Standing rules live in{" "}
        <a href={STANDING_RULES_HREF}>Settings → Access Rules</a>.
      </p>
      <div className="approval-history-filters row">
        <label className="approval-history-filter">
          <span className="text-sm muted">Tool:</span>
          <input
            type="text"
            aria-label="Filter by tool"
            placeholder="Filter by tool"
            value={toolFilter}
            onChange={(event) => setToolFilter(event.target.value)}
          />
        </label>
        <label className="approval-history-filter">
          <span className="text-sm muted">Decision:</span>
          <select
            aria-label="Filter by decision"
            value={actionFilter}
            onChange={(event) =>
              setActionFilter(event.target.value as ActionFilter)
            }
          >
            <option value="all">All</option>
            <option value="allowed">Allowed</option>
            <option value="denied">Denied</option>
          </select>
        </label>
        <button
          type="button"
          className="ghost icon-text-btn"
          onClick={() => setClearOpen(true)}
        >
          <span>Clear logs</span>
        </button>
      </div>

      {error ? <p className="error">{error}</p> : null}
      {entries.length === 0 && !loading ? (
        <div className="approval-history-empty muted">
          <p>No recorded decisions.</p>
        </div>
      ) : null}

      {entries.length > 0 ? (
        <table className="approval-history-table">
          <thead>
            <tr>
              <th scope="col">Decided</th>
              <th scope="col">Tool</th>
              <th scope="col">Target</th>
              <th scope="col">Scope</th>
              <th scope="col">Decision</th>
              <th scope="col">Duration</th>
              <th scope="col">Surface</th>
              <th scope="col">Session</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((entry) => {
              const target =
                typeof entry.displayTarget === "string"
                  ? entry.displayTarget.trim()
                  : "";
              const sessionID =
                typeof entry.sessionID === "string"
                  ? entry.sessionID.trim()
                  : "";
              const decidedDate = parseRunTimestamp(entry.decidedAt);
              return (
                <tr
                  key={entry.id}
                  data-testid={`approval-history-row-${entry.id}`}
                >
                  <td title={decidedDate.getTime() > 0 ? decidedDate.toLocaleString() : undefined}>
                    {decidedLabel(entry.decidedAt)}
                  </td>
                  <td>{entry.toolName}</td>
                  <td>
                    {target ? (
                      <code
                        className="approval-history-target"
                        title={target}
                      >
                        {truncateTarget(target)}
                      </code>
                    ) : (
                      "-"
                    )}
                  </td>
                  <td>{describeHistoryScope(entry.scopeKind, entry.scopeData)}</td>
                  <td>
                    <span
                      className={`badge approval-history-decision approval-history-decision-${entry.allowed ? "allowed" : "denied"}`}
                    >
                      {entry.allowed ? "Allowed" : "Denied"}
                    </span>
                  </td>
                  <td>{entry.duration}</td>
                  <td>{entry.surface}</td>
                  <td>
                    {sessionID ? (
                      <a href={`#chat/${sessionID}`}>Open session</a>
                    ) : (
                      "-"
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : null}

      {clearOpen ? (
        <Modal
          label="Clear decision history"
          onClose={cancelClear}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Clear decision history</h3>
            <button
              type="button"
              className="icon-button"
              onClick={cancelClear}
              disabled={clearing}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted run-modal-paragraph-spaced">
              Clearing will permanently delete all decision history.
            </p>
          </div>
          <div className="modal-footer">
            <button
              type="button"
              className="ghost"
              onClick={cancelClear}
              disabled={clearing}
            >
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => void confirmClear()}
              disabled={clearing}
              aria-label="Confirm clear all decisions"
            >
              {clearing ? "Clearing…" : "Confirm clear all decisions"}
            </button>
          </div>
        </Modal>
      ) : null}
    </div>
  );
}
