// Rune Weaver Dashboard — Chat approval handling for inline permissions and questions.

import { useCallback, useEffect, useState } from "react";
import {
  ApiError,
  decideApproval,
  listApprovals,
  respondToQuestion,
  type PermissionRequest,
  type TrustDuration,
} from "../../api";

interface UseChatApprovalsOptions {
  sessionID: string;
  onError: (error: string) => void;
}

export function useChatApprovals({ sessionID, onError }: UseChatApprovalsOptions) {
  const [pendingApprovals, setPendingApprovals] = useState<PermissionRequest[]>([]);
  const [decidingApprovalIDs, setDecidingApprovalIDs] = useState<Set<string>>(
    () => new Set<string>(),
  );

  const refreshApprovals = useCallback(() => {
    void listApprovals()
      .then((response) => {
        if (response && Array.isArray(response.approvals)) {
          setPendingApprovals(response.approvals);
        }
      })
      .catch(() => {
        // Keep prior inbox on transient failure.
      });
  }, []);

  useEffect(() => {
    let cancelled = false;
    listApprovals()
      .then((response) => {
        if (!cancelled && response && Array.isArray(response.approvals)) {
          setPendingApprovals(response.approvals);
        }
      })
      .catch(() => {
        // Keep prior inbox on transient failure.
      });
    return () => {
      cancelled = true;
    };
  }, [sessionID]);

  const handleDecideApproval = useCallback(
    async (id: string, approved: boolean, duration: TrustDuration) => {
      setDecidingApprovalIDs((previous) => new Set(previous).add(id));
      try {
        await decideApproval(id, approved, duration, undefined, "chat");
        setPendingApprovals((previous) =>
          previous.filter((item) => item.id !== id),
        );
      } catch (failure) {
        onError(
          failure instanceof ApiError ? failure.message : "Decision failed",
        );
      } finally {
        setDecidingApprovalIDs((previous) => {
          if (!previous.has(id)) return previous;
          const next = new Set(previous);
          next.delete(id);
          return next;
        });
      }
      refreshApprovals();
    },
    [refreshApprovals, onError],
  );

  const handleRespondQuestion = useCallback(
    async (id: string, answer?: string, cancelled?: boolean) => {
      setDecidingApprovalIDs((previous) => new Set(previous).add(id));
      try {
        await respondToQuestion(id, answer, cancelled);
        setPendingApprovals((previous) =>
          previous.filter((item) => item.id !== id),
        );
      } catch (failure) {
        onError(
          failure instanceof ApiError ? failure.message : "Response failed",
        );
      } finally {
        setDecidingApprovalIDs((previous) => {
          if (!previous.has(id)) return previous;
          const next = new Set(previous);
          next.delete(id);
          return next;
        });
      }
      refreshApprovals();
    },
    [refreshApprovals, onError],
  );

  return {
    pendingApprovals,
    setPendingApprovals,
    decidingApprovalIDs,
    setDecidingApprovalIDs,
    refreshApprovals,
    handleDecideApproval,
    handleRespondQuestion,
  };
}
