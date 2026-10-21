// Rune Weaver Dashboard — Shared onboarding status hook with focus and auth refresh.
import { useCallback, useEffect, useState } from "react";
import {
  completeOnboarding as apiCompleteOnboarding,
  dismissChecklist as apiDismissChecklist,
  getOnboardingStatus,
  isOnboardingCompleted,
  reopenOnboarding as apiReopenOnboarding,
  resetOnboarding as apiResetOnboarding,
  skipOnboardingStep as apiSkipOnboardingStep,
  type OnboardingStatus,
  type OnboardingStepId,
} from "../api/onboarding";
import { ApiError, subscribeAuthState } from "../api/http";

export interface UseOnboardingStatusResult {
  status: OnboardingStatus | null;
  isLoading: boolean;
  isCompleted: boolean;
  needsAuth: boolean;
  error: string | null;
  refresh: () => Promise<void>;
  complete: (seedPromptUsed: string) => Promise<void>;
  skip: (stepId: OnboardingStepId) => Promise<void>;
  dismiss: () => Promise<void>;
  reopen: () => Promise<void>;
  reset: () => Promise<void>;
}

export function useOnboardingStatus(options?: { disabled?: boolean }): UseOnboardingStatusResult {
  const disabled = options?.disabled === true;
  const [status, setStatus] = useState<OnboardingStatus | null>(null);
  const [isLoading, setIsLoading] = useState(!disabled);
  const [needsAuth, setNeedsAuth] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Single re-read path for mount, focus, auth change, and post-mutation refresh.
  const refresh = useCallback(async (): Promise<void> => {
    if (disabled) return;
    setIsLoading(true);
    try {
      const next = await getOnboardingStatus();
      setStatus(next);
      setNeedsAuth(false);
      setError(null);
    } catch (err) {
      // A uniform 401 means the credential is gone: surface needs-auth with no
      // cached row rather than an error string that invites retry.
      if (err instanceof ApiError && err.status === 401) {
        setStatus(null);
        setNeedsAuth(true);
        setError(null);
      } else {
        setError(err instanceof Error ? err.message : "Failed to load onboarding status");
      }
    } finally {
      setIsLoading(false);
    }
  }, [disabled]);

  // Initial read on mount; the cancelled flag drops a late resolve after unmount.
  useEffect(() => {
    if (disabled) {
      setIsLoading(false);
      return;
    }
    let cancelled = false;
    (async () => {
      setIsLoading(true);
      try {
        const next = await getOnboardingStatus();
        if (!cancelled) {
          setStatus(next);
          setNeedsAuth(false);
          setError(null);
        }
      } catch (err) {
        if (cancelled) return;
        if (err instanceof ApiError && err.status === 401) {
          setStatus(null);
          setNeedsAuth(true);
          setError(null);
        } else {
          setError(err instanceof Error ? err.message : "Failed to load onboarding status");
        }
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [disabled]);

  // Window focus re-reads so a second tab completing onboarding converges without reload.
  useEffect(() => {
    if (typeof window === "undefined") return;
    const handleFocus = (): void => {
      void refresh();
    };
    window.addEventListener("focus", handleFocus);
    return () => {
      window.removeEventListener("focus", handleFocus);
    };
  }, [refresh]);

  // Auth transitions drop the cached row and re-read: a login may now succeed
  // while a logout must not keep showing the previous owner's checklist.
  useEffect(() => {
    return subscribeAuthState(() => {
      setStatus(null);
      setNeedsAuth(false);
      setError(null);
      void refresh();
    });
  }, [refresh]);

  // Mutation wrappers refresh afterwards so callers never render a stale row.
  const complete = useCallback(
    async (seedPromptUsed: string): Promise<void> => {
      await apiCompleteOnboarding(seedPromptUsed);
      await refresh();
    },
    [refresh],
  );

  const skip = useCallback(
    async (stepId: OnboardingStepId): Promise<void> => {
      await apiSkipOnboardingStep(stepId);
      await refresh();
    },
    [refresh],
  );

  const dismiss = useCallback(async (): Promise<void> => {
    await apiDismissChecklist();
    await refresh();
  }, [refresh]);

  const reopen = useCallback(async (): Promise<void> => {
    await apiReopenOnboarding();
    await refresh();
  }, [refresh]);

  // Full reset clears completion plus skips plus dismissal plus seed,
  // then re-reads so the wizard gate remounts from the cleared row.
  const reset = useCallback(async (): Promise<void> => {
    await apiResetOnboarding();
    await refresh();
  }, [refresh]);

  return {
    status,
    isLoading,
    isCompleted: isOnboardingCompleted(status),
    needsAuth,
    error,
    refresh,
    complete,
    skip,
    dismiss,
    reopen,
    reset,
  };
}

export default useOnboardingStatus;
