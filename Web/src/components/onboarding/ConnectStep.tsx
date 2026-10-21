// Rune Weaver Dashboard — Onboarding connect step with live readiness.
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { fetchJson } from "../../api/http";
import { skipOnboardingStep } from "../../api/onboarding";
import {
  calendarBadge,
  emailBadge,
  indexBadge,
  isConnectReady,
  parseOnboardingStatus,
  type OnboardingBadge,
  type OnboardingStatus,
} from "./seedPrompt";
import {
  ONBOARDING_GOALS,
  isOnboardingGoal,
  step3CardOrderForGoal,
  type OnboardingGoal,
  type Step3CardId,
} from "./PersonaStep";
import { snoozeWizard } from "./wizardSnooze";
import { wizardSettingsHref } from "./wizardHelpers";

export interface ConnectStepProps {
  goal?: OnboardingGoal | null;
  status?: OnboardingStatus | null;
  loading?: boolean;
  error?: string | null;
  refresh?: () => Promise<void> | void;
  onSkipCalendar?: () => Promise<void> | void;
  skipping?: boolean;
}

// Null goal renders every card in this order with no disclosure.
const DEFAULT_STEP3_ORDER: Step3CardId[] = ["email", "calendar", "index"];

// Live re-read backing Check Again; drifted rows degrade to never-started.
async function loadOnboardingStatus(): Promise<OnboardingStatus> {
  const raw = await fetchJson<unknown>("/onboarding/status");
  return parseOnboardingStatus(raw);
}

function badgeClassName(badge: OnboardingBadge): string {
  if (badge === "Ready") return "connect-badge connect-badge-ready";
  if (badge === "Configured") return "connect-badge connect-badge-configured";
  if (badge === "Needs permission")
    return "connect-badge connect-badge-needs-permission";
  return "connect-badge connect-badge-not-connected";
}

interface ConnectCardProps {
  id: Step3CardId;
  title: string;
  badge: OnboardingBadge;
  isPrimary: boolean;
  goalLabel: string | null;
  description: string;
  body?: ReactNode;
  actions?: ReactNode;
}

// Single card chrome: header plus badge plus echo plus desc plus slots.
function ConnectCard({
  id,
  title,
  badge,
  isPrimary,
  goalLabel,
  description,
  body,
  actions,
}: ConnectCardProps) {
  return (
    <article
      className={isPrimary ? "connect-card connect-card-primary" : "connect-card"}
      data-testid={`connect-${id}-card`}
    >
      <div className="connect-card-header">
        <h3 className="connect-card-title">{title}</h3>
        <span className={badgeClassName(badge)} data-testid={`connect-${id}-badge`}>
          {badge}
        </span>
      </div>
      {isPrimary && goalLabel ? (
        <p className="connect-goal-echo" data-testid="connect-goal-echo">
          You chose {goalLabel}
        </p>
      ) : null}
      <p className="connect-card-desc">{description}</p>
      {body}
      {actions ? (
        <div className="connect-card-actions onboarding-actions">{actions}</div>
      ) : null}
    </article>
  );
}

interface CheckAgainButtonProps {
  testId: string;
  loading: boolean;
  onCheck: () => void;
  className?: string;
}

// Shared refresh wiring so every panel re-reads the same live status.
function CheckAgainButton({
  testId,
  loading,
  onCheck,
  className = "ghost",
}: CheckAgainButtonProps) {
  return (
    <button
      type="button"
      className={className}
      data-testid={testId}
      onClick={() => void onCheck()}
      disabled={loading}
    >
      Check Again
    </button>
  );
}

interface SettingsLinkProps {
  tab: "email" | "indexing";
  testId: string;
  label: string;
}

// Snooze hides the wizard in the new tab so Settings edits without overlap.
function SettingsLink({ tab, testId, label }: SettingsLinkProps) {
  return (
    <a
      className="ghost connect-settings-link"
      data-testid={testId}
      href={wizardSettingsHref(tab)}
      target="_blank"
      rel="noopener noreferrer"
      onClick={() => snoozeWizard()}
    >
      {label}
    </a>
  );
}

