// Rune Weaver Server — Scheduler, scheduled-send, and settings change broadcasts.

import Foundation
import RuneWeaverCore

/// Type-only wake-up; receivers refetch via GET and ignore unknown types.
public struct WSSchedulerJobsChanged: Codable, Sendable, Equatable {
    /// Always `"scheduler_jobs_changed"`.
    public let type: String

    /// Creates a scheduler-jobs change signal.
    public init() {
        self.type = "scheduler_jobs_changed"
    }
}

/// Type-only wake-up; receivers refetch via GET and ignore unknown types.
public struct WSScheduledSendsChanged: Codable, Sendable, Equatable {
    /// Always `"scheduled_sends_changed"`.
    public let type: String

    /// Creates a scheduled-sends change signal.
    public init() {
        self.type = "scheduled_sends_changed"
    }
}

/// Type-only wake-up; receivers refetch via GET and ignore unknown types.
public struct WSSettingsChanged: Codable, Sendable, Equatable {
    /// Always `"settings_changed"`.
    public let type: String

    /// Creates a settings change signal.
    public init() {
        self.type = "settings_changed"
    }
}

extension WSHub {
    /// Encodes one type-only wake-up, logging and dropping on failure.
    private func broadcastTypeOnlyFrame(_ frame: some Encodable, label: String) async {
        let text: String
        do {
            let data = try JSONEncoder().encode(frame)
            guard let encodedText = String(data: data, encoding: .utf8) else { return }
            text = encodedText
        } catch {
            RuneWeaverLog.server.error("WSHub: failed to encode \(label) frame: \(error.localizedDescription)")
            return
        }
        await broadcast(text: text)
    }

    /// Broadcasts a scheduler-jobs change so dashboards refetch the job list.
    public func broadcastSchedulerJobsChanged() async {
        await broadcastTypeOnlyFrame(WSSchedulerJobsChanged(), label: "scheduler jobs changed")
    }

    /// Broadcasts a scheduled-sends change so dashboards refetch the send list.
    public func broadcastScheduledSendsChanged() async {
        await broadcastTypeOnlyFrame(WSScheduledSendsChanged(), label: "scheduled sends changed")
    }

    /// Broadcasts a settings change so dashboards refetch settings.
    public func broadcastSettingsChanged() async {
        await broadcastTypeOnlyFrame(WSSettingsChanged(), label: "settings changed")
    }
}
