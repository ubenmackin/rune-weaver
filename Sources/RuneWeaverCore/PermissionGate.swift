// Rune Weaver Core — Graduated-trust permission gate.

import Foundation

/// How long a graduated-trust grant lasts.
public enum TrustDuration: String, Sendable, Codable, Equatable, CaseIterable {
    /// Approve once. No grant is stored.
    case thisTime
    /// Trust the action for the next 5 minutes.
    case fiveMinutes
    /// Trust the action for the next hour.
    case oneHour
    /// Trust the action for the next day.
    case oneDay
    /// Trust the action indefinitely.
    case forever

    /// Human-readable label shown in approval prompts.
    public var displayName: String {
        switch self {
        case .thisTime: "Only this time"
        case .fiveMinutes: "Next 5 minutes"
        case .oneHour: "Next hour"
        case .oneDay: "Next day"
        case .forever: "Forever"
        }
    }

    /// Grant lifetime in seconds, or nil when the grant never expires.
    public var timeInterval: TimeInterval? {
        switch self {
        case .thisTime: 0
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .forever: nil
        }
    }
}

/// Identifies a trustable action: a tool plus an optional target.
public struct ActionDescriptor: Sendable, Codable, Equatable, Hashable {
    /// Name of the tool (e.g. `"email.send"`).
    public let toolName: String
    /// Action target (e.g. `"dr.smith@clinic.com"`). Empty matches all.
    public let target: String

    /// Creates an action descriptor.
    public init(toolName: String, target: String = "") {
        self.toolName = toolName
        self.target = target
    }

    /// Maximum argument bytes parsed for approval targets.
    ///
    /// Bounds the JSON parse so an oversized arguments blob fails closed to
    /// an empty target instead of inflating the grant store; mirrors the
    /// hardened object-shape checks on the bus path.
    static let maxArgumentsJSONBytes = 64 * 1024

