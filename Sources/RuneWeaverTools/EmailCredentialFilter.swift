// Rune Weaver Tools — Deterministic credential filter for agent-visible mail.
//
// Scans subjects and bodies for one-time codes, magic sign-in links, and
// password-reset links without any model call, so the agent can never be
// steered into reading or exfiltrating a credential. Senders stay visible so
// the agent knows what arrived; link URLs and code values redact in both the
// subject and the body of the agent-visible copy. The human inbox is untouched
// — the filter applies at the envelope boundary where tool output is built and
// at the index gateway where mail is ingested, so search recall cannot
// resurrect a redacted link.

import Foundation

/// Severity of credential content found in one message.
public enum EmailCredentialLevel: String, Sendable, Equatable, Codable, CaseIterable {
    /// No credential signal; the body passes through untouched.
    case none
    /// Weak signal (a keyword without a code or link); passes unredacted so
    /// everyday mail is never mangled by a guess.
    case suspicious
    /// Definite one-time code, magic link, or password-reset link; the
    /// agent-visible body must carry the redacted form.
    case credentialBearing
}

/// Outcome of scanning one subject/body pair.
public struct EmailCredentialVerdict: Sendable, Equatable {
    /// Severity driving pass-through versus redaction.
    public let level: EmailCredentialLevel
    /// Redacted body for `credentialBearing`, nil otherwise.
    public let redactedBody: String?
    /// Redacted subject for `credentialBearing`, nil otherwise.
    public let redactedSubject: String?

    /// Creates a verdict.
    /// - Parameters:
    ///   - level: Severity of the finding.
    ///   - redactedBody: Redacted body when redaction applies, nil otherwise.
    ///   - redactedSubject: Redacted subject when redaction applies, nil otherwise.
    public init(level: EmailCredentialLevel, redactedBody: String? = nil, redactedSubject: String? = nil) {
        self.level = level
        self.redactedBody = redactedBody
        self.redactedSubject = redactedSubject
    }

    /// Suspicious verdict that passes through unredacted.
    public static var suspicious: EmailCredentialVerdict {
        EmailCredentialVerdict(level: .suspicious, redactedBody: nil)
    }

    /// Clean verdict that passes through unredacted.
    public static var none: EmailCredentialVerdict {
        EmailCredentialVerdict(level: .none, redactedBody: nil)
    }

    /// Redacted verdict for a definite credential.
    /// - Parameters:
    ///   - redactedBody: Body with links and codes replaced.
    ///   - redactedSubject: Subject with links and codes replaced.
    public static func credentialBearing(redactedBody: String, redactedSubject: String? = nil) -> EmailCredentialVerdict {
        EmailCredentialVerdict(level: .credentialBearing, redactedBody: redactedBody, redactedSubject: redactedSubject)
    }
}

/// Deterministic, model-free scanner keeping credentials out of agent context.
///
/// Heuristics stay deliberately narrow: a bare number is never enough, and a
/// bare keyword without an artifact stays `suspicious` so dates, prices, and
/// years never redact. Only the co-occurrence of a code keyword with nearby
/// digits, or a reset/magic phrase or URL-path marker, reaches
/// `credentialBearing`. Matching is case-insensitive and scheme-agnostic so
/// `HTTP`, `www.`, and bare-domain links classify the same.
public enum EmailCredentialFilter: Sendable {
    /// Placeholder replacing every link URL in a redacted body.
    public static let redactedLinkPlaceholder = "[redacted credential link]"
    /// Placeholder replacing each one-time code in a redacted body.
    public static let redactedCodePlaceholder = "[redacted code]"
    /// Characters scanned on either side of a digit run for a code keyword.
    /// Wide enough for "Your verification code is 482913" yet narrow enough
    /// that a year on another paragraph never joins an unrelated keyword.
    public static let codeWindowRadius = 120

    /// Assesses one message, returning the redacted subject and body when definite.
    /// - Parameters:
    ///   - subject: Decoded `Subject` header, redacted when the verdict is definite.
    ///   - body: Decoded plain-text body (or snippet) to scan.
    /// - Returns: Verdict with redacted forms set only for `credentialBearing`.
    public static func assess(subject: String, body: String) -> EmailCredentialVerdict {
        let combinedLower = (subject + "\n" + body).lowercased()
        if codeIsCredentialBearing(subject: subject, body: body) {
            return .credentialBearing(
                redactedBody: redactedAgentBody(subject: subject, body: body),
                redactedSubject: redactedAgentSubject(subject: subject, body: body)
            )
        }
        if hasMagicLink(in: combinedLower) || hasPasswordReset(in: combinedLower) {
            return .credentialBearing(
                redactedBody: redactedAgentBody(subject: subject, body: body),
                redactedSubject: redactedAgentSubject(subject: subject, body: body)
            )
        }
        if isSuspicious(combinedLower) {
            return .suspicious
        }
        return .none
    }

