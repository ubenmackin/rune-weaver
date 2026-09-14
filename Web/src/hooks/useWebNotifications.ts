// Hook to manage browser Notification API permissions and listen for real-time WebSocket events.
// Triggers native browser notifications and maintains unread badge counts for Runs and Approvals.

import { useCallback, useState } from "react";
import { useSharedWebSocket } from "./useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
} from "./useSharedWebSocket";

export function useWebNotifications() {
  const [permission, setPermission] = useState<NotificationPermission>(() => {
    if (typeof window !== "undefined" && "Notification" in window) {
      return Notification.permission;
    }
    return "default";
  });

  const [runsBadge, setRunsBadge] = useState(0);
  const [approvalsBadge, setApprovalsBadge] = useState(0);

  const handleMessage = useCallback((data: WSIncomingFrame) => {
    if (!data || typeof data !== "object") return;
    // Narrow the typed union through the generic frame so run and request
    // nests stay explicit without widening the handler to `any`.
    const frame = data as WSGenericFrame;
    const frameType = typeof frame.type === "string" ? frame.type : undefined;
    if (frameType === "run_completed" && frame.run && typeof frame.run === "object") {
      const run = frame.run as Record<string, unknown>;
      setRunsBadge((prev) => prev + 1);

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const kind = typeof run.kind === "string" ? run.kind : undefined;
        const response = typeof run.response === "string" ? run.response : undefined;
        const message = typeof run.message === "string" ? run.message : undefined;
        const title = `Rune Weaver: ${kind === "scheduler" ? "Job Run Finished" : "Chat Finished"}`;
        const body = response ? response.slice(0, 150) : message;
        new Notification(title, { body });
      }
    } else if (frameType === "approval" && frame.request && typeof frame.request === "object") {
      const request = frame.request as Record<string, unknown>;
      setApprovalsBadge((prev) => prev + 1);

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        const toolName = typeof request.toolName === "string" ? request.toolName : "unknown tool";
        const detail =
          typeof request.description === "string"
            ? request.description
            : typeof request.toolName === "string"
              ? request.toolName
              : "A tool needs approval";
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
