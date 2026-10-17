// Rune Weaver Core — Secure credentials manager with Keychain and environment fallback.

import Foundation

#if canImport(Security)
    import Security
#endif

/// Errors thrown by ``SecretsManager``.
public enum SecretsError: Error, Sendable, Equatable {
    /// The key or secret was empty.
    case invalidInput(reason: String)
    /// A Keychain operation failed.
    case keychainError(status: Int32)
    /// Secret bytes could not be encoded or decoded as UTF-8.
    case encodingError
    /// A surrogate reference named a key with no stored secret.
    case unknownSurrogate(key: String)
}

/// macOS Keychain-backed secrets with environment variable fallback.
public actor SecretsManager {
    /// Default Keychain service namespace for all RuneWeaver secrets.
    public static let defaultService = "com.runeweaver.secrets"

    /// Account prefix reserved for sovereign ledger material: the secrets routes
    /// reject it so operator secrets never overwrite or delete it, and surrogate
    /// resolution reports it unknown so agent-composed headers never read it.
    public static let reservedAccountPrefix = "sovereign."

    /// Keychain service namespace used when callers omit `service`.
    public let service: String

    /// Whether secrets are held in-memory rather than written to the system Keychain.
    public let inMemory: Bool

    /// Creates a secrets manager. service: Keychain service namespace.
    public init(service: String = SecretsManager.defaultService, inMemory: Bool = false) {
        self.service = service
        self.inMemory = inMemory
    }

    private var fallbackStore: FallbackStore = .init()

    /// Reads the live process environment for `key`.
    private nonisolated func liveEnvironmentValue(for key: String) -> String? {
        key.withCString { cKey in
            guard let cValue = getenv(cKey) else { return nil }
            return String(validatingCString: cValue)
        }
    }

    // MARK: - Store / retrieve

    /// Stores a secret in the Keychain, updating any existing item.
    public func store(key: String, service: String? = nil, secret: String) throws {
        let namespace = service ?? self.service
        let data = try Self.validatedStoreData(key: key, namespace: namespace, secret: secret)
        try upsertSecret(data, key: key, service: namespace)
    }

    /// Retrieves a secret, checking the environment first.
    public func retrieve(key: String, service: String? = nil) throws -> String? {
        guard !key.isEmpty else {
            throw SecretsError.invalidInput(reason: "key must not be empty")
        }
        if let live = liveEnvironmentValue(for: key), !live.isEmpty {
            return live
        }
        if let injected = ProcessInfo.processInfo.environment[key], !injected.isEmpty {
            return injected
        }
        let namespace = service ?? self.service
        guard let stored = try readSecret(key: key, service: namespace) else { return nil }
        backfillLabelIfNeeded(stored.label, key: key, service: namespace)
        return stored.secret
    }

    /// Stores a secret directly in the Keychain without consulting the
    /// environment. Used for operator-owned material that must never be
    /// shadowed by an injected variable.
    public func storeKeychain(key: String, secret: String) throws {
        let data = try Self.validatedStoreData(key: key, namespace: self.service, secret: secret)
        try upsertSecret(data, key: key, service: self.service)
    }

    /// Retrieves a secret directly from the Keychain without consulting the
    /// environment. A locked Keychain surfaces as a keychain error so the
    /// caller can fail closed with an unlock remedy.
    public func retrieveKeychain(key: String) throws -> String? {
        guard !key.isEmpty else {
            throw SecretsError.invalidInput(reason: "key must not be empty")
        }
        guard let stored = try readSecret(key: key, service: self.service) else { return nil }
        return stored.secret
    }

    /// Adds a secret only when the key holds no item yet, giving fresh
    /// material a single creator: `errSecDuplicateItem` leaves the stored
    /// winner untouched instead of clobbering it with a second write.
    /// - Parameters:
    ///   - key: Keychain account name.
    ///   - secret: Secret to store when the key is absent.
    /// - Returns: Whether this call created the item.
    public func storeKeychainIfAbsent(key: String, secret: String) throws -> Bool {
        let data = try Self.validatedStoreData(key: key, namespace: self.service, secret: secret)
        #if canImport(Security)
            if !inMemory {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: self.service,
                    kSecAttrAccount as String: key,
                    kSecValueData as String: data,
                    kSecAttrLabel as String: "Rune Weaver: \(key)",
                    kSecAttrDescription as String: "Rune Weaver credential for \(key)"
                ]
                let status = SecItemAdd(query as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    return false
                }
                guard status == errSecSuccess else {
                    throw SecretsError.keychainError(status: status)
                }
                return true
            }
        #endif
        if fallbackStore[keyed: key, service: self.service] != nil {
            return false
        }
        fallbackStore[keyed: key, service: self.service] = data
        return true
    }

    /// Validates the shared store inputs and encodes the secret as UTF-8.
    private static func validatedStoreData(key: String, namespace: String, secret: String) throws -> Data {
        guard !key.isEmpty else {
            throw SecretsError.invalidInput(reason: "key must not be empty")
        }
        guard !namespace.isEmpty else {
            throw SecretsError.invalidInput(reason: "service must not be empty")
        }
        guard !secret.isEmpty else {
            throw SecretsError.invalidInput(reason: "secret must not be empty")
        }
        guard let data = secret.data(using: .utf8) else {
            throw SecretsError.encodingError
        }
        return data
    }

    /// Adds or updates one generic-password item, or lands in the in-memory
    /// stand-in when `inMemory` is set or the Security framework is absent.
    private func upsertSecret(_ data: Data, key: String, service namespace: String) throws {
        #if canImport(Security)
            if !inMemory {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: namespace,
                    kSecAttrAccount as String: key
                ]
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrLabel as String: "Rune Weaver: \(key)",
                    kSecAttrDescription as String: "Rune Weaver credential for \(key)"
                ]
                var status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                }
                guard status == errSecSuccess else {
                    throw SecretsError.keychainError(status: status)
                }
                return
            }
        #endif
        fallbackStore[keyed: key, service: namespace] = data
    }

    /// Reads one item as UTF-8 without consulting the environment, carrying
    /// the stored label so the env-consulting path can decide to backfill.
    private func readSecret(key: String, service namespace: String) throws -> (secret: String, label: String?)? {
        #if canImport(Security)
            if !inMemory {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: namespace,
                    kSecAttrAccount as String: key,
                    kSecReturnData as String: true,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecItemNotFound {
                    return nil
                }
                guard status == errSecSuccess else {
                    throw SecretsError.keychainError(status: status)
                }
                guard let dict = item as? [String: Any],
                      let data = dict[kSecValueData as String] as? Data,
                      let secret = String(data: data, encoding: .utf8)
                else {
                    throw SecretsError.encodingError
                }
                return (secret, dict[kSecAttrLabel as String] as? String)
            }
        #endif
        guard let data = fallbackStore[keyed: key, service: namespace],
              let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return (secret, nil)
    }

    /// Backfills a readable label on items written before labels were set.
    /// Applies only to real Keychain items; the in-memory store needs none.
    private func backfillLabelIfNeeded(_ currentLabel: String?, key: String, service namespace: String) {
        #if canImport(Security)
            guard !inMemory, currentLabel == nil || currentLabel == namespace else { return }
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: namespace,
                kSecAttrAccount as String: key
            ]
            let updateAttrs: [String: Any] = [
                kSecAttrLabel as String: "Rune Weaver: \(key)",
                kSecAttrDescription as String: "Rune Weaver credential for \(key)"
            ]
            _ = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        #endif
    }

    /// Deletes a secret from the Keychain. Missing items are a no-op.
    public func delete(key: String, service: String? = nil) throws {
        guard !key.isEmpty else {
            throw SecretsError.invalidInput(reason: "key must not be empty")
        }
        let namespace = service ?? self.service
        #if canImport(Security)
            if !inMemory {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: namespace,
                    kSecAttrAccount as String: key
                ]
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw SecretsError.keychainError(status: status)
                }
                return
            }
        #endif
        fallbackStore.remove(keyed: key, service: namespace)
    }

    /// Lists stored key names for the service namespace without reading values. Queries attributes
    /// only so no secret bytes are loaded, then returns the sorted account names capped to the
    /// listing bound.
    public func listKeys(service: String? = nil) throws -> [String] {
        let namespace = service ?? self.service
        #if canImport(Security)
            if !inMemory {
                // Attributes-only fetch: no value data requested, so matching
                // never loads secret bytes into this process.
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: namespace,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitAll
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound {
                    return []
                }
                guard status == errSecSuccess else {
                    throw SecretsError.keychainError(status: status)
                }
                var names: [String] = []
                if let items = result as? [[String: Any]] {
                    for item in items {
                        if let account = item[kSecAttrAccount as String] as? String, !account.isEmpty {
                            names.append(account)
                        }
                    }
                } else if let item = result as? [String: Any],
                          let account = item[kSecAttrAccount as String] as? String,
                          !account.isEmpty
                {
                    names.append(account)
                }
                names.sort()
                if names.count > Self.maxListKeys {
                    names = Array(names.prefix(Self.maxListKeys))
                }
                return names
            }
        #endif
        let names = fallbackStore.keys(for: namespace).sorted()
        if names.count > Self.maxListKeys {
            return Array(names.prefix(Self.maxListKeys))
        }
        return names
    }
}

