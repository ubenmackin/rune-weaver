// Rune Weaver Core — TOML serialization for RuneWeaverConfig.

import Foundation

// MARK: - RuneWeaverConfig TOML Serialization

// swiftformat:disable extensionAccessControl

extension RuneWeaverConfig {
    /// Quotes a string for TOML output.
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
    public func renderTOML() -> String {
        var lines: [String] = ["# Rune Weaver configuration", ""]
        lines += renderEngineTOML()
        lines += renderServerTOML()
        lines += renderAuthTOML()
        lines += renderLLMTOML()
        lines += renderServicesTOML()
        lines += renderFilesTOML()
        lines += renderIndexTOML()
        lines += renderBrowserTOML()
        lines += renderEmailTOML()
        lines += renderHomeTOML()
        lines += renderSchedulerTOML()
        lines += renderPluginsTOML()
        lines += renderMediaTOML()
        lines += renderDesktopTOML()
        lines += renderSecurityTOML()
        return lines.joined(separator: "\n")
    }

    private func renderEngineTOML() -> [String] {
        [
            "[engine]",
            "name = \(Self.tomlQuoted(engine.name))",
            "log_level = \(Self.tomlQuoted(engine.logLevel))",
            "compaction_threshold_percent = \(engine.compactionThresholdPercent)",
            "max_tool_iterations = \(engine.maxToolIterations)",
            ""
        ]
    }

    private func renderServerTOML() -> [String] {
        [
            "[server]",
            "hostname = \(Self.tomlQuoted(server.hostname))",
            "port = \(server.port)",
            ""
        ]
    }

    private func renderAuthTOML() -> [String] {
        var lines = ["[auth]"]
        // Only declared source names render. The token value is never a TOML
        // key, and unset sources stay omitted so a round-trip cannot invent a
        // blank entry that would read as configured.
        if let tokenEnv = auth.tokenEnv, !tokenEnv.isEmpty {
            lines.append("token_env = \(Self.tomlQuoted(tokenEnv))")
        }
        if let tokenFile = auth.tokenFile, !tokenFile.isEmpty {
            lines.append("token_file = \(Self.tomlQuoted(tokenFile))")
        }
        lines.append("")
        return lines
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
            // Persist prefix-reuse knobs only when set so older files round-trip
            // without new keys and small `--parallel` servers keep auto-assign.
            if let slotCount = entry.slotCount {
                lines.append("slot_count = \(slotCount)")
            }
            if let cachePrompt = entry.cachePrompt {
                lines.append("cache_prompt = \(cachePrompt ? "true" : "false")")
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
            "container_base_image = \(Self.tomlQuoted(sandbox.containerBaseImage))",
            "archive_session_ttl_minutes = \(sandbox.archiveSessionTTLMinutes)",
            "max_concurrent_machines = \(sandbox.maxConcurrentMachines)",
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

    private func renderIndexTOML() -> [String] {
        // Every key renders, including the disabled default, so a saved file
        // documents the full indexer policy and a round-trip never depends on
        // an implicit default silently diverging from what was written.
        [
            "[index]",
            "enabled = \(index.enabled ? "true" : "false")",
            "files = \(index.files ? "true" : "false")",
            "mail = \(index.mail ? "true" : "false")",
            "messages = \(index.messages ? "true" : "false")",
            "roots = \(Self.tomlStringArray(index.roots))",
            "exclude = \(Self.tomlStringArray(index.exclude))",
            "max_file_mb = \(index.maxFileMB)",
            "mail_vector_window = \(Self.tomlQuoted(index.mailVectorWindow))",
            "icloud_evicted = \(Self.tomlQuoted(index.iCloudEvicted))",
            "describe_images_with_llm = \(index.describeImagesWithLLM ? "true" : "false")",
            "nightly_budget = \(index.nightlyBudget)",
            "db_path = \(Self.tomlQuoted(index.dbPath))",
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

    private func renderBrowserTOML() -> [String] {
        [
            "[browser]",
            "searxng_url = \(Self.tomlQuoted(browser.searxngURL))",
            "search_timeout_seconds = \(browser.searchTimeoutSeconds)",
            "max_results = \(browser.maxResults)",
            "allowed_origins = \(Self.tomlStringArray(browser.allowedOrigins))",
            ""
        ]
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

    private func renderMediaTOML() -> [String] {
        var lines: [String] = []
        lines += renderArrSection(name: "sonarr", config: media.sonarr, defaultAPIKeyEnv: ArrInstanceConfig.defaultSonarrAPIKeyEnv)
        lines += renderArrSection(name: "radarr", config: media.radarr, defaultAPIKeyEnv: ArrInstanceConfig.defaultRadarrAPIKeyEnv)
        return lines
    }

    /// Renders one `[media.<service>]` section, or nothing when stock.
    ///
    /// The `isCustomized` gate is the single persistence decision so blank-vs-nil
    /// cannot diverge between "should I write" and "what do I write": blanks read
    /// as absent on both paths, and a nil/blank/default key name all read as stock
    /// (the client falls back to the conventional name), collapsing to omitted
    /// rather than emitting a section that would decode back as default.
    private func renderArrSection(name: String, config: ArrInstanceConfig, defaultAPIKeyEnv: String) -> [String] {
        guard config.isCustomized(defaultAPIKeyEnv: defaultAPIKeyEnv) else { return [] }
        var lines: [String] = [
            "[media.\(name)]",
            "enabled = \(config.enabled ? "true" : "false")"
        ]
        if let url = NormalizedText.value(config.url) {
            lines.append("url = \(Self.tomlQuoted(url))")
        }
        // Emitted even when it matches the conventional name so a customized
        // section stays explicit; an omitted key decodes back to stock, which is
        // why nil and default intentionally share the omitted form.
        if let apiKeyEnv = NormalizedText.value(config.apiKeyEnv) {
            lines.append("api_key_env = \(Self.tomlQuoted(apiKeyEnv))")
        }
        if let profile = NormalizedText.value(config.defaultQualityProfile) {
            lines.append("default_quality_profile = \(Self.tomlQuoted(profile))")
        }
        if let folder = NormalizedText.value(config.defaultRootFolder) {
            lines.append("default_root_folder = \(Self.tomlQuoted(folder))")
        }
        lines.append("")
        return lines
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

    private func renderDesktopTOML() -> [String] {
        var lines = ["[desktop]"]
        lines.append("max_image_dimension = \(desktop.maxImageDimension)")
        lines.append("jpeg_quality = \(desktop.jpegQuality)")
        lines.append("blocked_apps = [\(desktop.blockedApps.map { Self.tomlQuoted($0) }.joined(separator: ", "))]")
        lines.append("")
        return lines
    }

    /// Renders the additive `[security]` section.
    ///
    /// Every key renders, including the default-ON values, so a saved file
    /// documents the defense policy and a round-trip never depends on an
    /// implicit default silently diverging from what was written.
    private func renderSecurityTOML() -> [String] {
        [
            "[security]",
            "untrusted_labeling = \(security.untrustedLabeling ? "true" : "false")",
            "email_credential_filter = \(security.emailCredentialFilter ? "true" : "false")",
            ""
        ]
    }
}

// swiftformat:enable extensionAccessControl
