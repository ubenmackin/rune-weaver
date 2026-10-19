// Rune Weaver Server — Onboarding REST surface for the setup wizard.

import Foundation
import RuneWeaverCore
import RuneWeaverLLM
import Vapor
#if canImport(EventKit)
    import EventKit
#endif

/// Registers every onboarding route on the application.
public func registerOnboardingRoutes(_ app: Application) {
    let onboarding = app.grouped(PathComponent.constant(ServerPaths.onboarding))
    onboarding.get(PathComponent.constant(ServerPaths.onboardingStatus), use: onboardingStatusHandler)
    onboarding.post(PathComponent.constant(ServerPaths.onboardingComplete), use: onboardingCompleteHandler)
    onboarding.post(PathComponent.constant(ServerPaths.onboardingSkip), use: onboardingSkipHandler)
    onboarding.post(PathComponent.constant(ServerPaths.onboardingDismiss), use: onboardingDismissHandler)
    onboarding.post(PathComponent.constant(ServerPaths.onboardingReopen), use: onboardingReopenHandler)
}

/// Rejects unauthenticated callers when an owner verifier is installed.
private func requireOnboardingAuth(_ req: Request) throws {
    if req.application.runeWeaverAuth != nil, !req.runeWeaverAuthenticated {
        throw Abort(.unauthorized, reason: "Owner authentication required.")
    }
}

/// Builds the live status snapshot, reading persisted state fresh each call.
private func liveOnboardingStatus(for req: Request) async throws -> OnboardingStatusResponse {
    let context = req.application.runeWeaver
    let state = try await readOnboardingState(context: context)
    let brainReady = await liveBrainReady(context: context)
    let personaSet = !context.persona.isDefaultIdentity
    let emailEvidence = await liveEmailEvidence(context: context)
    let calendarEvidence = liveCalendarEvidence()
    let indexEvidence = await liveIndexEvidence(context: context)
    let policyAcked = await livePolicyAcked(context: context, state: state)
    return makeOnboardingStatusResponse(
        state: state,
        readiness: OnboardingReadiness(
            brainReady: brainReady,
            personaSet: personaSet,
            emailReady: emailEvidence.ready,
            calendarReady: calendarEvidence.ready,
            indexReady: indexEvidence.ready,
            policyAcked: policyAcked,
            calendarStatus: calendarEvidence.status,
            emailAccounts: emailEvidence.accounts,
            indexEnabled: indexEvidence.enabled,
            indexWatermark: indexEvidence.watermark
        )
    )
}

/// Reads the single onboarding row off the event loop.
private func readOnboardingState(context: ServerContext) async throws -> OnboardingState {
    do {
        return try await SQLiteSerialIO.run { try context.onboarding.read() }
    } catch {
        throw Abort(.internalServerError, reason: error.localizedDescription)
    }
}

/// Persists the single onboarding row off the event loop.
private func writeOnboardingState(_ state: OnboardingState, context: ServerContext) async throws {
    do {
        try await SQLiteSerialIO.run { try context.onboarding.write(state) }
    } catch let error as OnboardingStoreError {
        throw mapOnboardingStoreError(error)
    }
}

/// Live serving posture only; file-config presence never counts without a
/// serving provider pinging healthy right now.
private func liveBrainReady(context: ServerContext) async -> Bool {
    guard let provider = context.servingLLM else {
        return false
    }
    return await provider.isAvailable()
}

/// Verified mail evidence: configured accounts plus UID watermarks.
/// Configured alone never counts; a watermark proves a UID fetch succeeded.
private func liveEmailEvidence(context: ServerContext) async -> (ready: Bool, accounts: [OnboardingEmailAccount]) {
    let accounts = await SQLiteSerialIO.runUncancellable {
        context.emailConfig?.accounts ?? []
    }
    guard !accounts.isEmpty else {
        return (false, [])
    }
    let store = MailIndexCheckpointStore(path: context.indexMailCheckpointPath)
    let watermarks = await store.snapshot().watermarks
    var rows: [OnboardingEmailAccount] = []
    rows.reserveCapacity(accounts.count)
    var anyVerified = false
    for account in accounts {
        let prefix = mailboxKey(account: account.name, mailbox: "")
        let verified = watermarks.keys.contains { $0.hasPrefix(prefix) && (watermarks[$0] ?? 0) > 0 }
        if verified {
            anyVerified = true
        }
        rows.append(OnboardingEmailAccount(address: account.name, fetchSucceeded: verified))
    }
    return (anyVerified, rows)
}

/// Verified calendar posture: exact granted token alone counts.
private func liveCalendarEvidence() -> (ready: Bool, status: String?) {
    #if canImport(EventKit)
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        return (granted, granted ? "granted" : nil)
    #else
        return (false, nil)
    #endif
}

/// Verified index evidence backing the status snapshot.
private struct IndexEvidence {
    let ready: Bool
    let enabled: Bool
    let watermark: String?
}

/// Verified index evidence: a wired store plus a real watermark both required.
private func liveIndexEvidence(context: ServerContext) async -> IndexEvidence {
    guard let store = context.indexStore else {
        return IndexEvidence(ready: false, enabled: false, watermark: nil)
    }
    guard let stats = try? await store.fastStats() else {
        return IndexEvidence(ready: false, enabled: true, watermark: nil)
    }
    let hasWatermark = stats.indexAsOf.timeIntervalSince1970 > 0
    let watermark = hasWatermark ? SharedDateFormatters.isoWithFractionalSecondsString(from: stats.indexAsOf) : nil
    return IndexEvidence(ready: hasWatermark, enabled: true, watermark: watermark)
}