/// Surrogate references stay beside the manager so Keychain reads keep one owner.
extension SecretsManager {
    // MARK: - Surrogates (agent-visible references)

    /// Prefix marking an agent-visible surrogate for a stored secret.
    public static let surrogatePrefix = "rwsecret:"

    /// Placeholder standing in for a resolved value swept from output.
    public static let redactedPlaceholder = "[redacted]"

    /// Issues an agent-visible surrogate for a stored key.
    public nonisolated func surrogate(for key: String) throws -> String {
        guard !key.isEmpty else {
            throw SecretsError.invalidInput(reason: "key must not be empty")
        }
        guard key.allSatisfy({ Self.isSurrogateKeyChar($0) }) else {
            throw SecretsError.invalidInput(reason: "key must contain only A-Z, a-z, 0-9, _, -, .")
        }
        return Self.surrogatePrefix + key
    }

    /// Whether a value holds at least one well-formed surrogate reference.
    /// - Parameter value: Candidate header value or free text.
    /// - Returns: True when `rwsecret:<key>` with a non-empty key occurs.
    public static func containsSurrogate(_ value: String) -> Bool {
        !surrogates(in: value).isEmpty
    }

    /// Whether a value mentions the surrogate prefix in any form.
    public static func containsSurrogatePrefix(_ value: String) -> Bool {
        value.contains(surrogatePrefix)
    }

