// Rune Weaver Tools — SMTP derivation and verified-TLS subprocess bridge.

import Foundation
import RuneWeaverCore

/// SMTP host and port derivation for `email.send`.
public enum EmailSMTPBridge: Sendable {
    /// SMTP submission ports honored when carried on the account record.
    public static let submissionPorts: Set<Int> = EmailConfig.allowedSubmissionPorts
    /// Default submission port (STARTTLS) when the account port names IMAP.
    public static let defaultPort = 587
    /// Implicit-TLS submission port tried second under `auto`.
    public static let implicitTLSPort = 465

    /// One verified-TLS submission endpoint to try in order.
    public struct Endpoint: Sendable, Equatable {
        /// SMTP hostname for this attempt.
        public let host: String
        /// SMTP submission port for this attempt.
        public let port: Int
        /// Whether this attempt dials implicit TLS (`ssl`) or STARTTLS.
        public let useImplicitTLS: Bool

        /// Creates an endpoint.
        public init(host: String, port: Int, useImplicitTLS: Bool) {
            self.host = host
            self.port = port
            self.useImplicitTLS = useImplicitTLS
        }
    }

    /// Derives the SMTP host for resolved credentials.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Explicit `smtp_host` when set, else `smtp.` host when the account names `imap.`, else the account host.
    public static func smtpHost(for credentials: ResolvedEmailCredentials) -> String {
        if let override = credentials.smtpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = host.lowercased()
        if lowered.hasPrefix("imap.") {
            return "smtp." + host.dropFirst("imap.".count)
        }
        return host
    }

    /// Derives the SMTP port for resolved credentials.
    /// - Parameter credentials: Resolved connection fields plus password.
    /// - Returns: Explicit `smtp_port` when set, else the account port when it already names submission, else 587.
    public static func smtpPort(for credentials: ResolvedEmailCredentials) -> Int {
        if let override = credentials.smtpPort {
            return override
        }
        if submissionPorts.contains(credentials.port) {
            return credentials.port
        }
        return defaultPort
    }

    /// Whether a submission port expects implicit TLS.
    /// - Parameter port: SMTP port.
    /// - Returns: True only for 465.
    public static func usesImplicitTLS(port: Int) -> Bool {
        port == 465
    }

    /// Ordered verified-TLS endpoints for resolved credentials.
    public static func endpoints(for credentials: ResolvedEmailCredentials) -> [Endpoint] {
        let host = smtpHost(for: credentials).trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitPort = credentials.smtpPort {
            switch credentials.smtpSecurity {
            case .ssl:
                return [Endpoint(host: host, port: explicitPort, useImplicitTLS: true)]
            case .starttls:
                return [Endpoint(host: host, port: explicitPort, useImplicitTLS: false)]
            case .auto:
                return [Endpoint(host: host, port: explicitPort, useImplicitTLS: explicitPort == 465)]
            }
        }
        switch credentials.smtpSecurity {
        case .ssl:
            return [Endpoint(host: host, port: implicitTLSPort, useImplicitTLS: true)]
        case .starttls:
            return [Endpoint(host: host, port: defaultPort, useImplicitTLS: false)]
        case .auto:
            // When the IMAP port already names submission, honor it first so
            // explicit provider ports keep working, then fall back to the
            // standard pair. Deduplicate while preserving order.
            var ordered: [Endpoint] = []
            if submissionPorts.contains(credentials.port), credentials.port != defaultPort, credentials.port != implicitTLSPort {
                ordered.append(Endpoint(host: host, port: credentials.port, useImplicitTLS: credentials.port == 465))
            }
            ordered.append(Endpoint(host: host, port: defaultPort, useImplicitTLS: false))
            ordered.append(Endpoint(host: host, port: implicitTLSPort, useImplicitTLS: true))
            var seen: Set<Int> = []
            return ordered.filter { seen.insert($0.port).inserted }
        }
    }
}

/// One sandbox-confined attachment staged for MIME encoding.
public struct EmailSMTPAttachment: Sendable, Equatable {
    /// Base filename for the MIME part.
    public let filename: String
    /// MIME type (e.g. `application/pdf`).
    public let contentType: String
    /// Decoded file bytes.
    public let data: Data

