// Rune Weaver LLM — Provider circuit breaker and rate-limit cooldown tracker.
// Tracks consecutive provider outages and rate-limit signals (HTTP 429, 5xx, timeouts)
// across turns to temporarily rest failing backends and route around them cleanly.

import Foundation
import RuneWeaverCore

/// Actor tracking LLM provider health, consecutive errors, and active cooldown periods.
public actor ProviderCircuitBreaker {
    /// Health snapshot for a single provider.
    public struct ProviderHealth: Sendable, Equatable {
        /// Windowed failure count (mirrors `failureTimestamps.count` for callers).
        public var consecutiveFailures: Int = 0
        /// Expiration date for the current cooldown window, if any.
        public var cooldownUntil: Date?
        /// Error message recorded on last failure.
        public var lastError: String?
        /// Recent failure timestamps inside the rolling window.
        /// Pruned on every record so isolated failures hours apart never trip.
        public var failureTimestamps: [Date] = []

        /// Checks if the provider is currently resting.
        public func isCoolingDown(at date: Date = Date()) -> Bool {
            guard let cooldownUntil else { return false }
            return date < cooldownUntil
        }
    }

    /// Health records keyed by unique provider identifier (`provider/model`).
    private var states: [String: ProviderHealth] = [:]

    /// Default cooldown for 2 failures in the rolling window (3 minutes = 180s).
    public let outageCooldown: TimeInterval
    /// Default cooldown for HTTP 429 rate limit (60s).
    public let rateLimitCooldown: TimeInterval
    /// Failures inside the rolling window before tripping the outage cooldown.
    public let failureThreshold: Int
    /// Rolling window bounding what counts as consecutive (seconds).
    public let failureWindow: TimeInterval

    /// Creates a circuit breaker with clamped bounds so misconfiguration fails closed.
    public init(
        outageCooldown: TimeInterval = 180,
        rateLimitCooldown: TimeInterval = 60,
        failureThreshold: Int = 2,
        failureWindow: TimeInterval = 60
    ) {
        // Clamp to sane ranges: cooldowns never negative, threshold at least
        // one failure, window at least one second so pruning stays meaningful.
        self.outageCooldown = max(0, outageCooldown)
        self.rateLimitCooldown = max(0, rateLimitCooldown)
        self.failureThreshold = max(1, failureThreshold)
        self.failureWindow = max(1, failureWindow)
    }

    /// Stable identity string for a provider.
    public static func providerKey(for provider: any LLMProvider) -> String {
        "\(provider.modelInfo.provider)/\(provider.modelInfo.name)"
    }

    /// Whether the provider is healthy and not currently in a cooldown window.
    public func isAvailable(provider: any LLMProvider, at date: Date = Date()) -> Bool {
        let key = Self.providerKey(for: provider)
        guard let health = states[key] else { return true }
        return !health.isCoolingDown(at: date)
    }

    /// Remaining cooldown seconds for a cooling provider, or nil if healthy.
    public func cooldownRemaining(provider: any LLMProvider, at date: Date = Date()) -> TimeInterval? {
        let key = Self.providerKey(for: provider)
        guard let health = states[key], let until = health.cooldownUntil else { return nil }
        let diff = until.timeIntervalSince(date)
        return diff > 0 ? diff : nil
    }

    /// Records a successful completion, resetting failure counts and clearing cooldown.
    public func recordSuccess(provider: any LLMProvider) {
        let key = Self.providerKey(for: provider)
        states.removeValue(forKey: key)
    }

    /// Records a provider failure, tripping cooldown only when the threshold is met inside the rolling window.
    public func recordFailure(provider: any LLMProvider, error: String, at date: Date = Date()) {
        let key = Self.providerKey(for: provider)
        var health = states[key] ?? ProviderHealth()
        health.lastError = error
        let lower = error.lowercased()

        if isRateLimit(lower) {
            // Rate limits rest the backend immediately; windowed counts stay
            // untouched so a single 429 never consumes the outage budget.
            health.cooldownUntil = date.addingTimeInterval(rateLimitCooldown)
            states[key] = health
            return
        }

        // Drop failures that aged out so two 5xx hours apart never trip the
        // outage cooldown; only failures clustered inside the window count.
        health.failureTimestamps = health.failureTimestamps.filter {
            date.timeIntervalSince($0) <= failureWindow
        }
        // An expired cooldown no longer rests the provider; clear it so a
        // lone new failure cannot inherit a stale window.
        if let until = health.cooldownUntil, date >= until {
            health.cooldownUntil = nil
        }
        health.failureTimestamps.append(date)
        // Bound retained timestamps to twice the threshold so a hot loop
        // cannot grow the array without bound while still preserving enough
        // evidence to trip either the outage or generic cooldown.
        let retainedLimit = failureThreshold * 2
        if health.failureTimestamps.count > retainedLimit {
            health.failureTimestamps.removeFirst(health.failureTimestamps.count - retainedLimit)
        }
        health.consecutiveFailures = health.failureTimestamps.count

        if isServerOutageOrTimeout(lower) {
            if health.consecutiveFailures >= failureThreshold {
                health.cooldownUntil = date.addingTimeInterval(outageCooldown)
            }
            states[key] = health
            return
        }

        // Generic errors need twice the evidence before resting the backend,
        // so transient blips stay usable while persistent breakage still cools.
        if health.consecutiveFailures >= failureThreshold * 2 {
            health.cooldownUntil = date.addingTimeInterval(outageCooldown)
        }
        states[key] = health
    }

    /// Resets health records for a single provider.
    public func reset(provider: any LLMProvider) {
        let key = Self.providerKey(for: provider)
        states.removeValue(forKey: key)
    }

    /// Resets all provider health records.
    public func resetAll() {
        states.removeAll()
    }

    /// Checks if error text indicates a 429 rate limit or quota exhaustion.
    private func isRateLimit(_ lower: String) -> Bool {
        lower.contains("429")
            || lower.contains("rate limit")
            || lower.contains("quota exceeded")
            || lower.contains("too many requests")
    }

    /// Checks if error text indicates a 5xx server outage, overload, or connection timeout.
    private func isServerOutageOrTimeout(_ lower: String) -> Bool {
        lower.contains("500")
            || lower.contains("502")
            || lower.contains("503")
            || lower.contains("504")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("overloaded")
            || lower.contains("service unavailable")
            || lower.contains("bad gateway")
    }
}
