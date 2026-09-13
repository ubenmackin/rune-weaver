// Hook to manage browser Notification API permissions and listen for real-time WebSocket events.
// Triggers native browser notifications and maintains unread badge counts for Runs and Approvals.

import { useCallback, useState } from "react";
import { useSharedWebSocket } from "./useSharedWebSocket";

export function useWebNotifications() {
  const [permission, setPermission] = useState<NotificationPermission>(() => {
    if (typeof window !== "undefined" && "Notification" in window) {
      return Notification.permission;
    }
    return "default";
  });

  const [runsBadge, setRunsBadge] = useState(0);
  const [approvalsBadge, setApprovalsBadge] = useState(0);

  const handleMessage = useCallback((data: any) => {
    if (!data || typeof data !== "object") return;
    if (data.type === "run_completed" && data.run) {
      setRunsBadge((prev) => prev + 1);

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const title = `Rune Weaver: ${data.run.kind === "scheduler" ? "Job Run Finished" : "Chat Finished"}`;
        const body = data.run.response
          ? data.run.response.slice(0, 150)
          : data.run.message;
        new Notification(title, { body });
      }
    } else if (data.type === "approval" && data.request) {
      setApprovalsBadge((prev) => prev + 1);

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const toolName = data.request.toolName ?? "unknown tool";
        const detail = data.request.description ?? data.request.toolName ?? "A tool needs approval";
        new Notification("Rune Weaver: Approval Needed", {
          body: `Tool ${toolName}: ${detail}`,
        });
      }
    }
  }, []);

  useSharedWebSocket(handleMessage);

  const requestPermission = useCallback(async () => {
    if (typeof window === "undefined" || !("Notification" in window)) return;
    try {
      const outcome = await Notification.requestPermission();
      setPermission(outcome);
    } catch {
      // Ignore
    }
  }, []);

  const clearRunsBadge = useCallback(() => {
    setRunsBadge(0);
  }, []);

  const clearApprovalsBadge = useCallback(() => {
    setApprovalsBadge(0);
  }, []);

  return {
    notificationsEnabled: permission === "granted",
    permission,
    requestPermission,
    runsBadge,
    clearRunsBadge,
    approvalsBadge,
    clearApprovalsBadge,
  };
}