    /// Creates an attachment part.
    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// Outbound SMTP message content for `email.send`.
public struct EmailSMTPMessage: Sendable, Equatable {
    /// Sender address (always the account username).
    public let from: String
    /// Recipient addresses (total across to/cc/bcc capped at 20).
    public let to: [String]
    /// `cc` is RFC 5322 standard field name, so the short name is intentional.
    /// CC recipients.
    public let cc: [String]
    /// BCC recipients, envelope-only.
    public let bcc: [String]
    /// Subject header (1-998 chars, no CR/LF).
    public let subject: String
    /// Plain-text body (HTML-derived fallback when only HTML was given).
    public let bodyText: String
    /// Optional HTML alternative body.
    public let bodyHtml: String?
    /// Optional `In-Reply-To` header value for threaded replies.
    public let inReplyTo: String?
    /// Optional `References` header value for threaded replies.
    public let references: String?
    /// Sandbox-confined attachments for MIME encoding.
    public let attachments: [EmailSMTPAttachment]

    /// Creates a send message.
    public init(
        from: String,
        to: [String],
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        bodyText: String,
        bodyHtml: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        attachments: [EmailSMTPAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }
}

/// One attachment part encoded for the Python SMTP helper.
struct EmailSMTPBridgeAttachment: Encodable {
    /// Base filename for the MIME part.
    let filename: String
    /// MIME type (e.g. `application/pdf`).
    let contentType: String
    /// Base64-encoded file bytes.
    let contentBase64: String

    /// Encodes a staged attachment for the bridge.
    /// - Parameter attachment: Decoded attachment bytes.
    /// - Returns: Bridge attachment with base64 bytes.
    static func bridge(_ attachment: EmailSMTPAttachment) -> Self {
        Self(
            filename: attachment.filename,
            contentType: attachment.contentType,
            contentBase64: attachment.data.base64EncodedString()
        )
    }
}

/// Bridge request document sent to the Python SMTP helper over stdin.
struct EmailSMTPBridgeRequest: Encodable {
    /// Operation: always `"send"`.
    let op: String
    /// SMTP hostname for this attempt.
    let host: String
    /// SMTP submission port (25, 465, 587, or 2525).
    let port: Int
    /// Login username (also the sender).
    let username: String
    /// Runtime-resolved password. Never logged.
    let password: String
    /// Sender address (account username).
    let fromAddress: String
    /// Envelope recipients.
    let to: [String]
    /// `cc` is RFC 5322 standard field name, so the short name is intentional.
    /// CC envelope recipients.
    let cc: [String]
    /// BCC envelope recipients (envelope-only, never in headers).
    let bcc: [String]
    /// Subject header.
    let subject: String
    /// Plain-text body.
    let bodyText: String
    /// Optional HTML alternative body.
    let bodyHtml: String?
    /// Optional `In-Reply-To` header value.
    let inReplyTo: String?
    /// Optional `References` header value.
    let references: String?
    /// MIME attachments encoded as base64.
    let attachments: [EmailSMTPBridgeAttachment]?

    private enum CodingKeys: String, CodingKey {
        case op
        case host
        case port
        case username
        case password
        case fromAddress = "from"
        case to
        // `cc` is RFC 5322 standard field name, so the short name is intentional.
        case cc
        case bcc
        case subject
        case bodyText
        case bodyHtml
        case inReplyTo
        case references
        case attachments
    }

    /// Creates a send request from resolved connection fields and grouped message content.
    static func send(
        credentials: ResolvedEmailCredentials,
        smtpHost: String,
        smtpPort: Int,
        message: EmailSMTPMessage
    ) -> Self {
        let bridgeAttachments = message.attachments.isEmpty ? nil : message.attachments.map(EmailSMTPBridgeAttachment.bridge)
        return Self(
            op: "send",
            host: smtpHost,
            port: smtpPort,
            username: credentials.username,
            password: credentials.password,
            fromAddress: message.from,
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            subject: message.subject,
            bodyText: message.bodyText,
            bodyHtml: message.bodyHtml,
            inReplyTo: message.inReplyTo,
            references: message.references,
            attachments: bridgeAttachments
        )
    }
}

/// Embedded `python3 smtplib` helper for `email.send`.
enum EmailSMTPBridgeScript {
    /// Python source executed via `python3 -c`.
    static let source = #"""
    import sys, json, smtplib, ssl, re, base64
    from email.message import EmailMessage

    def fail(message):
        sys.stdout.write(json.dumps({"ok": False, "error": message}))
        sys.stdout.flush()

