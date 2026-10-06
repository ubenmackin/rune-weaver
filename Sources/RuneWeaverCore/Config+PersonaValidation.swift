// Rune Weaver Core — Workspace quota plus persona normalization validation.
//
// Extends the fail-closed `RuneWeaverConfig` validation with workspace quota
// bounds and persona normalization so the main validation file stays within
// the file-length budget while load-time and settings-PUT paths keep one
// shared range per field. Workspace quotas bound shell scratch growth;
// persona normalizers keep prompt-injected text single-line and bounded.

// swiftformat:disable extensionAccessControl

import Foundation

/// Single-sourced workspace quota validation shared by file-load and the
/// settings PUT so the two paths agree on fields and messages.
///
/// Quotas bound shell scratch so a stray download cannot fill the disk and a
/// quota walk cannot dominate a turn; the temp TTL bounds `tmp/` growth
/// without manual cleanup. Both the full-config check and per-field merge
/// validation route through these helpers so the ranges cannot drift.
public extension WorkspaceConfig {
    /// Validates the total size cap in megabytes.
    ///
    /// Bounds keep a trivially small scratch quota (which would fail the first
    /// write) or a host-scale quota from persisting through any write path.
    /// - Parameter quotaMB: Total bytes permitted under the workspace root, in megabytes.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when outside 10-10240.
    static func validateQuotaMB(_ quotaMB: Int) throws {
        if quotaMB < minQuotaMB || quotaMB > maxQuotaMB {
            throw ConfigError.validationError(
                field: "workspace.quota_mb",
                message: "must be between \(minQuotaMB) and \(maxQuotaMB) (got \(quotaMB))"
            )
        }
    }

    /// Validates the total file-count cap.
    ///
    /// Bounds keep the quota walk cheap: too few files makes the guard
    /// trivial while too many lets the walk dominate a shell turn.
    /// - Parameter quotaFiles: Total files permitted under the workspace root.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when outside 100-100000.
    static func validateQuotaFiles(_ quotaFiles: Int) throws {
        if quotaFiles < minQuotaFiles || quotaFiles > maxQuotaFiles {
            throw ConfigError.validationError(
                field: "workspace.quota_files",
                message: "must be between \(minQuotaFiles) and \(maxQuotaFiles) (got \(quotaFiles))"
            )
        }
    }

    /// Validates temp retention in days.
    ///
    /// Zero is the deliberate clear-on-boot posture, so the lower bound stays
    /// at zero while the upper bound keeps `tmp/` as scratch rather than
    /// long-term storage.
    /// - Parameter tmpTTLDays: Days `tmp/` entries survive before pruning.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when outside 0-90.
    static func validateTmpTTLDays(_ tmpTTLDays: Int) throws {
        if tmpTTLDays < minTmpTTLDays || tmpTTLDays > maxTmpTTLDays {
            throw ConfigError.validationError(
                field: "workspace.tmp_ttl_days",
                message: "must be between \(minTmpTTLDays) and \(maxTmpTTLDays) (got \(tmpTTLDays))"
            )
        }
    }
}

