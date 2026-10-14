// Rune Weaver Core — Access rules, scopes, and the single scope matcher.
//
// Purpose: own the rule model the permission gate persists and evaluates — one
// tool, one scope, one action, one optional lifetime — plus the single matcher
// that decides whether a live tool call falls inside a scope, so no caller
// re-derives target, recipient, host, path, or command comparison.
// Scope: `AccessScope` with its canonicalizers, `AccessRule` with tolerant
// durable decoding, `EphemeralGrant` for the non-durable task and session
// tiers, and the matcher. Persistence, replay, and the approval decision flow
// stay with `PermissionGate`, `ApprovalQueue`, and `AccessRuleStore`.
// Architectural role: the Core model beside the gate that the CLI, service, and
// dashboard surfaces share. `exactTarget` carries the legacy grant target so a
// migrated row keeps covering the exact call the owner approved.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Whether an access rule trusts or refuses the calls its scope covers.
public enum AccessAction: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// Covered calls run without asking again.
    case allow
    /// Covered calls are refused with the rule's reason.
    case deny
}

/// How wide an access rule reaches for one tool.
///
/// Every case carries only canonical data: a scope created or decoded through
/// ``AccessScope/canonicalized(_:)`` already holds the spelling the matcher
/// compares against, so evaluation never has to judge a shape that should have
/// died at creation. Unknown envelope kinds fail decoding rather than degrading
/// into a scope that matches nothing silently.
public enum AccessScope: Sendable, Codable, Equatable, Hashable {
    /// Every call of the tool, whatever the arguments say.
    case toolWide
    /// Exactly one action target, as the legacy grant key derives it.
    case exactTarget(String)
    /// A set of message or mail recipients.
    case recipientSet([String])
    /// A network host, optionally with every subdomain beneath it.
    case domain(host: String, subdomains: Bool)
    /// A filesystem path prefix and everything beneath it.
    case pathPrefix(String)
    /// A bash command pattern.
    case glob(String)

    /// Largest recipient set one rule may carry.
    public static let maxRecipientSetMembers = 50
    /// Longest host a domain scope may carry.
    public static let maxDomainHostChars = 253
    /// Longest path prefix one rule may carry.
    public static let maxPathPrefixChars = 1024
    /// Longest glob pattern one rule may carry.
    public static let maxGlobChars = 256