    /// Extracts the key from an exact surrogate reference.
    public static func surrogateKey(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(surrogatePrefix) else { return nil }
        let afterPrefix = String(trimmed.dropFirst(surrogatePrefix.count))
        var end = afterPrefix.startIndex
        while end < afterPrefix.endIndex, isSurrogateKeyChar(afterPrefix[end]) {
            end = afterPrefix.index(after: end)
        }
        guard end > afterPrefix.startIndex else { return nil }
        guard end == afterPrefix.endIndex else { return nil }
        return String(afterPrefix[..<end])
    }

    /// Lists every surrogate key referenced inside a value.
    public static func surrogates(in value: String) -> [String] {
        var keys: [String] = []
        var cursor = value.startIndex
        while let found = value.range(of: surrogatePrefix, range: cursor ..< value.endIndex) {
            var end = found.upperBound
            while end < value.endIndex, isSurrogateKeyChar(value[end]) {
                end = value.index(after: end)
            }
            if end > found.upperBound {
                keys.append(String(value[found.upperBound ..< end]))
            }
            cursor = found.upperBound
            if cursor >= value.endIndex {
                break
            }
        }
        return keys
    }

    /// Maximum key names returned by a single listing.
    ///
    /// Bounds enumeration so one request cannot stream an unbounded Keychain.
    public static let maxListKeys = 2000

    /// Maximum secret key characters accepted as a surrogate name. Bounds Keychain and memory
    /// pressure from unbounded key strings.
    public static let maxSurrogateKeyLength = 256