    /// Parses tool arguments as a hardened JSON object.
    ///
    /// Pins `options: []` and requires the top-level object shape so
    /// fragments (arrays, strings, numbers) reject, matching the bus execute
    /// and narration gates. Oversized payloads fail closed before parsing.
    /// - Parameter argumentsJSON: Raw tool arguments.
    /// - Returns: Argument object, or nil when oversized, non-UTF8, or not an object.
    static func parsedArgumentsObject(from argumentsJSON: String) -> [String: Any]? {
        guard argumentsJSON.utf8.count <= maxArgumentsJSONBytes else { return nil }
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Derives a descriptor from a tool call.
    /// - Parameters:
    ///   - toolCall: Raw invocation arguments.
    ///   - tool: Tool receiving the call.
    /// - Returns: The action descriptor the gate stores and checks.
    public static func descriptor(for toolCall: ToolInput, tool: any Tool) -> ActionDescriptor {
        descriptor(for: toolCall, toolName: tool.name)
    }

    /// Derives a descriptor from a raw tool call and a tool name alone.
    ///
    /// An approval decision retains only the parked request's tool name, so the
    /// decide path cannot reach a live `Tool` instance. Branching on the tool
    /// name here keeps the grant stored on approval identical to the
    /// descriptor allow-checks and usage accounting derive later; generic
    /// extraction would store a different target for `browser.act` (action,
    /// ref, and page URL) and `api.request` (method, URL, and body preview), so
    /// a durable narrow grant would never cover the identical next call and the
    /// engine would re-prompt despite the user having trusted that exact action.
    /// - Parameters:
    ///   - toolCall: Raw invocation arguments.
    ///   - toolName: Tool name selecting the specialized target shape.
    /// - Returns: The action descriptor the gate stores and checks.
    public static func descriptor(for toolCall: ToolInput, toolName: String) -> ActionDescriptor {
        if toolName == "browser.act",
           let combined = browserActTarget(from: toolCall)
        {
            return ActionDescriptor(toolName: toolName, target: combined)
        }
        if toolName == "api.request",
           let combined = apiRequestTarget(from: toolCall)
        {
            return ActionDescriptor(toolName: toolName, target: combined)
        }
        if toolName == "messages.send" {
            // `messages.send` never falls through to the generic target path.
            // Generic extraction accepts arrays and comma-split strings and
            // skips a non-string `recipient` for a handle-shaped `to`, so a
            // malformed call could derive a canonical handle and mint a durable
            // per-handle grant for a send that can never execute. The strict
            // derivation yields nil for those shapes, and the empty target it
            // maps to is a descriptor `isGrantable` already refuses for sends.
            return ActionDescriptor(toolName: toolName, target: messagesRecipientHandle(from: toolCall) ?? "")
        }
        return ActionDescriptor(toolName: toolName, target: ActionDescriptor.target(from: toolCall))
    }

    /// Canonical handle for a `messages.send` recipient, or nil when the call
    /// carries no usable canonical handle.
    ///
    /// A durable send grant must key on the exact handle the owner authorized,
    /// so the target derives through the shared classification owner instead of
    /// the generic lowercased-text extraction that would store a display name.
    /// Handle spellings canonicalize (`+1 (555) 123-4567` and `+15551234567`
    /// agree on one target), while names and malformed recipients return nil so
    /// callers can refuse them before any approval or grant is derived.
    ///
    /// The scan is strict about a present key: once `recipient` exists it
    /// decides the target, so a non-string value (`["+15551234567"]`, `123`,
    /// `true`, `{}`) or a blank/name-shaped string is malformed and returns nil
    /// rather than falling through to the `to` alias. Only a missing (or null)
    /// `recipient` lets `to` supply the handle, matching the tool decoder that
    /// reads a null recipient as absent. Falling through on a present
    /// non-string is exactly how an array or numeric recipient paired with a
    /// handle-shaped `to` could mint a durable grant for a send that can never
    /// execute.
    /// - Parameter toolCall: Raw `messages.send` invocation.
    /// - Returns: Canonical handle, or nil when absent or not a handle.
    static func messagesRecipientHandle(from toolCall: ToolInput) -> String? {
        guard let object = parsedArgumentsObject(from: toolCall.argumentsJSON) else { return nil }
        for key in ["recipient", "to"] {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let text = raw as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return MessageRecipientClassification.canonicalHandle(trimmed)
        }
        return nil
    }

    /// Extracts a target string from raw tool arguments.
    public static func target(from toolCall: ToolInput) -> String {
        guard let object = parsedArgumentsObject(from: toolCall.argumentsJSON)
        else { return "" }
        for key in ["to", "recipient", "email"] {
            if let joined = normalizedEmailTarget(object[key]) {
                return joined
            }
        }
        // Browser refs combine with the page URL so element-scoped grants
        // never collapse across pages; the dedicated act path below adds
        // the action verb for the same reason.
        if let ref = stringifiedBrowserRef(in: object) {
            if let url = trimmedString(object["url"]), !url.isEmpty {
                return "\(ref) @ \(url)"
            }
            return ref
        }
        for key in ["target", "path", "url", "address", "destination"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }

    /// Builds the approval target for a browser action call.
    private static func browserActTarget(from toolCall: ToolInput) -> String? {
        guard let object = parsedArgumentsObject(from: toolCall.argumentsJSON)
        else { return nil }
        let action = trimmedString(object["action"])
            ?? trimmedString(object["type"])
            ?? trimmedString(object["kind"])
        let ref = stringifiedBrowserRef(in: object)
        let url = trimmedString(object["url"])
            ?? trimmedString(object["page"])
            ?? trimmedString(object["pageUrl"])
            ?? trimmedString(object["page_url"])
        var headParts: [String] = []
        if let action, !action.isEmpty {
            headParts.append(action)
        }
        if let ref, !ref.isEmpty {
            headParts.append(ref)
        }
        let head = headParts.joined(separator: " ")
        if !head.isEmpty, let url, !url.isEmpty {
            return "\(head) @ \(url)"
        }
        if !head.isEmpty {
            return head
        }
        if let url, !url.isEmpty {
            return url
        }
        return nil
    }

    /// Builds the approval target for a constrained API request call.
    ///
    /// The target carries the header summary alongside method, URL, and body
    /// preview so the approver can verify the secret slot: a surrogate
    /// reference (`rwsecret:<KEY>`) stays visible while a pasted live value
    /// redacts to the shared placeholder and never reaches the grant store.
    /// Calls without headers keep the historical `METHOD URL [body:preview]`
    /// shape so existing narrow grants keep covering.
    private static func apiRequestTarget(from toolCall: ToolInput) -> String? {
        guard let object = parsedArgumentsObject(from: toolCall.argumentsJSON)
        else { return nil }
        let rawMethod = trimmedString(object["method"])
            ?? trimmedString(object["verb"])
        let method = (rawMethod ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let effectiveMethod = method.isEmpty ? "GET" : method
        let url = trimmedString(object["url"])
            ?? trimmedString(object["uri"])
            ?? trimmedString(object["link"])
        let body = trimmedString(object["body"])
            ?? trimmedString(object["payload"])
            ?? trimmedString(object["data"])
        guard let url, !url.isEmpty else { return nil }
        var target = "\(effectiveMethod) \(url)"
        if let headers = apiRequestHeaders(from: object), !headers.isEmpty {
            target += " headers:\(apiRedactedHeaderSummary(headers))"
        }
        guard let body, !body.isEmpty else {
            return target
        }
        let preview = apiBodyPreview(body)
        return "\(target) body:\(preview)"
    }

    /// Extracts model-authored headers from API request arguments.
    ///
    /// Accepts the `headers`/`header` aliases the tool decoder honors so the
    /// approval target sees what the transport will validate. Entries with
    /// blank names or non-string values drop; blank values drop so an empty
    /// header object reads as absent and keeps the historical target shape.
    private static func apiRequestHeaders(from object: [String: Any]) -> [String: String]? {
        let raw: Any? = object["headers"] ?? object["header"]
        guard let raw else { return nil }
        var checked: [String: String] = [:]
        if let stringMap = raw as? [String: String] {
            for (name, value) in stringMap {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedValue.isEmpty else { continue }
                checked[trimmedName] = trimmedValue
            }
        } else if let anyMap = raw as? [String: Any] {
            for (name, value) in anyMap {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                guard let text = value as? String else { continue }
                let trimmedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedValue.isEmpty else { continue }
                checked[trimmedName] = trimmedValue
            }
        } else {
            return nil
        }
        return checked.isEmpty ? nil : checked
    }

    /// Summarizes headers for the approval target with secrets redacted.
    ///
    /// Delegates to the shared core header rule so approval targets and the
    /// tools-layer preview policy agree on surrogate visibility: an
    /// `Authorization` value carrying a `rwsecret:<KEY>` reference stays
    /// visible so dry-run previews and approval targets agree, while any other
    /// `Authorization` value redacts to the shared placeholder and never
    /// persists a live secret in the grant store. Other headers pass through
    /// the shared sweep (no resolved values exist at approval time to sweep).
    private static func apiRedactedHeaderSummary(_ headers: [String: String]) -> String {
        var redacted: [String: String] = [:]
        redacted.reserveCapacity(headers.count)
        for (name, value) in headers {
            let isAuth = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "authorization"
            redacted[name] = SecretsManager.redactedHeaderValue(value, isAuthorization: isAuth, resolvedSecrets: [])
        }
        return redacted.sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ", ")
    }

    /// Collapses a request body to the short preview used in API targets.
    private static func apiBodyPreview(_ body: String) -> String {
        let single = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > 200 else { return single }
        return String(single.prefix(200))
    }

    /// Trims an optional string value, collapsing blank to nil.
    private static func trimmedString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalizes a browser element ref from its string or integer aliases.
    private static func stringifiedBrowserRef(in object: [String: Any]) -> String? {
        for key in ["ref", "target", "selector", "element", "elementRef"] {
            if let text = trimmedString(object[key]) {
                return text
            }
            // Booleans bridge to NSNumber, so skip them before the numeric
            // pass: `true` must never park as `"e1"`.
            if object[key] is Bool {
                continue
            }
            // JSON numbers arrive as NSNumber: accept integral positives
            // only so `12` maps to `"e12"` while `12.5` or `0` falls
            // through to fail-closed validation downstream.
            if let boxed = object[key] as? NSNumber,
               boxed.doubleValue == Double(boxed.intValue),
               boxed.intValue >= 1
            {
                return "e\(boxed.intValue)"
            }
        }
        return nil
    }

    /// Normalizes an email recipient value to a lowercased target.
    private static func normalizedEmailTarget(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Split comma-separated strings so `"a@x.com, B@x.com"` matches
            // the array-joined form instead of a spacing variant.
            let parts = trimmed.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ",")
        }
        if let list = value as? [String] {
            let parts = list.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ",")
        }
        if let list = value as? [Any] {
            let parts = list.compactMap { $0 as? String }.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ",")
        }
        return nil
    }
}