/// Verified policy alone; a skipped protect step never
/// counts as acked so it reappears as a checklist item.
private func livePolicyAcked(context: ServerContext, state: OnboardingState) async -> Bool {
    if state.skippedSteps.contains("protect") {
        return false
    }
    let snapshot = await context.policyStore.readSnapshot()
    return snapshot.violations.isEmpty
}

/// Serves the persisted row plus live derived readiness.
private func onboardingStatusHandler(_ req: Request) async throws -> OnboardingStatusResponse {
    try requireOnboardingAuth(req)
    return try await liveOnboardingStatus(for: req)
}

/// Marks onboarding complete with the current instant.
private func onboardingCompleteHandler(_ req: Request) async throws -> OnboardingStatusResponse {
    try requireOnboardingAuth(req)
    let context = req.application.runeWeaver
    let body: OnboardingCompleteRequest
    do {
        body = try req.content.decode(OnboardingCompleteRequest.self)
    } catch {
        throw Abort(.badRequest, reason: "malformed onboarding complete body")
    }
    let rawSeed = body.seedPromptUsed?.trimmingCharacters(in: .whitespacesAndNewlines)
    let seed: String? = (rawSeed?.isEmpty ?? true) ? nil : rawSeed
    if let seed, seed.count > OnboardingStore.maxSeedPromptLength {
        throw Abort(.badRequest, reason: "seed_prompt_used exceeds \(OnboardingStore.maxSeedPromptLength) characters")
    }
    var state = try await readOnboardingState(context: context)
    if state.completedAt == nil {
        state.completedAt = Date()
    }
    if seed != nil {
        state.seedPromptUsed = seed
    }
    try await writeOnboardingState(state, context: context)
    return try await liveOnboardingStatus(for: req)
}

/// Records one allowlisted skip, refusing unknown ids with a machine token.
private func onboardingSkipHandler(_ req: Request) async throws -> Response {
    try requireOnboardingAuth(req)
    let context = req.application.runeWeaver
    let body: OnboardingSkipRequest
    do {
        body = try req.content.decode(OnboardingSkipRequest.self)
    } catch {
        return unknownStepResponse()
    }
    let trimmed = (body.step ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, OnboardingStore.allowedSteps.contains(trimmed) else {
        return unknownStepResponse()
    }
    var state = try await readOnboardingState(context: context)
    if state.completedAt != nil {
        throw Abort(.conflict, reason: "onboarding already completed")
    }
    if !state.skippedSteps.contains(trimmed) {
        guard state.skippedSteps.count < OnboardingStore.maxSkippedSteps else {
            throw Abort(.badRequest, reason: "skipped_steps exceeds \(OnboardingStore.maxSkippedSteps) entries")
        }
        state.skippedSteps.append(trimmed)
        let snapshot = state
        do {
            try await SQLiteSerialIO.run { try context.onboarding.write(snapshot) }
        } catch let error as OnboardingStoreError {
            if case .unknownStep = error {
                return unknownStepResponse()
            }
            throw mapOnboardingStoreError(error)
        }
    }
    let status = try await liveOnboardingStatus(for: req)
    return try await status.encodeResponse(for: req)
}

/// Dismisses the post-setup checklist without touching completion.
private func onboardingDismissHandler(_ req: Request) async throws -> OnboardingStatusResponse {
    try requireOnboardingAuth(req)
    let context = req.application.runeWeaver
    var state = try await readOnboardingState(context: context)
    state.checklistDismissed = true
    try await writeOnboardingState(state, context: context)
    return try await liveOnboardingStatus(for: req)
}

/// Reopens the wizard by clearing completion; prior values stay intact.
private func onboardingReopenHandler(_ req: Request) async throws -> OnboardingStatusResponse {
    try requireOnboardingAuth(req)
    let context = req.application.runeWeaver
    var state = try await readOnboardingState(context: context)
    state.completedAt = nil
    state.checklistDismissed = false
    try await writeOnboardingState(state, context: context)
    return try await liveOnboardingStatus(for: req)
}

/// Encodes the fixed unknown-step refusal body.
private func unknownStepResponse() -> Response {
    Response(
        status: .badRequest,
        headers: HTTPHeaders([("Content-Type", "application/json; charset=utf-8")]),
        body: .init(string: #"{"error":"unknown_step"}"#)
    )
}

/// Maps store bounds onto HTTP codes, keeping unknown steps machine-readable.
private func mapOnboardingStoreError(_ error: OnboardingStoreError) -> Abort {
    switch error {
    case let .unknownStep(step):
        Abort(.badRequest, reason: "unknown_step: \(step)")
    case let .tooManySkipped(count):
        Abort(.badRequest, reason: "skipped_steps exceeds \(OnboardingStore.maxSkippedSteps) entries (\(count))")
    case let .seedTooLong(count):
        Abort(.badRequest, reason: "seed_prompt_used exceeds \(OnboardingStore.maxSeedPromptLength) characters (\(count))")
    case let .storeUnavailable(detail):
        Abort(.internalServerError, reason: detail)
    case let .persistenceFailed(detail):
        Abort(.internalServerError, reason: detail)
    }
}
