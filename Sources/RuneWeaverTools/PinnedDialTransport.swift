// Rune Weaver Tools — Pinned-address dial transport for API requests.

import Foundation
import Network
import os
import RuneWeaverCore
import Security

/// Typed failures from the pinned dial path. Every case fails closed: when the exchange cannot
/// complete over a vetted address, no request bytes reach an unvetted peer.
public enum PinnedDialError: Error, Sendable, Equatable {
    /// The live transport was asked to dial without a vetting pin.
    case unpinnedDialRefused
    /// The pin carried no numeric address to dial.
    case emptyPin
    /// No pinned address completed the exchange within the request budget.
    case allAddressesFailed(String)
    /// The exchange did not finish within the request budget.
    case timedOut
    /// One request field could not be serialized without risking header
    /// injection or an ambiguous wire shape.
    case malformedRequest(String)
    /// The peer response could not be framed safely.
    case malformedResponse(String)
    /// The peer closed before the framed response completed.
    case truncatedResponse
}

extension PinnedDialError: LocalizedError {
    /// Human-readable reason surfaced through the tool failure envelope.
    public var errorDescription: String? {
        switch self {
        case .unpinnedDialRefused:
            "Refusing to dial without an SSRF-vetted address pin."
        case .emptyPin:
            "Refusing to dial: the SSRF vetting pin carried no address."
        case let .allAddressesFailed(detail):
            "Pinned dial failed for every vetted address: \(detail)"
        case .timedOut:
            "Pinned dial timed out before the exchange completed."
        case let .malformedRequest(detail):
            "Refusing to send the request: \(detail)"
        case let .malformedResponse(detail):
            "Pinned dial received an unusable response: \(detail)"
        case .truncatedResponse:
            "Pinned dial connection closed before the response completed."
        }
    }
}

/// Builds the HTTP/1.1 wire bytes for one pinned hop.
enum PinnedHTTPRequestSerializer: Sendable {
    /// Header names the dialer owns; caller-supplied copies are dropped so the
    /// pinned authority and body framing cannot be overridden.
    private static let reservedHeaderNames: Set<String> = [
        "host",
        "connection",
        "content-length",
        "transfer-encoding",
        "proxy-connection",
        "upgrade",
        "keep-alive",
        "accept-encoding"
    ]

    /// Serializes one request for the pinned connection. request: Request shaped by
    /// the tool.
    static func serialize(_ request: URLRequest, pin: SSRFDialPin) throws -> Data {
        let method = request.httpMethod?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "GET"
        guard !method.isEmpty, method.allSatisfy(\.isLetter) else {
            throw PinnedDialError.malformedRequest("request method '\(method)' is not a plain token")
        }
        guard let url = request.url else {
            throw PinnedDialError.malformedRequest("request has no URL")
        }
        let target = try requestTarget(for: url)
        let hostHeader = hostIdentity(for: pin)
        guard !hostHeader.contains(where: { $0 == "\r" || $0 == "\n" || $0 == " " }) else {
            throw PinnedDialError.malformedRequest("pinned host identity is not header-safe")
        }
        // Request identity encoding: the pinned dialer frames entity bytes
        // itself and has no decompressor, so a compressed response would be
        // unreadable; asking for identity keeps the framed body faithful.
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)", "Connection: close", "Accept-Encoding: identity"]
        if let body = request.httpBody, !body.isEmpty {
            lines.append("Content-Length: \(body.count)")
        }
        var seen = Set<String>()
        let callerHeaders = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }
        for (name, value) in callerHeaders {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmedName.lowercased()
            guard !trimmedName.isEmpty, !reservedHeaderNames.contains(lowered), !seen.contains(lowered) else { continue }
            guard isHeaderToken(trimmedName), !value.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                throw PinnedDialError.malformedRequest("header '\(trimmedName)' is not wire-safe")
            }
            seen.insert(lowered)
            lines.append("\(trimmedName): \(value)")
        }
        var bytes = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body = request.httpBody, !body.isEmpty {
            bytes.append(body)
        }
        return bytes
    }

    /// Origin-form target preserving the encoded path and query.
    private static func requestTarget(for url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PinnedDialError.malformedRequest("request URL could not be decomposed")
        }
        var target = components.percentEncodedPath
        if target.isEmpty {
            target = "/"
        }
        if let query = components.percentEncodedQuery {
            target += "?" + query
        }
        guard !target.contains(where: { $0 == "\r" || $0 == "\n" || $0 == " " || $0 == "\t" }) else {
            throw PinnedDialError.malformedRequest("request target is not wire-safe")
        }
        return target
    }

    /// Host header value preserving the original authority identity.
    private static func hostIdentity(for pin: SSRFDialPin) -> String {
        let renderedHost = pin.host.contains(":") && !pin.host.hasPrefix("[") ? "[\(pin.host)]" : pin.host
        let defaultPort = pin.isSecure ? 443 : 80
        guard pin.port != defaultPort else { return renderedHost }
        return "\(renderedHost):\(pin.port)"
    }

    /// RFC 7230 token check for header names.
    private static func isHeaderToken(_ name: String) -> Bool {
        let extra = "!#$%&'*+-.^_`|~"
        return name.allSatisfy { character in
            character.isLetter || character.isNumber || extra.contains(character)
        }
    }
}