/// A persisted graduated-trust grant for an ``ActionDescriptor``.
public struct TrustGrant: Sendable, Codable, Equatable {
    /// Stable grant identifier.
    public let id: UUID
    /// The trusted action (tool + target).
    public let actionDescriptor: ActionDescriptor
    /// When the grant was created.
    public let grantedAt: Date
    /// When the grant expires, or nil when it never expires.
    public let expiresAt: Date?
    /// The duration tier this grant was created with.
    public let duration: TrustDuration
    /// How many covered calls have run against this grant.
    public var useCount: Int
    /// When the grant last covered a call, or nil when never used.
    public var lastUsedAt: Date?

    /// Coding keys for durable grant rows.
    private enum CodingKeys: String, CodingKey {
        /// Stable grant identifier.
        case id
        /// The trusted action.
        case actionDescriptor
        /// When the grant was created.
        case grantedAt
        /// When the grant expires.
        case expiresAt
        /// The duration tier.
        case duration
        /// Covered-call counter.
        case useCount
        /// Last covered-call time.
        case lastUsedAt
    }

    /// Creates a trust grant.
    public init(
        id: UUID = UUID(),
        actionDescriptor: ActionDescriptor,
        grantedAt: Date = Date(),
        expiresAt: Date?,
        duration: TrustDuration,
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.actionDescriptor = actionDescriptor
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.duration = duration
        // Counters never go negative in memory; clamp direct construction
        // so a corrupt caller cannot seed a negative baseline.
        self.useCount = max(0, useCount)
        self.lastUsedAt = lastUsedAt
    }

    /// Decodes a grant, tolerating rows written before usage counters existed.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.actionDescriptor = try container.decode(ActionDescriptor.self, forKey: .actionDescriptor)
        self.grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.duration = try container.decode(TrustDuration.self, forKey: .duration)
        // Older persisted rows predate usage tracking, so a missing counter
        // means the grant was never observed in use rather than a corrupt row.
        // Clamp negatives so legacy or hand-edited JSON cannot seed a
        // negative in-memory baseline.
        let decodedCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        self.useCount = max(0, decodedCount)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    /// Encodes a grant including its usage counters.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(actionDescriptor, forKey: .actionDescriptor)
        try container.encode(grantedAt, forKey: .grantedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }

