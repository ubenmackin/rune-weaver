// Rune Weaver Server Tests — Web Push VAPID, RFC 8291 encryption, subscription storage, and routes.

import CryptoKit
import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

@Suite("Web Push Infrastructure")
struct WebPushTests {
    @Test
    func `WebPushKeys generates valid P256 keypair and signs ES256 JWT`() throws {
        let keys = WebPushKeys(privateKey: P256.Signing.PrivateKey())
        let pubKeyB64 = keys.publicKeyBase64URL

        guard let pubKeyData = WebPushKeys.dataFromBase64URL(pubKeyB64) else {
            Issue.record("Failed to decode public key from base64url")
            return
        }
        // X9.63 uncompressed P-256 public key is 65 bytes starting with 0x04
        #expect(pubKeyData.count == 65)
        #expect(pubKeyData.first == 0x04)

        let jwt = try keys.signJWT(
            audience: "https://web.push.apple.com",
            subject: "mailto:operator@example.com"
        )
        let components = jwt.components(separatedBy: ".")
        #expect(components.count == 3)

        guard let headerData = WebPushKeys.dataFromBase64URL(components[0]),
              let payloadData = WebPushKeys.dataFromBase64URL(components[1]),
              let signatureData = WebPushKeys.dataFromBase64URL(components[2])
        else {
            Issue.record("Failed to decode JWT segments")
            return
        }

        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["typ"] as? String == "JWT")

        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        #expect(payload?["aud"] as? String == "https://web.push.apple.com")
        #expect(payload?["sub"] as? String == "mailto:operator@example.com")
        let exp = try #require(payload?["exp"] as? Int)
        let now = Int(Date().timeIntervalSince1970)
        #expect(exp - now <= 43200 + 5)
        #expect(exp - now >= 43200 - 5)

