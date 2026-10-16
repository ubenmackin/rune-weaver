// Rune Weaver Core — Permission gate data types and contracts.

import Foundation

/// How long a graduated-trust grant lasts.
public enum TrustDuration: String, Sendable, Codable, Equatable, CaseIterable {
    /// Approve once. No grant is stored.
    case thisTime
    /// Trust the action for the remainder of the current turn/task.
    case forTask
    /// Trust the action for the remainder of the current conversation session.
    case forSession
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
        case .forTask: "For rest of this task"
        case .forSession: "For rest of this session"
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
        case .forTask, .forSession: nil
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .forever: nil
        }
    }

    /// Whether the tier can back a durable rule.
    public var isDurable: Bool {
        switch self {
        case .fiveMinutes, .oneHour, .oneDay, .forever: true
        case .thisTime, .forTask, .forSession: false
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
    static let maxArgumentsJSONBytes = 64 * 1024

    /// Parses tool arguments as a hardened JSON object. Pins `options: []` and requires the
    /// top-level object shape so fragments (arrays, strings, numbers) reject, matching the bus
    /// execute and narration gates.
    static func parsedArgumentsObject(from argumentsJSON: String) -> [String: Any]? {
        guard argumentsJSON.utf8.count <= maxArgumentsJSONBytes else { return nil }
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Derives a descriptor from a tool call. toolCall: Raw invocation arguments.
    public static func descriptor(for toolCall: ToolInput, tool: any Tool) -> ActionDescriptor {
        descriptor(for: toolCall, toolName: tool.name)
    }

    /// Derives a descriptor from a raw tool call and a tool name alone. An approval decision
    /// retains only the parked request's tool name, so the decide path cannot reach a live `Tool`
    /// instance.
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
            return ActionDescriptor(toolName: toolName, target: messagesRecipientHandle(from: toolCall) ?? "")
        }
        return ActionDescriptor(toolName: toolName, target: ActionDescriptor.target(from: toolCall))
    }

    /// Canonical handle for a `messages.send` recipient, or nil when the call carries no usable
    /// canonical handle.
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

/// Outcome of promoting a persisted grant to its tool-wide scope.
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

/// Outcome of changing a persisted grant's duration tier in place. Re-arming can fail for two
/// reasons callers must keep distinct: the identifier may name no live grant, or the requested tier
/// may not be a durable tier.
public enum GrantRearmOutcome: Sendable, Equatable {
    /// The grant was found and now carries the new duration with expiry
    /// recomputed from now. Identity and usage counters are unchanged.
    case rearmed
    /// No live grant carries the identifier: unknown, expired, or pruned.
    case notFound
    /// The requested tier cannot back a durable grant. Only the four durable
    /// tiers may re-arm; a one-shot approval has no lifetime to recompute.
    /// Carries the caller-facing explanation.
    case invalidDuration(reason: String)

    /// Caller-facing reason a `thisTime` approval cannot re-arm a grant.
    /// One-shot approvals store no row, so there is no lifetime to extend;
    /// re-arming accepts only the durable tiers.
    public static let thisTimeRefusal =
        "thisTime is one-shot and cannot re-arm a grant; choose fiveMinutes, oneHour, oneDay, or forever"
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
    /// Engine-derived display target naming what "this target" covers.
    public let displayTarget: String?
    /// Server-stamped sandbox tier line for bash approvals, rendered verbatim.
    public let sandboxSummary: String?

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
        case egressHost
        /// Engine-derived display target.
        case displayTarget
        /// Stamped sandbox tier line.
        case sandboxSummary
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
        egressHost: String? = nil,
        sandboxSummary: String? = nil
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
        self.displayTarget = PermissionRequestTarget.derive(
            toolName: toolName,
            argumentsJSON: input.argumentsJSON,
            egressHost: egressHost
        )
        self.sandboxSummary = sandboxSummary
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
        self.displayTarget = try container.decodeIfPresent(String.self, forKey: .displayTarget)
        self.sandboxSummary = try container.decodeIfPresent(String.self, forKey: .sandboxSummary)
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
        try container.encodeIfPresent(displayTarget, forKey: .displayTarget)
        try container.encodeIfPresent(sandboxSummary, forKey: .sandboxSummary)
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
public enum ToolAdmissionVerdict: Sendable, Equatable {
    /// The call may proceed to permission evaluation and approval filing.
    case proceed
    /// The call is refused before admission; the reason is the caller-facing message.
    case refuse(reason: String)
}

/// Optional pre-admission validation seam for target-shaped tool calls. A refusal is answered to
/// the model as an immediate failure result, so an invalid target is actionable before the owner is
/// asked to approve anything.
public protocol ToolAdmissionValidating: Sendable {
    /// Validates one call before permission evaluation and approval filing.
    /// - Parameter input: Raw invocation about to be admitted.
    /// - Returns: `.proceed` to keep the existing admission path, or `.refuse` with the caller-facing reason.
    func admissionVerdict(for input: ToolInput) async -> ToolAdmissionVerdict
}
