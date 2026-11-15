// Rune Weaver Server — Missed-schedule evaluation and system-wake handling for ServerSchedulerWorker.

#if os(macOS) && canImport(AppKit)
    import AppKit
#endif
import Foundation
import os
import RuneWeaverCore

/// Thread-safe token unregistering `NSWorkspace.didWakeNotification` deterministically on stop or deinit.
final class WakeNotificationToken: @unchecked Sendable {
    private struct Entry: @unchecked Sendable {
        let center: NotificationCenter
        let observer: any NSObjectProtocol
    }

    private let state: OSAllocatedUnfairLock<Entry?>

    init(handler: @escaping @Sendable () -> Void) {
        #if os(macOS) && canImport(AppKit)
            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler()
            }
            self.state = OSAllocatedUnfairLock(initialState: Entry(center: center, observer: observer))
        #else
            _ = handler
            self.state = OSAllocatedUnfairLock(initialState: nil)
        #endif
    }

    deinit {
        release()
    }

    func release() {
        let entry = state.withLock { current -> Entry? in
            let existing = current
            current = nil
            return existing
        }
        if let entry {
            entry.center.removeObserver(entry.observer)
        }
    }
}

extension ServerSchedulerWorker {
    /// Cron evaluation outcome pairing the fire reason with its scheduled slot timestamp.
    struct CronEvaluationDecision: Sendable, Equatable {
        let reason: SchedulerFireReason
        let slotAt: Date
    }

    /// Evaluates whether an enabled cron job should fire on-time or as a missed-slot catch-up.
    func evaluateCronTrigger(for job: SchedulerJob, now: Date, windowStart: Date) -> CronEvaluationDecision? {
        guard job.hasCronTrigger, let cron = try? CronSchedule.parse(job.schedule), let latestSlot = cron.previousFire(beforeOrAt: now) else {
            return nil
        }
        let anchor = job.scheduleAnchorAt ?? job.createdAt
        guard latestSlot >= anchor else {
            return nil
        }
        // Only slots that never started are eligible for catch-up; started runs record
        // `lastScheduledSlotAt` immediately upon acquiring the run lock.
        if let recordedSlot = job.lastScheduledSlotAt, latestSlot <= recordedSlot {
            return nil
        }
        if latestSlot > windowStart, now.timeIntervalSince(latestSlot) <= Self.strictCronGraceSeconds {
            return CronEvaluationDecision(reason: .cron, slotAt: latestSlot)
        }
        if job.misfirePolicy == .catchUp {
            return CronEvaluationDecision(reason: .cronCatchUp, slotAt: latestSlot)
        }
        return nil
    }

    /// Whether the background loop is currently parked waiting for the next tick interval.
    var isSleepingForNextTick: Bool {
        sleepTask != nil
    }

    /// Wakes the idle sleep wait so a catch-up sweep runs immediately after system wake.
    func wakeNow() {
        guard isStarted else { return }
        if let sleepTask {
            sleepTask.cancel()
        } else {
            pendingWakeSweep = true
        }
    }

    /// Sleeps until the next tick interval unless stopped or interrupted by a wake notification.
    func sleepForNextTick(seconds interval: TimeInterval) async {
        if pendingWakeSweep {
            pendingWakeSweep = false
            return
        }
        guard isStarted, !Task.isCancelled else { return }
        let waiter: Task<Void, Never> = Task {
            _ = try? await Task.sleep(for: .seconds(interval))
        }
        sleepTask = waiter
        await waiter.value
        sleepTask = nil
    }
}
