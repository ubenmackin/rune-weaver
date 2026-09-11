import Foundation

#if canImport(Security)
    import Security
#endif

/// Errors thrown by ``SecretsManager``.
///
/// These errors carry only key names and status codes — secret values
/// are never embedded in them.
public enum SecretsError: Error, Sendable, Equatable {
    /// The key or secret was empty.
    case invalidInput(reason: String)
    /// A Keychain operation failed.
    case keychainError(status: Int32)
    /// Secret bytes could not be encoded or decoded as UTF-8.
    case encodingError
}

/// macOS Keychain-backed secrets with environment variable fallback.
///
/// Lookup order in ``SecretsManager/retrieve(key:service:)``:
/// 1. `ProcessInfo.processInfo.environment[key]` — Docker/vault injection.
/// 2. macOS Keychain item `(service, key)`.
///
/// Writes always go to the Keychain. Secrets are never logged, never
/// included in error messages, and never written to `config.toml`.
public actor SecretsManager {
    /// Default Keychain service namespace for all RuneWeaver secrets.
    public static let defaultService = "com.runeweaver.secrets"

    /// Keychain service namespace used when callers omit `service`.
    public let service: String

    /// Creates a secrets manager.
    /// - Parameter service: Keychain service namespace. Defaults to
    ///   `com.runeweaver.secrets`.
    public init(service: String = SecretsManager.defaultService) {
        self.service = service
    }

    // MARK: - Store / retrieve

    /// Stores a secret in the Keychain, updating any existing item.
    /// - Parameters:
    ///   - key: Account name within `service` (e.g. `OPENROUTER_API_KEY`).
    ///   - service: Keychain service. Defaults to this manager's service.
    ///   - secret: Secret value. Never logged.
    public func store(key: String, service: String? = nil, secret: String) throws {
        let namespace = service ?? self.service
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
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: namespace,
                kSecAttrAccount as String: key
            ]
            let attributes: [String: Any] = [kSecValueData as String: data]
            var status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
            guard status == errSecSuccess else {
                throw SecretsError.keychainError(status: status)
            }
        #else
            fallbackStore[keyed: key, service: namespace] = data
        #endif
    }

    /// Retrieves a secret, checking the environment first.
    ///
    /// Environment variables take precedence so Docker/vault-injected
    /// secrets work without Keychain entries. Returns `nil` when the
    /// secret exists in neither place.
    /// - Parameters:
    ///   - key: Account name, also used as the environment variable name.
    ///   - service: Keychain service. Defaults to this manager's service.
    /// - Returns: The secret, or `nil` when not found.
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
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: namespace,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
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
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw SecretsError.encodingError
            }
            return secret
        #else
            guard let data = fallbackStore[keyed: key, service: namespace] else { return nil }
            return String(data: data, encoding: .utf8)
        #endif
    }

    /// Deletes a secret from the Keychain. Missing items are a no-op.
    /// - Parameters:
    ///   - key: Account name.
    ///   - service: Keychain service. Defaults to this manager's service.
    public func delete(key: String, service: String? = nil) throws {
        guard !key.isEmpty else {
            throw SecretsError.invalidInput(reason: "key must not be empty")
        }
        let namespace = service ?? self.service
        #if canImport(Security)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: namespace,
                kSecAttrAccount as String: key
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretsError.keychainError(status: status)
            }
        #else
            fallbackStore.remove(keyed: key, service: namespace)
        #endif
    }

    // MARK: - Env-name resolution

    /// Resolves an `api_key_env`-style reference: environment variable
    /// first, then the Keychain under the same name.
    ///
    /// `ProviderConfig.apiKeyEnv`, `HomeAssistantConfig.tokenEnv`, and
    /// `EmailAccount.passwordEnvVar` flow through here so TOML only names
    /// the variable while the value itself comes from the environment or
    /// Keychain.
    /// - Parameters:
    ///   - envVar: Environment variable name (and Keychain key).
    ///   - service: Keychain service. Defaults to this manager's service.
    /// - Returns: The secret, or `nil` when `envVar` is `nil`/unset.
    public func resolve(_ envVar: String?, service: String? = nil) throws -> String? {
        guard let envVar, !envVar.isEmpty else { return nil }
        return try retrieve(key: envVar, service: service)
    }

    /// Reads the live process environment for `key`.
    ///
    /// Uses `getenv` so values installed with `setenv` after launch are
    /// visible. `ProcessInfo.processInfo.environment` is a launch-time
    /// snapshot and misses such updates. Never logs the value.
    /// - Parameter key: Environment variable name.
    /// - Returns: Value, or `nil` when unset or not valid UTF-8.
    private nonisolated func liveEnvironmentValue(for key: String) -> String? {
        key.withCString { cKey in
            guard let cValue = getenv(cKey) else { return nil }
            return String(validatingCString: cValue)
        }
    }

    #if !canImport(Security)
        private var fallbackStore: FallbackStore = .init()
    #endif
}

#if !canImport(Security)
    /// In-memory stand-in used only where the Security framework is
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
    }
#endif