    /// Returns the agent-visible subject, redacting only when definite.
    /// - Parameters:
    ///   - subject: Original subject, possibly carrying a code or link.
    ///   - body: Original body giving keyword context for windowed codes.
    ///   - enabled: False passes through byte-identically (config off-switch).
    /// - Returns: Redacted subject, or the input verbatim.
    public static func agentVisibleSubject(subject: String, body: String, enabled: Bool) -> String {
        guard enabled else { return subject }
        let verdict = assess(subject: subject, body: body)
        guard verdict.level == .credentialBearing, let redacted = verdict.redactedSubject else { return subject }
        return redacted
    }

    /// Returns the agent-visible body, redacting only when definite.
    /// - Parameters:
    ///   - subject: Message subject giving keyword context for windowed codes.
    ///   - body: Original body.
    ///   - enabled: False passes through byte-identically (config off-switch).
    /// - Returns: Redacted body, or the input verbatim.
    public static func agentVisibleBody(subject: String, body: String, enabled: Bool) -> String {
        guard enabled else { return body }
        let verdict = assess(subject: subject, body: body)
        guard verdict.level == .credentialBearing, let redacted = verdict.redactedBody else { return body }
        return redacted
    }

    /// Returns the agent-visible snippet, redacting only when definite.
    /// - Parameters:
    ///   - subject: Message subject giving keyword context.
    ///   - snippet: Search-hit snippet to scan.
    ///   - enabled: False passes through byte-identically.
    /// - Returns: Redacted snippet, or the input verbatim.
    public static func agentVisibleSnippet(subject: String, snippet: String, enabled: Bool) -> String {
        agentVisibleBody(subject: subject, body: snippet, enabled: enabled)
    }

    /// Applies the credential filter to one agent-visible value.
    /// Single-sources the `guard enabled else return self` plus verbatim-copy
    /// pass-through so the four envelope `agentVisible` shapes cannot drift on
    /// disabled versus non-bearing behavior.
    /// - Parameters:
    ///   - enabled: False passes through byte-identically.
    ///   - original: Value to filter.
    ///   - transform: Filtered copy builder, run only when enabled.
    /// - Returns: Filtered copy, or the original when disabled or unchanged.
    public static func applyFilter<T: Equatable>(enabled: Bool, original: T, transform: () -> T) -> T {
        guard enabled else { return original }
        let filtered = transform()
        return filtered == original ? original : filtered
    }

    /// Redacts every link URL and windowed code in a definite body.
    ///
    /// Links go first so digits inside a token URL leave with the URL instead
    /// of double-redacting; codes are then re-licensed against the surviving
    /// text so only keyword-adjacent numbers are replaced.
    /// - Parameters:
    ///   - subject: Message subject for code keyword context.
    ///   - body: Original body.
    /// - Returns: Body with placeholders in place of links and codes.
    public static func redactedAgentBody(subject: String, body: String) -> String {
        let withoutLinks = redactURLs(in: body)
        return redactCredentialCodes(subject: subject, body: withoutLinks)
    }

    /// Redacts every link URL and windowed code in a definite subject.
    ///
    /// Mirrors the body path so a code carried by the subject alone (for
    /// example `Your verification code is 482913`) cannot persist verbatim
    /// while the body redacts. Links strip first so token digits leave with
    /// the URL; codes then re-license against the surviving text.
    /// - Parameters:
    ///   - subject: Original subject.
    ///   - body: Original body giving keyword context for windowed codes.
    /// - Returns: Subject with placeholders in place of links and codes.
    public static func redactedAgentSubject(subject: String, body: String) -> String {
        let withoutLinks = redactURLs(in: subject)
        return redactSubjectCodes(subject: withoutLinks, body: body)
    }
}

// MARK: - Definite signals