    /// Whether the grant is expired at the given date.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when `expiresAt` is past `date`.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Whether the grant is currently valid.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when not expired.
    public func isValid(at date: Date = Date()) -> Bool {
        !isExpired(at: date)
    }
}

/// Outcome of promoting a persisted grant to its tool-wide scope.
///
/// Widening can fail for two reasons callers must keep distinct: the
/// identifier may name no live grant, or the grant may be live but belong to a
/// tool with no tool-wide scope. Collapsing both into "not widened" makes a
/// visible, live grant read as unknown.
public enum GrantWidenOutcome: Sendable, Equatable {
    /// The grant was found and now covers every target for its tool. An
    /// already tool-wide grant reports success without changing.
    case widened
    /// No live grant carries the identifier: unknown, expired, or pruned.
    case notFound
    /// A live grant exists but its tool has no tool-wide scope, so promoting
    /// it would invent trust the owner never approved. Carries the
    /// caller-facing explanation.
    case notWidenable(reason: String)

    /// Caller-facing reason a live `messages.send` grant cannot be widened.
    /// Send trust is keyed to the canonical recipient the owner approved, so
    /// there is no tool-wide scope to promote it to.
    public static let messagesSendRefusal = "messages.send grants are per-recipient and cannot be widened"
}

/// Estimated risk level of an action requesting approval.
public enum ImpactSeverity: String, Sendable, Codable, Equatable, CaseIterable {
    /// Read-only inspection, search, or status query with no side effects.
    case safe
    /// Local state changes, non-destructive file writes, or network requests.
    case moderate
    /// Destructive actions, bulk deletions, privilege escalation, or sensitive data access.
    case dangerous
}

/// Safety and impact assessment for a tool invocation.
public struct ImpactAssessment: Sendable, Codable, Equatable {
    /// Evaluated risk severity.
    public let severity: ImpactSeverity
    /// Plain-English explanation of the expected outcome.
    public let outcome: String
    /// Specific risk warnings identified during evaluation.
    public let warnings: [String]

    /// Creates an impact assessment.
    public init(severity: ImpactSeverity, outcome: String, warnings: [String] = []) {
        self.severity = severity
        self.outcome = outcome
        self.warnings = warnings
    }
}

/// Approval prompt sent to connected clients (e.g. over WebSocket).
public struct PermissionRequest: Sendable, Codable, Equatable {
    /// Stable request identifier.
    public let id: UUID
    /// Name of the tool requesting approval.
    public let toolName: String
    /// Human-readable summary of what the tool wants to do.
    public let description: String
    /// The original invocation arguments.
    public let input: ToolInput
    /// Duration options offered to the user.
    public let suggestedDurations: [TrustDuration]
    /// Owning session for narrated parked turns, if known.
    public let sessionID: UUID?
    /// Conversational intent of the agent proposing this action.
    public let intent: String?
    /// Evaluated safety and impact outcome.
    public let assessment: ImpactAssessment?
    /// Target host for unlisted network egress requests.
    public let egressHost: String?

    /// Coding keys for the approval prompt.
    private enum CodingKeys: String, CodingKey {
        /// Stable request identifier.
        case id
        /// Name of the tool requesting approval.
        case toolName
        /// Human-readable summary.
        case description
        /// Original invocation arguments.
        case input
        /// Duration options offered to the user.
        case suggestedDurations
        /// Owning session, when tagged.
        case sessionID
        /// Agent intent.
        case intent
        /// Impact assessment.
        case assessment
        /// Target host for egress requests.
        case egressHost = "egress_host"
    }

    /// Creates a permission request.
    public init(
        id: UUID = UUID(),
        toolName: String,
        description: String = "",
        input: ToolInput,
        suggestedDurations: [TrustDuration] = TrustDuration.allCases,
        sessionID: UUID? = nil,
        intent: String? = nil,
        assessment: ImpactAssessment? = nil,
        egressHost: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.description = description
        self.input = input
        self.suggestedDurations = suggestedDurations
        self.sessionID = sessionID
        self.intent = intent
        self.assessment = assessment
        self.egressHost = egressHost
    }

    /// Decodes a request, tolerating payloads written before session tagging or assessment.
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.input = try container.decode(ToolInput.self, forKey: .input)
        self.suggestedDurations = try container.decode([TrustDuration].self, forKey: .suggestedDurations)
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.intent = try container.decodeIfPresent(String.self, forKey: .intent)
        self.assessment = try container.decodeIfPresent(ImpactAssessment.self, forKey: .assessment)
        self.egressHost = try container.decodeIfPresent(String.self, forKey: .egressHost)
    }

    /// Encodes a request, omitting optional fields when absent.
    /// - Parameter encoder: Destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(description, forKey: .description)
        try container.encode(input, forKey: .input)
        try container.encode(suggestedDurations, forKey: .suggestedDurations)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encodeIfPresent(assessment, forKey: .assessment)
        try container.encodeIfPresent(egressHost, forKey: .egressHost)
    }
}