export default function ConnectStep({
  goal: controlledGoal = null,
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
  const emailAccounts = Array.isArray(effectiveStatus?.emailAccounts)
    ? effectiveStatus.emailAccounts
    : [];

  const normalizedGoal = isOnboardingGoal(controlledGoal) ? controlledGoal : null;
  // Null goal falls back to the default order with no disclosure.
  const orderedIds: Step3CardId[] = normalizedGoal
    ? step3CardOrderForGoal(normalizedGoal)
    : DEFAULT_STEP3_ORDER;
  const primaryId: Step3CardId | null = normalizedGoal ? orderedIds[0] : null;
  const otherIds: Step3CardId[] = normalizedGoal ? orderedIds.slice(1) : [];
  const goalLabel = normalizedGoal
    ? (ONBOARDING_GOALS.find((option) => option.value === normalizedGoal)?.label ??
      normalizedGoal)
    : null;

  function renderCard(id: Step3CardId, isPrimary: boolean) {
    if (id === "email") {
      const body =
        emailAccounts.length > 0 ? (
          <ul className="connect-account-list" data-testid="connect-email-accounts">
            {emailAccounts.map((account, idx) => {
              const rawAddress =
                typeof account?.address === "string" ? account.address.trim() : "";
              // Blank addresses render as a dash so a row never collapses.
              const displayAddress = rawAddress ? rawAddress : "—";
              return (
                <li
                  key={`${displayAddress}-${idx}`}
                  className="connect-account-row"
                  data-testid="connect-email-account"
                >
                  <span className="connect-account-address" title={displayAddress}>
                    {displayAddress}
                  </span>
                  <span
                    className="connect-account-pill"
                    data-testid="connect-email-account-pill"
                  >
                    {account?.fetchSucceeded === true ? "Fetched" : "Configured"}
                  </span>
                </li>
              );
            })}
          </ul>
        ) : (
          <p className="connect-card-empty" data-testid="connect-email-empty">
            No account yet
          </p>
        );
      return (
        <ConnectCard
          id="email"
          title="Email"
          badge={email}
          isPrimary={isPrimary}
          goalLabel={goalLabel}
          description="Summarize unread mail once an account has fetched successfully."
          body={body}
          actions={
            <>
              <SettingsLink
                tab="email"
                testId="connect-email-settings-link"
                label="Open Email settings"
              />
              <CheckAgainButton
                testId="connect-email-check-again"
                loading={loading}
                onCheck={() => void handleRefresh()}
              />
            </>
          }
        />
      );
    }
    if (id === "calendar") {
      if (showPermissionDetour) {
        return (
          <ConnectCard
            id="calendar"
            title="Calendar"
            badge={calendar}
            isPrimary={isPrimary}
            goalLabel={goalLabel}
            description="Preview today's schedule once calendar access is granted."
            body={
              <div
                className="calendar-permission-explainer notice-banner"
                data-testid="calendar-permission-explainer"
              >
                <p className="permission-explainer-text">
                  Rune Weaver needs Calendars in System Settings to show your schedule.
                </p>
                <a
                  className="ghost permission-open-link"
                  href="x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                >
                  Open Permissions
                </a>
                <div className="permission-explainer-actions onboarding-actions">
                  <CheckAgainButton
                    testId="connect-calendar-check-again"
                    loading={loading}
                    onCheck={() => void handleRefresh()}
                    className="ghost permission-check-btn"
                  />
                  <button
                    type="button"
                    className="primary permission-skip-btn"
                    onClick={() => void handleSkipCalendar()}
                    disabled={skipping}
                  >
                    {skipping ? "Skipping…" : "Skip connect for now"}
                  </button>
                </div>
              </div>
            }
          />
        );
      }
      return (
        <ConnectCard
          id="calendar"
          title="Calendar"
          badge={calendar}
          isPrimary={isPrimary}
          goalLabel={goalLabel}
          description="Preview today's schedule once calendar access is granted."
          actions={
            <CheckAgainButton
              testId="connect-calendar-check-again"
              loading={loading}
              onCheck={() => void handleRefresh()}
            />
          }
        />
      );
    }
    return (
      <ConnectCard
        id="index"
        title="Index"
        badge={index}
        isPrimary={isPrimary}
        goalLabel={goalLabel}
        description="Search local notes once indexing is enabled with a fresh watermark."
        actions={
          <>
            <SettingsLink
              tab="indexing"
              testId="connect-index-settings-link"
              label="Open Indexing settings"
            />
            <CheckAgainButton
              testId="connect-index-check-again"
              loading={loading}
              onCheck={() => void handleRefresh()}
            />
          </>
        }
      />
    );
  }

  return (
    <section
      className="onboarding-step connect-step"
      aria-label="Connect your tools"
      data-testid="connect-step"
    >
      <div className="onboarding-step-header">
        <h2 className="onboarding-step-title">Connect</h2>
        <p className="onboarding-step-subtitle">
          Link the sources Rune Weaver can use right now.
        </p>
      </div>

      {loading || (!effectiveStatus && !error) ? (
        <p className="onboarding-loading">Loading status…</p>
      ) : null}
      {error ? (
        <p className="error-banner" role="alert">
          {error}
        </p>
      ) : null}

      {normalizedGoal && primaryId ? (
        <>
          <div className="connect-cards connect-cards-primary">
            {renderCard(primaryId, true)}
          </div>
          <details className="connect-disclosure" data-testid="connect-other-options">
            <summary>Show other options</summary>
            <div className="connect-cards connect-cards-secondary">
              {otherIds.map((id) => (
                <div key={id} className="connect-mini-wrap">
                  {renderCard(id, false)}
                </div>
              ))}
            </div>
          </details>
        </>
      ) : (
        <div className="connect-cards">
          {orderedIds.map((id) => (
            <div key={id} className="connect-mini-wrap">
              {renderCard(id, false)}
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