    /// Normalized recipient spelling for a rule member or a live call.
    ///
    /// Single owner of recipient spelling so a rule and the call it compares
    /// against agree: trimming and lowercasing both sides first means
    /// `" B@X.COM "` and `"b@x.com"` are one recipient rather than two
    /// near-misses that never join.
    /// - Parameter raw: Candidate recipients.
    /// - Returns: Deduplicated, sorted, lowercased spellings with blanks gone.
    public static func normalizeRecipients(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let canonical = (MessageRecipientClassification.canonicalHandle(trimmed) ?? trimmed).lowercased()
            guard seen.insert(canonical).inserted else { continue }
            normalized.append(canonical)
        }
        return normalized.sorted()
    }

    /// Canonical host for a domain scope, or nil when the value can never match.
    ///
    /// Lowercasing and the trailing-root-dot strip make the stored host agree
    /// with the port-less lowercase form egress screening compares. Blank,
    /// whitespace-carrying, wildcard, glob, and port-qualified shapes refuse
    /// through the shared ``AllowedOriginPattern`` gate so a value that could
    /// never authorize still cannot persist as a configured grant.
    /// - Parameter raw: Candidate host.
    /// - Returns: Canonical host, or nil when malformed.
    public static func canonicalDomain(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var stripped = trimmed
        while stripped.hasSuffix(".") {
            stripped.removeLast()
        }
        guard !stripped.isEmpty, stripped.count <= Self.maxDomainHostChars else { return nil }
        // A domain carries no edges, so every wildcard placement refuses first;
        // the shared gate then refuses glob syntax, whitespace, URL syntax,
        // userinfo, and port qualifiers.
        guard AllowedOriginPattern.classifyWildcard(stripped) == .none else { return nil }
        guard AllowedOriginPattern.isValidExemptionEntry(stripped) else { return nil }
        return stripped
    }

    /// Canonical filesystem prefix for a path scope, or nil when the value can
    /// never match.
    ///
    /// Tilde expansion, standardization, and symlink resolution run on the
    /// prefix so a call's path resolves against the same spelling the rule
    /// stored. A relative value refuses because a prefix without a root could
    /// only match whatever directory the process happened to be standing in.
    /// - Parameter raw: Candidate prefix.
    /// - Returns: Absolute canonical prefix, or nil when malformed.
    public static func canonicalPathPrefix(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxPathPrefixChars else { return nil }
        if trimmed.hasPrefix("file://") {
            trimmed = String(trimmed.dropFirst(7))
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // Relative input is never a boundary: `URL(fileURLWithPath:)` does not
        // absolutize, so the slash test on the expanded spelling is the refused
        // case rather than something standardization would repair.
        guard expanded.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        let fileManager = FileManager.default
        var existing = standardized
        var trailing: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.path != "/" {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in trailing {
            resolved.appendPathComponent(component)
        }
        let path = resolved.path
        guard path.hasPrefix("/"), !path.isEmpty else { return nil }
        return path
    }

    /// Canonical glob pattern for a command scope, or nil when blank.
    ///
    /// Bash pattern semantics (`BashSecurity.matches`) own the wildcards, so the
    /// canonicalizer only trims and bounds: a pattern with leading or trailing
    /// whitespace spells a different command line than the one it names.
    /// - Parameter raw: Candidate pattern.
    /// - Returns: Trimmed pattern, or nil when blank or over-bound.
    public static func canonicalGlob(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxGlobChars else { return nil }
        return trimmed
    }

    /// Canonical form of a scope, or nil when it carries a malformed shape.
    ///
    /// The single gate creation and decoding share: every rule stores only what
    /// the canonicalizers accept, so an over-bound recipient set, a wildcard
    /// host, a relative prefix, or a blank glob is refused before it can become
    /// a rule the matcher would later have to judge.
    /// - Parameter scope: Candidate scope.
    /// - Returns: Canonical scope, or nil when any part is malformed.
    public static func canonicalized(_ scope: AccessScope) -> AccessScope? {
        switch scope {
        case .toolWide:
            return .toolWide
        case let .exactTarget(target):
            // Stored byte-for-byte: this is the legacy grant key, so trimming or
            // lowering here would change what a migrated rule covers.
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .exactTarget(target)
        case let .recipientSet(members):
            let normalized = AccessScope.normalizeRecipients(members)
            guard !normalized.isEmpty, normalized.count <= Self.maxRecipientSetMembers else { return nil }
            return .recipientSet(normalized)
        case let .domain(host, subdomains):
            guard let canonicalHost = AccessScope.canonicalDomain(host) else { return nil }
            return .domain(host: canonicalHost, subdomains: subdomains)
        case let .pathPrefix(path):
            guard let canonicalPath = AccessScope.canonicalPathPrefix(path) else { return nil }
            return .pathPrefix(canonicalPath)
        case let .glob(pattern):
            guard let canonicalPattern = AccessScope.canonicalGlob(pattern) else { return nil }
            return .glob(canonicalPattern)
        }
    }

    /// Whether this scope may key a durable `messages.send` grant.
    ///
    /// Send trust is keyed to the exact canonical recipient the owner
    /// authorized: a recipient set covers the handles it names, and an exact
    /// target must itself spell a canonical handle. A tool-wide send scope is
    /// the signature of a malformed call and a display-name target is the
    /// signature of a name-shaped call; both store nothing while the approved
    /// call still fails closed at execution. A wildcard exact target
    /// (`*`, `?`) is exempt: pattern sends such as `+1555*` persist and match
    /// through the same pathname glob the evaluator uses. Single owner of the
    /// invariant so the approval queue, the rules routes, and the gate's grant
    /// check agree on what send trust may cover.
    /// - Returns: True when the scope may back a durable send grant.
    public var isMintableSendScope: Bool {
        switch self {
        case .recipientSet:
            true
        case let .exactTarget(target):
            target.contains("*") || target.contains("?") || MessageRecipientClassification.canonicalHandle(target) == target
        case .toolWide, .domain, .pathPrefix, .glob:
            false
        }
    }

    /// Whether a live tool call falls inside this scope.
    ///
    /// Callers gate on tool-name equality first: the scope matcher answers only
    /// the "how wide" half of the question, so `toolWide` returns true without
    /// reading the arguments at all. A malformed call (non-object, non-UTF-8, or
    /// oversized JSON) matches nothing but `toolWide`.
    /// - Parameters:
    ///   - toolName: Name of the tool making the call.
    ///   - argumentsJSON: Raw tool arguments document.
    /// - Returns: True when the call falls inside this scope.
    public func matches(toolName: String, argumentsJSON: String) -> Bool {
        switch self {
        case .toolWide:
            return true
        case let .exactTarget(target):
            // A blank target is the malformed-call signature, not a scope: the
            // legacy derivation only ever produces it from unusable arguments.
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let call = ToolInput(toolName: toolName, argumentsJSON: argumentsJSON)
            let callTarget = ActionDescriptor.descriptor(for: call, toolName: toolName).target
            return Self.matchesTarget(callTarget: callTarget, pattern: target, toolName: toolName)
        case let .recipientSet(members):
            // Normalized here too, so member order or casing in the stored or
            // decoded scope cannot decide whether a recipient is covered.
            let normalized = AccessScope.normalizeRecipients(members)
            guard !normalized.isEmpty else { return false }
            return matchesRecipientSet(normalized, toolName: toolName, argumentsJSON: argumentsJSON)
        case let .domain(host, subdomains):
            guard let canonicalHost = AccessScope.canonicalDomain(host) else { return false }
            return matchesDomain(host: canonicalHost, subdomains: subdomains, toolName: toolName, argumentsJSON: argumentsJSON)
        case let .pathPrefix(prefix):
            guard let canonicalPrefix = AccessScope.canonicalPathPrefix(prefix) else { return false }
            return matchesPathPrefix(canonicalPrefix, toolName: toolName, argumentsJSON: argumentsJSON)
        case let .glob(pattern):
            guard let canonicalPattern = AccessScope.canonicalGlob(pattern) else { return false }
            return matchesGlob(canonicalPattern, toolName: toolName, argumentsJSON: argumentsJSON)
        }
    }

    /// Coding keys for the tagged scope envelope.
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case host
        case subdomains
    }

    /// Envelope kind tags. An unrecognized tag refuses the row instead of
    /// degrading into a scope that matches nothing quietly.
    private enum EnvelopeKind: String {
        case toolWide
        case exactTarget
        case recipientSet
        case domain
        case pathPrefix
        case glob
    }

    /// Decodes one scope from its tagged envelope.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard let tag = EnvelopeKind(rawValue: kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown access scope kind '\(kind)'."
            )
        }
        let decoded: AccessScope
        switch tag {
        case .toolWide:
            decoded = .toolWide
        case .exactTarget:
            let value = try container.decodeIfPresent(String.self, forKey: .value)
            guard let value else { throw Self.missingValue(.exactTarget, in: container) }
            decoded = .exactTarget(value)
        case .recipientSet:
            let value = try container.decodeIfPresent([String].self, forKey: .value)
            guard let value else { throw Self.missingValue(.recipientSet, in: container) }
            decoded = .recipientSet(value)
        case .domain:
            guard let nested = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .value) else {
                throw Self.missingValue(.domain, in: container)
            }
            let host = try nested.decodeIfPresent(String.self, forKey: .host)
            guard let host else { throw Self.missingValue(.domain, in: container) }
            decoded = try .domain(host: host, subdomains: nested.decodeIfPresent(Bool.self, forKey: .subdomains) ?? false)
        case .pathPrefix:
            let value = try container.decodeIfPresent(String.self, forKey: .value)
            guard let value else { throw Self.missingValue(.pathPrefix, in: container) }
            decoded = .pathPrefix(value)
        case .glob:
            let value = try container.decodeIfPresent(String.self, forKey: .value)
            guard let value else { throw Self.missingValue(.glob, in: container) }
            decoded = .glob(value)
        }
        // A row that does not survive canonicalization is malformed data, not a
        // scope the matcher should have to refuse at evaluation time.
        guard let canonical = AccessScope.canonicalized(decoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Access scope '\(kind)' is not canonical."
            )
        }
        self = canonical
    }

    /// Encodes one scope into its tagged envelope.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toolWide:
            try container.encode(EnvelopeKind.toolWide.rawValue, forKey: .kind)
        case let .exactTarget(target):
            try container.encode(EnvelopeKind.exactTarget.rawValue, forKey: .kind)
            try container.encode(target, forKey: .value)
        case let .recipientSet(members):
            try container.encode(EnvelopeKind.recipientSet.rawValue, forKey: .kind)
            try container.encode(members, forKey: .value)
        case let .domain(host, subdomains):
            try container.encode(EnvelopeKind.domain.rawValue, forKey: .kind)
            var nested = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .value)
            try nested.encode(host, forKey: .host)
            try nested.encode(subdomains, forKey: .subdomains)
        case let .pathPrefix(path):
            try container.encode(EnvelopeKind.pathPrefix.rawValue, forKey: .kind)
            try container.encode(path, forKey: .value)
        case let .glob(pattern):
            try container.encode(EnvelopeKind.glob.rawValue, forKey: .kind)
            try container.encode(pattern, forKey: .value)
        }
    }

    /// The error an envelope missing its payload throws.
    /// - Parameters:
    ///   - kind: Kind whose payload is absent.
    ///   - container: Container that failed to carry it.
    /// - Returns: A data-corrupted error naming the kind.
    private static func missingValue(
        _ kind: EnvelopeKind,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        DecodingError.dataCorruptedError(
            forKey: .value,
            in: container,
            debugDescription: "Access scope '\(kind.rawValue)' is missing its value."
        )
    }
}

