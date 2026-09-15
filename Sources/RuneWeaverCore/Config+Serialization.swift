// Rune Weaver Core — TOML serialization for RuneWeaverConfig.
//
// Renders the validated configuration back to a canonical config.toml
// document so bootstrap seeds, migrations, and dashboard edits round-trip
// without drift. Emits spec-valid quoted strings and stable section order
// so serialized output always reparses to an equivalent snapshot.

import Foundation

// MARK: - RuneWeaverConfig TOML Serialization

// swiftformat:disable extensionAccessControl

extension RuneWeaverConfig {
    /// Quotes a string for TOML output.
    ///
    /// Control characters use spec-valid basic-string escapes so rendered
    /// values always reparse instead of emitting raw control bytes.
    public static func tomlQuoted(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if character.unicodeScalars.count == 1,
                   let scalar = character.unicodeScalars.first,
                   scalar.value < 0x20
                {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.append(character)
                }
            }
        }
        out += "\""
        return out
    }

    /// Renders this configuration as canonical TOML.
    ///
    /// Providers sort by name so repeated saves stay diff-stable; only
    /// `api_key_env` names persist (secret values resolve at runtime via
    /// `SecretsManager`), email accounts persist identity fields only, and
    /// home integrations persist with `token_env` names only.
    public func renderTOML() -> String {
        var lines: [String] = ["# Rune Weaver configuration", ""]
        lines += renderEngineTOML()
        lines += renderLLMTOML()
        lines += renderServicesTOML()
        lines += renderFilesTOML()
        lines += renderEmailTOML()
        lines += renderHomeTOML()
        lines += renderSchedulerTOML()
        lines += renderPluginsTOML()
        return lines.joined(separator: "\n")
    }

    private func renderEngineTOML() -> [String] {
        [
            "[engine]",
            "name = \(Self.tomlQuoted(engine.name))",
            "log_level = \(Self.tomlQuoted(engine.logLevel))",
            ""
        ]
    }

    private func renderLLMTOML() -> [String] {
        var lines: [String] = [
            "[llm]",
            "default_provider = \(Self.tomlQuoted(llm.defaultProvider))"
        ]
        if let fallback = llm.fallbackProvider, !fallback.isEmpty {
            lines.append("fallback_provider = \(Self.tomlQuoted(fallback))")
        }
        lines.append("")
        for name in llm.providers.keys.sorted() {
            guard let entry = llm.providers[name] else { continue }
            lines.append("[llm.providers.\(name)]")
            lines.append("enabled = \(entry.enabled ? "true" : "false")")
            if let model = entry.model, !model.isEmpty {
                lines.append("model = \(Self.tomlQuoted(model))")
            }
            if let serverURL = entry.serverURL, !serverURL.isEmpty {
                lines.append("server_url = \(Self.tomlQuoted(serverURL))")
            }
            if let apiKeyEnv = entry.apiKeyEnv, !apiKeyEnv.isEmpty {
                lines.append("api_key_env = \(Self.tomlQuoted(apiKeyEnv))")
            }
            if let providerType = entry.providerType, !providerType.isEmpty {
                lines.append("provider_type = \(Self.tomlQuoted(providerType))")
            }
            lines.append("api_style = \(Self.tomlQuoted(entry.apiStyle.rawValue))")
            if let contextLength = entry.contextLength {
                lines.append("context_length = \(contextLength)")
            }
            lines.append("")
        }
        return lines
    }

    private func renderServicesTOML() -> [String] {
        [
            "[memory]",
            "vector_db_path = \(Self.tomlQuoted(memory.vectorDBPath))",
            "episodes_db_path = \(Self.tomlQuoted(memory.episodesDBPath))",
            "embedding_model = \(Self.tomlQuoted(memory.embeddingModel))",
            "embedding_backend = \(Self.tomlQuoted(memory.embeddingBackend))",
            "",
            "[voice]",
            "stt_provider = \(Self.tomlQuoted(voice.sttProvider))",
            "whisper_model = \(Self.tomlQuoted(voice.whisperModel))",
            "tts_provider = \(Self.tomlQuoted(voice.ttsProvider))",
            "",
            "[sandbox]",
            "staging_path = \(Self.tomlQuoted(sandbox.stagingPath))",
            "retention_days = \(sandbox.retentionDays)",
            "max_total_bytes = \(sandbox.maxTotalBytes)",
            "cleanup_interval_seconds = \(sandbox.cleanupIntervalSeconds)",
            ""
        ]
    }

    private func renderFilesTOML() -> [String] {
        // Lists render as inline TOML arrays so the minimal parser can
        // re-read them without a full array-table implementation; each
        // element is quoted to survive spaces and glob characters.
        [
            "[files]",
            "deny_patterns = \(Self.tomlStringArray(files.denyPatterns))",
            "allow_roots = \(Self.tomlStringArray(files.allowRoots))",
            "require_approval_on_deny = \(files.requireApprovalOnDeny ? "true" : "false")",
            ""
        ]
    }

    /// Renders a string list as an inline TOML array.
    /// - Parameter values: Elements to quote and join.
    /// - Returns: Inline array document (e.g. `["a", "b"]` or `[]`).
    private static func tomlStringArray(_ values: [String]) -> String {
        guard !values.isEmpty else { return "[]" }
        return "[" + values.map { tomlQuoted($0) }.joined(separator: ", ") + "]"
    }

    private func renderEmailTOML() -> [String] {
        var lines: [String] = []
        for account in email.accounts {
            lines.append("[[email.accounts]]")
            lines.append("name = \(Self.tomlQuoted(account.name))")
            lines.append("type = \(Self.tomlQuoted(account.type))")
            lines.append("host = \(Self.tomlQuoted(account.host))")
            lines.append("port = \(account.port)")
            lines.append("username = \(Self.tomlQuoted(account.username))")
            if let smtpHost = account.smtpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !smtpHost.isEmpty {
                lines.append("smtp_host = \(Self.tomlQuoted(smtpHost))")
            }
            if let smtpPort = account.smtpPort {
                lines.append("smtp_port = \(smtpPort)")
            }
            if account.smtpSecurity != .auto {
                lines.append("smtp_security = \(Self.tomlQuoted(account.smtpSecurity.rawValue))")
            }
            lines.append("")
        }
        return lines
    }

    private func renderHomeTOML() -> [String] {
        // Home integrations persist in array order (order is user intent,
        // not a map, so no sorting). Only `token_env` names persist; token
        // values resolve at runtime via `SecretsManager` and never touch TOML.
        var lines: [String] = []
        for entry in home.homekit {
            lines.append("[[home.homekit]]")
            lines.append("enabled = \(entry.enabled ? "true" : "false")")
            lines.append("")
        }
        for entry in home.homeAssistant {
            lines.append("[[home.home_assistant]]")
            lines.append("enabled = \(entry.enabled ? "true" : "false")")
            if let url = entry.url, !url.isEmpty {
                lines.append("url = \(Self.tomlQuoted(url))")
            }
            if let tokenEnv = entry.tokenEnv, !tokenEnv.isEmpty {
                lines.append("token_env = \(Self.tomlQuoted(tokenEnv))")
            }
            lines.append("")
        }
        return lines
    }

    private func renderSchedulerTOML() -> [String] {
        var lines: [String] = []
        for job in scheduler.jobs {
            lines.append("[[scheduler.jobs]]")
            lines.append("name = \(Self.tomlQuoted(job.name))")
            lines.append("prompt = \(Self.tomlQuoted(job.prompt))")
            lines.append("enabled = \(job.enabled ? "true" : "false")")
            if let schedule = job.schedule, !schedule.isEmpty {
                lines.append("schedule = \(Self.tomlQuoted(schedule))")
            }
            if let poll = job.poll {
                lines.append("poll_account = \(Self.tomlQuoted(poll.account))")
                lines.append("poll_query = \(Self.tomlQuoted(poll.query))")
                if let mailbox = poll.mailbox, !mailbox.isEmpty {
                    lines.append("poll_mailbox = \(Self.tomlQuoted(mailbox))")
                }
                lines.append("poll_interval_seconds = \(poll.pollIntervalSeconds)")
                lines.append("poll_limit = \(poll.limit)")
            }
            lines.append("")
        }
        return lines
    }

    private func renderPluginsTOML() -> [String] {
        [
            "[plugins]",
            "plugins_dir = \(Self.tomlQuoted(plugins.pluginsDir))",
            "marketplace_index_url = \(Self.tomlQuoted(plugins.marketplaceIndexURL))",
            "auto_rescan = \(plugins.autoRescan ? "true" : "false")",
            ""
        ]
    }

    /// Saves and validates the configuration to a file URL.
    /// Creates a `.bak` backup file if the target already exists,
    /// and atomically replaces the file.
    public func save(to fileURL: URL? = nil) throws {
        let url = fileURL ?? Self.defaultConfigFileURL()
        try validate()
        let tomlText = renderTOML()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("bak")
            // Stale backup removal is best-effort; a missing backup is
            // expected on first save so its failure never blocks the write.
            try? FileManager.default.removeItem(at: backupURL)
            // The backup must succeed before overwriting so a copy failure
            // never leaves the config replaced without a recovery copy.
            try FileManager.default.copyItem(at: url, to: backupURL)
        }
        try tomlText.write(to: url, atomically: true, encoding: .utf8)
    }
}

// swiftformat:enable extensionAccessControl
