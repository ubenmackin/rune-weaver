// Rune Weaver Core — Workspace quota plus persona normalization validation.

// swiftformat:disable extensionAccessControl

import Foundation

/// Single-sourced workspace quota validation shared by file-load and the settings PUT so the two
/// paths agree on fields and messages.
public extension WorkspaceConfig {
    /// Validates the total size cap in megabytes. Bounds keep a trivially small scratch quota
    /// (which would fail the first write) or a host-scale quota from persisting through any write
    /// path.
    static func validateQuotaMB(_ quotaMB: Int) throws {
        if quotaMB < minQuotaMB || quotaMB > maxQuotaMB {
            throw ConfigError.validationError(
                field: "workspace.quota_mb",
                message: "must be between \(minQuotaMB) and \(maxQuotaMB) (got \(quotaMB))"
            )
        }
    }

    /// Validates the total file-count cap. Bounds keep the quota walk cheap: too few files makes
    /// the guard trivial while too many lets the walk dominate a shell turn.
    static func validateQuotaFiles(_ quotaFiles: Int) throws {
        if quotaFiles < minQuotaFiles || quotaFiles > maxQuotaFiles {
            throw ConfigError.validationError(
                field: "workspace.quota_files",
                message: "must be between \(minQuotaFiles) and \(maxQuotaFiles) (got \(quotaFiles))"
            )
        }
    }

    /// Validates temp retention in days. Zero is the deliberate clear-on-boot posture, so the lower
    /// bound stays at zero while the upper bound keeps `tmp/` as scratch rather than long-term
    /// storage.
    static func validateTmpTTLDays(_ tmpTTLDays: Int) throws {
        if tmpTTLDays < minTmpTTLDays || tmpTTLDays > maxTmpTTLDays {
            throw ConfigError.validationError(
                field: "workspace.tmp_ttl_days",
                message: "must be between \(minTmpTTLDays) and \(maxTmpTTLDays) (got \(tmpTTLDays))"
            )
        }
    }
}

/// Normalize-or-reject enforcement shared by `[persona]` TOML decoding, JSON decoding, and
/// load-time validation so the entry paths agree on the documented persona bounds without drifting
/// on fields or messages.
public extension PersonaConfig {
    /// Normalizes `assistant_name`.
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

    /// Normalizes `style`, squashing it to one control-free line and truncating overlong guidance.
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
