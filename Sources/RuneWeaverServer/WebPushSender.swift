// Rune Weaver Server — RFC 8291 (Message Encryption for Web Push) & RFC 8292 (VAPID) outbound delivery.

import CryptoKit
import Foundation
import RuneWeaverCore
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Abstraction for HTTP outbound push transport so unit tests remain hermetic.
public protocol WebPushTransport: Sendable {
    func send(request: URLRequest) async throws -> (data: Data, httpStatus: Int)
}

/// Production transport using URLSession.
public struct URLSessionWebPushTransport: WebPushTransport {
    public init() {}

    public func send(request: URLRequest) async throws -> (data: Data, httpStatus: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

/// No-op transport for hermetic testing.
public struct NoOpWebPushTransport: WebPushTransport {
    public init() {}

    public func send(request _: URLRequest) async throws -> (data: Data, httpStatus: Int) {
        (Data(), 201)
    }
}

/// Dispatches system notifications to both local desktop notifier and subscribed mobile PWA Web Push devices.
public struct CompositeSchedulerNotifier: SchedulerNotifier {
    private let primary: any SchedulerNotifier?
    private let pushSender: WebPushSender
    /// Live per-type preferences shared with the scheduler worker and approval handler.
    public let notificationsBox: NotificationsConfigBox

    public init(
        primary: any SchedulerNotifier?,
        pushSender: WebPushSender,
        notificationsBox: NotificationsConfigBox = NotificationsConfigBox()
    ) {
        self.primary = primary
        self.pushSender = pushSender
        self.notificationsBox = notificationsBox
    }

    /// Convenience init preserving the boot call shape with a snapshot.
    public init(
        primary: any SchedulerNotifier?,
        pushSender: WebPushSender,
        notifications: NotificationsConfig
    ) {
        self.primary = primary
        self.pushSender = pushSender
        self.notificationsBox = NotificationsConfigBox(notifications)
    }

    /// Current preferences snapshot.
    public var currentNotifications: NotificationsConfig {
        notificationsBox.current
    }

    /// Replaces the live preferences without a restart.
    public func updateNotifications(_ config: NotificationsConfig) {
        notificationsBox.update(config)
    }

    public func notify(title: String, body: String) async {
        await notify(title: title, body: body, identifier: nil)
    }

    public func notify(title: String, body: String, identifier: String?) async {
        if let primary {
            await primary.notify(title: title, body: body, identifier: identifier)
        }
        let finalTag = NotifyID.normalize(identifier)
        await pushSender.broadcast(
            payload: WebPushSender.PushPayload(
                title: title,
                body: body,
                url: "/#approvals",
                tag: finalTag
            )
        )
    }

    /// Kind-aware notify skipping both desktop and push when suppressed.
    public func notify(title: String, body: String, identifier: String?, kind: NotificationKind) async {
        guard NotificationsFilter.shouldSurface(kind, config: notificationsBox.current) else { return }
        await notify(title: title, body: body, identifier: identifier)
    }
}

/// Single owner for per-type interruption config lookup.
public func notificationsConfig(for notifier: any SchedulerNotifier?) -> NotificationsConfig {
    if let composite = notifier as? CompositeSchedulerNotifier {
        return composite.currentNotifications
    }
    return NotificationsConfig()
}

/// Single owner for kind-aware interruption dispatch.
public func notifyKindAware(
    _ notifier: any SchedulerNotifier?,
    kind: NotificationKind,
    config: NotificationsConfig,
    title: String,
    body: String,
    identifier: String?
) async {
    guard NotificationsFilter.shouldSurface(kind, config: config) else { return }
    await notifier?.notify(title: title, body: body, identifier: identifier)
}

/// Encrypts and sends RFC 8291 Web Push notifications to Apple APNs and other push services.
public struct WebPushSender: Sendable {
    public let vapidKeys: WebPushKeys
    public let subscriptions: PushSubscriptionStore
    public let transport: any WebPushTransport
    public let notificationsBox: NotificationsConfigBox?

    public init(
        vapidKeys: WebPushKeys,
        subscriptions: PushSubscriptionStore,
        transport: any WebPushTransport = URLSessionWebPushTransport(),
        notificationsBox: NotificationsConfigBox? = nil
    ) {
        self.vapidKeys = vapidKeys
        self.subscriptions = subscriptions
        self.transport = transport
        self.notificationsBox = notificationsBox
    }

    /// Resolves the active VAPID subject claim (`mailto:...` or `https://...`).
    public var currentSubject: String {
        if let contact = notificationsBox?.current.pushContact, !contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return WebPushKeys.normalizeSubject(contact)
        }
        if let env = ProcessInfo.processInfo.environment["RUNEWEAVER_VAPID_SUBJECT"], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return WebPushKeys.normalizeSubject(env)
        }
        if ProcessInfo.processInfo.environment["RUNEWEAVER_HERMETIC_TESTS"] == "1" {
            return "mailto:test@example.com"
        }
        return ""
    }

