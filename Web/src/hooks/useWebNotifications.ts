// Hook to manage browser Notification API permissions and listen for real-time WebSocket events.
// Triggers native browser notifications and maintains unread badge counts for Runs and Approvals.

import { useCallback, useRef, useState } from "react";
import { useSharedWebSocket } from "./useSharedWebSocket";
import type {
  WSGenericFrame,
  WSIncomingFrame,
} from "./useSharedWebSocket";
import { normalizeSessionID } from "../approvalsSession";

export function useWebNotifications() {
  const [permission, setPermission] = useState<NotificationPermission>(() => {
    if (typeof window !== "undefined" && "Notification" in window) {
      return Notification.permission;
    }
    return "default";
  });

  const [runsBadge, setRunsBadge] = useState(0);
  const [approvalsBadge, setApprovalsBadge] = useState(0);
  // Degraded-tool notices keep their own counter instead of inflating runs
  // or approvals; the bell surfaces the count as an amber badge gated behind
  // the same permission toggle, cleared when the chat view is shown.
  const [warningsBadge, setWarningsBadge] = useState(0);
  // Dedup seen warning lines so live plus terminal repeats never inflate the bell.
  const seenWarningsRef = useRef<Set<string>>(new Set());

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
    } else if (frameType === "warning") {
      // Degraded-tool skips are informational, never fatal. Session-filter like the chat
      // banner so one session's skips never alarm another, dedup by line so repeats never
      // inflate, and skip while chat is visible since the banner already informs.
      const rawSession: unknown = frame.sessionID;
      const frameSession = typeof rawSession === "string" ? rawSession : undefined;
      // Untagged warnings carry no owner and never touch the banner, so they never touch the bell.
      if (!frameSession) return;
      try {
        const active = normalizeSessionID(
          typeof window !== "undefined" ? window.localStorage.getItem("rw_active_session_id") : null,
        );
        if (active && normalizeSessionID(frameSession) !== active) return;
      } catch {
        // Storage is best-effort; without an active session fall through to visible check.
      }
      if (typeof window !== "undefined") {
        try {
          const hash = window.location.hash.replace("#", "").toLowerCase();
          const path = window.location.pathname.replace(/^\//, "").toLowerCase();
          const chatVisible =
            hash === "" || hash === "chat" || path === "" || path === "chat" || path === "/";
          // Chat stays mounted across tabs, so staying on chat shows the banner already;
          // counting again would ever-grow the bell beside an already-visible notice.
          if (chatVisible && !document.hidden) return;
        } catch {
          // Ignore visibility probe failures and count honestly.
        }
      }
      const rawMessage: unknown = frame.message;
      const message =
        typeof rawMessage === "string" && rawMessage.trim().length > 0
          ? rawMessage
          : "A tool was skipped for this turn";
      if (seenWarningsRef.current.has(message)) return;
      seenWarningsRef.current.add(message);
      setWarningsBadge((prev) => prev + 1);

      if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
        new Notification("Rune Weaver: Tool Warning", {
          body: message.slice(0, 150),
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

  const clearWarningsBadge = useCallback(() => {
    seenWarningsRef.current.clear();
    setWarningsBadge(0);
  }, []);

  return {
    notificationsEnabled: permission === "granted",
    permission,
    requestPermission,
    runsBadge,
    clearRunsBadge,
    approvalsBadge,
    clearApprovalsBadge,
    warningsBadge,
    clearWarningsBadge,
  };
}
