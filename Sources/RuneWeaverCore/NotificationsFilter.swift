// Rune Weaver Core — Per-type notification preferences.

import Foundation
import os

/// Interruption family gating desktop banners, mobile push, and badge frames.
public enum NotificationKind: String, Sendable, Codable, CaseIterable, Equatable {
    /// Approval filings awaiting a decision.
    case approvalRequested
    /// Scheduler job completions.
    case schedulerRun
    /// Goal advancement turns.
    case goalAdvance
    /// Proactive idea proposals.
    case ideaProposed
    /// Index run failures.
    case indexFailed
    /// Chat turn failures.
    case chatFailed
}

/// Six per-type switches under `[notifications]`, plus optional VAPID push contact.
public struct NotificationsConfig: Sendable, Equatable {
    /// Whether approval filings interrupt.
    public var approvalRequested: Bool
    /// Whether scheduler completions interrupt.
    public var schedulerRun: Bool
    /// Whether goal advances interrupt.
    public var goalAdvance: Bool
    /// Whether idea proposals interrupt.
    public var ideaProposed: Bool
    /// Whether index failures interrupt.
    public var indexFailed: Bool
    /// Whether chat failures interrupt.
    public var chatFailed: Bool
    /// Public contact email or domain for Web Push VAPID subject (RFC 8292).
    public var pushContact: String

    /// Creates a config defaulting every kind to surfaced.
    public init(
        approvalRequested: Bool = true,
        schedulerRun: Bool = true,
        goalAdvance: Bool = true,
        ideaProposed: Bool = true,
        indexFailed: Bool = true,
        chatFailed: Bool = true,
        pushContact: String = ""
    ) {
        self.approvalRequested = approvalRequested
        self.schedulerRun = schedulerRun
        self.goalAdvance = goalAdvance
        self.ideaProposed = ideaProposed
        self.indexFailed = indexFailed
        self.chatFailed = chatFailed
        self.pushContact = pushContact
    }

    private enum CodingKeys: String, CodingKey {
        case approvalRequested
        case schedulerRun
        case goalAdvance
        case ideaProposed
        case indexFailed
        case chatFailed
        case pushContact
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }
}

extension NotificationsConfig: Codable {
    /// Decodes tolerantly on missing keys but rejects unknown keys.
    public init(from decoder: any Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(["approvalRequested", "schedulerRun", "goalAdvance", "ideaProposed", "indexFailed", "chatFailed", "pushContact"])
        for key in dynamic.allKeys where !known.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: dynamic,
                debugDescription: "Unknown notifications key '\(key.stringValue)'"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvalRequested = try container.decodeIfPresent(Bool.self, forKey: .approvalRequested) ?? true
        schedulerRun = try container.decodeIfPresent(Bool.self, forKey: .schedulerRun) ?? true
        goalAdvance = try container.decodeIfPresent(Bool.self, forKey: .goalAdvance) ?? true
        ideaProposed = try container.decodeIfPresent(Bool.self, forKey: .ideaProposed) ?? true
        indexFailed = try container.decodeIfPresent(Bool.self, forKey: .indexFailed) ?? true
        chatFailed = try container.decodeIfPresent(Bool.self, forKey: .chatFailed) ?? true
        pushContact = try container.decodeIfPresent(String.self, forKey: .pushContact) ?? ""
    }

    /// Encodes every switch and push contact so a round-trip never invents a default.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(approvalRequested, forKey: .approvalRequested)
        try container.encode(schedulerRun, forKey: .schedulerRun)
        try container.encode(goalAdvance, forKey: .goalAdvance)
        try container.encode(ideaProposed, forKey: .ideaProposed)
        try container.encode(indexFailed, forKey: .indexFailed)
        try container.encode(chatFailed, forKey: .chatFailed)
        try container.encode(pushContact, forKey: .pushContact)
    }
}

/// Single owner of per-type interruption filtering.
public enum NotificationsFilter {
    /// Whether this kind interrupts under the current preferences.
    public static func shouldSurface(_ kind: NotificationKind, config: NotificationsConfig) -> Bool {
        switch kind {
        case .approvalRequested:
            config.approvalRequested
        case .schedulerRun:
            config.schedulerRun
        case .goalAdvance:
            config.goalAdvance
        case .ideaProposed:
            config.ideaProposed
        case .indexFailed:
            config.indexFailed
        case .chatFailed:
            config.chatFailed
        }
    }
}

/// Reference-shared live preferences so one update reaches every fan-out surface without a restart.
public final class NotificationsConfigBox: Sendable {
    private let state: OSAllocatedUnfairLock<NotificationsConfig>

    /// Creates a box holding the given snapshot.
    public init(_ config: NotificationsConfig = NotificationsConfig()) {
        state = OSAllocatedUnfairLock(initialState: config)
    }

    /// Current snapshot.
    public var current: NotificationsConfig {
        state.withLock { $0 }
    }

    /// Replaces the snapshot.
    public func update(_ config: NotificationsConfig) {
        state.withLock { $0 = config }
    }
}
