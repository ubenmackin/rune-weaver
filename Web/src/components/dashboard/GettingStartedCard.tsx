// Rune Weaver Dashboard — Getting started checklist with dismiss and resume.
import { useEffect, useState } from "react";
import {
  dismissChecklist,
  neverStartedOnboardingStatus,
  parseOnboardingStatus,
  reopenOnboarding,
  type OnboardingStatus,
} from "../../api/onboarding";
import { isCalendarGranted, isConnectReady, isEmailReady, isIndexReady } from "../onboarding/seedPrompt";
import {
  clearWizardSnooze,
  isWizardSnoozed,
  subscribeWizardSnooze,
} from "../onboarding/wizardSnooze";
import type { Tab } from "../TopNav";

// Single resume control shared by the pill and card branches.
function ResumeButton({ onResume }: { onResume: () => void }) {
  return (
    <button
      type="button"
      className="btn btn-primary"
      data-testid="getting-started-resume"
      onClick={onResume}
      aria-label="Resume setup"
    >
      Resume setup
    </button>
  );
}

export type ChecklistItemId = "brain" | "persona" | "connect" | "policy" | "chat";

export interface ChecklistItem {
  id: ChecklistItemId;
  label: string;
  completed: boolean;
}

// Single-shape input reusing the canonical status plus dashboard chat flags.
export type GettingStartedStatusInput = Partial<OnboardingStatus> & {
  firstChatSent?: boolean | number | null;
  hasChat?: boolean | number | null;
  first_chat_sent?: boolean | number | null;
  [key: string]: unknown;
};

export const CHECKLIST_LABELS: Record<ChecklistItemId, string> = {
  brain: "Brain ready",
  persona: "Persona set",
  connect: "Email/Calendar/Index connected",
  policy: "Policy reviewed",
  chat: "First chat sent",
};

export const CHECKLIST_TOTAL = 5;

// Strict true-or-1 check so chat flags fail closed to incomplete.
function isTrueFlag(value: unknown): boolean {
  return value === true || value === 1;
}

// Derives the five rows from live readiness plus skipped steps; clicks never complete a row.
export function deriveChecklistItems(
  status: GettingStartedStatusInput | null | undefined,
): ChecklistItem[] {
  const record = (status ?? {}) as Record<string, unknown>;
  const parsed = parseOnboardingStatus(status) ?? neverStartedOnboardingStatus();
  const skipped = new Set<string>(parsed.skippedSteps ?? []);
  const brainVerified = parsed.brainReady === true;
  const personaVerified = parsed.personaSet === true;
  // Skipped connect ignores legacy flags so only verified evidence completes it.
  const connectVerified =
    isCalendarGranted(parsed) || isEmailReady(parsed) || isIndexReady(parsed);
  const connectLive = isConnectReady(parsed);
  const policyVerified = parsed.policyAcked === true;
  // A skipped-but-unverified row stays incomplete so it reappears as Start.
  function verifiedOrSkippedIncomplete(step: string, verified: boolean): boolean {
    if (skipped.has(step) && !verified) return false;
    return verified;
  }
  const brain = verifiedOrSkippedIncomplete("brain", brainVerified);
  const persona = verifiedOrSkippedIncomplete("persona", personaVerified);
  const connect = skipped.has("connect") ? connectVerified : connectLive;
  const policy = verifiedOrSkippedIncomplete("protect", policyVerified);
  const chat =
    isTrueFlag(record.firstChatSent) ||
    isTrueFlag(record.hasChat) ||
    isTrueFlag(record.first_chat_sent);
  return [
    { id: "brain", label: CHECKLIST_LABELS.brain, completed: brain },
    { id: "persona", label: CHECKLIST_LABELS.persona, completed: persona },
    { id: "connect", label: CHECKLIST_LABELS.connect, completed: connect },
    { id: "policy", label: CHECKLIST_LABELS.policy, completed: policy },
    { id: "chat", label: CHECKLIST_LABELS.chat, completed: chat },
  ];
}

// Counts verified rows for the Setup N of 5 progress copy.
export function countCompletedItems(items: ChecklistItem[]): number {
  return items.filter((item) => item.completed).length;
}

export interface GettingStartedCardProps {
  status: GettingStartedStatusInput | null | undefined;
  loading?: boolean;
  dismissed?: boolean;
  finishing?: boolean;
  onDismiss?: () => void;
  onExpand?: () => void;
  onStart?: (itemId: ChecklistItemId) => void;
  onSelectTab?: (tab: Tab) => void;
  onFinish?: () => void;
}

