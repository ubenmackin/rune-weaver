// Rune Weaver Dashboard — Shared surfacing-only card for engine-filed system notices.

import { useState } from "react";
import { postSovereignRebaseline, type PermissionRequest } from "../api";
import { SettingsIcon } from "./icons";

export interface SystemNoticeCardProps {
  request: PermissionRequest;
  // Surface the card renders on: the inbox groups notices under System, the
  // dashboard queue mounts the same card beside its approval cards.
  variant?: "inbox" | "queue";
  // Called after a mapped remedy settles so the owning surface refetches its
  // pending list; the settled card also drops live through the
  // approval_decided frame, so the card performs no reads of its own.
  onRemedy?: (request: PermissionRequest) => void;
}

// Deep link into the Settings → Access surface, the same settings hash the
// pulse card's Open Policy action writes, so a probe notice lands on the
// policy surface through hashchange with no reload.
const POLICY_HREF = "#settings/access";

// Busy label plus fallback reason, mirroring the pulse card's ceremony copy
// so both surfaces read one re-baseline vocabulary.
const REBASELINE_BUSY_LABEL = "Re-baselining…";
const REBASELINE_FAILED_COPY = "Re-baseline failed.";

// The one remedy a notice can carry: a primary re-baseline ceremony or a
// policy deep link, keyed by the fixed system tool names.
type SystemRemedy =
  | { kind: "rebaseline"; label: string }
  | { kind: "openPolicy"; label: string };

// Unknown names map to no remedy, so a system notice stays surfacing-only no
// matter what the engine files next.
function remedyFor(toolName: string): SystemRemedy | null {
  switch (toolName) {
    case "sovereign.mismatch":
      return { kind: "rebaseline", label: "Re-baseline & re-verify" };
    case "security.probe":
      return { kind: "openPolicy", label: "Open Policy" };
    default:
      return null;
  }
}

export default function SystemNoticeCard({
  request,
  variant = "inbox",
  onRemedy,
}: SystemNoticeCardProps) {
  // Re-baseline busy flag plus server reason: the disabled button and the
  // guard together prevent a double ceremony, and a refused ceremony stays
  // visible instead of vanishing.
  const [remedying, setRemedying] = useState(false);
  const [remedyError, setRemedyError] = useState<string | null>(null);
  const remedy = remedyFor(request.toolName);
  const narrative = request.description?.trim() ?? "";

  async function handleRemedy() {
    if (!remedy || remedy.kind !== "rebaseline" || remedying) return;
    setRemedying(true);
    setRemedyError(null);
    try {
      await postSovereignRebaseline();
      // Settlement reaches the dashboards through the approval_decided frame
      // and the owning surface's refetch, so this card only notifies — the
      // settlement broadcast, not a fetch here, is what drops the card.
      onRemedy?.(request);
    } catch (failure) {
      setRemedyError(
        failure instanceof Error && failure.message
          ? failure.message
          : REBASELINE_FAILED_COPY,
      );
    } finally {
      setRemedying(false);
    }
  }

  return (
    <div
      className={`card approval-card${variant === "queue" ? " action-card" : ""}`}
      data-testid={`system-notice-${request.id}`}
    >
      <div className="approval-card-header">
        <div className="approval-title-group">
          <span className="badge approval-tool-badge">{request.toolName}</span>
          <span
            className="badge system-notice-chip"
            data-testid={`system-notice-chip-${request.id}`}
          >
            System notice
          </span>
        </div>
      </div>

      {narrative ? (
        <div className="approval-narrative approval-intent">{narrative}</div>
      ) : null}

      {remedy ? (
        <div className="approval-actions-bar">
          {remedy.kind === "rebaseline" ? (
            <>
              <button
                type="button"
                className="primary"
                disabled={remedying}
                onClick={() => void handleRemedy()}
              >
                {remedying ? REBASELINE_BUSY_LABEL : remedy.label}
              </button>
              {remedyError ? (
                <p className="error text-sm" role="alert">
                  {remedyError}
                </p>
              ) : null}
            </>
          ) : (
            <a className="ghost icon-text-btn" href={POLICY_HREF}>
              <SettingsIcon size={14} />
              <span>{remedy.label}</span>
            </a>
          )}
        </div>
      ) : null}
    </div>
  );
}