/// Incremental HTTP/1.1 response framer for one pinned exchange.
struct PinnedHTTPResponseParser: Sendable {
    /// Outcome of feeding one received chunk.
    enum Outcome {
        /// More bytes are required to frame the response.
        case needMore
        /// The framed response plus its capped body bytes.
        case complete(HTTPURLResponse, Data)
        /// Framing failed closed.
        case failed(PinnedDialError)
    }

    /// Maximum header bytes accepted before the response fails closed.
    private static let maxHeaderBytes = 64 * 1024
    private static let crlf = Data([13, 10])
    private static let headerTerminator = Data([13, 10, 13, 10])

    /// Body framing state of the response being parsed.
    private enum BodyMode: Sendable {
        case headers
        case fixed(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTerminator
        case trailers
        case untilClose
        case done
    }

    /// Result of one framing step inside `feed`.
    private enum FramingStep {
        /// The parser advanced and should frame the next state.
        case advance
        /// The exchange settled with this outcome.
        case settle(Outcome)
    }

    /// Parsed status line plus ordered fields from one response header block.
    private struct ParsedHeaderBlock {
        /// Final (non-interim) response status code.
        let statusCode: Int
        /// HTTP version token, nil when the status line did not carry one.
        let httpVersion: String?
        /// Ordered header fields as received.
        let headers: [(name: String, value: String)]
    }

    /// URL reported on the framed response (the original request URL).
    private let responseURL: URL
    /// Response body cap; a body past this bound completes as truncated.
    private let maxBodyBytes: Int
    /// Unconsumed received bytes.
    private var buffer = Data()
    /// Accumulated decoded body bytes.
    private var body = Data()
    /// Current framing state.
    private var mode = BodyMode.headers
    /// Status code of the final (non-interim) response.
    private var statusCode = 0
    /// HTTP version token of the final response, nil when unrecognized.
    private var httpVersion: String?
    /// Ordered header fields of the final response.
    private var headerFields: [(name: String, value: String)] = []

    /// Creates a framer for one exchange. responseURL: Original request URL
    /// reported on the response.
    init(responseURL: URL, maxBodyBytes: Int) {
        self.responseURL = responseURL
        self.maxBodyBytes = maxBodyBytes
    }

    /// Feeds received bytes and advances framing. chunk: Bytes received from the
    /// pinned connection.
    mutating func feed(_ chunk: Data, closed: Bool) -> Outcome {
        if !chunk.isEmpty {
            buffer.append(chunk)
        }
        while true {
            let step: FramingStep = switch mode {
            case .headers:
                frameHeaderBlock(closed: closed)
            case .trailers:
                frameTrailerLine(closed: closed)
            case let .fixed(remaining):
                consumeFixedBody(remaining: remaining, closed: closed)
            case .chunkSize:
                frameChunkSizeLine(closed: closed)
            case let .chunkData(remaining):
                consumeChunkBody(remaining: remaining, closed: closed)
            case .chunkTerminator:
                frameChunkTerminator(closed: closed)
            case .untilClose:
                frameUntilClose(closed: closed)
            case .done:
                .settle(settled())
            }
            switch step {
            case .advance:
                continue
            case let .settle(outcome):
                return outcome
            }
        }
    }