    /// Whether a raw secret key is usable as a surrogate name.
    public static func isValidSurrogateKey(_ rawKey: String) -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= maxSurrogateKeyLength else { return false }
        return key.allSatisfy { isSurrogateKeyChar($0) }
    }

    /// Whether a key name collides with a reserved sovereign account.
    public static func isReservedAccount(_ rawKey: String) -> Bool {
        rawKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(reservedAccountPrefix)
    }

    /// Whether a character may appear in a surrogate key name.
    /// - Parameter character: Candidate key character.
    /// - Returns: True for secret-name characters; everything else ends the key.
    static func isSurrogateKeyChar(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        let scalarValue = scalar.value
        let isUpper = scalarValue >= 65 && scalarValue <= 90
        let isLower = scalarValue >= 97 && scalarValue <= 122
        let isDigit = scalarValue >= 48 && scalarValue <= 57
        return isUpper || isLower || isDigit || character == "_" || character == "-" || character == "."
    }

    /// Resolves one exact surrogate reference to its live secret.
    public func resolveSurrogate(_ surrogate: String, service: String? = nil) throws -> String {
        guard let key = Self.surrogateKey(from: surrogate) else {
            throw SecretsError.invalidInput(reason: "value is not a secret surrogate (expected rwsecret:<key>)")
        }
        guard !Self.isReservedAccount(key) else {
            // Reserved sovereign material refuses resolution and reports as
            // unknown, so the surrogate surface can never read the signing key
            // or anchor and a probe cannot confirm the account exists.
            throw SecretsError.unknownSurrogate(key: key)
        }
        guard let secret = try retrieve(key: key, service: service), !secret.isEmpty else {
            throw SecretsError.unknownSurrogate(key: key)
        }
        return secret
    }

    /// Resolves every surrogate embedded in a value just-in-time.
    public func resolveValueContainingSurrogates(
        _ value: String,
        service: String? = nil
    ) throws -> (resolved: String, secrets: [String]) {
        let keys = Self.surrogates(in: value)
        guard !keys.isEmpty else {
            if Self.containsSurrogatePrefix(value) {
                throw SecretsError.invalidInput(reason: "value contains a malformed secret surrogate (expected rwsecret:<key>)")
            }
            return (value, [])
        }
        var resolved = value
        var secrets: [String] = []
        secrets.reserveCapacity(keys.count)
        for key in keys {
            // Same reservation refusal as the exact-reference path.
            guard !Self.isReservedAccount(key) else {
                throw SecretsError.unknownSurrogate(key: key)
            }
            guard let secret = try retrieve(key: key, service: service), !secret.isEmpty else {
                throw SecretsError.unknownSurrogate(key: key)
            }
            resolved = resolved.replacingOccurrences(
                of: Self.surrogatePrefix + key,
                with: secret
            )
            secrets.append(secret)
        }
        return (resolved, secrets)
    }

    /// Sweeps resolved secret values out of a value with longest-first ordering. Longest values
    /// sweep first so overlapping secrets cannot leave a suffix behind.
    public static func sweepResolved(_ content: String, secrets: [String]) -> String {
        let ordered = secrets.filter { !$0.isEmpty }.sorted(by: { $0.count > $1.count })
        guard !ordered.isEmpty else { return content }
        var swept = content
        for secret in ordered {
            swept = swept.replacingOccurrences(of: secret, with: redactedPlaceholder)
        }
        return swept
    }

    /// Sweeps resolved secret values out of output content. - secrets: Live values inserted at the
    /// transport boundary.
    public nonisolated func redactResolved(_ content: String, secrets: [String] = []) -> String {
        Self.sweepResolved(content, secrets: secrets)
    }

    /// Redacts one header value with the single-sourced surrogate rule. The dependency runs tools
    /// to core only, so the gate and the tools layer both delegate here without an import cycle.
    public static func redactedHeaderValue(_ value: String, isAuthorization: Bool, resolvedSecrets: [String] = []) -> String {
        if isAuthorization {
            if resolvedSecrets.isEmpty, containsSurrogate(value) {
                sweepResolved(value, secrets: resolvedSecrets)
            } else {
                redactedPlaceholder
            }
        } else {
            sweepResolved(value, secrets: resolvedSecrets)
        }
    }

    // MARK: - Env-name resolution

    /// Resolves an `api_key_env`-style reference or an exact surrogate. Malformed surrogate-like
    /// inputs (bare prefix or trailing text) fail closed instead of falling through to a plain
    /// lookup.
    public func resolve(_ envVar: String?, service: String? = nil) throws -> String? {
        guard let envVar, !envVar.isEmpty else { return nil }
        if Self.surrogateKey(from: envVar) != nil {
            return try resolveSurrogate(envVar, service: service)
        }
        if Self.containsSurrogatePrefix(envVar) {
            throw SecretsError.invalidInput(reason: "value is not a valid secret surrogate (expected rwsecret:<key>)")
        }
        return try retrieve(key: envVar, service: service)
    }
}

/// In-memory stand-in used when inMemory is enabled or where the Security framework is
/// unavailable (e.g. Linux CI). The environment fallback still applies.
private struct FallbackStore: Sendable {
    private var values: [String: Data] = [:]

    subscript(keyed key: String, service namespace: String) -> Data? {
        get { values["\(namespace)/\(key)"] }
        set { values["\(namespace)/\(key)"] = newValue }
    }

    mutating func remove(keyed key: String, service namespace: String) {
        values.removeValue(forKey: "\(namespace)/\(key)")
    }

    /// Key names stored under one namespace.
    func keys(for namespace: String) -> [String] {
        let prefix = "\(namespace)/"
        var names: [String] = []
        names.reserveCapacity(values.count)
        for full in values.keys where full.hasPrefix(prefix) {
            let key = String(full.dropFirst(prefix.count))
            if !key.isEmpty {
                names.append(key)
            }
        }
        return names
    }
}