        // Verify cryptographic signature with public key
        let signingInput = "\(components[0]).\(components[1])"
        let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let isValid = keys.privateKey.publicKey.isValidSignature(ecdsaSignature, for: Data(signingInput.utf8))
        #expect(isValid)
    }

    @Test
    func `WebPushKeys persists in SecretsManager and restores identical key`() async throws {
        let secrets = SecretsManager(inMemory: true)
        let first = try await WebPushKeys.loadOrGenerate(secrets: secrets)
        let second = try await WebPushKeys.loadOrGenerate(secrets: secrets)

        #expect(first.publicKeyBase64URL == second.publicKeyBase64URL)
        #expect(first.privateKey.rawRepresentation == second.privateKey.rawRepresentation)
    }

    @Test
    func `PushSubscriptionStore enforces strict SSRF endpoint validation`() {
        // Allowed valid gateways
        #expect(PushSubscriptionStore.validateEndpoint("https://web.push.apple.com/QN57829-token") != nil)
        #expect(PushSubscriptionStore.validateEndpoint("https://fcm.googleapis.com/fcm/send/token") != nil)
        #expect(PushSubscriptionStore.validateEndpoint("https://push.services.mozilla.com/push/v1/token") != nil)
        #expect(PushSubscriptionStore.validateEndpoint("https://wns2-sn1p.notify.windows.com/w/?token=abc") != nil)

        // Blocked SSRF attempts
        #expect(PushSubscriptionStore.validateEndpoint("http://web.push.apple.com/token") == nil) // Insecure HTTP
        #expect(PushSubscriptionStore.validateEndpoint("https://127.0.0.1/push") == nil) // Loopback IP
        #expect(PushSubscriptionStore.validateEndpoint("https://10.0.0.1/push") == nil) // Private LAN IP
        #expect(PushSubscriptionStore.validateEndpoint("https://192.168.1.5/push") == nil) // Private LAN IP
        #expect(PushSubscriptionStore.validateEndpoint("https://localhost/push") == nil) // Localhost
        #expect(PushSubscriptionStore.validateEndpoint("https://internal.company.local/push") == nil) // .local
        #expect(PushSubscriptionStore.validateEndpoint("https://user:pass@web.push.apple.com/token") == nil) // Credentials
        #expect(PushSubscriptionStore.validateEndpoint("https://evil-attacker.com/steal") == nil) // Unknown domain
        #expect(PushSubscriptionStore.validateEndpoint("https://apple.com.attacker.com/push") == nil) // Spoofed domain
    }

    @Test
    func `PushSubscriptionStore manages subscriptions in SQLite`() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-test-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let store = PushSubscriptionStore(dbPath: tempDB)
        #expect(await store.allSubscriptions().isEmpty)

        let deviceKey = P256.KeyAgreement.PrivateKey()
        let deviceP256 = WebPushKeys.base64URL(deviceKey.publicKey.x963Representation)
        let deviceAuth = WebPushKeys.base64URL(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        let record = try await store.save(
            endpoint: "https://web.push.apple.com/sub-1",
            p256dh: deviceP256,
            auth: deviceAuth,
            userAgent: "iPhone Safari"
        )
        #expect(record.endpoint == "https://web.push.apple.com/sub-1")
        #expect(record.userAgent == "iPhone Safari")

        let all = await store.allSubscriptions()
        #expect(all.count == 1)
        #expect(all[0].endpoint == "https://web.push.apple.com/sub-1")

        // Upsert updates keys without duplicating rows
        let rotatedKey = P256.KeyAgreement.PrivateKey()
        let rotatedP256 = WebPushKeys.base64URL(rotatedKey.publicKey.x963Representation)
        let rotatedAuth = WebPushKeys.base64URL(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        try await store.save(
            endpoint: "https://web.push.apple.com/sub-1",
            p256dh: rotatedP256,
            auth: rotatedAuth,
            userAgent: "iPad Safari"
        )
        let updatedAll = await store.allSubscriptions()
        #expect(updatedAll.count == 1)
        #expect(updatedAll[0].p256dhKey == rotatedP256)
        #expect(updatedAll[0].userAgent == "iPad Safari")

        // Removal
        let removed = await store.remove(endpoint: "https://web.push.apple.com/sub-1")
        #expect(removed)
        #expect(await store.allSubscriptions().isEmpty)
    }

    @Test
    func `WebPushSender RFC 8291 encryption and decryption round-trip`() throws {
        let clientPrivateKey = P256.KeyAgreement.PrivateKey()
        let clientPublicKeyB64 = WebPushKeys.base64URL(clientPrivateKey.publicKey.x963Representation)
        let clientAuthData = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let clientAuthB64 = WebPushKeys.base64URL(clientAuthData)

        let originalPlaintext = Data(#"{"title":"Action Requires Attention","body":"Severity: high"}"#.utf8)

        let encrypted = try WebPushSender.encryptPayload(
            plaintext: originalPlaintext,
            clientP256Base64: clientPublicKeyB64,
            clientAuthBase64: clientAuthB64
        )

        // aes128gcm header is 86 bytes: 16 salt + 4 rs + 1 idlen + 65 key.
        #expect(encrypted.count > 86)
        let salt = encrypted.subdata(in: 0 ..< 16)
        let rsData = encrypted.subdata(in: 16 ..< 20)
        let idlen = encrypted[20]
        let serverPublicKeyData = encrypted.subdata(in: 21 ..< 86)

        #expect(idlen == 65)
        #expect(serverPublicKeyData.count == 65)
        #expect(serverPublicKeyData[0] == 0x04)
        let rs = rsData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        #expect(rs == 4096)

        let serverPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPublicKeyData)
        let clientSharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let clientSharedSymmetricKey = clientSharedSecret.withUnsafeBytes { SymmetricKey(data: $0) }

        let prk = HKDF<SHA256>.extract(inputKeyMaterial: clientSharedSymmetricKey, salt: clientAuthData)
        var ikmInfo = Data("WebPush: info\0".utf8)
        ikmInfo.append(clientPrivateKey.publicKey.x963Representation)
        ikmInfo.append(serverPublicKeyData)
        let ikm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: ikmInfo, outputByteCount: 32)

        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16
        )

        let nonceData = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12
        ).withUnsafeBytes { Data($0) }
        let nonce = try AES.GCM.Nonce(data: nonceData)

        let ciphertextAndTag = encrypted.subdata(in: 86 ..< encrypted.count)
        let ciphertext = ciphertextAndTag.subdata(in: 0 ..< (ciphertextAndTag.count - 16))
        let tag = ciphertextAndTag.subdata(in: (ciphertextAndTag.count - 16) ..< ciphertextAndTag.count)

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let decryptedWithDelimiter = try AES.GCM.open(sealedBox, using: cek)

        // Delimiter 0x02 marks terminal record
        #expect(decryptedWithDelimiter.last == 0x02)
        let decryptedPlaintext = decryptedWithDelimiter.dropLast()
        #expect(decryptedPlaintext == originalPlaintext)
    }

    @Test
    func `sw_js is allowlisted for static root delivery without auth`() {
        #expect(ServerAuthRequest.isKnownStaticRootFile("sw.js"))
    }

    @Test
    func `WebPushKeys subject normalization handles raw domains, emails, and URIs`() {
        #expect(WebPushKeys.normalizeSubject("volcrypt.com") == "https://volcrypt.com")
        #expect(WebPushKeys.normalizeSubject("operator@volcrypt.com") == "mailto:operator@volcrypt.com")
        #expect(WebPushKeys.normalizeSubject("https://volcrypt.com/push") == "https://volcrypt.com/push")
        #expect(WebPushKeys.normalizeSubject("mailto:alerts@volcrypt.com") == "mailto:alerts@volcrypt.com")
        #expect(WebPushKeys.normalizeSubject("   ") == "")
    }

    private struct MockPushTransport: WebPushTransport {
        let status: Int
        let body: String

        func send(request _: URLRequest) async throws -> (data: Data, httpStatus: Int) {
            (Data(body.utf8), status)
        }
    }

    @Test
    func `WebPushSender surfaces APNs error status and body on non-2xx responses`() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-err-test-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let store = PushSubscriptionStore(dbPath: tempDB)
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let deviceP256 = WebPushKeys.base64URL(deviceKey.publicKey.x963Representation)
        let deviceAuth = WebPushKeys.base64URL(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        _ = try await store.save(
            endpoint: "https://web.push.apple.com/test-endpoint",
            p256dh: deviceP256,
            auth: deviceAuth
        )

        let mockTransport = MockPushTransport(status: 400, body: "BadJwtToken")
        let vapid = WebPushKeys(privateKey: P256.Signing.PrivateKey())
        let configBox = NotificationsConfigBox(NotificationsConfig(pushContact: "operator@volcrypt.com"))
        let sender = WebPushSender(
            vapidKeys: vapid,
            subscriptions: store,
            transport: mockTransport,
            notificationsBox: configBox
        )

        let result = await sender.broadcast(payload: WebPushSender.PushPayload(title: "Alert", body: "Test"))
        #expect(result.delivered == 0)
        #expect(result.totalSubscribers == 1)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("HTTP 400: BadJwtToken"))
    }
}
