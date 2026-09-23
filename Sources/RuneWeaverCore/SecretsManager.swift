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

    // MARK: - Surrogates (agent-visible references)

    /// Prefix marking an agent-visible surrogate for a stored secret.
    ///
    /// The surrogate carries only the key name (for example
    /// `rwsecret:MY_API_KEY`); the value stays in the environment or
    /// Keychain until the transport boundary swaps it back. The surrogate
    /// itself is safe to show the model, log, and persist because it reveals
    /// nothing beyond which slot will be used.
    public static let surrogatePrefix = "rwsecret:"

    /// Placeholder standing in for a resolved value swept from output.
    ///
    /// Mirrors the API header redaction marker so logs and envelopes agree
    /// on one redacted shape without the core depending on the tools layer.
    public static let redactedPlaceholder = "[redacted]"

    /// Issues an agent-visible surrogate for a stored key.
    ///
    /// The surrogate is a reference, not a copy: no secret bytes are read or
    /// stored here, so a later rotation is picked up at resolution time.
    /// Issuance validates so every issued reference round-trips through
    /// `containsSurrogate` and `surrogateKey`: an empty or non-name key would
    /// otherwise produce an unresolvable `rwsecret:` reference with no error.
    /// - Parameter key: Secret key (environment / Keychain name).
    /// - Returns: `rwsecret:<key>` reference for model-visible arguments.
    /// - Throws: `invalidInput` when the key is empty or holds non-name characters.
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
    ///
    /// Single source for fail-closed transport: well-formed references parse
    /// through `surrogates(in:)`, while bare or malformed occurrences
    /// (`rwsecret:`, `rwsecret: `, `rwsecret:!`) still mention the prefix and
    /// must throw instead of forwarding the literal to the wire.
    /// - Parameter value: Candidate header value or free text.
    /// - Returns: True when `rwsecret:` occurs anywhere in the value.
    public static func containsSurrogatePrefix(_ value: String) -> Bool {
        value.contains(surrogatePrefix)
    }

    /// Extracts the key from an exact surrogate reference.
    ///
    /// Only the whole-value form qualifies (`rwsecret:KEY` with optional
    /// surrounding whitespace); embedded forms like `Bearer rwsecret:KEY`
    /// resolve through the header-value path instead. Inner whitespace after
    /// the prefix disqualifies the exact form so this path agrees with
    /// `surrogates(in:)`, which requires immediate name characters: a value
    /// like `rwsecret: KEY` parses as malformed on both paths instead of
    /// succeeding here while yielding no keys there. The key shares the
    /// single-source name alphabet with `surrogates(in:)`: any trailing text
    /// after the maximal name run disqualifies the exact form so both paths
    /// agree on where the key ends.
    /// - Parameter value: Candidate exact reference.
    /// - Returns: Trimmed key, or nil when the value is not an exact surrogate.
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
    ///
    /// Keys are maximal runs of secret-name characters (`A-Z`, `a-z`,
    /// `0-9`, `_`, `-`, `.`) following each prefix occurrence, so trailing
    /// prose punctuation never joins the key. The cursor advances past the
    /// prefix (not past the consumed key) so a chained prefix inside the key
    /// run (`rwsecret:rwsecret:KEY`) still reports both references instead of
    /// swallowing the second.
    /// - Parameter value: Header value or free text to scan.
    /// - Returns: Referenced keys in encounter order, duplicates preserved.
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
    ///
    /// Reads through the same environment-first, Keychain-second path as
    /// `retrieve`, so rotation between issuance and use is honored.
    /// - Parameters:
    ///   - surrogate: Exact `rwsecret:<key>` reference.
    ///   - service: Keychain namespace override.
    /// - Returns: Live secret value.
    /// - Throws: `invalidInput` when the value is not an exact surrogate;
    ///   `unknownSurrogate` when the key holds no secret.
    public func resolveSurrogate(_ surrogate: String, service: String? = nil) throws -> String {
        guard let key = Self.surrogateKey(from: surrogate) else {
            throw SecretsError.invalidInput(reason: "value is not a secret surrogate (expected rwsecret:<key>)")
        }
        guard let secret = try retrieve(key: key, service: service), !secret.isEmpty else {
            throw SecretsError.unknownSurrogate(key: key)
        }
        return secret
    }

    /// Resolves every surrogate embedded in a value just-in-time.
    ///
    /// Header values may carry a bare reference (`rwsecret:KEY`) or embed it
    /// in a scheme (`Bearer rwsecret:KEY`); each reference is swapped for its
    /// live secret at the transport boundary, keeping agent-authored arguments
    /// free of real values. A bare prefix with no well-formed key fails closed
    /// instead of forwarding the literal to the wire.
    /// - Parameters:
    ///   - value: Header value possibly holding surrogates.
    ///   - service: Keychain namespace override.
    /// - Returns: Resolved value plus the live secrets that were inserted,
    ///   in encounter order, for output sweeping.
    /// - Throws: `invalidInput` when the value mentions the prefix without a
    ///   well-formed key; `unknownSurrogate` naming the first key with no secret.
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

    /// Sweeps resolved secret values out of a value with longest-first ordering.
    ///
    /// Single source for every longest-first secret sweep: the instance
    /// `redactResolved` and the tools-layer header sweep both delegate here so
    /// the ordering rule and the shared redacted marker cannot diverge.
    /// Longest values sweep first so overlapping secrets cannot leave a suffix
    /// behind.
    /// - Parameters:
    ///   - content: Value possibly echoing secrets.
    ///   - secrets: Live values inserted at the transport boundary.
    /// - Returns: Content with every non-empty secret replaced by the shared marker.
    public static func sweepResolved(_ content: String, secrets: [String]) -> String {
        let ordered = secrets.filter { !$0.isEmpty }.sorted(by: { $0.count > $1.count })
        guard !ordered.isEmpty else { return content }
        var swept = content
        for secret in ordered {
            swept = swept.replacingOccurrences(of: secret, with: redactedPlaceholder)
        }
        return swept
    }

    /// Sweeps resolved secret values out of output content.
    ///
    /// Defense against echo: when a server reflects a credential (an
    /// `Authorization` value bounced in a body, for example), every inserted
    /// value is replaced with the shared redacted marker before the envelope
    /// reaches the model. Delegates to the shared sweep so the instance path
    /// and the header path stay identical.
    /// - Parameters:
    ///   - content: Tool output content possibly echoing secrets.
    ///   - secrets: Live values inserted at the transport boundary.
    /// - Returns: Content with every non-empty secret replaced by `[redacted]`.
    public nonisolated func redactResolved(_ content: String, secrets: [String] = []) -> String {
        Self.sweepResolved(content, secrets: secrets)
    }

    /// Redacts one header value with the single-sourced surrogate rule.
    ///
    /// Single source for the approval-target summary and the tools-layer
    /// preview policy so both agree on surrogate visibility: an
    /// `Authorization` value carrying a well-formed `rwsecret:<key>`
    /// reference stays visible while unresolved (no secret bytes to hide),
    /// every other `Authorization` value redacts to the shared placeholder,
    /// and non-`Authorization` values sweep resolved echoes. The dependency
    /// runs tools to core only, so the gate and the tools layer both
    /// delegate here without an import cycle.
    /// - Parameters:
    ///   - value: Raw header value.
    ///   - isAuthorization: True for the `Authorization` header (case-insensitive match by callers).
    ///   - resolvedSecrets: Live values inserted at the transport boundary.
    /// - Returns: Visible surrogate reference, swept value, or the shared placeholder.
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

    /// Resolves an `api_key_env`-style reference or an exact surrogate.
    ///
    /// Surrogate inputs (`rwsecret:KEY`) swap back to the live secret and
    /// throw a typed error when the slot is empty; plain names keep the
    /// historical environment-first, Keychain-second lookup returning nil
    /// when absent. Malformed surrogate-like inputs (bare prefix or trailing
    /// text) fail closed instead of falling through to a plain lookup.
    /// Embedded forms (`Bearer rwsecret:KEY`) resolve through
    /// `resolveValueContainingSurrogates` instead.
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

    /// Reads the live process environment for `key`.
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