    def is_valid_email(addr):
        if not isinstance(addr, str):
            return False
        if "\r" in addr or "\n" in addr:
            return False
        if not addr or len(addr) > 254:
            return False
        return re.fullmatch(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", addr.strip()) is not None

    def as_list(value):
        if value is None:
            return []
        if isinstance(value, list):
            return value
        return []

    def main():
        try:
            req = json.loads(sys.stdin.read() or "{}")
        except Exception:
            fail("Invalid SMTP bridge request JSON")
            return
        op = req.get("op") or ""
        if op != "send":
            fail("Unknown SMTP op '%s'" % op)
            return
        host = req.get("host") or ""
        try:
            port = int(req.get("port") or 587)
        except Exception:
            port = 587
        username = req.get("username") or ""
        password = req.get("password") or ""
        fromAddr = req.get("from") or username
        if isinstance(fromAddr, str):
            fromAddr = fromAddr.strip()
        toAddrs = as_list(req.get("to"))
        ccAddrs = as_list(req.get("cc"))
        bccAddrs = as_list(req.get("bcc"))
        subject = req.get("subject") or ""
        bodyText = req.get("bodyText")
        if bodyText is None:
            bodyText = req.get("body") or ""
        bodyHtml = req.get("bodyHtml")
        inReplyTo = req.get("inReplyTo")
        references = req.get("references")
        rawAttachments = req.get("attachments")
        if rawAttachments is None:
            rawAttachments = []
        if not host or not username or not password:
            fail("Missing SMTP connection fields")
            return
        if port not in (25, 465, 587, 2525):
            fail("Unsupported SMTP port %s (expected 25, 465, 587, or 2525)" % port)
            return
        if not isinstance(fromAddr, str) or not fromAddr:
            fail("Missing sender address")
            return
        if "\r" in fromAddr or "\n" in fromAddr:
            fail("Invalid sender address")
            return
        if not isinstance(toAddrs, list) or len(toAddrs) < 1 or len(toAddrs) > 20:
            fail("Invalid recipients: 'to' needs 1-20 addresses")
            return
        for fieldName, addrs in (("to", toAddrs), ("cc", ccAddrs), ("bcc", bccAddrs)):
            if not isinstance(addrs, list):
                fail("Invalid recipients in '%s'" % fieldName)
                return
            if len(addrs) > 20:
                fail("Invalid recipients in '%s': at most 20 addresses" % fieldName)
                return
            for addr in addrs:
                if not isinstance(addr, str) or not is_valid_email(addr):
                    fail("Invalid recipient in '%s'" % fieldName)
                    return
                if "\r" in addr or "\n" in addr:
                    fail("Invalid recipient in '%s'" % fieldName)
                    return
        totalRecipients = len(toAddrs) + len(ccAddrs) + len(bccAddrs)
        if totalRecipients > 20:
            fail("Invalid recipients: at most 20 recipients total across to/cc/bcc")
            return
        if not isinstance(subject, str) or not subject.strip():
            fail("Invalid subject: subject must not be empty")
            return
        if len(subject.strip()) > 998:
            fail("Invalid subject: subject must be at most 998 characters")
            return
        if "\r" in subject or "\n" in subject:
            fail("Invalid subject: subject must not contain CR or LF")
            return
        if not isinstance(bodyText, str) or not bodyText.strip():
            fail("Invalid body: 'bodyText' must not be empty")
            return
        if len(bodyText.encode("utf-8")) > 1048576:
            fail("Invalid body: 'bodyText' exceeds the 1 MB size cap")
            return
        if bodyHtml is not None and bodyHtml != "":
            if not isinstance(bodyHtml, str):
                fail("Invalid body: 'bodyHtml' must be text")
                return
            if len(bodyHtml.encode("utf-8")) > 1048576:
                fail("Invalid body: 'bodyHtml' exceeds the 1 MB size cap")
                return
        else:
            bodyHtml = None
        combinedBodyBytes = len(bodyText.encode("utf-8")) + (len(bodyHtml.encode("utf-8")) if bodyHtml else 0)
        if combinedBodyBytes > 1048576:
            fail("Invalid body: combined body exceeds the 1 MB size cap")
            return
        for headerName, headerValue in (("In-Reply-To", inReplyTo), ("References", references)):
            if headerValue is None or headerValue == "":
                continue
            if not isinstance(headerValue, str):
                fail("Invalid threading header '%s'" % headerName)
                return
            if "\r" in headerValue or "\n" in headerValue:
                fail("Invalid threading header '%s'" % headerName)
                return
        if inReplyTo == "":
            inReplyTo = None
        if references == "":
            references = None
        decodedAttachments = []
        if rawAttachments:
            if not isinstance(rawAttachments, list):
                fail("Invalid attachments: expected a list")
                return
            if len(rawAttachments) > 20:
                fail("Invalid attachments: at most 20 files")
                return
            totalAttachmentBytes = 0
            for entry in rawAttachments:
                if not isinstance(entry, dict):
                    fail("Invalid attachment entry")
                    return
                filename = entry.get("filename") or "attachment"
                contentType = entry.get("contentType") or "application/octet-stream"
                encoded = entry.get("contentBase64") or ""
                if not isinstance(filename, str) or not filename.strip():
                    fail("Invalid attachment filename")
                    return
                if "\r" in filename or "\n" in filename or "/" in filename or "\\" in filename:
                    fail("Invalid attachment filename")
                    return
                if not isinstance(contentType, str) or "/" not in contentType:
                    fail("Invalid attachment content type")
                    return
                if "\r" in contentType or "\n" in contentType:
                    fail("Invalid attachment content type")
                    return
                if not isinstance(encoded, str) or not encoded:
                    fail("Invalid attachment bytes")
                    return
                try:
                    raw = base64.b64decode(encoded, validate=True)
                except Exception:
                    fail("Invalid attachment bytes")
                    return
                if len(raw) > 10485760:
                    fail("Invalid attachment '%s': exceeds the 10 MB per-file cap" % filename.strip())
                    return
                totalAttachmentBytes += len(raw)
                if totalAttachmentBytes > 26214400:
                    fail("Invalid attachments: exceeds the 25 MB total cap")
                    return
                decodedAttachments.append((filename.strip(), contentType.strip(), raw))
        msg = EmailMessage()
        msg["From"] = fromAddr
        msg["To"] = ", ".join([a.strip() for a in toAddrs])
        if ccAddrs:
            msg["Cc"] = ", ".join([a.strip() for a in ccAddrs])
        msg["Subject"] = subject.strip()
        if inReplyTo:
            msg["In-Reply-To"] = inReplyTo.strip()
        if references:
            msg["References"] = references.strip()
        msg.set_content(bodyText)
        if bodyHtml:
            msg.add_alternative(bodyHtml, subtype="html")
        for (filename, contentType, raw) in decodedAttachments:
            maintype, _, subtype = contentType.partition("/")
            if not maintype.strip() or not subtype.strip():
                maintype, subtype = "application", "octet-stream"
            else:
                maintype = maintype.strip()
                subtype = subtype.strip().split(";")[0].strip() or "octet-stream"
            msg.add_attachment(raw, maintype=maintype, subtype=subtype, filename=filename)
        envelope = [a.strip() for a in (toAddrs + ccAddrs + bccAddrs)]
        try:
            ctx = ssl.create_default_context()
            if port == 465:
                server = smtplib.SMTP_SSL(host, port, context=ctx, timeout=30)
            else:
                server = smtplib.SMTP(host, port, timeout=30)
                try:
                    server.starttls(context=ctx)
                except Exception as exc:
                    try:
                        server.quit()
                    except Exception:
                        pass
                    fail("Could not start TLS to %s@%s:%s: %s" % (username, host, port, exc))
                    return
        except Exception as exc:
            fail("Could not connect to %s@%s:%s: %s" % (username, host, port, exc))
            return
        try:
            try:
                server.login(username, password)
            except Exception as exc:
                fail("SMTP login failed for %s@%s:%s: %s" % (username, host, port, exc))
                return
            try:
                server.send_message(msg, from_addr=fromAddr, to_addrs=envelope)
            except Exception as exc:
                fail("SMTP send failed: %s" % exc)
                return
            sys.stdout.write(json.dumps({"ok": True, "from": fromAddr, "sentTo": envelope, "subject": subject.strip()}))
            sys.stdout.flush()
        finally:
            try:
                server.quit()
            except Exception:
                try:
                    server.close()
                except Exception:
                    pass

    main()
    """#
}

/// Outbound SMTP gateway used by `email.send`.
public protocol EmailSMTPGateway: Sendable {
    /// Sends one message through the derived SMTP host and port.
    func send(
        credentials: ResolvedEmailCredentials,
        message: EmailSMTPMessage
    ) async throws
}

/// Bridge `send` response shape.
private struct SMTPSendResponse: Decodable {
    /// Whether the operation succeeded.
    let ok: Bool
    /// Error detail when `ok` is false.
    let error: String?
}

/// Subprocess gateway shelling out to `python3 smtplib`.
public struct SubprocessSMTPGateway: EmailSMTPGateway, Sendable {
    /// Environment variable overriding the Python executable.
    public static let pythonEnvVar = "RUNEWEAVER_PYTHON_BIN"

    /// Explicit Python executable path, if any.
    public let pythonExecutable: String?

    /// Creates a subprocess gateway.
    public init(pythonExecutable: String? = nil) {
        if let pythonExecutable, !pythonExecutable.isEmpty {
            self.pythonExecutable = pythonExecutable
        } else if let configured = ProcessInfo.processInfo.environment[Self.pythonEnvVar] {
            if configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.pythonExecutable = nil
            } else {
                self.pythonExecutable = configured
            }
        } else {
            self.pythonExecutable = nil
        }
    }

    /// Sends via the Python helper across the ordered verified-TLS endpoints.
    public func send(
        credentials: ResolvedEmailCredentials,
        message: EmailSMTPMessage
    ) async throws {
        let trimmedFrom = message.from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid sender address")
        }
        if trimmedFrom.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
            throw EmailIMAPError.bridgeFailed("Invalid sender address")
        }
        _ = try EmailSendValidation.validateRecipients(message.to, field: "to", required: true)
        _ = try EmailSendValidation.validateRecipients(message.cc, field: "cc", required: false)
        _ = try EmailSendValidation.validateRecipients(message.bcc, field: "bcc", required: false)
        try EmailSendValidation.validateTotalRecipients(to: message.to, cc: message.cc, bcc: message.bcc)
        _ = try EmailSendValidation.validateSubject(message.subject)
        try EmailSendValidation.validateBody(message.bodyText, field: "bodyText")
        let normalizedHtml = try EmailSendValidation.validateOptionalBody(message.bodyHtml, field: "bodyHtml")
        try EmailSendValidation.validateCombinedBody(text: message.bodyText, html: normalizedHtml)
        try EmailSendValidation.validateThreadingHeader(message.inReplyTo, field: "In-Reply-To")
        try EmailSendValidation.validateThreadingHeader(message.references, field: "References")
        let normalizedMessage = EmailSMTPMessage(
            from: trimmedFrom,
            to: message.to.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            cc: message.cc.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            bcc: message.bcc.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            subject: message.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyText: message.bodyText,
            bodyHtml: normalizedHtml,
            inReplyTo: message.inReplyTo?.trimmingCharacters(in: .whitespacesAndNewlines),
            references: message.references?.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.attachments
        )
        let endpoints = EmailSMTPBridge.endpoints(for: credentials)
        guard !endpoints.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid SMTP host")
        }
        var lastError: Error?
        for endpoint in endpoints {
            let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                lastError = EmailIMAPError.bridgeFailed("Invalid SMTP host")
                continue
            }
            if host.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) {
                throw EmailIMAPError.bridgeFailed("Invalid SMTP host")
            }
            let request = EmailSMTPBridgeRequest.send(
                credentials: credentials,
                smtpHost: host,
                smtpPort: endpoint.port,
                message: normalizedMessage
            )
            do {
                let data = try await run(request: request)
                let response = try JSONDecoder().decode(SMTPSendResponse.self, from: data)
                if response.ok {
                    return
                }
                lastError = EmailIMAPError.bridgeFailed(response.error ?? "SMTP send failed")
            } catch let error as EmailIMAPError {
                // Connection/TLS failures on the first `auto` endpoint fall
                // through to the next port; validation failures throw
                // immediately only when a single endpoint was configured.
                if endpoints.count == 1 {
                    throw error
                }
                lastError = error
            } catch {
                if endpoints.count == 1 {
                    throw EmailIMAPError.decodeFailed(error.localizedDescription)
                }
                lastError = EmailIMAPError.decodeFailed(error.localizedDescription)
            }
            // A login or send rejection is endpoint-independent (same
            // credentials and message), so retrying the next port only helps
            // connect/TLS failures. Surface auth/send errors immediately.
            if let bridge = lastError as? EmailIMAPError, case let .bridgeFailed(detail) = bridge,
               detail.contains("login failed") || detail.contains("SMTP send failed") || detail.contains("Invalid") || detail.contains("Missing")
               || detail.contains("Unsupported")
            {
                throw bridge
            }
        }
        if let lastError {
            throw lastError
        }
        throw EmailIMAPError.bridgeFailed("SMTP send failed")
    }

    /// Runs the SMTP helper once with the given request.
    func run(request: EmailSMTPBridgeRequest) async throws -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw EmailIMAPError.bridgeFailed("Could not encode SMTP request: \(error.localizedDescription)")
        }
        return try await EmailSubprocessIO.runBridgeIO(
            scriptSource: EmailSMTPBridgeScript.source,
            payload: payload,
            pythonExecutable: pythonExecutable,
            serviceName: "SMTP"
        )
    }
}