    /// Frames one header block, discarding interim 1xx responses.
    private mutating func frameHeaderBlock(closed: Bool) -> FramingStep {
        guard let terminator = buffer.range(of: Self.headerTerminator) else {
            if buffer.count > Self.maxHeaderBytes {
                return .settle(.failed(.malformedResponse("response headers exceeded the framing budget")))
            }
            return .settle(closed ? .failed(.truncatedResponse) : .needMore)
        }
        let block = Data(buffer[buffer.startIndex ..< terminator.lowerBound])
        buffer.removeSubrange(buffer.startIndex ..< terminator.upperBound)
        guard let framed = Self.parseHeaderBlock(block) else {
            return .settle(.failed(.malformedResponse("response header block was not parseable")))
        }
        if (100 ..< 200).contains(framed.statusCode) {
            // Interim response (for example an early hint): discard it and
            // frame the final response that follows.
            return .advance
        }
        guard let nextMode = Self.bodyMode(status: framed.statusCode, headers: framed.headers) else {
            return .settle(.failed(.malformedResponse("response body framing was ambiguous")))
        }
        statusCode = framed.statusCode
        httpVersion = framed.httpVersion
        headerFields = framed.headers
        mode = nextMode
        return .advance
    }

    /// Consumes one trailer line; an empty line ends the chunked framing.
    private mutating func frameTrailerLine(closed: Bool) -> FramingStep {
        guard let lineEnd = buffer.range(of: Self.crlf) else {
            if buffer.count > Self.maxHeaderBytes {
                return .settle(.failed(.malformedResponse("response trailers exceeded the framing budget")))
            }
            return .settle(closed ? .failed(.truncatedResponse) : .needMore)
        }
        let line = Data(buffer[buffer.startIndex ..< lineEnd.lowerBound])
        buffer.removeSubrange(buffer.startIndex ..< lineEnd.upperBound)
        if line.isEmpty {
            mode = .done
        }
        return .advance
    }

    /// Consumes bytes for a fixed-length body, settling once capped. remaining:
    /// Body bytes still expected.
    private mutating func consumeFixedBody(remaining: Int, closed: Bool) -> FramingStep {
        guard !buffer.isEmpty else {
            return .settle(closed ? .failed(.truncatedResponse) : .needMore)
        }
        let take = min(buffer.count, remaining)
        body.append(buffer.prefix(take))
        buffer.removeFirst(take)
        let left = remaining - take
        mode = left == 0 ? .done : .fixed(remaining: left)
        if let capped = cappedOutcome() {
            return .settle(capped)
        }
        return .advance
    }

    /// Frames one chunk-size line; a zero size moves to the trailer section.
    /// - Parameter closed: Whether the peer closed after the fed bytes.
    /// - Returns: `.advance` when framing should continue, else the outcome.
    private mutating func frameChunkSizeLine(closed: Bool) -> FramingStep {
        guard let lineEnd = buffer.range(of: Self.crlf) else {
            if buffer.count > Self.maxHeaderBytes {
                return .settle(.failed(.malformedResponse("chunk-size line exceeded the framing budget")))
            }
            return .settle(closed ? .failed(.truncatedResponse) : .needMore)
        }
        let line = Data(buffer[buffer.startIndex ..< lineEnd.lowerBound])
        buffer.removeSubrange(buffer.startIndex ..< lineEnd.upperBound)
        // A size line that is not valid UTF-8 can never carry a hexadecimal
        // size, so it fails closed instead of being decoded lossily.
        guard let lineText = String(bytes: line, encoding: .utf8) else {
            return .settle(.failed(.malformedResponse("chunk-size line was not UTF-8")))
        }
        // Chunk extensions follow `;` and are not part of the size.
        let token = lineText.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        guard let size = Int(token.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
            return .settle(.failed(.malformedResponse("chunk size was not hexadecimal")))
        }
        mode = size == 0 ? .trailers : .chunkData(remaining: size)
        return .advance
    }