export default function GettingStartedCard({
  status,
  loading = false,
  dismissed = false,
  finishing = false,
  onDismiss,
  onExpand,
  onStart,
  onSelectTab,
  onFinish,
}: GettingStartedCardProps) {
  const [dismissBusy, setDismissBusy] = useState(false);
  const [expandBusy, setExpandBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [snoozed, setSnoozed] = useState(() => isWizardSnoozed());

  useEffect(() => subscribeWizardSnooze(setSnoozed), []);

  // Verified completion drops the flag so resume never lingers past the gate.
  useEffect(() => {
    if (status === null || status === undefined) return;
    if (
      countCompletedItems(deriveChecklistItems(status)) >= CHECKLIST_TOTAL &&
      isWizardSnoozed()
    ) {
      clearWizardSnooze();
    }
  }, [status]);

  if (loading) return null;
  if (status === null || status === undefined) return null;

  const items = deriveChecklistItems(status);
  const done = countCompletedItems(items);

  // Permanent removal rides on verified completion alone, never on dismiss.
  if (done >= CHECKLIST_TOTAL) return null;

  async function handleDismiss(): Promise<void> {
    if (dismissBusy) return;
    setDismissBusy(true);
    setError(null);
    try {
      await dismissChecklist();
      clearWizardSnooze();
      onDismiss?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to dismiss checklist");
    } finally {
      setDismissBusy(false);
    }
  }

  async function handleExpand(): Promise<void> {
    if (expandBusy) return;
    setExpandBusy(true);
    setError(null);
    try {
      await reopenOnboarding();
      clearWizardSnooze();
      onExpand?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to reopen checklist");
    } finally {
      setExpandBusy(false);
    }
  }

  // Resume reopens at the persisted step through the gate; refresh converges the card.
  function handleResume(): void {
    clearWizardSnooze();
    onExpand?.();
  }

  function handleComplete(): void {
    clearWizardSnooze();
    onFinish?.();
  }

  function handleStart(itemId: ChecklistItemId): void {
    if (onStart) {
      onStart(itemId);
      return;
    }
    if (!onSelectTab) return;
    // Policy owns the Access deep-link; chat lands in Chat; the rest open Settings.
    if (itemId === "chat") {
      onSelectTab("chat");
      return;
    }
    onSelectTab("settings");
    if (itemId === "policy" && typeof window !== "undefined") {
      window.location.hash = "#settings/access";
    }
  }

  if (dismissed) {
    return (
      <div
        className="dashboard-section getting-started-pill"
        data-testid="getting-started-pill"
        aria-label="Getting started progress"
      >
        <span data-testid="getting-started-pill-progress">
          Setup {done} of {CHECKLIST_TOTAL}
        </span>
        {snoozed ? <ResumeButton onResume={handleResume} /> : null}
        <button
          type="button"
          className="btn-link"
          data-testid="getting-started-expand"
          onClick={() => void handleExpand()}
          disabled={expandBusy}
          aria-label="Show getting started checklist"
        >
          {expandBusy ? "Opening…" : "Show"}
        </button>
        {error ? <span className="notice-banner error">{error}</span> : null}
      </div>
    );
  }

  return (
    <section
      className="dashboard-section getting-started-section"
      aria-label="Getting started"
      data-testid="getting-started-card"
    >
      <div className="dashboard-section-header">
        <div className="dashboard-section-title-wrap">
          <h2 className="dashboard-section-title">Getting started</h2>
        </div>
        <span className="dashboard-section-subtitle" data-testid="getting-started-progress">
          Setup {done} of {CHECKLIST_TOTAL}
        </span>
      </div>

      {error ? <div className="notice-banner error">{error}</div> : null}

      <ul className="getting-started-list">
        {items.map((item) => (
          <li
            key={item.id}
            className="getting-started-row"
            data-testid={`getting-started-row-${item.id}`}
          >
            <span className="getting-started-label">{item.label}</span>
            {item.completed ? (
              <span
                className="getting-started-done"
                data-testid={`getting-started-status-${item.id}`}
              >
                Done
              </span>
            ) : (
              <button
                type="button"
                className="btn btn-secondary"
                data-testid={`getting-started-start-${item.id}`}
                aria-label={`Start ${item.label}`}
                onClick={() => handleStart(item.id)}
              >
                Start
              </button>
            )}
          </li>
        ))}
      </ul>

      <div className="getting-started-actions">
        {snoozed ? <ResumeButton onResume={handleResume} /> : null}
        <button
          type="button"
          className="btn btn-secondary"
          data-testid="getting-started-dismiss"
          onClick={() => void handleDismiss()}
          disabled={dismissBusy}
        >
          {dismissBusy ? "Dismissing…" : "Dismiss"}
        </button>
        <button
          type="button"
          className="btn btn-primary"
          data-testid="getting-started-finish"
          onClick={() => handleComplete()}
          disabled={finishing}
        >
          {finishing ? "Finishing…" : "Finish"}
        </button>
      </div>
    </section>
  );
}
