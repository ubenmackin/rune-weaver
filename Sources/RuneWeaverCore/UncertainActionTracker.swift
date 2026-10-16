// Rune Weaver Core — Uncertain action idempotency tracker.

import CryptoKit
import Foundation

/// Unique fingerprint representing a mutating tool execution.
public struct UncertainActionFingerprint: Sendable, Hashable {
    /// Name of the tool that executed.
    public let toolName: String
    /// Hex-encoded SHA-256 hash of the normalized argument string.
    public let argumentsHash: String
    /// When the uncertain outcome was recorded.
    public let recordedAt: Date

    public init(toolName: String, argumentsHash: String, recordedAt: Date = Date()) {
        self.toolName = toolName
        self.argumentsHash = argumentsHash
        self.recordedAt = recordedAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(toolName)
        hasher.combine(argumentsHash)
    }

    public static func == (lhs: UncertainActionFingerprint, rhs: UncertainActionFingerprint) -> Bool {
        lhs.toolName == rhs.toolName && lhs.argumentsHash == rhs.argumentsHash
    }
}

/// Actor managing unconfirmed or timed-out mutating actions to enforce idempotency guards.
public actor UncertainActionTracker {
    /// Active fingerprints mapped by their lookup key (toolName:argumentsHash).
    private var pending: [String: UncertainActionFingerprint] = [:]
    /// Maximum time an uncertain outcome blocks retries before expiring (default 15 minutes).
    public let ttl: TimeInterval

    /// Set of known mutating tool names subject to idempotency safeguards.
    public static let defaultMutatingTools: Set<String> = [
        "api.request",
        "bash.exec",
        "desktop.action",
        "email.send",
        "files.write",
        "messages.send"
    ]

    /// Creates a tracker with the specified time-to-live.
    public init(ttl: TimeInterval = 900) {
        self.ttl = ttl
    }

    /// Computes a stable lookup key for a tool and its arguments.
    public static func makeKey(toolName: String, argumentsJSON: String) -> String {
        let hash = computeHash(for: argumentsJSON)
        return "\(toolName):\(hash)"
    }

    /// Computes a SHA-256 hash of the canonical form of the arguments string.
    public static func computeHash(for argumentsJSON: String) -> String {
        let canonical = canonicalArgumentsJSON(argumentsJSON)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the canonical encoding of an arguments payload for hashing.
    private static func canonicalArgumentsJSON(_ argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
              JSONSerialization.isValidJSONObject(value),
              let canonicalData = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8)
        else { return trimmed }
        return canonical
    }

    /// Checks whether a tool name is considered mutating and eligible for safeguard.
    public static func isMutating(toolName: String, argumentsJSON: String = "") -> Bool {
        if defaultMutatingTools.contains(toolName) {
            // For api.request, only mutating HTTP methods need safeguard if detectable
            if toolName == "api.request", let data = argumentsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let method = (obj["method"] as? String)?.uppercased()
            {
                return ["POST", "PUT", "DELETE", "PATCH"].contains(method)
            }
            return true
        }
        return false
    }

    /// Records an action whose outcome could not be verified (e.g. timeout).
    public func recordUncertain(toolName: String, argumentsJSON: String) {
        let key = Self.makeKey(toolName: toolName, argumentsJSON: argumentsJSON)
        let hash = Self.computeHash(for: argumentsJSON)
        pending[key] = UncertainActionFingerprint(
            toolName: toolName,
            argumentsHash: hash,
            recordedAt: Date()
        )
    }

    /// Returns true if an identical mutating action is currently blocked due to prior uncertain outcome.
    public func isBlocked(toolName: String, argumentsJSON: String) -> Bool {
        pruneExpired()
        guard Self.isMutating(toolName: toolName, argumentsJSON: argumentsJSON) else { return false }
        let key = Self.makeKey(toolName: toolName, argumentsJSON: argumentsJSON)
        return pending[key] != nil
    }

    /// Clears an action fingerprint after verification or successful execution.
    public func clear(toolName: String, argumentsJSON: String) {
        let key = Self.makeKey(toolName: toolName, argumentsJSON: argumentsJSON)
        pending.removeValue(forKey: key)
    }

    /// Clears all tracked fingerprints.
    public func clearAll() {
        pending.removeAll()
    }

    /// Returns count of currently active uncertain action fingerprints.
    public func count() -> Int {
        pruneExpired()
        return pending.count
    }

    /// Prunes entries that have outlived the TTL.
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        pending = pending.filter { _, entry in entry.recordedAt > cutoff }
    }
}