    /// Consumes bytes for the current chunk, moving to its CRLF terminator.
    /// remaining: Chunk bytes still expected.
    private mutating func consumeChunkBody(remaining: Int, closed: Bool) -> FramingStep {
        guard !buffer.isEmpty else {
            return .settle(closed ? .failed(.truncatedResponse) : .needMore)
        }
        let take = min(buffer.count, remaining)
        body.append(buffer.prefix(take))
        buffer.removeFirst(take)
        let left = remaining - take
        mode = left == 0 ? .chunkTerminator : .chunkData(remaining: left)
        if let capped = cappedOutcome() {
            return .settle(capped)
        }
        return .advance
    }

    /// Verifies the CRLF that must close chunk data.
    /// - Parameter closed: Whether the peer closed after the fed bytes.
    /// - Returns: `.advance` when framing should continue, else the outcome.
    private mutating func frameChunkTerminator(closed: Bool) -> FramingStep {
        guard buffer.count >= 2 else {
            return .settle(closed ? .failed(.truncatedResponse) : .needMore)
        }
        let terminator = Data(buffer.prefix(2))
        buffer.removeFirst(2)
        guard terminator == Self.crlf else {
            return .settle(.failed(.malformedResponse("chunk data was not CRLF-terminated")))
        }
        mode = .chunkSize
        return .advance
    }

    /// Consumes close-delimited body bytes; only a peer close settles it.
    /// - Parameter closed: Whether the peer closed after the fed bytes.
    /// - Returns: `.advance` when framing should continue, else the outcome.
    private mutating func frameUntilClose(closed: Bool) -> FramingStep {
        if !buffer.isEmpty {
            body.append(buffer)
            buffer.removeAll(keepingCapacity: true)
            if let capped = cappedOutcome() {
                return .settle(capped)
            }
        }
        if closed {
            mode = .done
            return .advance
        }
        return .settle(.needMore)
    }

    /// Settles the exchange once the retained body exceeded the output cap.
    /// The retained slice is `maxBodyBytes + 1` bytes so the caller's byte-cap
    /// classification keeps reporting the truncation.
    private mutating func cappedOutcome() -> Outcome? {
        guard body.count > maxBodyBytes else { return nil }
        return settled()
    }

    /// Builds the terminal outcome from the framed status, headers, and body.
    private func settled() -> Outcome {
        guard statusCode != 0,
              let response = HTTPURLResponse(
                  url: responseURL,
                  statusCode: statusCode,
                  httpVersion: httpVersion,
                  headerFields: Dictionary(headerFields.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
              )
        else {
            return .failed(.malformedResponse("response envelope could not be constructed"))
        }
        let cappedBody = body.count > maxBodyBytes ? Data(body.prefix(maxBodyBytes + 1)) : body
        return .complete(response, cappedBody)
    }

    /// Chooses the framing for the final response, or nil when it is ambiguous.
    private static func bodyMode(status: Int, headers rawHeaders: [(name: String, value: String)]) -> BodyMode? {
        // These statuses carry no body regardless of framing headers.
        if status == 204 || status == 304 {
            return .done
        }
        let headers = Dictionary(rawHeaders.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        if let encoding = headers["transfer-encoding"]?.lowercased() {
            // Only a lone `chunked` coding is framed here: RFC 7230 requires
            // chunked to be last, and any other coding (for example gzip)
            // leaves entity bytes the dialer cannot decode, so it fails closed.
            let codings = encoding.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return codings == ["chunked"] ? .chunkSize : nil
        }
        if let lengthValue = headers["content-length"] {
            // Only a clean non-negative decimal frames a fixed body; anything
            // else leaves the destination of the following bytes ambiguous.
            guard let length = Int(lengthValue.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                return nil
            }
            // A zero length settles immediately: waiting for body bytes that
            // can never arrive would stall the hop until its deadline.
            return length == 0 ? .done : .fixed(remaining: length)
        }
        return .untilClose
    }

    /// Parses one header block into status, version, and ordered fields. A block that is not valid
    /// UTF-8 cannot be framed honestly, so it returns nil and the caller fails closed instead of
    /// decoding lossily.
    private static func parseHeaderBlock(_ block: Data) -> ParsedHeaderBlock? {
        guard let blockText = String(bytes: block, encoding: .utf8) else { return nil }
        let lines = blockText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]), (100 ... 999).contains(status) else {
            return nil
        }
        let version = parts[0].hasPrefix("HTTP/") ? String(parts[0]) : nil
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex ..< separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name, value))
        }
        return ParsedHeaderBlock(statusCode: status, httpVersion: version, headers: headers)
    }
}