// MARK: - Scope Matching Internals

extension AccessScope {
    /// Argument keys a path scope reads, in priority order.
    ///
    /// The protected-path set the gate already screens, so a rule scoped to a
    /// path and the guard that refuses engine edits read the same keys.
    fileprivate static let pathArgumentKeys = ["path", "file_path", "filePath", "target", "destination", "directory", "dir"]

    /// Whether the scope's recipient set covers a live call's recipients.
    ///
    /// A `messages.send` call compares the canonical handle the owner
    /// authorized, because the shared classifier proves `+1 (555) 123-4567` and
    /// `+15551234567` are one recipient. Every other tool compares normalized
    /// spellings so a comma-joined string and an array agree.
    private func matchesRecipientSet(_ members: [String], toolName: String, argumentsJSON: String) -> Bool {
        guard let object = ActionDescriptor.parsedArgumentsObject(from: argumentsJSON) else { return false }
        if toolName == "messages.send" {
            let call = ToolInput(toolName: toolName, argumentsJSON: argumentsJSON)
            guard let handle = ActionDescriptor.messagesRecipientHandle(from: call),
                  let callKey = MessageRecipientNameNormalizer.handleKey(handle) else { return false }
            return members.contains { MessageRecipientNameNormalizer.handleKey($0) == callKey }
        }
        let spelled = Self.callRecipients(from: object)
        guard !spelled.isEmpty else { return false }
        let normalized = AccessScope.normalizeRecipients(spelled)
        guard !normalized.isEmpty else { return false }
        return normalized.allSatisfy { members.contains($0) }
    }

