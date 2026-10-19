// Rune Weaver Dashboard — Onboarding connect step with live readiness.

import { useCallback, useEffect, useState } from "react";
import { fetchJson } from "../../api/http";
import { skipOnboardingStep } from "../../api/onboarding";
import {
  calendarBadge,
  emailBadge,
  indexBadge,
  isConnectReady,
  parseOnboardingStatus,
  type OnboardingStatus,
} from "./seedPrompt";

export interface ConnectStepProps {
  status?: OnboardingStatus | null;
  loading?: boolean;
  error?: string | null;
  refresh?: () => Promise<void> | void;
  onSkipCalendar?: () => Promise<void> | void;
  skipping?: boolean;
}

// Live re-read backing Check Again; drifted rows degrade to never-started.
async function loadOnboardingStatus(): Promise<OnboardingStatus> {
  const raw = await fetchJson<unknown>("/onboarding/status");
  return parseOnboardingStatus(raw);
}

export default function ConnectStep({
  status: controlledStatus,
  loading: controlledLoading,
  error: controlledError,
  refresh: controlledRefresh,
  onSkipCalendar: controlledSkip,
  skipping: controlledSkipping,
}: ConnectStepProps) {
  const [internalStatus, setInternalStatus] = useState<OnboardingStatus | null>(null);
  const [internalLoading, setInternalLoading] = useState(false);
  const [internalError, setInternalError] = useState<string | null>(null);
  const [internalSkipping, setInternalSkipping] = useState(false);
  const isControlled = controlledStatus !== undefined;

  const reloadInternal = useCallback(async () => {
    setInternalLoading(true);
    setInternalError(null);
    try {
      setInternalStatus(await loadOnboardingStatus());
    } catch (err) {
      setInternalError(err instanceof Error ? err.message : "Failed to load status");
    } finally {
      setInternalLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!isControlled) void reloadInternal();
  }, [isControlled, reloadInternal]);

  const effectiveStatus = isControlled ? controlledStatus ?? null : internalStatus;
  const loading = controlledLoading ?? internalLoading;
  const error = controlledError ?? internalError;
  const skipping = controlledSkipping ?? internalSkipping;

  const handleRefresh = useCallback(async () => {
    if (controlledRefresh) {
      await controlledRefresh();
      return;
    }
    await reloadInternal();
  }, [controlledRefresh, reloadInternal]);

  const handleSkipCalendar = useCallback(async () => {
    if (controlledSkip) {
      await controlledSkip();
      return;
    }
    // Detour always records connect skip so reload resumes past connect.
    setInternalSkipping(true);
    try {
      await skipOnboardingStep("connect");
      await reloadInternal();
    } catch (err) {
      setInternalError(err instanceof Error ? err.message : "Failed to skip calendar");
    } finally {
      setInternalSkipping(false);
    }
  }, [controlledSkip, reloadInternal]);

  const email = emailBadge(effectiveStatus);
  const calendar = calendarBadge(effectiveStatus);
  const index = indexBadge(effectiveStatus);
  // One verified capability satisfies connect; null status fails closed to it.
  const showPermissionDetour = !isConnectReady(effectiveStatus);

  return (
    <section className="onboarding-step connect-step" aria-label="Connect your tools" data-testid="connect-step">
      <div className="onboarding-step-header">
        <h2 className="onboarding-step-title">Connect</h2>
        <p className="onboarding-step-subtitle">
          Link the sources Rune Weaver can use right now.
        </p>
      </div>

      {loading ? <p className="onboarding-loading">Checking live status…</p> : null}
      {error ? (
        <p className="notice-banner error" role="alert">
          {error}
        </p>
      ) : null}

      <div className="connect-cards">
        <article className="connect-card" data-testid="connect-email-card">
          <div className="connect-card-header">
            <h3 className="connect-card-title">Email</h3>
            <span className="connect-badge" data-testid="connect-email-badge">
              {email}
            </span>
          </div>
          <p className="connect-card-desc">
            Summarize unread mail once an account has fetched successfully.
          </p>
        </article>

        <article className="connect-card" data-testid="connect-calendar-card">
          <div className="connect-card-header">
            <h3 className="connect-card-title">Calendar</h3>
            <span className="connect-badge" data-testid="connect-calendar-badge">
              {calendar}
            </span>
          </div>
          <p className="connect-card-desc">
            Preview today&apos;s schedule once calendar access is granted.
          </p>

          {showPermissionDetour ? (
            <div
              className="calendar-permission-explainer"
              data-testid="calendar-permission-explainer"
            >
              <p className="permission-explainer-text">
                Rune Weaver needs Calendars in System Settings to show your
                schedule.
              </p>
              <a
                className="btn-link permission-open-link"
                href="x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
              >
                Open Permissions
              </a>
              <div className="permission-explainer-actions">
                <button
                  type="button"
                  className="btn btn-secondary permission-check-btn"
                  onClick={() => void handleRefresh()}
                  disabled={loading}
                >
                  Check Again
                </button>
                <button
                  type="button"
                  className="btn btn-secondary permission-skip-btn"
                  onClick={() => void handleSkipCalendar()}
                  disabled={skipping}
                >
                  {skipping ? "Skipping…" : "Skip connect for now"}
                </button>
              </div>
            </div>
          ) : null}
        </article>

        <article className="connect-card" data-testid="connect-index-card">
          <div className="connect-card-header">
            <h3 className="connect-card-title">Index</h3>
            <span className="connect-badge" data-testid="connect-index-badge">
              {index}
            </span>
          </div>
          <p className="connect-card-desc">
            Search local notes once indexing is enabled with a fresh watermark.
          </p>
        </article>
      </div>
    </section>
  );
}