/// Normalize-or-reject enforcement shared by `[persona]` TOML decoding, JSON
/// decoding, and load-time validation so the entry paths agree on the
/// documented persona bounds without drifting on fields or messages.
///
/// Blank assistant names and overlong style guidance degrade deliberately —
/// neither can corrupt the prompt, the name falls back to the stock identity
/// and the style simply keeps its leading clause — each with a logged note so
/// the owner sees the silent fix. Shapes that cannot be repaired (an oversized
/// or unprintable name, an oversized owner name, an unknown tone or avatar
/// spelling) throw fail-closed with the dotted field path.
public extension PersonaConfig {
    /// Normalizes `assistant_name`.
    ///
    /// An absent or blank key falls back to the documented default with a
    /// logged note; a name that cannot fit the identity sentence (over the
    /// length bound or carrying control characters) throws, because a typo
    /// would otherwise render a broken "You are …" clause forever.
    /// - Parameters:
    ///   - raw: Raw configured value, nil when the key is absent.
    ///   - field: Dotted field name carried by the thrown error.
    /// - Returns: The trimmed usable assistant name.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when oversized or unprintable.
    static func normalizedAssistantName(_ raw: String?, field: String = "persona.assistant_name") throws -> String {
        guard let raw else { return defaultAssistantName }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            RuneWeaverLog.stores.warning(
                "PersonaConfig: blank \(field); falling back to default assistant name '\(defaultAssistantName)'"
            )
            return defaultAssistantName
        }
        if trimmed.count > maxAssistantNameLength {
            throw ConfigError.validationError(
                field: field,
                message: "must not exceed \(maxAssistantNameLength) characters (got \(trimmed.count))"
            )
        }
        // Control characters would splice the identity sentence across prompt
        // lines, so only printable text passes, mirroring the Host-gate rules.
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw ConfigError.validationError(
                field: field, message: "must contain only printable characters (got '\(trimmed)')"
            )
        }
        return trimmed
    }

    /// Parses `tone` against the closed preset set.
    ///
    /// An absent key keeps the default; an unknown string throws instead of
    /// silently picking a preset, matching the `[proactive] mode` posture.
    /// - Parameters:
    ///   - raw: Raw configured value, nil when the key is absent.
    ///   - field: Dotted field name carried by the thrown error.
    /// - Returns: The matching tone after trim and lowercase normalization.
    /// - Throws: ``ConfigError/validationError(field:message:)`` on any unknown spelling.
    static func normalizedTone(_ raw: String?, field: String = "persona.tone") throws -> PersonaTone {
        guard let raw else { return defaultTone }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let tone = PersonaTone(rawValue: lowered) else {
            throw ConfigError.validationError(
                field: field,
                message: "must be one of \(PersonaTone.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')"
            )
        }
        return tone
    }

    /// Normalizes `style`, squashing it to one control-free line and truncating
    /// overlong guidance.
    ///
    /// The shared single-line scrubber runs before the length bound because the
    /// composer injects this text verbatim: a multi-line or control-bearing
    /// value would otherwise splice the identity sentence across prompt lines.
    /// Truncation plus a logged note remains the documented fail-open posture:
    /// the leading clause carries the owner's intent, and a refusal would
    /// turn a stray paste into a boot failure for text that only decorates
    /// the identity sentence. The bound applies to the sanitized shape that
    /// actually reaches the prompt, and clean copy is untouched, so stored and
    /// keyed bytes match the composed bytes.
    /// - Parameters:
    ///   - raw: Raw configured value, nil when the key is absent.
    ///   - field: Dotted field name carried by the logged note.
    /// - Returns: The sanitized single-line style guidance, truncated to the documented bound when overlong.
    static func normalizedStyle(_ raw: String?, field: String = "persona.style") -> String {
        guard let raw else { return defaultStyle }
        let sanitized = NormalizedText.singleLineSanitized(raw)
        if sanitized.count > maxStyleLength {
            RuneWeaverLog.stores.warning(
                "PersonaConfig: \(field) exceeds \(maxStyleLength) characters (got \(sanitized.count)); truncating to the leading \(maxStyleLength)"
            )
            return String(sanitized.prefix(maxStyleLength))
        }
        return sanitized
    }

    /// Normalizes `user_name`.
    ///
    /// The shared single-line scrubber runs before the length bound so the
    /// address clause can never carry a line break or control byte into the
    /// prompt — the same splicing threat the assistant name refuses outright,
    /// repaired here because an owner name is display wording the composer
    /// injects verbatim. An absent or blank key keeps the address clause out of
    /// the prompt. An oversized name throws rather than truncating: unlike free
    /// prose, a cut name misrepresents the owner instead of just shortening
    /// advice, and the bound is checked on the sanitized shape so it constrains
    /// exactly what reaches the prompt.
    /// - Parameters:
    ///   - raw: Raw configured value, nil when the key is absent.
    ///   - field: Dotted field name carried by the thrown error.
    /// - Returns: The sanitized single-line owner name.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when oversized.
    static func normalizedUserName(_ raw: String?, field: String = "persona.user_name") throws -> String {
        guard let raw else { return defaultUserName }
        let sanitized = NormalizedText.singleLineSanitized(raw)
        if sanitized.count > maxUserNameLength {
            throw ConfigError.validationError(
                field: field,
                message: "must not exceed \(maxUserNameLength) characters (got \(sanitized.count))"
            )
        }
        return sanitized
    }

    /// Parses `avatar` against the closed accent set.
    ///
    /// An absent key keeps the default accent; an unknown string throws even
    /// though the value never reaches the prompt, so a typo surfaces with its
    /// field path instead of silently rendering the wrong color.
    /// - Parameters:
    ///   - raw: Raw configured value, nil when the key is absent.
    ///   - field: Dotted field name carried by the thrown error.
    /// - Returns: The matching avatar after trim and lowercase normalization.
    /// - Throws: ``ConfigError/validationError(field:message:)`` on any unknown spelling.
    static func normalizedAvatar(_ raw: String?, field: String = "persona.avatar") throws -> PersonaAvatar {
        guard let raw else { return defaultAvatar }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let avatar = PersonaAvatar(rawValue: lowered) else {
            throw ConfigError.validationError(
                field: field,
                message: "must be one of \(PersonaAvatar.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')"
            )
        }
        return avatar
    }
}

// swiftformat:enable extensionAccessControl