    /// Whether the scope's host covers a live call's egress hosts.
    ///
    /// Hosts come from the shared egress extractor so an `api.request` URL and
    /// a schemeless `curl example.com` inside a `bash.exec` command screen
    /// against the same list instead of a second parse.
    private func matchesDomain(host: String, subdomains: Bool, toolName: String, argumentsJSON: String) -> Bool {
        for candidate in ApprovalQueue.extractAllEgressHosts(toolName: toolName, argumentsJSON: argumentsJSON) {
            let lowered = candidate.lowercased()
            if lowered == host {
                return true
            }
            if subdomains, lowered.hasSuffix("." + host) {
                return true
            }
        }
        return false
    }

    /// Whether the scope's prefix covers a live call's path argument.
    ///
    /// Only the first non-empty path-ish key decides: the other keys belong to
    /// different shapes of the same call and must not widen the answer.
    private func matchesPathPrefix(_ prefix: String, toolName _: String, argumentsJSON: String) -> Bool {
        guard let object = ActionDescriptor.parsedArgumentsObject(from: argumentsJSON) else { return false }
        for key in Self.pathArgumentKeys {
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // A relative or over-long argument never resolves to a boundary, so
            // the call fails closed instead of falling through to a later key.
            guard let candidate = AccessScope.canonicalPathPrefix(trimmed) else { return false }
            return WorkspaceContainment.isInsidePath(candidate, root: prefix)
        }
        return false
    }

