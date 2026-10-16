// Rune Weaver Core — GoalStore SQLite-unavailable fallback stubs.

import Foundation

#if !canImport(SQLite3)
    /// Fallback when the SQLite3 module is unavailable.
    enum SQLiteGoalStore {
        static func create(goal _: Goal, steps _: [GoalStep], dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func goal(id _: UUID, dbPath _: String) throws -> Goal? {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func list(status _: GoalStatus?, limit _: Int? = nil, dbPath _: String) throws -> [Goal] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func replacePlan(goalID _: UUID, steps _: [GoalStep], dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func setStepStatus(
            goalID _: UUID,
            stepID _: UUID,
            status _: StepStatus,
            notes _: String?,
            lastRunID _: UUID?,
            dbPath _: String
        ) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func advanceDue(now _: Date, dbPath _: String) throws -> [Goal] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func markAdvanced(goalID _: UUID, nextDueAt _: Date?, dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func setStatus(goalID _: UUID, status _: GoalStatus, dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func updateDetails(
            goalID _: UUID,
            title _: String?,
            statement _: String?,
            stepIntervalMinutes _: Int?,
            dbPath _: String
        ) throws -> Goal {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func appendEvent(goalID _: UUID, kind _: GoalEventKind, message _: String, dbPath _: String) throws -> GoalEvent {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func events(goalID _: UUID, limit _: Int?, dbPath _: String) throws -> [GoalEvent] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func activeGoalCount(dbPath _: String) throws -> Int {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func steps(goalID _: UUID, dbPath _: String) throws -> [GoalStep] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func delete(goalID _: UUID, dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func nextActionableStep(goalID _: UUID, dbPath _: String) throws -> GoalStep? {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func addTrigger(
            goalID _: UUID,
            eventKind _: String,
            pattern _: String?,
            cooldownMinutes _: Int,
            dbPath _: String
        ) throws -> GoalTrigger {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func removeTriggers(goalID _: UUID, dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func replaceTriggers(goalID _: UUID, drafts _: [GoalTriggerDraft], dbPath _: String) throws {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func triggers(for _: UUID, dbPath _: String) throws -> [GoalTrigger] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func fireMatchingTriggers(events _: [GoalObservedEvent], now _: Date, dbPath _: String) throws -> [GoalTriggerFire] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }

        static func observedEvents(since _: Date, limit _: Int?, dbPath _: String) throws -> [GoalObservedEvent] {
            throw GoalStoreError.storeUnavailable("SQLite unavailable")
        }
    }
#endif