extension EmailCredentialFilter {
    /// Code-adjacent keywords licensing a nearby digit run as a one-time code.
    fileprivate static var codeKeywords: [String] {
        [
            "code", "otp", "one-time", "one time", "verification", "verify",
            "passcode", "security code", "login code", "authentication code",
            "2fa", "two-factor", "two factor", "token", "pin"
        ]
    }

    /// Phrases marking a password-reset message even before URL inspection.
    fileprivate static var resetPhrases: [String] {
        [
            "reset your password", "reset password", "password reset",
            "set a new password", "set your new password", "choose a new password",
            "create a new password", "forgot your password"
        ]
    }

    /// URL-path fragments marking a reset link regardless of scheme.
    /// The leading slash (or compound token) keeps prose like "please verify
    /// your email" from classifying without an actual link path.
    fileprivate static var resetPathMarkers: [String] {
        ["/reset", "reset-password", "reset_password", "password-reset", "password_reset", "password/reset"]
    }

    /// Phrases marking a magic sign-in link.
    fileprivate static var magicPhrases: [String] {
        [
            "magic link", "sign-in link", "sign in link", "signin link",
            "login link", "log-in link", "log in link"
        ]
    }

    /// URL-path fragments marking a magic link regardless of scheme.
    /// Bare "/login" is intentionally absent: a generic login page without a
    /// token, auth, magic, verify, or sign-in marker is not a credential.
    fileprivate static var magicPathMarkers: [String] {
        ["token=", "token/", "/auth", "/magic", "/verify", "magic-link", "magic_link", "/signin", "/sign-in"]
    }

    /// Weak keywords producing `suspicious` when no definite artifact joins them.
    fileprivate static var suspiciousKeywords: [String] {
        [
            "password", "passcode", "verification", "verify", "otp", "2fa",
            "magic", "sign-in", "signin", "sign in", "login", "log-in", "token",
            "reset", "one-time", "one time", "code", "credential", "authenticate"
        ]
    }

    /// Whether the lowercased text carries a password-reset phrase or link path.
    fileprivate static func hasPasswordReset(in lower: String) -> Bool {
        if resetPhrases.contains(where: { lower.contains($0) }) {
            return true
        }
        return resetPathMarkers.contains(where: { lower.contains($0) })
    }

    /// Whether the lowercased text carries a magic-link phrase or link path.
    fileprivate static func hasMagicLink(in lower: String) -> Bool {
        if magicPhrases.contains(where: { lower.contains($0) }) {
            return true
        }
        return magicPathMarkers.contains(where: { lower.contains($0) })
    }

    /// Whether the lowercased text carries only a weak credential hint.
    fileprivate static func isSuspicious(_ lower: String) -> Bool {
        suspiciousKeywords.contains(where: { lower.contains($0) })
    }

    /// Whether a 4–8 digit run sits near a code keyword in the combined text.
    ///
    /// The subject joins the window so a subject like "Your verification code"
    /// licenses a code at the top of the body, while a year or price pages
    /// away from any keyword never qualifies.
    fileprivate static func codeIsCredentialBearing(subject: String, body: String) -> Bool {
        let combined = subject + "\n" + body
        let lower = combined.lowercased() as NSString
        let ranges = allCodeRanges(in: combined)
        guard !ranges.isEmpty else { return false }
        for range in ranges {
            let start = max(0, range.location - codeWindowRadius)
            let end = min(lower.length, range.location + range.length + codeWindowRadius)
            guard end > start else { continue }
            let window = lower.substring(with: NSRange(location: start, length: end - start))
            if codeKeywords.contains(where: { window.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// All one-time-code candidate ranges in one text.
    ///
    /// Covers contiguous 4–8 digits plus the common spaced/dashed 3–3 split
    /// ("123 456", "123-456") so formatted codes classify like compact ones.
    fileprivate static func allCodeRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        if let continuous = try? NSRegularExpression(pattern: "\\b\\d{4,8}\\b") {
            ranges += continuous.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range)
        }
        if let spaced = try? NSRegularExpression(pattern: "\\b\\d{3}[\\s\\-]\\d{3}\\b") {
            ranges += spaced.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range)
        }
        return ranges
    }
}

// MARK: - Redaction

extension EmailCredentialFilter {
    /// Characters stripped from the end of a URL match before replacement.
    /// Trailing prose punctuation is preserved after the placeholder so
    /// "See https://example.com/reset." keeps its period.
    fileprivate static var trailingURLPunctuation: CharacterSet {
        CharacterSet(charactersIn: ".,;:!?)'\"")
    }