    /// Whether the scope's pattern covers a live call's bash command.
    private func matchesGlob(_ pattern: String, toolName: String, argumentsJSON: String) -> Bool {
        // Command patterns spell bash only; every other tool keeps its own
        // scope so a pattern can never silently cover a send or a write.
        guard toolName == "bash.exec" else { return false }
        guard let command = Self.bashCommand(from: argumentsJSON) else { return false }
        return BashSecurity.matches(command: command, pattern: pattern)
    }

    /// Whether a concrete call target matches a pattern or exact target.
    ///
    /// Wildcards `*` and `?` match through fnmatch, and the slash rule follows
    /// the shape of the comparison. A path-shaped comparison — `files.write`
    /// paths, email addresses, phone prefixes, and every other single-part
    /// target — runs with `FNM_PATHNAME`, so `*` never crosses `/` (`*.pem`
    /// matches `a.pem` but not `a/b.pem`) and `?` matches exactly one
    /// character other than `/`. A URL-shaped comparison — the multi-part
    /// `api.request` (`METHOD URL`) and `browser.act` (`ACTION @ URL`) scopes
    /// plus any pattern naming a `scheme://` target, as `web.fetch` carries —
    /// matches across `/`, so `* https://api.kraken.com/*` covers every path
    /// beneath that host. A leading dot carries no special meaning, and a bare
    /// `*` pattern still matches every target. For multi-part scopes like
    /// `api.request` (`METHOD URL`) and `browser.act` (`ACTION @ URL`), a
    /// URL-only pattern matches any leading segment. For `email.send`,
    /// comparison is case-insensitive. For `files.write`, tilde prefixes
    /// expand before comparison. The non-Darwin/Glibc fallback implements the
    /// same two slash modes without fnmatch.
    public static func matchesTarget(callTarget: String, pattern: String, toolName: String) -> Bool {
        let trimmedTarget = callTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTarget.isEmpty, !trimmedPattern.isEmpty else { return false }

        // Fast path: literal exact match
        if trimmedTarget == trimmedPattern {
            return true
        }

        // Wildcard wildcard-all
        if trimmedPattern == "*" {
            return true
        }

        // A URL-shaped comparison spans the path separator so one star covers
        // a whole URL path; every other shape keeps fnmatch's FNM_PATHNAME
        // rule so a star never crosses `/`.
        let crossesPathSeparator = trimmedPattern.contains("://") || toolName == "api.request" || toolName == "browser.act"

        // Email: case-insensitive match
        if toolName == "email.send" || (trimmedPattern.contains("@") && !trimmedPattern.contains(" ")) {
            if trimmedTarget.lowercased() == trimmedPattern.lowercased() {
                return true
            }
            if trimmedPattern.contains("*") || trimmedPattern.contains("?"),
               matchesGlobString(candidate: trimmedTarget.lowercased(), pattern: trimmedPattern.lowercased(), crossesPathSeparator: crossesPathSeparator)
            {
                return true
            }
        }

        // api.request: candidate target format is "METHOD URL..." (e.g. "GET https://api.kraken.com/0/public/Time")
        if toolName == "api.request" || toolName.isEmpty {
            // If pattern is a URL pattern without a method (e.g. "https://api.kraken.com/*" or "*://...")
            let isURLOnly = trimmedPattern.hasPrefix("http://") || trimmedPattern.hasPrefix("https://") || trimmedPattern.hasPrefix("*://")
            if isURLOnly {
                let methodAgnosticPattern = "* " + trimmedPattern
                if matchesGlobString(candidate: trimmedTarget, pattern: methodAgnosticPattern, crossesPathSeparator: crossesPathSeparator) {
                    return true
                }
            }
            // Case-insensitive method matching: "get https://..." should match "GET https://..."
            let parts = trimmedPattern.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let method = parts[0].uppercased()
                let normalizedPattern = "\(method) \(parts[1])"
                if normalizedPattern == trimmedTarget {
                    return true
                }
                if matchesGlobString(candidate: trimmedTarget, pattern: normalizedPattern, crossesPathSeparator: crossesPathSeparator) {
                    return true
                }
            }
        }