/// Verdict returned by ``PermissionGate/checkPermission(toolCall:tool:)``.
public enum PermissionDecision: Sendable, Equatable {
    /// The call may run immediately.
    case allowed
    /// The call needs user approval via the associated request.
    case requiresApproval(PermissionRequest)
    /// The call is refused with the associated reason.
    case denied(String)
}

/// Pre-admission verdict for a tool call carrying a target-shaped argument.
///
/// Tools whose arguments encode an externally-addressed target can refuse a
/// call before the permission gate parks it, so an invalid target never reaches
/// the approvals inbox and a durable trust grant can never be keyed on it.
/// Execution still re-validates and fails closed; this verdict only decides
/// whether the call may enter the approval pipeline.
public enum ToolAdmissionVerdict: Sendable, Equatable {
    /// The call may proceed to permission evaluation and approval filing.
    case proceed
    /// The call is refused before admission; the reason is the caller-facing message.
    case refuse(reason: String)
}

/// Optional pre-admission validation seam for target-shaped tool calls.
///
/// The orchestrator consults the verdict before `PermissionGate.checkPermission`
/// and before `ApprovalQueue.fileRequest`. A refusal is answered to the model as
/// an immediate failure result, so an invalid target is actionable before the
/// owner is asked to approve anything. Tools that do not conform keep their
/// existing admission path byte-identically.
public protocol ToolAdmissionValidating: Sendable {
    /// Validates one call before permission evaluation and approval filing.
    /// - Parameter input: Raw invocation about to be admitted.
    /// - Returns: `.proceed` to keep the existing admission path, or `.refuse` with the caller-facing reason.
    func admissionVerdict(for input: ToolInput) async -> ToolAdmissionVerdict
}

