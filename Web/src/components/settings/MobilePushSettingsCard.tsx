// Rune Weaver Dashboard — Standalone Mobile PWA Push Notification Settings Card.

import { useState } from "react";
import { useMobilePush } from "../../hooks/useMobilePush";

export function MobilePushSettingsCard() {
  const {
    isStandalone,
    isSupported,
    isSubscribed,
    isLoading,
    error,
    subscribeMobilePush,
    unsubscribeMobilePush,
    sendTestPush,
  } = useMobilePush();

  const [testResult, setTestResult] = useState<string | null>(null);

  // Card only renders on mobile standalone installations
  if (!isStandalone) return null;

  const handleToggle = async () => {
    setTestResult(null);
    if (isSubscribed) {
      await unsubscribeMobilePush();
    } else {
      await subscribeMobilePush();
    }
  };

  const handleSendTest = async () => {
    setTestResult(null);
    const res = await sendTestPush();
    if (res.delivered > 0) {
      setTestResult(`Test push delivered to ${res.delivered} device${res.delivered === 1 ? "" : "s"}!`);
    } else if (res.errors && res.errors.length > 0) {
      setTestResult(`Delivery failed: ${res.errors.join("; ")}`);
    } else if (res.totalSubscribers === 0) {
      setTestResult("No devices registered.");
    } else {
      setTestResult("No devices reached.");
    }
  };

  return (
    <div className="settings-section card" data-testid="mobile-push-settings-card">
      <div className="settings-section-title-group">
        <h3>Mobile Push Notifications (iOS PWA)</h3>
        <p className="settings-section-hint">
          Receive lock-screen alerts for tool approvals and background milestones when away from your Mac.
        </p>
      </div>

      {!isSupported ? (
        <div className="info-banner" role="status">
          Web Push is not available in this browser configuration. On iOS, add this app to your Home Screen to enable Web Push.
        </div>
      ) : (
        <>
          <div className="form-row mobile-push-row">
            <div className="form-group m-0">
              <label className="mobile-push-label">
                {isSubscribed ? "Push Notifications Active" : "Push Notifications Inactive"}
              </label>
              <span className="text-xs mobile-push-hint">
                {isSubscribed
                  ? "This device is registered to receive background push alerts."
                  : "Enable push notifications to be alerted when approvals are requested."}
              </span>
            </div>
            <button
              type="button"
              className={isSubscribed ? "ghost" : "primary"}
              onClick={() => void handleToggle()}
              disabled={isLoading}
              data-testid="toggle-mobile-push-btn"
            >
              {isLoading ? "Updating…" : isSubscribed ? "Disable Push" : "Enable Push"}
            </button>
          </div>

          {isSubscribed && (
            <div className="form-row settings-stack-gap">
              <button
                type="button"
                className="ghost"
                onClick={() => void handleSendTest()}
                disabled={isLoading}
                data-testid="send-test-push-btn"
              >
                Send Test Push
              </button>
              {testResult && (
                <span className="text-xs ml-2 mobile-push-result">
                  {testResult}
                </span>
              )}
            </div>
          )}

          {error && (
            <div className="error-banner settings-stack-gap" role="alert">
              {error}
            </div>
          )}
        </>
      )}
    </div>
  );
}
