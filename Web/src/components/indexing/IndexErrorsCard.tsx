// Rune Weaver Dashboard — Last index errors list with deduplication and Full Disk Access guidance.
import { AlertTriangleIcon } from "../icons";
import MarkdownText from "../MarkdownText";
import {
  FULL_DISK_ACCESS_SETTINGS_URL,
  dedupeIndexErrors,
  formatIndexCount,
  hasFullDiskAccessError,
  hashIndexError,
  isLongIndexError,
  resolveDisplayIndexErrors,
  truncateIndexError,
} from "./indexHelpers";

interface IndexErrorsCardProps {
  errors: unknown;
  errorsExpanded: boolean;
  expandedErrors: Set<string>;
  onToggleErrorsExpanded: () => void;
  onToggleErrorDetail: (detail: string) => void;
}

export default function IndexErrorsCard({
  errors,
  errorsExpanded,
  expandedErrors,
  onToggleErrorsExpanded,
  onToggleErrorDetail,
}: IndexErrorsCardProps) {
  const displayErrors = resolveDisplayIndexErrors(errors);
  const showFdaGuidance = hasFullDiskAccessError(errors);
  const hasErrorBlock = displayErrors.length > 0 || showFdaGuidance;
  if (!hasErrorBlock) return null;

  const totalErrorCount = dedupeIndexErrors(errors).length;

  return (
    <div
      className="index-errors"
      aria-label="Last index errors"
      data-testid="index-last-errors"
    >
      {displayErrors.length > 0 ? (
        <button
          type="button"
          className="ghost index-errors-header-toggle muted text-xs"
          data-testid="index-errors-header-toggle"
          aria-expanded={errorsExpanded}
          onClick={onToggleErrorsExpanded}
        >
          <span>Last errors ({formatIndexCount(totalErrorCount)})</span>
          <span>{errorsExpanded ? "Hide" : "Show"}</span>
        </button>
      ) : (
        <span
          className="index-errors-header-count muted text-xs"
          data-testid="index-errors-header-count"
        >
          <span>Last errors ({formatIndexCount(totalErrorCount)})</span>
        </span>
      )}
      {errorsExpanded && displayErrors.length > 0 ? (
        <div className="index-errors-scroll">
          {/* Raw error rows own this list so guidance steps below never
              read as raw rows when scoped by test id or assistive tech. */}
          <ul data-testid="index-error-list" className="muted text-xs">
            {displayErrors.map((detail, index) => {
              // Per-row expansion looks up the full error text so the toggle survives
              // status polls, while the React key stays a short hash plus position so
              // kilobyte-long failures never become full-text keys.
              const expanded = expandedErrors.has(detail);
              const long = isLongIndexError(detail);
              const visibleText = expanded ? detail : truncateIndexError(detail);
              // Truncated previews render as plain text: slicing raw markdown at the
              // preview budget can split emphasis, code, or link syntax and misrender
              // through MarkdownText, so only the expanded full text keeps markdown.
              const showPlainPreview = long && !expanded;
              return (
                <li
                  key={`index-error-${index}-${hashIndexError(detail)}`}
                  data-testid={`index-last-error-${index}`}
                  className="index-error-row"
                >
                  <span className="index-error-icon" aria-hidden="true">
                    <AlertTriangleIcon size={14} />
                  </span>
                  <span
                    className="index-error-text-wrap"
                    title={long && !expanded ? detail : undefined}
                  >
                    {showPlainPreview ? (
                      <span className="index-error-text">{visibleText}</span>
                    ) : (
                      <MarkdownText
                        text={visibleText}
                        className="index-error-text"
                      />
                    )}
                  </span>
                  {long ? (
                    <button
                      type="button"
                      className="ghost index-error-expand"
                      aria-expanded={expanded}
                      onClick={() => onToggleErrorDetail(detail)}
                    >
                      <span>{expanded ? "Show less" : "Show more"}</span>
                    </button>
                  ) : null}
                </li>
              );
            })}
          </ul>
        </div>
      ) : null}
      {/* Guided onboarding for the Full Disk Access denial stays visible even while the
          rows stay collapsed: macOS offers no prompt API, so the denial surfaces only
          at run time, and the top frame navigation beats a window.open popup block. */}
      {showFdaGuidance ? (
        <div
          className="index-fda-guidance mt-2"
          data-testid="index-fda-guidance"
        >
          <p className="muted text-sm mb-2">
            Messages indexing needs Full Disk Access. Grant it to
            RuneWeaver.app (or to your terminal emulator, for example
            Terminal.app or iTerm2, when you run rune-weaver serve),
            then restart and press Run.
          </p>
          <button
            type="button"
            className="ghost icon-text-btn"
            onClick={() => {
              window.location.href = FULL_DISK_ACCESS_SETTINGS_URL;
            }}
          >
            <span>Open Full Disk Access Settings</span>
          </button>
          <ol className="muted text-sm mt-2 index-fda-steps">
            <li>Open System Settings &gt; Privacy &amp; Security &gt; Full Disk Access.</li>
            <li>Click + and add RuneWeaver.app (or your terminal emulator, for example Terminal.app or iTerm2, when you run rune-weaver serve).</li>
            <li>Toggle the added entry ON and authenticate when prompted.</li>
            <li>Quit and restart the app or terminal, then press Run.</li>
          </ol>
        </div>
      ) : null}
    </div>
  );
}