    /// Replaces every link URL with the link placeholder.
    ///
    /// Matches `https?://`, `www.`, and bare-domain links so a credential URL
    /// without a scheme still redacts. Email addresses are skipped by checking
    /// for a preceding `@`, since redacting the sender's address would only
    /// obscure routing without removing any credential.
    fileprivate static func redactURLs(in text: String) -> String {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "(?:https?://|www\\.)[^\\s<>\"']+|\\b(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(?:/[^\\s<>\"']*)?"
        ) else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            // Skip email addresses: the matcher sees only the domain half.
            if match.range.location > 0 {
                let before = nsText.substring(with: NSRange(location: match.range.location - 1, length: 1))
                if before == "@" {
                    continue
                }
            }
            var matched = nsText.substring(with: match.range)
            // Trim trailing prose punctuation, keeping it after the placeholder.
            while let last = matched.unicodeScalars.last, trailingURLPunctuation.contains(last) {
                matched.removeLast()
            }
            guard !matched.isEmpty else { continue }
            let trimmedLength = (matched as NSString).length
            let trimmedRange = NSRange(location: match.range.location, length: trimmedLength)
            if trimmedRange.location + trimmedRange.length <= (mutable as NSString).length {
                mutable.replaceCharacters(in: trimmedRange, with: redactedLinkPlaceholder)
            }
        }
        return mutable as String
    }

    /// Replaces only keyword-licensed codes, leaving dates and prices alone.
    ///
    /// Ranges are recomputed on the link-stripped body so digits that left
    /// with a token URL are never considered, and replacement runs back to
    /// front so earlier offsets stay valid as placeholders change the length.
    fileprivate static func redactCredentialCodes(subject: String, body: String) -> String {
        let combined = subject + "\n" + body
        let lower = combined.lowercased() as NSString
        let bodyStart = (subject as NSString).length + 1
        let ranges = allCodeRanges(in: combined)
        var bodyRanges: [NSRange] = []
        for range in ranges {
            let start = max(0, range.location - codeWindowRadius)
            let end = min(lower.length, range.location + range.length + codeWindowRadius)
            guard end > start else { continue }
            let window = lower.substring(with: NSRange(location: start, length: end - start))
            guard codeKeywords.contains(where: { window.contains($0) }) else { continue }
            guard range.location >= bodyStart else { continue }
            bodyRanges.append(NSRange(location: range.location - bodyStart, length: range.length))
        }
        guard !bodyRanges.isEmpty else { return body }
        let mutable = NSMutableString(string: body)
        for bodyRange in bodyRanges.sorted(by: { $0.location > $1.location }) where bodyRange.location + bodyRange.length <= (mutable as NSString).length {
            mutable.replaceCharacters(in: bodyRange, with: redactedCodePlaceholder)
        }
        return mutable as String
    }

    /// Replaces only keyword-licensed codes inside the subject, leaving dates alone.
    ///
    /// Ranges are recomputed on the link-stripped subject so digits that left
    /// with a token URL are never considered. Licensing uses the combined
    /// subject-plus-body window, so a keyword in either half can license a
    /// subject code while an isolated year never qualifies.
    fileprivate static func redactSubjectCodes(subject: String, body: String) -> String {
        let combined = subject + "\n" + body
        let lower = combined.lowercased() as NSString
        let subjectLength = (subject as NSString).length
        let ranges = allCodeRanges(in: combined)
        var subjectRanges: [NSRange] = []
        for range in ranges {
            let start = max(0, range.location - codeWindowRadius)
            let end = min(lower.length, range.location + range.length + codeWindowRadius)
            guard end > start else { continue }
            let window = lower.substring(with: NSRange(location: start, length: end - start))
            guard codeKeywords.contains(where: { window.contains($0) }) else { continue }
            guard range.location + range.length <= subjectLength else { continue }
            subjectRanges.append(range)
        }
        guard !subjectRanges.isEmpty else { return subject }
        let mutable = NSMutableString(string: subject)
        let descendingRanges = subjectRanges.sorted(by: { $0.location > $1.location })
        for subjectRange in descendingRanges where subjectRange.location + subjectRange.length <= (mutable as NSString).length {
            mutable.replaceCharacters(in: subjectRange, with: redactedCodePlaceholder)
        }
        return mutable as String
    }
}