    /// Aggregate result of an outbound push broadcast.
    public struct PushDeliveryResult: Sendable, Codable, Equatable {
        public let delivered: Int
        public let totalSubscribers: Int
        public let errors: [String]

        public init(delivered: Int, totalSubscribers: Int, errors: [String] = []) {
            self.delivered = delivered
            self.totalSubscribers = totalSubscribers
            self.errors = errors
        }
    }

    /// Result of an individual device dispatch.
    public struct PushSendResult: Sendable {
        public let delivered: Bool
        public let status: Int
        public let errorBody: String?

        public init(delivered: Bool, status: Int, errorBody: String? = nil) {
            self.delivered = delivered
            self.status = status
            self.errorBody = errorBody
        }
    }

    /// Payload structure converted to JSON for the client Service Worker.
    public struct PushPayload: Codable, Sendable {
        public let title: String
        public let body: String
        public let url: String?
        public let tag: String?

        public init(title: String, body: String, url: String? = nil, tag: String? = nil) {
            self.title = title
            self.body = body
            self.url = url
            self.tag = tag
        }
    }

    /// Encrypts plaintext bytes following RFC 8291 (aes128gcm).
    public static func encryptPayload(
        plaintext: Data,
        clientP256Base64: String,
        clientAuthBase64: String
    ) throws -> Data {
        guard let clientP256Data = WebPushKeys.dataFromBase64URL(clientP256Base64),
              let clientAuthData = WebPushKeys.dataFromBase64URL(clientAuthBase64)
        else {
            throw PushSubscriptionError.invalidKeys
        }

        let clientPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: clientP256Data)
        let serverEphemeralKey = P256.KeyAgreement.PrivateKey()
        let serverPublicKeyData = serverEphemeralKey.publicKey.x963Representation

        // 1. ECDH Shared Secret
        let sharedSecret = try serverEphemeralKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
        let sharedSymmetricKey = sharedSecret.withUnsafeBytes { SymmetricKey(data: $0) }