/// Marks whether request bytes may already have reached the peer, so a retry against the next
/// pinned address can never resend a non-idempotent request.
private struct PinnedDialFailure: Error, Sendable {
    /// Typed failure raised by the attempt.
    let failure: PinnedDialError
    /// True once the attempt could have sent request bytes.
    let requestWasSent: Bool
}

/// Carries one `NWConnection` across an attempt's `@Sendable` callbacks.
private final class PinnedConnectionBox: Sendable {
    /// The wrapped connection for one attempt.
    let connection: NWConnection

    /// Wraps a connection for one attempt.
    /// - Parameter connection: Newly created connection for the pinned address.
    init(_ connection: NWConnection) {
        self.connection = connection
    }
}

/// One receive result: bytes delivered plus whether the peer closed after them.
private typealias PinnedReceiveResult = (data: Data, closed: Bool)

/// Performs one capped, no-follow HTTP/1.1 exchange over pinned addresses. Intent: `api.request`
/// never hands a hostname to a system resolver at dial time.
enum PinnedHTTPDialer: Sendable {
    /// Dials the pin and returns the capped response. request: Request shaped by
    /// the tool.
    static func perform(
        request: URLRequest,
        pin: SSRFDialPin,
        maxBytes: Int,
        timeoutSeconds: Double
    ) async throws -> (Data, URLResponse) {
        guard !pin.addresses.isEmpty else {
            throw PinnedDialError.emptyPin
        }
        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 1))
        var lastFailure: PinnedDialError = .timedOut
        for address in pin.addresses {
            guard deadline.timeIntervalSinceNow > 0 else { break }
            do {
                return try await exchange(
                    request: request,
                    pin: pin,
                    address: address,
                    maxBytes: maxBytes,
                    deadline: deadline
                )
            } catch let failure as PinnedDialFailure where !failure.requestWasSent {
                if Task.isCancelled {
                    throw CancellationError()
                }
                lastFailure = failure.failure
            } catch let failure as PinnedDialFailure {
                throw failure.failure
            }
        }
        // Every vetted address either failed before the request was sent or the budget ran out, so
        // no request bytes reached an unvetted peer.
        if pin.addresses.count == 1 {
            throw lastFailure
        }
        throw PinnedDialError.allAddressesFailed(lastFailure.localizedDescription)
    }

    /// Runs one exchange attempt against a single pinned address.
    private static func exchange(
        request: URLRequest,
        pin: SSRFDialPin,
        address: String,
        maxBytes: Int,
        deadline: Date
    ) async throws -> (Data, URLResponse) {
        guard let responseURL = request.url else {
            throw PinnedDialError.malformedRequest("request has no URL")
        }
        guard (1 ... 65535).contains(pin.port), let port = NWEndpoint.Port(rawValue: UInt16(pin.port)) else {
            throw PinnedDialError.malformedRequest("destination port \(pin.port) is not dialable")
        }
        let queue = DispatchQueue(label: "com.runeweaver.api-pinned-dial")
        let dial = PinnedConnectionBox(
            NWConnection(
                host: NWEndpoint.Host(address),
                port: port,
                using: makeParameters(pin: pin, queue: queue, timeoutSeconds: max(deadline.timeIntervalSinceNow, 1))
            )
        )
        defer { dial.connection.cancel() }
        // Guarded rather than a plain local: the flag is written inside the
        // cancellation-handler operation and read after it settles, so it stays
        // a Sendable value instead of a captured mutable local.
        let requestWasSent = OSAllocatedUnfairLock<Bool>(initialState: false)
        do {
            return try await withTaskCancellationHandler {
                try await awaitReady(dial, queue: queue, deadline: deadline)
                let payload = try PinnedHTTPRequestSerializer.serialize(request, pin: pin)
                requestWasSent.withLock { $0 = true }
                try await awaitSend(dial, payload: payload, queue: queue, deadline: deadline)
                return try await awaitResponse(
                    dial,
                    queue: queue,
                    responseURL: responseURL,
                    maxBytes: maxBytes,
                    deadline: deadline
                )
            } onCancel: {
                dial.connection.cancel()
            }
        } catch let error as PinnedDialError {
            throw PinnedDialFailure(failure: error, requestWasSent: requestWasSent.withLock { $0 })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Transport-level errors (NWError and friends) map to the typed
            // failure so the wrapper stays Sendable and the tool reports an
            // honest per-address reason.
            throw PinnedDialFailure(
                failure: .allAddressesFailed(error.localizedDescription),
                requestWasSent: requestWasSent.withLock { $0 }
            )
        }
    }

    /// Builds TCP/TLS parameters that pin the peer identity to the original host.
    private static func makeParameters(pin: SSRFDialPin, queue: DispatchQueue, timeoutSeconds: Double) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(Int(timeoutSeconds.rounded(.up)), 1)
        tcp.noDelay = true
        guard pin.isSecure else {
            return NWParameters(tls: nil, tcp: tcp)
        }
        let tls = NWProtocolTLS.Options()
        // ATS does not apply to Network.framework dials, so the floor ATS would
        // have enforced is pinned explicitly: TLS 1.2 or better.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        if !ApiSSRFGuard.isIPAddressLiteral(pin.host) {
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, pin.host)
        }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, completeVerification in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, pin.host as CFString)
            guard SecTrustSetPolicies(secTrust, policy) == errSecSuccess else {
                completeVerification(false)
                return
            }
            var error: CFError?
            completeVerification(SecTrustEvaluateWithError(secTrust, &error))
        }, queue)
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Waits for the pinned connection to become ready.
    private static func awaitReady(_ dial: PinnedConnectionBox, queue: DispatchQueue, deadline: Date) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw PinnedDialError.timedOut }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = CheckedOnce<Void>(continuation)
            dial.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case let .failed(error):
                    once.resume(throwing: error)
                case let .waiting(error):
                    // A waiting connection has no viable path; failing here lets
                    // the next pinned address try within the same budget.
                    once.resume(throwing: error)
                case .cancelled:
                    once.resume(throwing: CancellationError())
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + remaining) {
                guard !once.isSettled else { return }
                once.resume(throwing: PinnedDialError.timedOut)
                dial.connection.cancel()
            }
            dial.connection.start(queue: queue)
        }
    }

    /// Sends the serialized request over the ready connection.
    private static func awaitSend(_ dial: PinnedConnectionBox, payload: Data, queue: DispatchQueue, deadline: Date) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw PinnedDialError.timedOut }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = CheckedOnce<Void>(continuation)
            queue.asyncAfter(deadline: .now() + remaining) {
                guard !once.isSettled else { return }
                once.resume(throwing: PinnedDialError.timedOut)
                dial.connection.cancel()
            }
            dial.connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    once.resume(throwing: error)
                } else {
                    once.resume(returning: ())
                }
            })
        }
    }

    /// Reads and frames the response until the peer closes or the cap settles it.
    private static func awaitResponse(
        _ dial: PinnedConnectionBox,
        queue: DispatchQueue,
        responseURL: URL,
        maxBytes: Int,
        deadline: Date
    ) async throws -> (Data, URLResponse) {
        var parser = PinnedHTTPResponseParser(responseURL: responseURL, maxBodyBytes: maxBytes)
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PinnedDialError.timedOut }
            let received: PinnedReceiveResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PinnedReceiveResult, Error>) in
                let once = CheckedOnce<PinnedReceiveResult>(continuation)
                queue.asyncAfter(deadline: .now() + remaining) {
                    guard !once.isSettled else { return }
                    once.resume(throwing: PinnedDialError.timedOut)
                    dial.connection.cancel()
                }
                dial.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                    if let error {
                        once.resume(throwing: error)
                    } else {
                        once.resume(returning: (content ?? Data(), isComplete))
                    }
                }
            }
            switch parser.feed(received.data, closed: received.closed) {
            case .needMore:
                if received.closed {
                    throw PinnedDialError.truncatedResponse
                }
                continue
            case let .complete(response, body):
                return (body, response)
            case let .failed(error):
                throw error
            }
        }
        throw CancellationError()
    }
}
