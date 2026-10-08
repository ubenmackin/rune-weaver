// Rune Weaver Server — Proactive idea REST surface for the engine API.
//
// Purpose: exposes the suggestions the Wayfinder engine proposes over HTTP so
// dashboards can review them: listing with status filtering, per-status counts
// for the attention badge, dismissal, and acceptance. Acceptance is the single
// write this surface performs, and it routes through the same pursuit
// machinery the goal routes use rather than inventing a second execution path.
// Scope: route registration, request validation, decision routing, and
// `goal_updated` broadcasts only; durable rows stay with `IdeasStore` and
// planning plus goal creation stay with `GoalEngine`.
// Architectural role: thin Vapor adapter over the core suggestion store and
// pursuit engine, mirroring the goal route idiom (strict UUID checks, clamped
// limits, honest status codes, global middleware auth with no per-route
// checks) while keeping every accepted change observable on the shared hub.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers every idea route on the application.
///
/// Global middleware already guards data paths, so no route installs its own
/// auth; the summary literal registers before the `:id` parameter so the exact
/// path wins without relying on registration order.
/// - Parameter app: Application receiving the routes.
func registerIdeaRoutes(_ app: Application) {
    let ideas = app.grouped(PathComponent.constant(ServerPaths.ideas))
    registerIdeaListRoute(on: ideas)
    registerIdeaSummaryRoute(on: ideas)
    registerIdeaDismissRoute(on: ideas)
    registerIdeaAcceptRoute(on: ideas)
}

/// Lists ideas with optional status filtering for dashboards.
///
/// The bound rides the SQL LIMIT rather than a post-fetch slice so a long
/// suggestion history never loads whole; a present limit outside the advertised
/// range fails with a 400 instead of silently clamping.
/// - Parameter ideas: Route group receiving the list route.
private func registerIdeaListRoute(on ideas: RoutesBuilder) {
    ideas.get { req async throws -> IdeasListResponse in
        let filter = try parseIdeaStatusFilter(req.query[String.self, at: "status"])
        let limit = try parseQueryLimit(req, default: 50, min: 1, max: 200)
        let stored = try await req.application.runeWeaver.ideas.list(status: filter, limit: limit)
        return IdeasListResponse(ideas: stored.map(IdeaDTO.init))
    }
}

/// Counts ideas per status for the dashboard attention badge.
///
/// The summary literal registers before the `:id` parameter so the exact path
/// wins without relying on registration order.
/// - Parameter ideas: Route group receiving the summary route.
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
///
/// Dismissal is the owner's "no" and never blocks a future suggestion with the
/// same title, so this only moves the lifecycle state; unknown identifiers fail
/// with a 404 from the store rather than fabricating a row.
/// - Parameter ideas: Route group receiving the dismiss route.
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

/// Accepts one proposed idea, applying its suggested change.
///
/// `new_goal` ideas route through `GoalEngine.create` so the disabled and
/// capped guards answer with the same honest 400 as `POST /goals`.
/// `plan_adjustment` ideas replace their linked goal's plan only when that goal
/// still exists and is active; otherwise the request conflicts with a message
/// naming why. A `tip` has no executable change, so acceptance is purely the
/// lifecycle transition. The status claim lands before the effect so a replay
/// cannot double-apply.
/// - Parameter ideas: Route group receiving the accept route.
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
            // The effect never landed (both create and replacePlan are
            // all-or-nothing), so restore our own claim to leave the suggestion
            // actionable for a retry instead of stranding it accepted with no
            // change applied. The guarded revert only touches the row while it
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

/// Applies the executable change behind one accepted idea.
///
/// `new_goal` creation and the linked-goal precondition for `plan_adjustment`
/// are the only two effects; a tip is an acknowledgment. A plan adjustment
/// carries its replacement plan as newline-separated step lines produced from
/// the review prompt's structured `steps` field, and `GoalStore.replacePlan`
/// preserves in-flight and finished work exactly as an engine replan would.
/// - Parameters:
///   - idea: Idea being accepted.
///   - context: Live server context owning the pursuit engine and stores.
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
///
/// A suggestion is only applicable while its linked goal still exists and is
/// actively pursued: an achieved, abandoned, or paused goal has no pending work
/// to re-plan, so each miss is a 409 naming the reason instead of a silent
/// no-op that would leave the idea accepted but unapplied.
/// - Parameters:
///   - idea: Plan-adjustment idea being accepted.
///   - store: Durable goal persistence.
/// - Returns: Identifier of the linked active goal.
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
///
/// Each non-empty body line becomes one pending step: the ideas engine encodes
/// a plan adjustment's structured `steps` field as newline-separated lines, so
/// the split reconstructs the model's plan rather than guessing at prose. A
/// legacy or hand-authored body without newlines still yields one step, and
/// every title is length-bounded and the count capped so an overlong reply can
/// never widen the plan or become a single unbounded step.
/// - Parameters:
///   - idea: Plan-adjustment idea supplying the step text.
///   - goalID: Goal the replacement plan belongs to.
/// - Returns: Ordered pending steps.
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

/// Parses an optional status filter for the idea list route.
///
/// Blank and absent both mean unfiltered; an unknown value fails with a 400
/// naming the input instead of silently listing everything.
/// - Parameter raw: Raw status value.
/// - Returns: Parsed filter, or nil when unfiltered.
func parseIdeaStatusFilter(_ raw: String?) throws -> IdeaStatus? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let status = IdeaStatus(rawValue: trimmed) else {
        throw Abort(.badRequest, reason: "unknown status \(raw)")
    }
    return status
}

/// Maps idea store failures to HTTP codes: unknown rows become 404, a failed
/// guarded transition becomes 409, and transport failures stay 500 instead of
/// leaking driver detail.
/// - Parameters:
///   - error: Store failure.
///   - raw: Raw identifier for the not-found message.
/// - Returns: Abort with the mapped status.
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
