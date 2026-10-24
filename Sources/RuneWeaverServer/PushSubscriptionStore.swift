// Rune Weaver Server — SQLite store and SSRF validator for Web Push subscriptions.

import CryptoKit
import Foundation
import RuneWeaverCore
#if canImport(SQLite3)
    import SQLite3
#endif

/// Validated subscriber record stored in SQLite.
public struct PushSubscriptionRecord: Sendable, Equatable {
    public let id: String
    public let endpoint: String
    public let p256dhKey: String
    public let authSecret: String
    public let userAgent: String?
    public let createdAt: Date

    public init(
        id: String,
        endpoint: String,
        p256dhKey: String,
        authSecret: String,
        userAgent: String?,
        createdAt: Date
    ) {
        self.id = id
        self.endpoint = endpoint
        self.p256dhKey = p256dhKey
        self.authSecret = authSecret
        self.userAgent = userAgent
        self.createdAt = createdAt
    }
}

/// Errors raised when validating or persisting push subscriptions.
public enum PushSubscriptionError: LocalizedError, Sendable {
    case invalidEndpoint(String)
    case invalidKeys
    case databaseUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(endpoint):
            "Push endpoint rejected by security policy (SSRF prevention): \(endpoint)"
        case .invalidKeys:
            "Client subscription encryption keys (p256dh or auth) are invalid."
        case .databaseUnavailable:
            "Subscriptions database is unavailable."
        }
    }
}

/// Durable SQLite-backed actor for Web Push device subscriptions.
public actor PushSubscriptionStore {
    private let dbPath: String

    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Validates an endpoint URL against SSRF policy: requires HTTPS, no credentials, no fragments,
    /// no IP address literals, and host must match recognized Web Push gateway domains.
    public static func validateEndpoint(_ endpoint: String) -> URL? {
        guard let url = URL(string: endpoint),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              !isIPAddressOrLoopback(host),
              isAllowedPushGateway(host)
        else {
            return nil
        }
        return url
    }

    /// Matches host against recognized Web Push gateways.
    public static func isAllowedPushGateway(_ host: String) -> Bool {
        let allowedSuffixes = [
            ".web.push.apple.com",
            ".fcm.googleapis.com",
            ".push.services.mozilla.com",
            ".notify.windows.com"
        ]
        let exactHosts: Set = [
            "web.push.apple.com",
            "fcm.googleapis.com",
            "push.services.mozilla.com",
            "notify.windows.com"
        ]
        if exactHosts.contains(host) {
            return true
        }
        return allowedSuffixes.contains { host.hasSuffix($0) }
    }

    private static func isIPAddressOrLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        var sin = sockaddr_in()
        if host.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 {
            return true
        }
        var sin6 = sockaddr_in6()
        if host.withCString({ inet_pton(AF_INET6, $0, &sin6.sin6_addr) }) == 1 {
            return true
        }
        return false
    }

    private static func isValidSubscriptionKeys(p256dh: String, auth: String) -> Bool {
        guard let p256Data = WebPushKeys.dataFromBase64URL(p256dh),
              p256Data.count == 65, p256Data.first == 0x04,
              (try? P256.KeyAgreement.PublicKey(x963Representation: p256Data)) != nil,
              let authData = WebPushKeys.dataFromBase64URL(auth),
              authData.count == 16
        else {
            return false
        }
        return true
    }

    /// Saves or updates a verified push subscription.
    @discardableResult
    public func save(
        endpoint: String,
        p256dh: String,
        auth: String,
        userAgent: String? = nil
    ) async throws -> PushSubscriptionRecord {
        guard Self.validateEndpoint(endpoint) != nil else {
            throw PushSubscriptionError.invalidEndpoint(endpoint)
        }
        let trimmedP256 = p256dh.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuth = auth.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSubscriptionKeys(p256dh: trimmedP256, auth: trimmedAuth) else {
            throw PushSubscriptionError.invalidKeys
        }

        let record = PushSubscriptionRecord(
            id: UUID().uuidString,
            endpoint: endpoint,
            p256dhKey: trimmedP256,
            authSecret: trimmedAuth,
            userAgent: userAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )

        let path = dbPath
        let ok = await SQLiteSerialIO.runUncancellable {
            PushSubscriptionStoreIO.save(record, dbPath: path)
        }
        guard ok else {
            throw PushSubscriptionError.databaseUnavailable
        }
        return record
    }

    /// Removes a push subscription by its endpoint.
    @discardableResult
    public func remove(endpoint: String) async -> Bool {
        let path = dbPath
        return await SQLiteSerialIO.runUncancellable {
            PushSubscriptionStoreIO.remove(endpoint: endpoint, dbPath: path)
        }
    }

    /// Fetches all active subscriptions.
    public func allSubscriptions() async -> [PushSubscriptionRecord] {
        let path = dbPath
        return await SQLiteSerialIO.runUncancellable {
            PushSubscriptionStoreIO.all(dbPath: path)
        }
    }

    /// Clears all subscriptions (primarily for tests).
    public func clear() async {
        let path = dbPath
        await SQLiteSerialIO.runUncancellable {
            PushSubscriptionStoreIO.clear(dbPath: path)
        }
    }
}

