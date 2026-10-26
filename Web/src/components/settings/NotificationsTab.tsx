// Rune Weaver Dashboard — Notifications tab pane.

import { useMobilePush } from "../../hooks/useMobilePush";
import { MobilePushSettingsCard } from "./MobilePushSettingsCard";
import { SwitchControl } from "./SwitchControl";

interface NotificationTypeMeta {
  key: "approvalRequested" | "schedulerRun" | "goalAdvance" | "ideaProposed" | "indexFailed" | "chatFailed";
  label: string;
  hint: string;
}

const NOTIFICATION_TYPES: readonly NotificationTypeMeta[] = [
  { key: "approvalRequested", label: "Approval requested", hint: "Tool approvals waiting for a decision." },
  { key: "schedulerRun", label: "Scheduler run", hint: "Scheduled runs and due jobs." },
  { key: "goalAdvance", label: "Goal advance", hint: "Goal steps and progress updates." },
  { key: "ideaProposed", label: "Idea proposed", hint: "Proactive suggestions awaiting review." },
  { key: "indexFailed", label: "Index failed", hint: "Document index failures." },
  { key: "chatFailed", label: "Chat failed", hint: "Background chat failures." },
];

export interface NotificationsTabProps {
  notificationsApprovalRequested: boolean;
  setNotificationsApprovalRequested: (val: boolean) => void;
  notificationsSchedulerRun: boolean;
  setNotificationsSchedulerRun: (val: boolean) => void;
  notificationsGoalAdvance: boolean;
  setNotificationsGoalAdvance: (val: boolean) => void;
  notificationsIdeaProposed: boolean;
  setNotificationsIdeaProposed: (val: boolean) => void;
  notificationsIndexFailed: boolean;
  setNotificationsIndexFailed: (val: boolean) => void;
  notificationsChatFailed: boolean;
  setNotificationsChatFailed: (val: boolean) => void;
  notificationsPushContact?: string;
  setNotificationsPushContact?: (val: string) => void;
}

export function NotificationsTab({
  notificationsApprovalRequested,
  setNotificationsApprovalRequested,
  notificationsSchedulerRun,
  setNotificationsSchedulerRun,
  notificationsGoalAdvance,
  setNotificationsGoalAdvance,
  notificationsIdeaProposed,
  setNotificationsIdeaProposed,
  notificationsIndexFailed,
  setNotificationsIndexFailed,
  notificationsChatFailed,
  setNotificationsChatFailed,
  notificationsPushContact = "",
  setNotificationsPushContact = () => {},
}: NotificationsTabProps) {
  const { isStandalone } = useMobilePush();
  const prefs: Record<NotificationTypeMeta["key"], boolean> = {
    approvalRequested: notificationsApprovalRequested ?? true,
    schedulerRun: notificationsSchedulerRun ?? true,
    goalAdvance: notificationsGoalAdvance ?? true,
    ideaProposed: notificationsIdeaProposed ?? true,
    indexFailed: notificationsIndexFailed ?? true,
    chatFailed: notificationsChatFailed ?? true,
  };
  const setters: Record<NotificationTypeMeta["key"], (val: boolean) => void> = {
    approvalRequested: setNotificationsApprovalRequested,
    schedulerRun: setNotificationsSchedulerRun,
    goalAdvance: setNotificationsGoalAdvance,
    ideaProposed: setNotificationsIdeaProposed,
    indexFailed: setNotificationsIndexFailed,
    chatFailed: setNotificationsChatFailed,
  };

  return (
    <div className="settings-section card" data-testid="notifications-pane">
      <div className="settings-section-title-group">
        <h3>Notifications</h3>
        <p className="settings-section-hint">
          Choose which events may interrupt you. Applies live with no restart.
        </p>
      </div>

      {NOTIFICATION_TYPES.map((item) => (
        <div className="form-group checkbox-group" key={item.key}>
          <SwitchControl
            testId={`notifications-${item.key}`}
            checked={prefs[item.key] ?? true}
            onChange={(e) => setters[item.key](e.target.checked)}
            label={item.label}
            hint={item.label}
          />
          <span className="form-group-hint">{item.hint}</span>
        </div>
      ))}

      <div className="form-group settings-stack-gap">
        <label htmlFor="notifications-push-contact">
          Web Push Contact (Email or URL)
        </label>
        <input
          id="notifications-push-contact"
          data-testid="notifications-push-contact-input"
          type="text"
          value={notificationsPushContact}
          onChange={(e) => setNotificationsPushContact(e.target.value)}
          placeholder="operator@yourdomain.com or https://yourdomain.com"
          maxLength={320}
        />
        <span className="form-group-hint">
          Required for iOS PWA Web Push: Apple APNs validates that the VAPID subject domain resolves via public DNS.
        </span>
      </div>

      <div
        className="info-banner settings-stack-gap"
        role="note"
        data-testid="notifications-bell-explainer"
      >
        The bell is warnings-only: it shows degraded-tool warnings in amber while
        approvals, runs, and goals badge on their own tabs. Tapping the bell is
        mark-all-read: it routes to chat only when warnings are present, and it
        never requests OS notification permission — desktop banners live in the
        macOS menu bar app. Turning a type off only quiets interruptions (desktop
        banner, mobile push, web badge bump); run history, live run frames, and
        the approvals inbox still record every event.
      </div>

      {!isStandalone ? (
        <div
          className="settings-field-hint settings-stack-gap"
          data-testid="notifications-desktop-guidance"
        >
          On desktop, allow browser notifications to receive desktop banners.
          Push enrollment appears only in the installed standalone app.
        </div>
      ) : null}

      <div className="settings-stack-gap">
        <MobilePushSettingsCard />
      </div>
    </div>
  );
}

export default NotificationsTab;
