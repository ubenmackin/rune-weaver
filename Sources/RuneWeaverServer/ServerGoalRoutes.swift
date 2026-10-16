// Rune Weaver Server — Goal pursuit REST surface plus live push fan-out.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers every goal route on the application.
func registerGoalRoutes(_ app: Application) {
    let goals = app.grouped(PathComponent.constant(ServerPaths.goals))
    registerGoalListRoute(on: goals)
    registerGoalCreateRoute(on: goals)
    registerGoalSummaryRoute(on: goals)
    registerGoalDetailRoute(on: goals)
    registerGoalPatchRoute(on: goals)
    registerGoalDeleteRoute(on: goals)
    registerGoalAdvanceRoute(on: goals)
    registerGoalStepRoute(on: goals)
}

/// Lists goals with optional status filtering for dashboards. Steps stay per-row because plans are
/// bounded by config; fan-out lives here so the thin dispatcher stays free of closure detail.
private func registerGoalListRoute(on goals: RoutesBuilder) {
    goals.get { req async throws -> GoalsListResponse in
        let filter = try parseGoalStatusFilter(req.query[String.self, at: "status"])
        let context = req.application.runeWeaver
        let stored = try await context.goals.list(status: filter)
        var dtos: [GoalDTO] = []
        dtos.reserveCapacity(stored.count)
        for goal in stored {
            // Steps stay per-row because plans are bounded by config; a missing
            // plan degrades to empty progress instead of failing the list.
            let steps: [GoalStep]
            do {
                steps = try await context.goals.steps(goalID: goal.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                req.logger.warning("ServerGoalRoutes: failed to load steps for goal \(goal.id): \(error.localizedDescription)")
                steps = []
            }
            let isPlanning = await context.goalEngine.isPlanning(goalID: goal.id)
            dtos.append(GoalDTO(goal: goal, steps: steps, isPlanning: isPlanning))
        }
        return GoalsListResponse(goals: dtos)
    }
}

/// Creates a goal with background planning for dashboards and headless clients. Planning lands
/// shortly after creation on a tracked background task; the detached hop lives here so the
/// dispatcher never carries turn logic.
private func registerGoalCreateRoute(on goals: RoutesBuilder) {
    goals.post { req async throws -> GoalDetailResponse in
        let body = try req.content.decode(GoalCreateRequest.self)
        let title = try validatedGoalTitle(body.title)
        let statement = try validatedGoalStatement(body.statement)
        let cadence = try validatedGoalCadence(body.stepIntervalMinutes)
        let triggerDrafts = try goalTriggerDrafts(body.triggers)
        let context = req.application.runeWeaver
        let goal: Goal
        do {
            goal = try await context.goalEngine.create(
                title: title,
                statement: statement,
                cadence: cadence,
                triggers: triggerDrafts
            )
        } catch let error as GoalEngineError {
            // Disabled and capped creation share 400 with the engine's honest
            // message so dashboards surface why the row was refused.
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
        let steps: [GoalStep]
        do {
            steps = try await context.goals.steps(goalID: goal.id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load steps for goal \(goal.id): \(error.localizedDescription)")
            steps = []
        }
        let triggers: [GoalTriggerDTO]
        do {
            triggers = try await context.goals.triggers(for: goal.id).map(GoalTriggerDTO.init)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load triggers for goal \(goal.id): \(error.localizedDescription)")
            triggers = []
        }
        let events: [GoalEvent]
        do {
            events = try await context.goals.events(goalID: goal.id, limit: 50)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load events for goal \(goal.id): \(error.localizedDescription)")
            events = []
        }
        let dto = GoalDTO(goal: goal, steps: steps, isPlanning: true)
        await context.hub.broadcastGoal(dto)
        // Planning lands shortly after creation on a tracked background task;
        // awaiting it here would stall the response, so a background task waits
        // for the plan and pushes the ready row for live dashboards.
        context.schedulePlanReadyBroadcast(goalID: goal.id)
        return GoalDetailResponse(
            goal: dto,
            steps: steps.map(GoalStepDTO.init),
            triggers: triggers,
            events: events.map(GoalEventDTO.init)
        )
    }
}

/// Counts goals per status for dashboard badges.
private func registerGoalSummaryRoute(on goals: RoutesBuilder) {
    goals.get(PathComponent.constant(ServerPaths.goalSummary)) { req async throws -> GoalsSummaryResponse in
        let all = try await req.application.runeWeaver.goals.list(status: nil)
        var active = 0
        var paused = 0
        var needsInput = 0
        var achieved = 0
        var abandoned = 0
        var unplanned = 0
        for goal in all {
            switch goal.status {
            case .active:
                active += 1
            case .paused:
                paused += 1
            case .needsInput:
                needsInput += 1
            case .achieved:
                achieved += 1
            case .abandoned:
                abandoned += 1
            case .unplanned:
                unplanned += 1
            }
        }
        return GoalsSummaryResponse(
            total: all.count,
            active: active,
            paused: paused,
            needsInput: needsInput,
            achieved: achieved,
            abandoned: abandoned,
            unplanned: unplanned
        )
    }
}

/// Fetches one goal with its plan and bounded audit history. A present limit must sit inside the
/// advertised range instead of silently clamping; the tail bound lives here so the dispatcher stays
/// declarative.
private func registerGoalDetailRoute(on goals: RoutesBuilder) {
    goals.get(PathComponent.parameter("id")) { req async throws -> GoalDetailResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard let goal = try await context.goals.goal(id: id) else {
            throw Abort(.notFound, reason: "Unknown goal \(raw)")
        }
        // Bounded tail keeps long audit trails from crowding the row; a present
        // limit must sit inside the advertised range instead of silently clamping.
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 200)
        let steps = try await context.goals.steps(goalID: id)
        let triggers: [GoalTriggerDTO]
        do {
            triggers = try await context.goals.triggers(for: id).map(GoalTriggerDTO.init)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load triggers for goal \(id): \(error.localizedDescription)")
            triggers = []
        }
        let events = try await context.goals.events(goalID: id, limit: limit)
        let isPlanning = await context.goalEngine.isPlanning(goalID: id)
        return GoalDetailResponse(
            goal: GoalDTO(goal: goal, steps: steps, isPlanning: isPlanning),
            steps: steps.map(GoalStepDTO.init),
            triggers: triggers,
            events: events.map(GoalEventDTO.init)
        )
    }
}

/// Edits a goal's fields and lifecycle state with all-or-nothing validation. Every present field
/// validates before any column writes so a bad patch never half-applies title before failing on
/// interval.
private func registerGoalPatchRoute(on goals: RoutesBuilder) {
    goals.patch(PathComponent.parameter("id")) { req async throws -> GoalDetailResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let body = try req.content.decode(GoalPatchRequest.self)
        let context = req.application.runeWeaver
        guard try await context.goals.goal(id: id) != nil else {
            throw Abort(.notFound, reason: "Unknown goal \(raw)")
        }
        // Validate every present field before writing any column so a bad patch
        // never half-applies title before failing on interval.
        var newTitle: String?
        if let rawTitle = body.title {
            newTitle = try validatedGoalTitle(rawTitle)
        }
        var newStatement: String?
        if let rawStatement = body.statement {
            newStatement = try validatedGoalStatement(rawStatement)
        }
        var newInterval: Int?
        if let rawInterval = body.stepIntervalMinutes {
            newInterval = try validatedGoalCadence(rawInterval)
        }
        var newStatus: GoalStatus?
        if let rawStatus = body.status {
            newStatus = try parseGoalStatus(rawStatus)
        }
        // Trigger edits validate before any write so a blank kind never lands a
        // half-applied goal patch; present means replace, absent leaves the
        // armed set untouched.
        let triggerInputs = body.triggers
        if let triggerInputs {
            for input in triggerInputs where input.trimmedEventKind.isEmpty {
                throw Abort(.badRequest, reason: "trigger eventKind must not be empty")
            }
        }
        if newTitle != nil || newStatement != nil || newInterval != nil {
            do {
                _ = try await context.goals.updateDetails(
                    goalID: id,
                    title: newTitle,
                    statement: newStatement,
                    stepIntervalMinutes: newInterval
                )
            } catch let error as GoalStoreError {
                throw mapGoalStoreError(error, raw: raw)
            }
        }
        if let newStatus {
            do {
                try await context.goals.setStatus(goalID: id, status: newStatus)
            } catch let error as GoalStoreError {
                throw mapGoalStoreError(error, raw: raw)
            }
        }
        if let triggerInputs {
            // The absolute bound is the store's last-resort guard; the configured
            // per-goal budget is what create already honors, so an edit cannot
            // arm more triggers than creation would.
            let triggerBudget = await context.goalEngine.maxTriggersPerGoal
            try await replaceGoalTriggers(triggerInputs, goalID: id, store: context.goals, budget: triggerBudget)
        }
        guard let updated = try await context.goals.goal(id: id) else {
            throw Abort(.notFound, reason: "Unknown goal \(raw)")
        }
        let steps: [GoalStep]
        do {
            steps = try await context.goals.steps(goalID: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load steps for goal \(id): \(error.localizedDescription)")
            steps = []
        }
        let triggers: [GoalTriggerDTO]
        do {
            triggers = try await context.goals.triggers(for: id).map(GoalTriggerDTO.init)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load triggers for goal \(id): \(error.localizedDescription)")
            triggers = []
        }
        let events: [GoalEvent]
        do {
            events = try await context.goals.events(goalID: id, limit: 50)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            req.logger.warning("ServerGoalRoutes: failed to load events for goal \(id): \(error.localizedDescription)")
            events = []
        }
        let isPlanning = await context.goalEngine.isPlanning(goalID: id)
        let dto = GoalDTO(goal: updated, steps: steps, isPlanning: isPlanning)
        await context.hub.broadcastGoal(dto)
        return GoalDetailResponse(
            goal: dto,
            steps: steps.map(GoalStepDTO.init),
            triggers: triggers,
            events: events.map(GoalEventDTO.init)
        )
    }
}

/// Tombstones or hard-deletes a goal.
private func registerGoalDeleteRoute(on goals: RoutesBuilder) {
    goals.delete(PathComponent.parameter("id")) { req async throws -> HTTPStatus in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard try await context.goals.goal(id: id) != nil else {
            throw Abort(.notFound, reason: "Unknown goal \(raw)")
        }
        // Purge accepts both native booleans and string spellings so dashboard
        // toggles and hand-built curls agree without a second parameter.
        let purge = req.query[Bool.self, at: "purge"]
            ?? (req.query[String.self, at: "purge"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true")
        if purge {
            try await context.goalEngine.delete(goalID: id)
        } else {
            // Tombstone keeps history joinable: the row flips to abandoned
            // instead of vanishing, so run filters still resolve.
            try await context.goals.setStatus(goalID: id, status: .abandoned)
            if let updated = try await context.goals.goal(id: id) {
                let steps: [GoalStep]
                do {
                    steps = try await context.goals.steps(goalID: id)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    req.logger.warning("ServerGoalRoutes: failed to load steps for goal \(id): \(error.localizedDescription)")
                    steps = []
                }
                let isPlanning = await context.goalEngine.isPlanning(goalID: id)
                await context.hub.broadcastGoal(GoalDTO(goal: updated, steps: steps, isPlanning: isPlanning))
            }
        }
        return .noContent
    }
}

/// Manually advances a goal through the shared scheduler worker.
private func registerGoalAdvanceRoute(on goals: RoutesBuilder) {
    goals.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.goalAdvance)) { req async throws -> GoalAdvanceResponse in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        guard let goal = try await context.goals.goal(id: id) else {
            throw Abort(.notFound, reason: "Unknown goal \(raw)")
        }
        if goal.status == .unplanned {
            if await context.goalEngine.isPlanning(goalID: id) {
                throw Abort(.conflict, reason: "Goal \(raw) is already being planned")
            }
            let runID = await context.goalEngine.startPlanTask(for: goal)
            let steps: [GoalStep]
            do {
                steps = try await context.goals.steps(goalID: id)
            } catch {
                steps = []
            }
            await context.hub.broadcastGoal(GoalDTO(goal: goal, steps: steps, isPlanning: true))
            context.schedulePlanReadyBroadcast(goalID: id)
            return GoalAdvanceResponse(runID: runID, sessionID: UUID(), goalID: id)
        }
        do {
            // The worker owns the single-flight lock, session, run row, and
            // proactive gating so manual fires ride the exact background path
            // instead of a route-local reimplementation that could drift.
            let (runID, sessionID) = try await context.schedulerWorker.advanceGoalNow(goalID: id)
            return GoalAdvanceResponse(runID: runID, sessionID: sessionID, goalID: id)
        } catch let error as GoalEngineError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        } catch is ServerSchedulerWorker.GoalBusyError {
            // Mirrors the manual job run: the skipped audit row already landed,
            // so the route only needs the honest contention code.
            throw Abort(.conflict, reason: "Goal \(raw) is already running")
        } catch let error as GoalStoreError {
            throw mapGoalStoreError(error, raw: raw)
        } catch is CancellationError {
            throw Abort(.gone, reason: "Advance was cancelled")
        } catch let error as OrchestratorError {
            throw mapOrchestratorAdvanceError(error)
        } catch {
            throw Abort(.badGateway, reason: error.localizedDescription)
        }
    }
}

/// Moves one plan step and pushes the refreshed row. A blank note preserves history instead of
/// wiping prior text with whitespace; manual moves are progress boundaries so the refreshed row
/// broadcasts for live dashboards.
private func registerGoalStepRoute(on goals: RoutesBuilder) {
    goals.patch(
        PathComponent.parameter("id"),
        PathComponent.constant(ServerPaths.goalSteps),
        PathComponent.parameter("stepId")
    ) { req async throws -> GoalStepDTO in
        guard let rawGoal = req.parameters.get("id"), let goalID = UUID(uuidString: rawGoal) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        guard let rawStep = req.parameters.get("stepId"), let stepID = UUID(uuidString: rawStep) else {
            throw Abort(.badRequest, reason: "stepId must be a UUID")
        }
        let body = try req.content.decode(GoalStepPatchRequest.self)
        let status = try parseStepStatus(body.status)
        // A blank note preserves history instead of wiping prior text with
        // whitespace; the store keeps prior notes on nil via COALESCE.
        let trimmedNote: String? = {
            guard let note = body.note else { return nil }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let context = req.application.runeWeaver
        guard try await context.goals.goal(id: goalID) != nil else {
            throw Abort(.notFound, reason: "Unknown goal \(rawGoal)")
        }
        do {
            try await context.goals.setStepStatus(
                goalID: goalID,
                stepID: stepID,
                status: status,
                notes: trimmedNote,
                lastRunID: nil
            )
        } catch let error as GoalStoreError {
            throw mapGoalStoreError(error, raw: rawStep)
        }
        if status == .done || status == .skipped {
            try await context.goalEngine.checkCompletion(goalID: goalID)
        }
        let steps = try await context.goals.steps(goalID: goalID)
        guard let updated = steps.first(where: { $0.id == stepID }) else {
            throw Abort(.notFound, reason: "Unknown step \(rawStep)")
        }
        // Manual moves are progress boundaries: push the refreshed row so the
        // dashboard tally updates without refetching the plan.
        if let goal = try await context.goals.goal(id: goalID) {
            let isPlanning = await context.goalEngine.isPlanning(goalID: goalID)
            await context.hub.broadcastGoal(GoalDTO(goal: goal, steps: steps, isPlanning: isPlanning))
        }
        return GoalStepDTO(updated)
    }
}

/// Maps advancement turn failures to HTTP codes without leaking engine detail. Empty input is a
/// caller 400, loop overflow is unprocessable, and LLM transport stays a gateway failure so
/// dashboards keep the honest code.
private func mapOrchestratorAdvanceError(_ error: OrchestratorError) -> Abort {
    switch error {
    case .emptyInput:
        Abort(.badRequest, reason: "text must not be empty")
    case let .toolLoopExceeded(iterations):
        Abort(.unprocessableEntity, reason: "Tool loop exceeded \(iterations) rounds")
    case let .llmFailed(detail):
        Abort(.badGateway, reason: detail)
    }
}

/// Validates a goal title once for create and patch. Thin REST wrapper over the shared validator so
/// the route and CLI share one trimmed-empty rule while keeping the `Abort` idiom locally.
func validatedGoalTitle(_ raw: String) throws -> String {
    do {
        return try GoalValidation.validatedTitle(raw)
    } catch {
        throw Abort(.badRequest, reason: "title must not be empty")
    }
}

/// Validates a goal statement once for create and patch. Thin REST wrapper over the shared
/// validator so the route and CLI share one trimmed-empty rule while keeping the `Abort` idiom
/// locally.
func validatedGoalStatement(_ raw: String) throws -> String {
    do {
        return try GoalValidation.validatedStatement(raw)
    } catch {
        throw Abort(.badRequest, reason: "statement must not be empty")
    }
}

/// Validates an optional cadence hint against the configured pursuit bounds. Thin REST wrapper over
/// the config-owned validator so the route and CLI share one range while keeping their own error
/// idioms.
func validatedGoalCadence(_ raw: Int?) throws -> Int? {
    do {
        return try GoalsConfig.validateCadence(raw)
    } catch let error as GoalValidationError {
        switch error {
        case let .cadenceOutOfRange(value):
            throw Abort(
                .badRequest,
                reason: "stepIntervalMinutes must be between \(GoalsConfig.minStepIntervalMinutes) and \(GoalsConfig.maxStepIntervalMinutes) (got \(value))"
            )
        default:
            throw Abort(.badRequest, reason: "stepIntervalMinutes is invalid")
        }
    }
}

/// Maps REST trigger inputs onto engine draft specs, rejecting blank kinds. A trigger without an
/// event kind can never match, so it fails the request instead of being armed as dead weight.
private func goalTriggerDrafts(_ inputs: [GoalTriggerInput]?) throws -> [GoalTriggerDraft] {
    guard let inputs else { return [] }
    var drafts: [GoalTriggerDraft] = []
    drafts.reserveCapacity(inputs.count)
    for input in inputs {
        let kind = input.trimmedEventKind
        guard !kind.isEmpty else {
            throw Abort(.badRequest, reason: "trigger eventKind must not be empty")
        }
        drafts.append(GoalTriggerDraft(eventKind: kind, pattern: input.trimmedPattern, cooldownMinutes: input.cooldownMinutes))
    }
    return drafts
}

/// Replaces a goal's armed triggers through one atomic store transaction.
private func replaceGoalTriggers(
    _ inputs: [GoalTriggerInput],
    goalID: UUID,
    store: GoalStore,
    budget: Int
) async throws {
    let cap = min(max(0, budget), GoalsConfig.maxTriggersPerGoalBound)
    var drafts: [GoalTriggerDraft] = []
    drafts.reserveCapacity(min(inputs.count, cap))
    for input in inputs.prefix(cap) {
        let kind = input.trimmedEventKind
        guard !kind.isEmpty else {
            throw Abort(.badRequest, reason: "trigger eventKind must not be empty")
        }
        let cooldown = max(
            GoalsConfig.minTriggerCooldownMinutes,
            input.cooldownMinutes ?? GoalsConfig.defaultTriggerCooldownMinutes
        )
        drafts.append(GoalTriggerDraft(eventKind: kind, pattern: input.trimmedPattern, cooldownMinutes: cooldown))
    }
    do {
        try await store.replaceTriggers(goalID: goalID, drafts: drafts)
    } catch let error as GoalStoreError {
        throw mapGoalStoreError(error, raw: goalID.uuidString)
    }
}

/// Parses an optional status filter for list routes.
func parseGoalStatusFilter(_ raw: String?) throws -> GoalStatus? {
    do {
        return try GoalValidation.parseGoalStatusFilter(raw)
    } catch let error as GoalValidationError {
        switch error {
        case let .unknownGoalStatus(value):
            throw Abort(.badRequest, reason: "unknown status \(value)")
        case .emptyGoalStatus:
            throw Abort(.badRequest, reason: "status must not be empty")
        default:
            throw Abort(.badRequest, reason: "status is invalid")
        }
    }
}

/// Parses a required goal lifecycle state. Thin REST wrapper over the shared validator: only the
/// exact `rawValue` plus the `needsInput` camelCase alias for the parked state.
func parseGoalStatus(_ raw: String) throws -> GoalStatus {
    do {
        return try GoalValidation.parseGoalStatus(raw)
    } catch let error as GoalValidationError {
        switch error {
        case .emptyGoalStatus:
            throw Abort(.badRequest, reason: "status must not be empty")
        case let .unknownGoalStatus(value):
            throw Abort(.badRequest, reason: "unknown status \(value)")
        default:
            throw Abort(.badRequest, reason: "status is invalid")
        }
    }
}

/// Parses a required step state.
func parseStepStatus(_ raw: String) throws -> StepStatus {
    do {
        return try GoalValidation.parseStepStatus(raw)
    } catch let error as GoalValidationError {
        switch error {
        case .emptyStepStatus:
            throw Abort(.badRequest, reason: "status must not be empty")
        case let .unknownStepStatus(value):
            throw Abort(.badRequest, reason: "unknown status \(value)")
        default:
            throw Abort(.badRequest, reason: "status is invalid")
        }
    }
}

/// Maps store failures to HTTP codes: unknown rows become 404 while transport failures stay 500
/// instead of leaking driver detail. error: Store failure.
func mapGoalStoreError(_ error: GoalStoreError, raw: String) -> Abort {
    switch error {
    case let .notFound(detail):
        Abort(.notFound, reason: detail.isEmpty ? "Unknown goal \(raw)" : detail)
    case let .storeUnavailable(detail):
        Abort(.internalServerError, reason: detail)
    case let .persistenceFailed(detail):
        Abort(.internalServerError, reason: detail)
    }
}