// MARK: - Internal SQLite I/O

enum PushSubscriptionStoreIO {
    static func ensureTable(handle: OpaquePointer?) throws {
        #if canImport(SQLite3)
            let sql = """
            CREATE TABLE IF NOT EXISTS web_push_subscriptions (
                id TEXT PRIMARY KEY,
                endpoint TEXT UNIQUE NOT NULL,
                p256dh_key TEXT NOT NULL,
                auth_secret TEXT NOT NULL,
                user_agent TEXT,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_web_push_subscriptions_endpoint ON web_push_subscriptions(endpoint);
            """
            try SQLiteHelpers.exec(handle: handle, sql: sql, failure: { _ in PushSubscriptionError.databaseUnavailable })
        #endif
    }

    static func save(_ record: PushSubscriptionRecord, dbPath: String) -> Bool {
        #if canImport(SQLite3)
            do {
                guard let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { _ in PushSubscriptionError.databaseUnavailable }) else {
                    return false
                }
                defer { sqlite3_close(handle) }
                try ensureTable(handle: handle)

                let sql = """
                INSERT INTO web_push_subscriptions (id, endpoint, p256dh_key, auth_secret, user_agent, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(endpoint) DO UPDATE SET
                    id = excluded.id,
                    p256dh_key = excluded.p256dh_key,
                    auth_secret = excluded.auth_secret,
                    user_agent = excluded.user_agent,
                    created_at = excluded.created_at;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }

                SQLiteHelpers.bindText(stmt, index: 1, value: record.id)
                SQLiteHelpers.bindText(stmt, index: 2, value: record.endpoint)
                SQLiteHelpers.bindText(stmt, index: 3, value: record.p256dhKey)
                SQLiteHelpers.bindText(stmt, index: 4, value: record.authSecret)
                SQLiteHelpers.bindText(stmt, index: 5, value: record.userAgent)
                _ = sqlite3_bind_double(stmt, 6, record.createdAt.timeIntervalSince1970)

                return sqlite3_step(stmt) == SQLITE_DONE
            } catch {
                return false
            }
        #else
            return false
        #endif
    }

    static func remove(endpoint: String, dbPath: String) -> Bool {
        #if canImport(SQLite3)
            do {
                guard let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { _ in PushSubscriptionError.databaseUnavailable }) else {
                    return false
                }
                defer { sqlite3_close(handle) }
                try ensureTable(handle: handle)

                let sql = "DELETE FROM web_push_subscriptions WHERE endpoint = ?;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }

                SQLiteHelpers.bindText(stmt, index: 1, value: endpoint)
                guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
                return sqlite3_changes(handle) > 0
            } catch {
                return false
            }
        #else
            return false
        #endif
    }

    static func all(dbPath: String) -> [PushSubscriptionRecord] {
        #if canImport(SQLite3)
            do {
                guard let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { _ in PushSubscriptionError.databaseUnavailable }) else {
                    return []
                }
                defer { sqlite3_close(handle) }
                try ensureTable(handle: handle)

                let sql = "SELECT id, endpoint, p256dh_key, auth_secret, user_agent, created_at FROM web_push_subscriptions ORDER BY created_at DESC;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }

                var results: [PushSubscriptionRecord] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let id = SQLiteHelpers.columnText(stmt, index: 0),
                          let endpoint = SQLiteHelpers.columnText(stmt, index: 1),
                          let p256dh = SQLiteHelpers.columnText(stmt, index: 2),
                          let auth = SQLiteHelpers.columnText(stmt, index: 3)
                    else {
                        continue
                    }
                    let userAgent = SQLiteHelpers.columnText(stmt, index: 4)
                    let createdAtSec = sqlite3_column_double(stmt, 5)
                    results.append(PushSubscriptionRecord(
                        id: id,
                        endpoint: endpoint,
                        p256dhKey: p256dh,
                        authSecret: auth,
                        userAgent: userAgent,
                        createdAt: Date(timeIntervalSince1970: createdAtSec)
                    ))
                }
                return results
            } catch {
                return []
            }
        #else
            return []
        #endif
    }

    static func clear(dbPath: String) {
        #if canImport(SQLite3)
            do {
                guard let handle = try SQLiteHelpers.openHandle(dbPath: dbPath, unavailable: { _ in PushSubscriptionError.databaseUnavailable }) else {
                    return
                }
                defer { sqlite3_close(handle) }
                try ensureTable(handle: handle)
                try SQLiteHelpers.exec(handle: handle, sql: "DELETE FROM web_push_subscriptions;", failure: { _ in PushSubscriptionError.databaseUnavailable })
            } catch {}
        #endif
    }
}
