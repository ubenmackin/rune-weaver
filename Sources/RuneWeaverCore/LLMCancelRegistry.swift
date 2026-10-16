// Rune Weaver Core — Active LLM streaming connection cancellation registry.

import Foundation
import os

/// Thread-safe registry coordinating immediate cancellation of in-flight LLM HTTP connections.
public final class LLMCancelRegistry: Sendable {
    /// Shared singleton instance.
    public static let shared = LLMCancelRegistry()

    private struct State {
        var callbacks: [UUID: [UUID: @Sendable () -> Void]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Registers a cancellation callback for a given session.
    @discardableResult
    public func register(sessionID: UUID, cancel: @Sendable @escaping () -> Void) -> (@Sendable () -> Void) {
        let registrationID = UUID()
        state.withLock {
            var sessionMap = $0.callbacks[sessionID] ?? [:]
            sessionMap[registrationID] = cancel
            $0.callbacks[sessionID] = sessionMap
        }
        return { [weak self] in
            self?.unregister(sessionID: sessionID, registrationID: registrationID)
        }
    }

    /// Unregisters a specific callback for a session.
    public func unregister(sessionID: UUID, registrationID: UUID) {
        state.withLock {
            guard var sessionMap = $0.callbacks[sessionID] else { return }
            sessionMap.removeValue(forKey: registrationID)
            if sessionMap.isEmpty {
                $0.callbacks.removeValue(forKey: sessionID)
            } else {
                $0.callbacks[sessionID] = sessionMap
            }
        }
    }

    /// Triggers immediate cancellation for all in-flight callbacks registered under the given session.
    ///
    /// - Parameter sessionID: The session identifier whose LLM connections should be cancelled.
    public func cancel(sessionID: UUID) {
        let callbacksToInvoke: [@Sendable () -> Void] = state.withLock {
            guard let sessionMap = $0.callbacks.removeValue(forKey: sessionID) else {
                return []
            }
            return Array(sessionMap.values)
        }
        for callback in callbacksToInvoke {
            callback()
        }
    }
}
