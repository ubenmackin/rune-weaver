// Rune Weaver Server — Proactive idea REST surface for the engine API.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers every idea route on the application.
func registerIdeaRoutes(_ app: Application) {
    let ideas = app.grouped(PathComponent.constant(ServerPaths.ideas))
    registerIdeaListRoute(on: ideas)
    registerIdeaSummaryRoute(on: ideas)
    registerIdeaDismissRoute(on: ideas)
    registerIdeaAcceptRoute(on: ideas)
}

/// Lists ideas with optional status filtering for dashboards.
private func registerIdeaListRoute(on ideas: RoutesBuilder) {
    ideas.get { req async throws -> IdeasListResponse in
        let filter = try parseIdeaStatusFilter(req.query[String.self, at: "status"])
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 200)
        let stored = try await req.application.runeWeaver.ideas.list(status: filter, limit: limit)
        return IdeasListResponse(ideas: stored.map(IdeaDTO.init))
    }
}

/// Counts ideas per status for the dashboard attention badge.
private func registerIdeaSummaryRoute(on ideas: RoutesBuilder) {
    ideas.get(PathComponent.constant(ServerPaths.ideaSummary)) { req async throws -> IdeasSummaryResponse in
        let counts = try await req.application.runeWeaver.ideas.counts(status: nil)
        return IdeasSummaryResponse(
            proposed: counts[.proposed] ?? 0,
            accepted: counts[.accepted] ?? 0,
            dismissed: counts[.dismissed] ?? 0
        )
    }
}

/// Dismisses one proposed idea.
private func registerIdeaDismissRoute(on ideas: RoutesBuilder) {
    ideas.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.ideaDismiss)) { req async throws -> IdeaDTO in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        do {
            let updated = try await req.application.runeWeaver.ideas.setStatus(id: id, status: .dismissed)
            return IdeaDTO(updated)
        } catch let error as IdeasStoreError {
            throw mapIdeaStoreError(error, raw: raw)
        }
    }
}

/// Accepts one proposed idea, applying its suggested change. `new_goal` ideas route through
/// `GoalEngine.create` so the disabled and capped guards answer with the same honest 400 as `POST
/// /goals`.
private func registerIdeaAcceptRoute(on ideas: RoutesBuilder) {
    ideas.post(PathComponent.parameter("id"), PathComponent.constant(ServerPaths.ideaAccept)) { req async throws -> IdeaDTO in
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "id must be a UUID")
        }
        let context = req.application.runeWeaver
        let idea: Idea
        do {
            // A bounded single-row read keeps the accept lookup off the full
            // suggestion history; the store owns the row, the route never scans.
            guard let stored = try await context.ideas.idea(id: id) else {
                throw Abort(.notFound, reason: "Unknown idea \(raw)")
            }
            idea = stored
        } catch let error as IdeasStoreError {
            throw mapIdeaStoreError(error, raw: raw)
        }
        // Accepting is a one-way decision: a replayed accept must not apply the
        // suggestion twice, so an already-decided idea conflicts honestly.
        guard idea.status == .proposed else {
            throw Abort(.conflict, reason: "Idea \(raw) is already \(idea.status.rawValue)")
        }
        // Claim the transition atomically before the side effect so two racing
        // accepts (or a replay) can never both apply it: only the claim that
        // actually flips `proposed` proceeds to execute.
        let claimed: Idea
        do {
            claimed = try await context.ideas.claim(id: id, from: .proposed, to: .accepted)
        } catch let error as IdeasStoreError {
            throw mapIdeaStoreError(error, raw: raw)
        }
        do {
            try await applyAcceptedIdea(claimed, context: context)
        } catch {
            // The effect never landed (both create and replacePlan are all-or-nothing), so restore
            // our own claim to leave the suggestion actionable for a retry instead of stranding it
            // accepted with no change applied.
            do {
                _ = try await context.ideas.claim(id: id, from: .accepted, to: .proposed)
            } catch {
                RuneWeaverLog.server.warning("Failed to restore idea \(id) claim to proposed after apply failure: \(error.localizedDescription)")
            }
            throw error
        }
        return IdeaDTO(claimed)
    }
}