        // browser.act: candidate target format is "ACTION @ URL"
        if toolName == "browser.act" || toolName.isEmpty {
            let isURLOnly = trimmedPattern.hasPrefix("http://") || trimmedPattern.hasPrefix("https://") || trimmedPattern.hasPrefix("*://")
            if isURLOnly {
                let urlPattern = "* @ " + trimmedPattern
                if matchesGlobString(candidate: trimmedTarget, pattern: urlPattern, crossesPathSeparator: crossesPathSeparator) {
                    return true
                }
            }
        }

        // files.write / filesystem paths: expand tilde in pattern
        if trimmedPattern.hasPrefix("~") {
            let expandedPattern = (trimmedPattern as NSString).expandingTildeInPath
            if trimmedTarget == expandedPattern {
                return true
            }
            if matchesGlobString(candidate: trimmedTarget, pattern: expandedPattern, crossesPathSeparator: crossesPathSeparator) {
                return true
            }
        }

        // General glob wildcard match
        if trimmedPattern.contains("*") || trimmedPattern.contains("?") {
            return matchesGlobString(candidate: trimmedTarget, pattern: trimmedPattern, crossesPathSeparator: crossesPathSeparator)
        }

        return false
    }

    /// Whether a pattern's wildcards match a candidate in the slash mode its
    /// shape asks for.
    ///
    /// `FNM_PATHNAME` keeps `*` and `?` inside one path segment, while the
    /// zero-flag form lets them span `/` for URL-shaped comparisons. The
    /// non-Darwin/Glibc fallback implements the same two modes, so the slash
    /// rule cannot drift between platforms.
    /// - Parameters:
    ///   - candidate: Call target under test.
    ///   - pattern: Pattern carrying the wildcards.
    ///   - crossesPathSeparator: Whether `*` and `?` also match `/`.
    /// - Returns: True when the pattern matches the candidate.
    private static func matchesGlobString(candidate: String, pattern: String, crossesPathSeparator: Bool) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
            return fnmatch(pattern, candidate, crossesPathSeparator ? 0 : FNM_PATHNAME) == 0
        #else
            return wildcardPathnameMatch(candidate: candidate, pattern: pattern, crossesPathSeparator: crossesPathSeparator)
        #endif
    }

    /// Hand-rolled wildcard match mirroring fnmatch in both slash modes.
    ///
    /// With `crossesPathSeparator` false the match carries `FNM_PATHNAME`
    /// semantics: `*` consumes any run of characters except `/` and `?`
    /// consumes exactly one character other than `/`. With it true both
    /// consume `/` as well, mirroring fnmatch's zero flags for URL-shaped
    /// patterns. Greedy star matching with one backtrack point keeps the walk
    /// linear while still honoring the slash rule under backtracking.
    /// - Parameters:
    ///   - candidate: Call target under test.
    ///   - pattern: Pattern carrying the wildcards.
    ///   - crossesPathSeparator: Whether `*` and `?` also match `/`.
    /// - Returns: True when the pattern matches the candidate.
    private static func wildcardPathnameMatch(candidate: String, pattern: String, crossesPathSeparator: Bool) -> Bool {
        let candidateChars = Array(candidate)
        let patternChars = Array(pattern)
        var candidateIndex = 0
        var patternIndex = 0
        var starIndex: Int?
        var matchIndex = 0
        while candidateIndex < candidateChars.count {
            if patternIndex < patternChars.count, patternChars[patternIndex] == "?" {
                guard crossesPathSeparator || candidateChars[candidateIndex] != "/" else {
                    guard let star = starIndex else { return false }
                    patternIndex = star + 1
                    matchIndex += 1
                    candidateIndex = matchIndex
                    continue
                }
                patternIndex += 1
                candidateIndex += 1
            } else if patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
                starIndex = patternIndex
                matchIndex = candidateIndex
                patternIndex += 1
            } else if patternIndex < patternChars.count, patternChars[patternIndex] == candidateChars[candidateIndex] {
                patternIndex += 1
                candidateIndex += 1
            } else if let star = starIndex {
                guard crossesPathSeparator || candidateChars[matchIndex] != "/" else { return false }
                patternIndex = star + 1
                matchIndex += 1
                candidateIndex = matchIndex
            } else {
                return false
            }
        }
        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }

    /// Recipient-shaped values a call may carry, in the order the target
    /// derivation reads them.
    fileprivate static func callRecipients(from object: [String: Any]) -> [String] {
        var raw: [String] = []
        for key in ["to", "recipient", "email"] {
            guard let value = object[key], !(value is NSNull) else { continue }
            if let text = value as? String {
                raw.append(text)
            } else if let list = value as? [String] {
                raw.append(contentsOf: list)
            }
        }
        // Comma-joined spellings split so one string and one array reach the
        // same normalized members a rule holds.
        return raw.flatMap { $0.split(separator: ",").map(String.init) }
    }

    /// Trimmed, non-empty shell command from raw arguments, or nil when absent.
    ///
    /// Decodes through the shared `BashCommandArgs` shape so the matcher, the
    /// gate, and the tool agree on what the command is.
    fileprivate static func bashCommand(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(BashCommandArgs.self, from: data)
        else { return nil }
        let trimmed = args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One standing rule: a tool, a scope, an action, and an optional lifetime.
///
/// `duration` is nil for a standing rule that never expires, or one of the four
/// durable tiers. `thisTime` stores nothing and the task and session tiers
/// belong to ``EphemeralGrant``, so neither may back a durable row.
public struct AccessRule: Sendable, Codable, Equatable {
    /// Stable rule identifier.
    public let id: UUID
    /// Tool the rule covers.
    public let toolName: String
    /// How wide the rule reaches for that tool.
    public let scope: AccessScope
    /// Whether covered calls are trusted or refused.
    public let action: AccessAction
    /// When the rule was created.
    public let grantedAt: Date
    /// Lifetime tier, or nil for a standing rule that never expires.
    public let duration: TrustDuration?
    /// When the rule stops covering, or nil when it never expires.
    public let expiresAt: Date?
    /// How many covered calls have run against this rule.
    public var useCount: Int
    /// When the rule last covered a call, or nil when never used.
    public var lastUsedAt: Date?
    /// Caller-facing note recorded when the rule was created.
    public let reason: String?

    /// Coding keys for durable rule rows.
    private enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case scope
        case action
        case grantedAt
        case duration
        case expiresAt
        case useCount
        case lastUsedAt
        case reason
    }

    /// Creates a rule, refusing anything that could not later match.
    ///
    /// The tool name must name a tool, the scope must be canonical, and the
    /// duration must be a tier that can back a durable row. A dated tier without
    /// an explicit expiry derives one from `grantedAt`, while a standing or
    /// forever rule drops a caller-supplied expiry rather than silently
    /// shortening forever trust.
    /// - Parameters:
    ///   - id: Stable identifier. Defaults to a fresh one.
    ///   - toolName: Tool the rule covers.
    ///   - scope: Scope the rule reaches.
    ///   - action: Allow or deny.
    ///   - grantedAt: Creation time. Defaults to now.
    ///   - duration: Durable tier, or nil for a standing rule.
    ///   - expiresAt: Explicit expiry, honored only for a dated tier.
    ///   - reason: Caller-facing note.
    public init?(
        id: UUID = UUID(),
        toolName: String,
        scope: AccessScope,
        action: AccessAction = .allow,
        grantedAt: Date = Date(),
        duration: TrustDuration? = nil,
        expiresAt: Date? = nil,
        reason: String? = nil
    ) {
        guard let canonicalTool = Self.canonicalToolName(toolName),
              let canonicalScope = AccessScope.canonicalized(scope)
        else { return nil }
        if let duration, !duration.isDurable {
            return nil
        }
        self.id = id
        self.toolName = canonicalTool
        self.scope = canonicalScope
        self.action = action
        self.grantedAt = grantedAt
        self.duration = duration
        if let duration, let interval = duration.timeInterval {
            self.expiresAt = expiresAt ?? grantedAt.addingTimeInterval(interval)
        } else {
            self.expiresAt = nil
        }
        self.useCount = 0
        self.lastUsedAt = nil
        self.reason = reason
    }

    /// Whether a live call falls inside this rule.
    ///
    /// The tool-name gate lives here; the shape comparison is the single scope
    /// matcher, so no second copy of the match rules exists.
    /// - Parameters:
    ///   - toolName: Name of the tool making the call.
    ///   - argumentsJSON: Raw tool arguments document.
    /// - Returns: True when the rule covers the call.
    public func covers(toolName: String, argumentsJSON: String) -> Bool {
        guard toolName == self.toolName else { return false }
        return scope.matches(toolName: toolName, argumentsJSON: argumentsJSON)
    }

    /// Canonical tool name, or nil when blank.
    /// - Parameter raw: Candidate tool name.
    /// - Returns: Trimmed non-empty name, or nil.
    public static func canonicalToolName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the rule is expired at the given date.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when `expiresAt` is past `date`.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Whether the rule is currently valid.
    /// - Parameter date: Reference date. Defaults to now.
    /// - Returns: True when not expired.
    public func isValid(at date: Date = Date()) -> Bool {
        !isExpired(at: date)
    }

    /// Decodes a rule, tolerating rows written before usage tracking existed.
    ///
    /// Missing counters mean never observed in use, and negatives clamp to zero
    /// so a hand-edited row cannot seed a negative baseline. A duration that is
    /// not a durable tier rejects the whole row instead of trusting a lifetime
    /// the gate never minted.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        let scope = try container.decode(AccessScope.self, forKey: .scope)
        let action = try container.decodeIfPresent(AccessAction.self, forKey: .action) ?? .allow
        let grantedAt = try container.decodeIfPresent(Date.self, forKey: .grantedAt) ?? Date()
        let duration = try container.decodeIfPresent(TrustDuration.self, forKey: .duration)
        if let duration, !duration.isDurable {
            throw DecodingError.dataCorruptedError(
                forKey: .duration,
                in: container,
                debugDescription: "Access rules may carry only fiveMinutes, oneHour, oneDay, or forever."
            )
        }
        let candidate = try AccessRule(
            id: id,
            toolName: toolName,
            scope: scope,
            action: action,
            grantedAt: grantedAt,
            duration: duration,
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
            reason: container.decodeIfPresent(String.self, forKey: .reason)
        )
        // The creation gate already proved the tool name and scope canonical, so
        // a row that fails here is malformed data rather than a live rule.
        guard var rule = candidate else {
            throw DecodingError.dataCorruptedError(
                forKey: .scope,
                in: container,
                debugDescription: "Access rule carries an unusable tool name or scope."
            )
        }
        let decodedCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        rule.useCount = max(0, decodedCount)
        rule.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self = rule
    }

    /// Encodes a rule including its usage counters.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(scope, forKey: .scope)
        try container.encode(action, forKey: .action)
        try container.encode(grantedAt, forKey: .grantedAt)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