        // 2. PRK and IKM via HKDF-SHA256 (RFC 8291 Section 3.2)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: sharedSymmetricKey, salt: clientAuthData)
        var ikmInfo = Data("WebPush: info\0".utf8)
        ikmInfo.append(clientP256Data)
        ikmInfo.append(serverPublicKeyData)
        let ikm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: ikmInfo, outputByteCount: 32)

        // 3. Salt and Derivations (RFC 8188 / RFC 8291 Section 3.3)
        let salt = SymmetricKey(size: .bits128)
        let saltData = salt.withUnsafeBytes { Data($0) }

        let cekInfo = Data("Content-Encoding: aes128gcm\0".utf8)
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: saltData,
            info: cekInfo,
            outputByteCount: 16
        )

        let nonceInfo = Data("Content-Encoding: nonce\0".utf8)
        let nonceData = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: saltData,
            info: nonceInfo,
            outputByteCount: 12
        ).withUnsafeBytes { Data($0) }
        let nonce = try AES.GCM.Nonce(data: nonceData)

        // 4. Record Payload: Plaintext + Record delimiter (0x02 for single/terminal record)
        var recordPayload = plaintext
        recordPayload.append(0x02)

        let sealed = try AES.GCM.seal(recordPayload, using: cek, nonce: nonce)

        // 5. Build RFC 8188 Header (86 bytes total):
        // Salt (16 bytes) + rs (4 bytes = 4096 = 0x00001000) + idlen (1 byte = 0x41) + keyid (65 bytes)
        var header = Data()
        header.append(saltData)
        let rsBytes: [UInt8] = [0x00, 0x00, 0x10, 0x00] // 4096 bytes
        header.append(contentsOf: rsBytes)
        header.append(0x41) // 65 bytes uncompressed P-256 key
        header.append(serverPublicKeyData)

        var result = header
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    /// Dispatches an encrypted push alert to one subscriber. Returns false if the subscription expired and was pruned.
    public func send(
        to subscription: PushSubscriptionRecord,
        payload: PushPayload
    ) async throws -> PushSendResult {
        guard let url = PushSubscriptionStore.validateEndpoint(subscription.endpoint) else {
            await subscriptions.remove(endpoint: subscription.endpoint)
            return PushSendResult(delivered: false, status: 400, errorBody: "Invalid push endpoint URL")
        }

        let subject = currentSubject
        guard !subject.isEmpty else {
            throw WebPushKeysError.missingSubject
        }

        let jsonPayload = try JSONEncoder().encode(payload)
        let encryptedBody: Data
        do {
            encryptedBody = try Self.encryptPayload(
                plaintext: jsonPayload,
                clientP256Base64: subscription.p256dhKey,
                clientAuthBase64: subscription.authSecret
            )
        } catch {
            // Undecryptable keys can never deliver, so drop the row instead of failing every broadcast.
            await subscriptions.remove(endpoint: subscription.endpoint)
            return PushSendResult(delivered: false, status: 400, errorBody: "Undecryptable client keys; pruned subscription")
        }

        guard let host = url.host else {
            return PushSendResult(delivered: false, status: 400, errorBody: "Missing host in endpoint URL")
        }
        let audience = "\(url.scheme ?? "https")://\(host)"
        let jwt = try vapidKeys.signJWT(audience: audience, subject: subject)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("86400", forHTTPHeaderField: "TTL")
        request.setValue("high", forHTTPHeaderField: "Urgency")
        request.setValue("vapid t=\(jwt), k=\(vapidKeys.publicKeyBase64URL)", forHTTPHeaderField: "Authorization")
        request.httpBody = encryptedBody

        let (data, status) = try await transport.send(request: request)
        let bodyText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if status == 404 || status == 410 {
            // Subscription has expired or been revoked by the user on the device
            await subscriptions.remove(endpoint: subscription.endpoint)
            return PushSendResult(delivered: false, status: status, errorBody: "Subscription expired or revoked on device (HTTP \(status))")
        }

        if status >= 200 && status < 300 {
            return PushSendResult(delivered: true, status: status, errorBody: nil)
        }

        let errorDetail = bodyText.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(bodyText)"
        RuneWeaverLog.server.warning("[WebPushSender] Outbound push rejected by \(host): \(errorDetail)")
        return PushSendResult(delivered: false, status: status, errorBody: errorDetail)
    }

    /// Broadcasts an alert to all registered mobile devices, returning the count of successful deliveries.
    @discardableResult
    public func broadcast(payload: PushPayload) async -> PushDeliveryResult {
        let subs = await subscriptions.allSubscriptions()
        if subs.isEmpty {
            return PushDeliveryResult(delivered: 0, totalSubscribers: 0, errors: [])
        }
        var delivered = 0
        var errors: [String] = []
        for sub in subs {
            do {
                let result = try await send(to: sub, payload: payload)
                if result.delivered {
                    delivered += 1
                } else if let errorMsg = result.errorBody {
                    errors.append(errorMsg)
                }
            } catch {
                let errorDesc = error.localizedDescription
                RuneWeaverLog.server.warning("[WebPushSender] Failed to dispatch push to \(sub.endpoint): \(errorDesc)")
                errors.append(errorDesc)
            }
        }
        return PushDeliveryResult(delivered: delivered, totalSubscribers: subs.count, errors: errors)
    }
}