/// Applies the executable change behind one accepted idea. `new_goal` creation and the linked-goal
/// precondition for `plan_adjustment` are the only two effects; a tip is an acknowledgment.
private func applyAcceptedIdea(_ idea: Idea, context: ServerContext) async throws {
    switch idea.kind {
    case .newGoal:
        let created: Goal
        do {
            created = try await context.goalEngine.create(
                title: idea.title,
                statement: idea.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? idea.title : idea.body
            )
        } catch let error as GoalEngineError {
            // Disabled and capped creation share 400 with the engine's honest
            // message so dashboards surface why the goal was refused.
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
        // The creation already landed, so push the row for live dashboards the
        // same way the create route does: an immediate snapshot plus a detached
        // plan-ready refresh once background decomposition lands.
        let plan: [GoalStep]
        do {
            plan = try await context.goals.steps(goalID: created.id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            RuneWeaverLog.server.warning("ServerIdeaRoutes: failed to read steps for created goal \(created.id): \(error.localizedDescription)")
            plan = []
        }
        await context.hub.broadcastGoal(GoalDTO(goal: created, steps: plan))
        context.schedulePlanReadyBroadcast(goalID: created.id)
    case .planAdjustment:
        let goalID = try await linkedActiveGoalID(for: idea, store: context.goals)
        let steps = planSteps(from: idea, goalID: goalID)
        do {
            try await context.goals.replacePlan(goalID: goalID, steps: steps)
        } catch let error as GoalStoreError {
            throw mapGoalStoreError(error, raw: goalID.uuidString)
        }
        // The replan already landed, so a refresh read failure surfaces as a
        // storage error rather than a silent no-broadcast; the route's rollback
        // then leaves the idea retryable and `replacePlan` is idempotent.
        let refreshed: Goal?
        do {
            refreshed = try await context.goals.goal(id: goalID)
        } catch let error as GoalStoreError {
            throw mapGoalStoreError(error, raw: goalID.uuidString)
        }
        if let updated = refreshed {
            let plan: [GoalStep]
            do {
                plan = try await context.goals.steps(goalID: goalID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                RuneWeaverLog.server.warning("ServerIdeaRoutes: failed to read steps for updated goal \(goalID): \(error.localizedDescription)")
                plan = []
            }
            await context.hub.broadcastGoal(GoalDTO(goal: updated, steps: plan))
        }
    case .tip:
        // A tip carries no executable change; accepting it only flips status.
        break
    }
}

/// Resolves the active goal a plan-adjustment idea targets.
private func linkedActiveGoalID(for idea: Idea, store: GoalStore) async throws -> UUID {
    guard let goalID = idea.goalID else {
        throw Abort(.conflict, reason: "Idea \"\(idea.title)\" is not linked to a goal.")
    }
    // A read failure maps to its honest store status instead of masquerading as
    // a missing link: a transient storage fault must surface as a 500, not as a
    // conflict the owner would chase by re-pointing the idea.
    let goal: Goal
    do {
        guard let stored = try await store.goal(id: goalID) else {
            throw Abort(.conflict, reason: "Linked goal \(goalID.uuidString) no longer exists.")
        }
        goal = stored
    } catch let error as GoalStoreError {
        throw mapGoalStoreError(error, raw: goalID.uuidString)
    }
    guard goal.status == .active else {
        throw Abort(.conflict, reason: "Linked goal \(goalID.uuidString) is not active (status \(goal.status.rawValue)).")
    }
    return goalID
}

/// Builds the replacement plan for one accepted adjustment.
private func planSteps(from idea: Idea, goalID: UUID) -> [GoalStep] {
    let lines = idea.body
        .split(whereSeparator: { $0.isNewline })
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let titles = (lines.isEmpty ? [idea.title] : lines)
        .prefix(IdeasEngine.maxAdjustmentSteps)
        .map { String($0.prefix(IdeasEngine.maxAdjustmentStepLength)) }
    return titles.enumerated().map { index, title in
        GoalStep(goalID: goalID, ordinal: index, title: title, status: .pending)
    }
}

/// Parses an optional status filter for the idea list route. Blank and absent both mean unfiltered;
/// an unknown value fails with a 400 naming the input instead of silently listing everything.
func parseIdeaStatusFilter(_ raw: String?) throws -> IdeaStatus? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let status = IdeaStatus(rawValue: trimmed) else {
        throw Abort(.badRequest, reason: "unknown status \(raw)")
    }
    return status
}

/// Maps idea store failures to HTTP codes: unknown rows become 404, a failed guarded transition
/// becomes 409, and transport failures stay 500 instead of leaking driver detail.
/// error: Store failure.
func mapIdeaStoreError(_ error: IdeasStoreError, raw: String) -> Abort {
    switch error {
    case let .notFound(detail):
        Abort(.notFound, reason: detail.isEmpty ? "Unknown idea \(raw)" : detail)
    case let .conflict(detail):
        Abort(.conflict, reason: detail.isEmpty ? "Idea \(raw) is no longer proposed" : detail)
    case let .storeUnavailable(detail):
        Abort(.internalServerError, reason: detail)
    case let .persistenceFailed(detail):
        Abort(.internalServerError, reason: detail)
    }
}