/// Trust boundary between the agent and the real world.
public actor PermissionGate {
    /// Live grants, mirrored to the store best-effort.
    private var grants: [TrustGrant] = []
    /// Explicit refusals by descriptor, carrying the denial reason.
    private var denials: [ActionDescriptor: String] = [:]
    /// Optional persistence backend.
    private let store: (any TrustStore)?
    /// Configured plugins directory for protected path enforcement.
    public let pluginsDir: URL?
    /// Live bash shell policy consulted before parking `bash.exec` calls.
    private var bashConfig = BashConfig()
    /// Recurring task for pruning expired grants periodically.
    private var reaperTask: Task<Void, Never>?
    /// Optional egress policy evaluator for network egress admission.
    private var egressEvaluator: (any EgressPolicyEvaluator)?

    /// Creates a permission gate.
    public init(
        store: (any TrustStore)? = nil,
        pluginsDir: URL? = nil,
        egressEvaluator: (any EgressPolicyEvaluator)? = nil
    ) {
        self.store = store
        self.pluginsDir = pluginsDir
        self.egressEvaluator = egressEvaluator
    }

    /// Loads a permission gate hydrated from durable storage, pruning expired grants on startup.
    public static func load(
        store: (any TrustStore)? = nil,
        pluginsDir: URL? = nil,
        egressEvaluator: (any EgressPolicyEvaluator)? = nil
    ) async -> PermissionGate {
        let gate = PermissionGate(store: store, pluginsDir: pluginsDir, egressEvaluator: egressEvaluator)
        await gate.bootstrap()
        return gate
    }

    /// Updates the live egress policy evaluator consulted by the gate.
    /// - Parameter evaluator: Replacement egress evaluator.
    public func setEgressEvaluator(_ evaluator: (any EgressPolicyEvaluator)?) {
        egressEvaluator = evaluator
    }

    /// Updates the live bash shell policy consulted by the gate.
    /// - Parameter config: Replacement bash policy.
    public func updateBashConfig(_ config: BashConfig) {
        bashConfig = config
    }

    /// Hydrates grants from storage, cleaning up expired records immediately.
    public func bootstrap() async {
        guard let store else { return }
        let now = Date()
        try? await store.pruneExpired(at: now)
        do {
            grants = try await store.load()
        } catch {
            grants = []
        }
        grants.removeAll { $0.isExpired(at: now) }
        // Rows written before the per-recipient send invariant may key on an
        // empty or display-name target. Matching fails closed for them either
        // way, but an invalid descriptor stays an invalid descriptor: dropping
        // it at load keeps the grants list honest instead of showing send trust
        // that can never cover a real call.
        grants.removeAll { !Self.isGrantable($0.actionDescriptor) }
    }

    /// Starts a periodic background reaper that checks and cleans up expired grants.
    public func startPeriodicCleanup(intervalSeconds: TimeInterval = 60) async {
        await stopPeriodicCleanup()
        let interval = max(0.01, intervalSeconds)
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                await self.pruneExpiredAndPersist()
            }
        }
    }

    /// Stops the periodic background cleanup reaper, waiting for any in-flight prune to finish.
    ///
    /// Joining the task keeps a stop from racing an uncancellable store
    /// prune: without the join, a reader immediately after stop could
    /// observe the pre-prune rows or hit a transient write lock.
    public func stopPeriodicCleanup() async {
        let task = reaperTask
        reaperTask = nil
        task?.cancel()
        _ = await task?.value
    }

    /// Prunes expired grants from memory and storage.
    public func pruneExpiredAndPersist() async {
        let now = Date()
        grants.removeAll { $0.isExpired(at: now) }
        if let store {
            try? await store.pruneExpired(at: now)
        }
    }

    /// Checks whether a tool call targets a protected engine path.
    private func isProtectedTarget(toolCall: ToolInput) -> Bool {
        guard let object = ActionDescriptor.parsedArgumentsObject(from: toolCall.argumentsJSON)
        else {
            let target = ActionDescriptor.target(from: toolCall)
            guard !target.isEmpty else { return false }
            let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            return PluginSecurity.isProtectedPath(targetURL: url, pluginsDir: pluginsDir)
        }

        // Path-only keys: `to` is intentionally excluded because `email.send`
        // carries recipients under `to` as `[String]`, not a filesystem path;
        // scanning it would risk false protected-path denials on addresses.
        let candidateKeys = ["path", "file_path", "filePath", "target", "destination", "directory", "dir"]
        for key in candidateKeys {
            if let str = object[key] as? String, !str.isEmpty {
                let url = URL(fileURLWithPath: (str as NSString).expandingTildeInPath)
                if PluginSecurity.isProtectedPath(targetURL: url, pluginsDir: pluginsDir) {
                    return true
                }
            }
        }
        return false
    }

    private func checkEgressPermission(
        tool: any Tool,
        toolCall: ToolInput,
        sessionID: UUID?
    ) async -> PermissionDecision? {
        guard let evaluator = egressEvaluator else { return nil }
        let egressHosts = ApprovalQueue.extractAllEgressHosts(toolName: tool.name, argumentsJSON: toolCall.argumentsJSON)
        for host in egressHosts {
            let status = await evaluator.evaluateHostStatus(for: host, sessionID: sessionID)
            switch status {
            case let .explicitlyBlocked(reason):
                return .denied(reason)
            case .unlisted:
                let request = PermissionRequest(
                    toolName: tool.name,
                    description: tool.description,
                    input: toolCall,
                    suggestedDurations: TrustDuration.allCases,
                    sessionID: sessionID,
                    egressHost: host
                )
                return .requiresApproval(request)
            case .allowed:
                break
            }
        }
        return nil
    }

    /// Decides whether a tool call may run.
    public func checkPermission(
        toolCall: ToolInput,
        tool: any Tool,
        sessionID: UUID? = nil
    ) async -> PermissionDecision {
        pruneExpired()
        let descriptor = ActionDescriptor.descriptor(for: toolCall, tool: tool)
        if let reason = denials[descriptor] ?? denials[ActionDescriptor(toolName: tool.name)] {
            return .denied(reason)
        }

        // Guard against automated agent modifications to protected engine paths
        if tool.permissionLevel != .readOnly, isProtectedTarget(toolCall: toolCall) {
            return .denied("Access denied: direct modification of protected Rune Weaver engine files or installed plugins is prohibited.")
        }

        if let egressVerdict = await checkEgressPermission(tool: tool, toolCall: toolCall, sessionID: sessionID) {
            return egressVerdict
        }

        switch tool.permissionLevel {
        case .readOnly, .trusted:
            return .allowed
        case .requiresApproval:
            if tool.name == "bash.exec", let command = Self.bashCommand(from: toolCall) {
                let decision = BashSecurity.evaluate(command: command, config: bashConfig)
                switch decision.action {
                case .deny:
                    return .denied(decision.reason)
                case .allow:
                    return .allowed
                case .ask:
                    break
                }
            }
            if covers(descriptor) {
                return .allowed
            }
            let request = PermissionRequest(
                toolName: tool.name,
                description: tool.description,
                input: toolCall,
                suggestedDurations: TrustDuration.allCases,
                sessionID: sessionID
            )
            return .requiresApproval(request)
        }
    }

    /// Records trust for an action.
    public func grantTrust(for descriptor: ActionDescriptor, duration: TrustDuration) async {
        guard duration != .thisTime else { return }
        // Every durable mint path funnels through here — the CLI approval
        // handler, `ApprovalQueue.decide`, and the bus passthrough — so the
        // per-recipient send invariant is enforced at one boundary: a
        // `messages.send` target that is empty (malformed call) or not the
        // canonical handle (display name) is an invalid descriptor and stores
        // nothing. Handle-shaped sends mint their canonical handle exactly as
        // before, and every other tool keeps its tool-wide semantics.
        guard Self.isGrantable(descriptor) else { return }
        pruneExpired()
        let now = Date()
        let expiresAt = duration.timeInterval.map { now.addingTimeInterval($0) }
        // A tool-wide grant (empty target) covers every target for its tool,
        // so installing one is a widening act and must obey the same
        // never-shorten invariant as the explicit widen path: when an existing
        // tool-wide grant already survives at least as long as the
        // replacement, keep it and drop the redundant candidate. Effective
        // expiry is the sole comparison, so an equal-tier grant created later
        // or a lower-tier grant that expires later still wins, while an older
        // long-tier grant that has decayed past the replacement is replaced.
        if descriptor.target.isEmpty,
           let existing = grants.first(where: { $0.actionDescriptor == descriptor }),
           !Self.expiryLifetime(expiresAt, outlives: existing.expiresAt)
        {
            denials.removeValue(forKey: descriptor)
            return
        }
        grants.removeAll { $0.actionDescriptor == descriptor }
        // A replacement grant starts its usage history fresh so prior
        // counters cannot leak into the new lifetime.
        let grant = TrustGrant(
            actionDescriptor: descriptor,
            grantedAt: now,
            expiresAt: expiresAt,
            duration: duration,
            useCount: 0,
            lastUsedAt: nil
        )
        grants.append(grant)
        denials.removeValue(forKey: descriptor)
        await persist()
    }

    /// Records one covered use of a live grant without notifying clients.
    /// - Parameter descriptor: The executed action to attribute.
    public func recordUse(for descriptor: ActionDescriptor) async {
        pruneExpired()
        let now = Date()
        // Attribute usage exactly where an allow decision came from.
        // Staying silent keeps accounting out of the approval broadcast path.
        guard let index = coveringGrantIndex(for: descriptor, at: now) else { return }
        // Saturate at the limit instead of trapping on overflow.
        if grants[index].useCount < Int.max {
            grants[index].useCount += 1
        }
        grants[index].lastUsedAt = now
        await persist()
    }

    /// Removes trust for an action.
    public func revokeTrust(for descriptor: ActionDescriptor) async {
        if descriptor.target.isEmpty {
            grants.removeAll { $0.actionDescriptor.toolName == descriptor.toolName }
        } else {
            grants.removeAll { $0.actionDescriptor == descriptor }
        }
        await persist()
    }

    /// Removes one grant by identifier, persisting only when something changed.
    /// Expired grants are pruned first so an expired identifier reports no match.
    /// - Parameter id: Stable grant identifier.
    /// - Returns: True when a matching grant was removed.
    public func revokeGrant(id: UUID) async -> Bool {
        pruneExpired()
        let before = grants.count
        grants.removeAll { $0.id == id }
        guard grants.count != before else { return false }
        await persist()
        return true
    }

    /// Promotes an existing active grant to a tool-wide grant (empty target).
    /// Preserves the original grant's ID, grantedAt, expiresAt, duration, and usage counters.
    /// When a longer-lived tool-wide grant for the same tool already exists, that
    /// grant is kept instead so widening never shortens trust.
    /// - Parameter id: Stable grant identifier.
    /// - Returns: `.widened` when a live grant was found and now covers every
    ///   target (an already tool-wide grant is idempotent success),
    ///   `.notFound` when the identifier matches no live grant, and
    ///   `.notWidenable` when the grant is live but its tool has no tool-wide
    ///   scope.
    public func widenGrant(id: UUID) async -> GrantWidenOutcome {
        pruneExpired()
        guard let current = grants.first(where: { $0.id == id && $0.isValid() }) else {
            return .notFound
        }
        // A send grant is per-recipient by design: an empty target is an
        // invalid descriptor there, never a tool-wide scope, so send trust is
        // never promoted past the canonical handle the owner approved. The
        // distinct outcome keeps the live grant from reading as unknown on the
        // widen route.
        guard current.actionDescriptor.toolName != "messages.send" else {
            return .notWidenable(reason: GrantWidenOutcome.messagesSendRefusal)
        }
        guard !current.actionDescriptor.target.isEmpty else {
            return .widened
        }
        let widenedDescriptor = ActionDescriptor(toolName: current.actionDescriptor.toolName, target: "")
        // A pre-existing tool-wide grant may outlive the narrow grant the user
        // is promoting. Widening must never shorten trust, so keep any
        // covering tool-wide grant that survives at least as long as the
        // promotion and drop the now-redundant narrow row. Effective expiry is
        // the sole comparison: an absent expiry is the forever tier and always
        // wins, an equal-tier grant created later or a lower-tier grant with a
        // later expiry is kept rather than truncated to the promoted row's
        // earlier expiry, and only a promotion that strictly outlives the
        // covering grant replaces it.
        if let covering = grants.first(where: { $0.id != id && $0.actionDescriptor == widenedDescriptor }),
           !Self.expiryLifetime(current.expiresAt, outlives: covering.expiresAt)
        {
            grants.removeAll { $0.id == id }
            await persist()
            return .widened
        }
        // Dedupe can remove a tool-wide grant positioned before the target,
        // shifting the target's slot; a pre-removal index would then land on an
        // unrelated grant or read past the end when the target was last.
        // Re-resolve the target by its stable identifier after the mutation.
        grants.removeAll { $0.id != id && $0.actionDescriptor == widenedDescriptor }
        let widened = TrustGrant(
            id: current.id,
            actionDescriptor: widenedDescriptor,
            grantedAt: current.grantedAt,
            expiresAt: current.expiresAt,
            duration: current.duration,
            useCount: current.useCount,
            lastUsedAt: current.lastUsedAt
        )
        if let index = grants.firstIndex(where: { $0.id == id }) {
            grants[index] = widened
        } else {
            // The dedupe excludes the target's own identifier, so it should
            // always survive; append only as a last resort so a promoted grant
            // is never silently dropped if in-memory state ever drifts.
            grants.append(widened)
        }
        await persist()
        return .widened
    }

    /// Explicitly refuses an action with a reason.
    public func deny(_ descriptor: ActionDescriptor, reason: String) {
        denials[descriptor] = reason
    }

    /// Clears an explicit refusal.
    /// - Parameter descriptor: The action to unblock.
    public func removeDenial(for descriptor: ActionDescriptor) {
        denials.removeValue(forKey: descriptor)
    }

    /// Returns the currently valid grants, pruning expired ones first.
    /// - Returns: Live grants.
    public func activeGrants() -> [TrustGrant] {
        pruneExpired()
        return grants
    }

    /// Whether a live grant covers the descriptor.
    /// - Parameter descriptor: The action to check.
    /// - Returns: True when a valid grant matches.
    public func isTrusted(_ descriptor: ActionDescriptor) -> Bool {
        pruneExpired()
        return covers(descriptor)
    }

    // MARK: - Private

    /// Extracts the bash command for rule evaluation via the shared decoder.
    /// - Parameter toolCall: Raw invocation arguments.
    /// - Returns: Trimmed command (possibly empty so `evaluate` denies), or nil only when unparseable.
    private static func bashCommand(from toolCall: ToolInput) -> String? {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(BashCommandArgs.self, from: data)
        else { return nil }
        // Blank commands return empty so the evaluator denies closed instead
        // of skipping evaluation and parking for approval.
        return args.command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the first effective expiry strictly outlives the second. A nil
    /// expiry is the forever tier, so it outlives every dated grant while two
    /// forever grants tie. Widening and tool-wide granting rely on this as the
    /// sole never-shorten comparison: a candidate only replaces a covering
    /// grant when it strictly outlives it, so trust can never be truncated by
    /// nominal tier or by a grant date that happens to land earlier.
    private static func expiryLifetime(_ candidate: Date?, outlives incumbent: Date?) -> Bool {
        guard let candidate else { return incumbent != nil }
        guard let incumbent else { return false }
        return candidate > incumbent
    }

    /// Whether a descriptor may key a durable grant.
    ///
    /// A `messages.send` grant must store the exact canonical handle the owner
    /// authorized. An empty target is the generic tool-wide scope, but for a
    /// send it is the signature of a malformed call (missing, blank, or
    /// non-string recipient), and a display-name target is the signature of a
    /// name-shaped call; neither may persist send trust, so both are invalid
    /// descriptors rather than a tool-wide scope. Every other tool keeps its
    /// existing tool-wide semantics.
    /// - Parameter descriptor: Candidate grant key.
    /// - Returns: True when the descriptor may be stored.
    private static func isGrantable(_ descriptor: ActionDescriptor) -> Bool {
        guard descriptor.toolName == "messages.send" else { return true }
        guard !descriptor.target.isEmpty else { return false }
        return MessageRecipientClassification.canonicalHandle(descriptor.target) == descriptor.target
    }

    /// Index of the live grant covering the descriptor, if any. An exact
    /// tool-plus-target grant wins, with a tool-wide empty-target grant as
    /// the fallback. Shared by allow checks and usage accounting so both
    /// attribute to the same grant.
    private func coveringGrantIndex(for descriptor: ActionDescriptor, at date: Date) -> Int? {
        // A `messages.send` scope is always an exact canonical handle. An empty
        // target is the widen scope every other tool supports but, for a send,
        // the signature of a malformed call (or a legacy tool-wide row), so it
        // never matches — not even exactly — and never falls back to a stored
        // empty-target grant. Handle-shaped sends keep the exact-match path.
        let isMessagesSend = descriptor.toolName == "messages.send"
        if !(isMessagesSend && descriptor.target.isEmpty),
           let exact = grants.firstIndex(where: {
               $0.isValid(at: date)
                   && $0.actionDescriptor.toolName == descriptor.toolName
                   && $0.actionDescriptor.target == descriptor.target
           })
        {
            return exact
        }
        guard !descriptor.target.isEmpty, !isMessagesSend else { return nil }
        return grants.firstIndex(where: {
            $0.isValid(at: date)
                && $0.actionDescriptor.toolName == descriptor.toolName
                && $0.actionDescriptor.target.isEmpty
        })
    }

    /// Whether any live grant covers the descriptor, either by exact
    /// target match or by a tool-wide grant with an empty target.
    private func covers(_ descriptor: ActionDescriptor) -> Bool {
        coveringGrantIndex(for: descriptor, at: Date()) != nil
    }

    /// Drops expired grants from memory only, without touching storage.
    private func pruneExpired() {
        let now = Date()
        grants.removeAll { $0.isExpired(at: now) }
    }

    /// Mirrors the current grants to the store in actor order.
    private func persist() async {
        guard let store else { return }
        let snapshot = grants
        do {
            try await store.save(snapshot)
        } catch {
            RuneWeaverLog.stores.error("PermissionGate: Failed to persist trust grants: \(error)")
        }
    }
}
