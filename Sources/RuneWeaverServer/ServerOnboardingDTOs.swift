// Rune Weaver Server — Onboarding status contracts for the setup wizard.

import Foundation
import RuneWeaverCore
import Vapor

/// Verified mail account evidence backing the setup wizard seed contract.
public struct OnboardingEmailAccount: Content, Equatable, Sendable {
    /// Account nickname from the live mail config.
    public var address: String
    /// Whether a UID fetch watermark proves the path live.
    public var fetchSucceeded: Bool

    /// Creates a verified mail account row.
    public init(address: String = "", fetchSucceeded: Bool = false) {
        self.address = address
        self.fetchSucceeded = fetchSucceeded
    }
}

/// Persisted plus derived onboarding snapshot for `GET /onboarding/status`.
public struct OnboardingStatusResponse: Content, Equatable, Sendable {
    /// Completion instant, nil while the wizard never finished.
    public var completedAt: Date?
    /// Skipped step ids from the closed allowlist.
    public var skippedSteps: [String]
    /// Whether the post-setup checklist is dismissed.
    public var checklistDismissed: Bool
    /// Optional owner seed prompt, capped at 200 characters.
    public var seedPromptUsed: String?
    /// Whether a serving LLM provider is wired.
    public var brainReady: Bool
    /// Whether the owner persona diverges from stock defaults.
    public var personaSet: Bool
    /// Whether at least one mail account is configured.
    public var emailReady: Bool
    /// Whether calendar access is granted for live reads.
    public var calendarReady: Bool
    /// Whether the document index carries a watermark.
    public var indexReady: Bool
    /// Whether the live security policy verifies.
    public var policyAcked: Bool
    /// Verified calendar posture (`"granted"` when authorized, nil otherwise).
    public var calendarStatus: String?
    /// Verified mail accounts; `fetchSucceeded` proves a UID watermark.
    public var emailAccounts: [OnboardingEmailAccount]
    /// Whether the document index is enabled.
    public var indexEnabled: Bool
    /// Verified index watermark as ISO-8601, nil when no pass has run.
    public var indexWatermark: String?

    /// Creates a status snapshot.
    public init(
        completedAt: Date? = nil,
        skippedSteps: [String] = [],
        checklistDismissed: Bool = false,
        seedPromptUsed: String? = nil,
        brainReady: Bool = false,
        personaSet: Bool = false,
        emailReady: Bool = false,
        calendarReady: Bool = false,
        indexReady: Bool = false,
        policyAcked: Bool = false,
        calendarStatus: String? = nil,
        emailAccounts: [OnboardingEmailAccount] = [],
        indexEnabled: Bool = false,
        indexWatermark: String? = nil
    ) {
        self.completedAt = completedAt
        self.skippedSteps = skippedSteps
        self.checklistDismissed = checklistDismissed
        self.seedPromptUsed = seedPromptUsed
        self.brainReady = brainReady
        self.personaSet = personaSet
        self.emailReady = emailReady
        self.calendarReady = calendarReady
        self.indexReady = indexReady
        self.policyAcked = policyAcked
        self.calendarStatus = calendarStatus
        self.emailAccounts = emailAccounts
        self.indexEnabled = indexEnabled
        self.indexWatermark = indexWatermark
    }
}

/// Live derived readiness flags backing the setup wizard checklist.
public struct OnboardingReadiness: Equatable, Sendable {
    /// Whether a serving LLM provider is wired.
    public var brainReady: Bool
    /// Whether the owner persona diverges from stock defaults.
    public var personaSet: Bool
    /// Whether at least one mail account is configured.
    public var emailReady: Bool
    /// Whether calendar access is granted for live reads.
    public var calendarReady: Bool
    /// Whether the document index carries a watermark.
    public var indexReady: Bool
    /// Whether the live security policy verifies.
    public var policyAcked: Bool
    /// Verified calendar posture (`"granted"` when authorized, nil otherwise).
    public var calendarStatus: String?
    /// Verified mail accounts; `fetchSucceeded` proves a UID watermark.
    public var emailAccounts: [OnboardingEmailAccount]
    /// Whether the document index is enabled.
    public var indexEnabled: Bool
    /// Verified index watermark as ISO-8601, nil when no pass has run.
    public var indexWatermark: String?

    /// Creates a readiness snapshot, defaulting every flag to not ready.
    public init(
        brainReady: Bool = false,
        personaSet: Bool = false,
        emailReady: Bool = false,
        calendarReady: Bool = false,
        indexReady: Bool = false,
        policyAcked: Bool = false,
        calendarStatus: String? = nil,
        emailAccounts: [OnboardingEmailAccount] = [],
        indexEnabled: Bool = false,
        indexWatermark: String? = nil
    ) {
        self.brainReady = brainReady
        self.personaSet = personaSet
        self.emailReady = emailReady
        self.calendarReady = calendarReady
        self.indexReady = indexReady
        self.policyAcked = policyAcked
        self.calendarStatus = calendarStatus
        self.emailAccounts = emailAccounts
        self.indexEnabled = indexEnabled
        self.indexWatermark = indexWatermark
    }
}

/// Builds a status response from stored state plus live readiness flags.
public func makeOnboardingStatusResponse(
    state: OnboardingState,
    readiness: OnboardingReadiness
) -> OnboardingStatusResponse {
    OnboardingStatusResponse(
        completedAt: state.completedAt,
        skippedSteps: state.skippedSteps,
        checklistDismissed: state.checklistDismissed,
        seedPromptUsed: state.seedPromptUsed,
        brainReady: readiness.brainReady,
        personaSet: readiness.personaSet,
        emailReady: readiness.emailReady,
        calendarReady: readiness.calendarReady,
        indexReady: readiness.indexReady,
        policyAcked: readiness.policyAcked,
        calendarStatus: readiness.calendarStatus,
        emailAccounts: readiness.emailAccounts,
        indexEnabled: readiness.indexEnabled,
        indexWatermark: readiness.indexWatermark
    )
}

/// Skip request carrying one allowlisted step id.
public struct OnboardingSkipRequest: Content, Equatable {
    /// Step to record as skipped.
    public var step: String?

    /// Creates a skip request.
    public init(step: String? = nil) {
        self.step = step
    }
}

/// Completion request carrying an optional seed prompt.
public struct OnboardingCompleteRequest: Content, Equatable {
    /// Optional owner seed prompt, capped at 200 characters.
    public var seedPromptUsed: String?

    /// Creates a completion request.
    public init(seedPromptUsed: String? = nil) {
        self.seedPromptUsed = seedPromptUsed
    }
}

/// Machine-readable unknown-step refusal for `POST /onboarding/skip`.
public struct OnboardingErrorResponse: Content, Equatable {
    /// Fixed error token (`"unknown_step"`).
    public var error: String

    /// Creates an error refusal.
    public init(error: String) {
        self.error = error
    }
}

extension ServerPaths {
    /// Onboarding group backing the setup wizard.
    public static let onboarding = "onboarding"
    /// Status subpath under `/onboarding`.
    public static let onboardingStatus = "status"
    /// Completion subpath under `/onboarding`.
    public static let onboardingComplete = "complete"
    /// Skip subpath under `/onboarding`.
    public static let onboardingSkip = "skip"
    /// Dismiss subpath under `/onboarding`.
    public static let onboardingDismiss = "dismiss"
    /// Reopen subpath under `/onboarding`.
    public static let onboardingReopen = "reopen"
}
