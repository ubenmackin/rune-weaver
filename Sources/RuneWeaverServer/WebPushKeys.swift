// Rune Weaver Server — VAPID P-256 keypair management and JWT signing for Web Push (RFC 8292).

import CryptoKit
import Foundation
import RuneWeaverCore

/// Failures loading or persisting the VAPID keypair or signing tokens.
public enum WebPushKeysError: LocalizedError, Sendable {
    case persistenceUnavailable(reason: String)
    case missingSubject
    case invalidSubject(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .persistenceUnavailable(reason):
            reason
        case .missingSubject:
            "Web Push contact is not configured. Please set a contact email or domain under Settings -> Notifications."
        case let .invalidSubject(reason):
            reason
        }
    }
}

/// Manages VAPID P-256 key persistence and signing for Web Push notifications.
public struct WebPushKeys: Sendable {
    /// Dedicated account key in SecretsManager.
    public static let vapidSecretAccount = "sovereign.webpush.vapid_p256"

    /// Private signing key.
    public let privateKey: P256.Signing.PrivateKey

    /// Creates a key manager with an explicit private key.
    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Loads or generates a persistent VAPID keypair using the provided SecretsManager.
    public static func loadOrGenerate(secrets: SecretsManager?) async throws -> WebPushKeys {
        guard let secrets else {
            throw WebPushKeysError.persistenceUnavailable(
                reason: "VAPID signing key requires SecretsManager persistence; refusing ephemeral fallback."
            )
        }

        let stored: String?
        do {
            stored = try await secrets.retrieveKeychain(key: vapidSecretAccount)
        } catch {
            throw WebPushKeysError.persistenceUnavailable(
                reason: "VAPID signing key is locked in the Keychain; unlock the Keychain and retry."
            )
        }
        if let stored {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawData = Data(base64Encoded: trimmed),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: rawData)
            else {
                throw WebPushKeysError.persistenceUnavailable(
                    reason: "VAPID signing key in the Keychain is corrupt; delete the stale Keychain item to mint a fresh key."
                )
            }
            return WebPushKeys(privateKey: key)
        }

        let newKey = P256.Signing.PrivateKey()
        let b64 = newKey.rawRepresentation.base64EncodedString()
        do {
            // Add-only mint converges via the re-read below: a concurrent
            // creator's item wins and every writer adopts one identity key.
            _ = try await secrets.storeKeychainIfAbsent(key: vapidSecretAccount, secret: b64)
        } catch {
            // Fall through to adopt the stored winner; absence there still fails closed.
        }
        let adopted: String?
        do {
            adopted = try await secrets.retrieveKeychain(key: vapidSecretAccount)
        } catch {
            throw WebPushKeysError.persistenceUnavailable(
                reason: "VAPID signing key was stored but could not be read back; unlock the Keychain and retry."
            )
        }
        guard let adopted,
              let rawData = Data(base64Encoded: adopted.trimmingCharacters(in: .whitespacesAndNewlines)),
              let winner = try? P256.Signing.PrivateKey(rawRepresentation: rawData)
        else {
            throw WebPushKeysError.persistenceUnavailable(
                reason: "VAPID signing key could not be persisted; unlock the Keychain and retry."
            )
        }
        return WebPushKeys(privateKey: winner)
    }

    /// Uncompressed X9.63 public key (65 bytes) encoded as unpadded base64url.
    public var publicKeyBase64URL: String {
        Self.base64URL(privateKey.publicKey.x963Representation)
    }

    /// Normalizes a user-supplied contact (email or URL) into a valid RFC 8292 `sub` claim.
    public static func normalizeSubject(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            return trimmed
        }
        if trimmed.contains("@") {
            return "mailto:\(trimmed)"
        }
        return "https://\(trimmed)"
    }

    /// Signs a VAPID ES256 JWT for the target push gateway audience (RFC 8292).
    /// - Parameters:
    ///   - audience: Push gateway audience origin (e.g. `https://web.push.apple.com`).
    ///   - subject: Contact URI (`mailto:...` or `https://...`) identifying the operator.
    ///   - expirationSeconds: Expiry delta. Defaults to 43,200s (12h) to avoid clock skew rejection.
    public func signJWT(
        audience: String,
        subject: String,
        expirationSeconds: Int = 43200
    ) throws -> String {
        let normalized = Self.normalizeSubject(subject)
        guard !normalized.isEmpty else {
            throw WebPushKeysError.missingSubject
        }

        let headerJSON = #"{"alg":"ES256","typ":"JWT"}"#
        let headerB64 = Self.base64URL(Data(headerJSON.utf8))

        // Clamped expiration: must not exceed 24 hours (86,400s) per RFC 8292 §2.1.
        let clampedDelta = max(60, min(expirationSeconds, 86400))
        let exp = Int(Date().timeIntervalSince1970) + clampedDelta
        let payloadDict: [String: Any] = [
            "aud": audience,
            "exp": exp,
            "sub": normalized
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys])
        let payloadB64 = Self.base64URL(payloadData)

        let signingInput = "\(headerB64).\(payloadB64)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        let signatureB64 = Self.base64URL(signature.rawRepresentation)

        return "\(signingInput).\(signatureB64)"
    }

    /// Encodes data to base64url string without trailing '=' padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Decodes an unpadded base64url string to Data.
    public static func dataFromBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