/// A non-durable grant that lives for one task or one conversation session.
///
/// The task and session tiers end on a lifecycle signal rather than a clock, so
/// they never persist as ``AccessRule`` rows.
public struct EphemeralGrant: Sendable, Codable, Equatable, Hashable {
    /// How long the grant survives.
    public enum Kind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
        /// Trust survives the remainder of the owning task or turn.
        case task
        /// Trust survives the remainder of the owning conversation session.
        case session
    }

    /// Tool the grant covers.
    public let toolName: String
    /// How wide the grant reaches for that tool.
    public let scope: AccessScope
    /// Which lifecycle boundary ends the grant.
    public let kind: Kind

    /// Creates a grant, refusing anything that could not later match.
    ///
    /// Uses the same canonical gate as ``AccessRule`` so an ephemeral grant
    /// cannot carry a shape a durable row would refuse.
    /// - Parameters:
    ///   - toolName: Tool the grant covers.
    ///   - scope: Scope the grant reaches.
    ///   - kind: Lifecycle boundary that ends the grant.
    public init?(toolName: String, scope: AccessScope, kind: Kind) {
        guard let canonicalTool = AccessRule.canonicalToolName(toolName),
              let canonicalScope = AccessScope.canonicalized(scope)
        else { return nil }
        self.toolName = canonicalTool
        self.scope = canonicalScope
        self.kind = kind
    }
}
