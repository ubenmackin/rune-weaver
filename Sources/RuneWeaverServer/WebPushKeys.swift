// Rune Weaver Server — VAPID P-256 keypair management and JWT signing for Web Push (RFC 8292).

import CryptoKit
import Foundation
import RuneWeaverCore

/// Failures loading or persisting the VAPID keypair.
public enum WebPushKeysError: LocalizedError, Sendable {
    case persistenceUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .persistenceUnavailable(reason):
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

    /// Signs a VAPID ES256 JWT for the target push gateway audience (RFC 8292).
    public func signJWT(
        audience: String,
        subject: String = "mailto:operator@runeweaver.local",
        expirationSeconds: Int = 86400
    ) throws -> String {
        let headerJSON = #"{"alg":"ES256","typ":"JWT"}"#
        let headerB64 = Self.base64URL(Data(headerJSON.utf8))

        let exp = Int(Date().timeIntervalSince1970) + expirationSeconds
        let payloadDict: [String: Any] = [
            "aud": audience,
            "exp": exp,
            "sub": subject
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
