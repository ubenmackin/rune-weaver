// Rune Weaver Core — Fail-closed validation for RuneWeaverConfig.

import Foundation

// MARK: - RuneWeaverConfig Validation

// swiftformat:disable extensionAccessControl

extension RuneWeaverConfig {
    /// Validates every section, throwing a descriptive error on failure.
    /// - Throws: ``ConfigError/validationError(field:message:)`` or
    ///   ``ConfigError/missingRequired(field:)``.
    public func validate() throws {
        try validateEngineSection()
        try validateLLMSection()
        try validateMemorySection()
        try validateVoiceSection()
        try validateSandboxSection()
        try validateFilesSection()
        try validateBrowserSection()
        try validateEmailSection()
        try validateHomeSection()
        try validateSchedulerSection()
        try validatePluginsSection()
    }

    private func validateEngineSection() throws {
        if engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: "engine.name", message: "must not be empty")
        }
        let allowedLevels = ["trace", "debug", "info", "notice", "warning", "error", "critical"]
        if !allowedLevels.contains(engine.logLevel.lowercased()) {
            throw ConfigError.validationError(
                field: "engine.log_level",
                message: "must be one of \(allowedLevels.joined(separator: ", "))"
            )
        }
        if engine.compactionThresholdPercent < 10 || engine.compactionThresholdPercent > 100 {
            throw ConfigError.validationError(
                field: "engine.compaction_threshold_percent",
                message: "must be between 10 and 100 (got \(engine.compactionThresholdPercent))"
            )
        }
        if engine.maxToolIterations < 1 || engine.maxToolIterations > 100 {
            throw ConfigError.validationError(
                field: "engine.max_tool_iterations",
                message: "must be between 1 and 100 (got \(engine.maxToolIterations))"
            )
        }
    }

    private func validateLLMSection() throws {
        if llm.defaultProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.missingRequired(field: "llm.default_provider")
        }
        if let fallback = llm.fallbackProvider,
           fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ConfigError.validationError(
                field: "llm.fallback_provider", message: "must not be empty when set"
            )
        }
        guard llm.providers[llm.defaultProvider] != nil else {
            throw ConfigError.validationError(
                field: "llm.default_provider",
                message: "unknown provider '\(llm.defaultProvider)' (missing [llm.providers.\(llm.defaultProvider)])"
            )
        }
        if let fallback = llm.fallbackProvider {
            guard llm.providers[fallback] != nil else {
                throw ConfigError.validationError(
                    field: "llm.fallback_provider",
                    message: "unknown provider '\(fallback)' (missing [llm.providers.\(fallback)])"
                )
            }
        }
        for (name, provider) in llm.providers {
            try validateProvider(provider, name: name)
        }
    }

    private func validateProvider(_ provider: ProviderConfig, name: String) throws {
        // Provider names render as bare `[llm.providers.<name>]` segments
        // where dots or whitespace would fork the table path, so only
        // TOML bare-key characters are accepted.
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw ConfigError.validationError(
                field: "llm.providers.\(name)", message: "must match [A-Za-z0-9_-]+ (got '\(name)')"
            )
        }
        let prefix = "llm.providers.\(name)"
        if let model = provider.model, model.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).model", message: "must not be empty when set"
            )
        }
        if let length = provider.contextLength, length <= 0 {
            throw ConfigError.validationError(
                field: "\(prefix).context_length", message: "must be positive"
            )
        }
        // Sticky ids outside the server's slot pool are rejected, so a
        // non-positive pool can never pin safely and fails at load instead
        // of mid-turn.
        if let slotCount = provider.slotCount, slotCount <= 0 {
            throw ConfigError.validationError(
                field: "\(prefix).slot_count", message: "must be positive"
            )
        }
        if let serverURL = provider.serverURL {
            try Self.validateURLField(serverURL, field: "\(prefix).server_url")
        }
        if let env = provider.apiKeyEnv, env.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).api_key_env", message: "must not be empty when set"
            )
        }
        if let type = provider.providerType, type.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).provider_type", message: "must not be empty when set"
            )
        }
    }

    private func validateMemorySection() throws {
        if memory.vectorDBPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "memory.vector_db_path", message: "must not be empty"
            )
        }
        if memory.episodesDBPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "memory.episodes_db_path", message: "must not be empty"
            )
        }
        if memory.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "memory.embedding_model", message: "must not be empty"
            )
        }
        // Closed backend set keeps recall behavior predictable: unknown
        // strings would silently pick a path, so they fail with the field
        // name just like the neighboring `embedding_model` check.
        let allowedBackends = MemoryConfig.allowedEmbeddingBackends
        if !allowedBackends.contains(memory.embeddingBackend) {
            throw ConfigError.validationError(
                field: "memory.embedding_backend",
                message: "must be one of \(allowedBackends.joined(separator: ", ")) (got '\(memory.embeddingBackend)')"
            )
        }
    }

    private func validateVoiceSection() throws {
        if voice.sttProvider.isEmpty {
            throw ConfigError.validationError(
                field: "voice.stt_provider", message: "must not be empty"
            )
        }
        if voice.whisperModel.isEmpty {
            throw ConfigError.validationError(
                field: "voice.whisper_model", message: "must not be empty"
            )
        }
        if voice.ttsProvider.isEmpty {
            throw ConfigError.validationError(
                field: "voice.tts_provider", message: "must not be empty"
            )
        }
    }

    private func validateSandboxSection() throws {
        if sandbox.containerBaseImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "sandbox.container_base_image", message: "must not be empty"
            )
        }
        if sandbox.archiveSessionTTLMinutes <= 0 || sandbox.archiveSessionTTLMinutes > 1440 {
            throw ConfigError.validationError(
                field: "sandbox.archive_session_ttl_minutes", message: "must be between 1 and 1440"
            )
        }
        if sandbox.maxConcurrentMachines <= 0 {
            throw ConfigError.validationError(
                field: "sandbox.max_concurrent_machines", message: "must be positive"
            )
        }
    }

    private func validateFilesSection() throws {
        try Self.validateFilesPatterns(files.denyPatterns, field: "files.deny_patterns")
        try Self.validateFilesPatterns(files.allowRoots, field: "files.allow_roots")
    }

    private func validateBrowserSection() throws {
        // Fail closed on a blank or relative SearXNG URL so search never
        // fans out to an unintended host; range checks mirror the mail
        // search caps so context budgets stay predictable. Only http/https
        // pass here so `ftp:`/`file:`-adjacent values fail at config load
        // instead of later in `searchRequest` via `WebURLSafety`.
        try Self.validateHTTPURLField(browser.searxngURL, field: "browser.searxng_url")
        if browser.searchTimeoutSeconds < 1 || browser.searchTimeoutSeconds > 120 {
            throw ConfigError.validationError(
                field: "browser.search_timeout_seconds", message: "must be between 1 and 120"
            )
        }
        if browser.maxResults < 1 || browser.maxResults > BrowserConfig.maxAllowedResults {
            throw ConfigError.validationError(
                field: "browser.max_results",
                message: "must be between 1 and \(BrowserConfig.maxAllowedResults)"
            )
        }
    }

    /// Validates one files list for blank entries and directory escapes.
    public static func validateFilesPatterns(_ patterns: [String], field: String) throws {
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw ConfigError.validationError(field: field, message: "must not contain empty patterns")
            }
            if trimmed.contains("..") {
                throw ConfigError.validationError(
                    field: field, message: "must not contain '..' (got '\(pattern)')"
                )
            }
        }
    }

    /// SMTP submission ports the send path can actually dial.
    private static var allowedSMTPPorts: Set<Int> {
        EmailConfig.allowedSubmissionPorts
    }

    private func validateEmailSection() throws {
        for account in email.accounts {
            try validateEmailAccount(account)
        }
    }

    private func validateEmailAccount(_ account: EmailAccount) throws {
        let prefix = "email.accounts[\(account.name)]"
        if account.name.isEmpty {
            throw ConfigError.validationError(
                field: "email.accounts.name", message: "must not be empty"
            )
        }
        if account.host.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).host", message: "must not be empty"
            )
        }
        if account.username.isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).username", message: "must not be empty"
            )
        }
        if account.port < 1 || account.port > 65535 {
            throw ConfigError.validationError(
                field: "\(prefix).port", message: "must be between 1 and 65535"
            )
        }
        if let smtpHost = account.smtpHost, smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "\(prefix).smtp_host", message: "must not be empty when set"
            )
        }
        if let smtpPort = account.smtpPort, !Self.allowedSMTPPorts.contains(smtpPort) {
            throw ConfigError.validationError(
                field: "\(prefix).smtp_port",
                message: "must be one of \(Self.allowedSMTPPorts.sorted().map(String.init).joined(separator: ", ")) (got \(smtpPort))"
            )
        }
    }

    private func validateHomeSection() throws {
        for entry in home.homeAssistant {
            if let url = entry.url {
                try Self.validateURLField(url, field: "home.home_assistant.url")
            }
            if let env = entry.tokenEnv, env.isEmpty {
                throw ConfigError.validationError(
                    field: "home.home_assistant.token_env",
                    message: "must not be empty when set"
                )
            }
        }
    }

    private func validateSchedulerSection() throws {
        do {
            try scheduler.validate()
        } catch let error as SchedulerConfigError {
            throw Self.mapSchedulerConfigError(error)
        }
    }

    private func validatePluginsSection() throws {
        if plugins.pluginsDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: "plugins.plugins_dir", message: "must not be empty")
        }
    }

    private static func mapSchedulerConfigError(_ error: SchedulerConfigError) -> ConfigError {
        // Single-sourced via `SchedulerConfigError/displayDetail` and
        // `fieldSuffix` so config and store messages/fields cannot drift.
        if error.jobName == nil {
            return ConfigError.validationError(
                field: "scheduler.jobs.name", message: error.displayDetail
            )
        }
        if case .duplicateName = error {
            return ConfigError.validationError(
                field: "scheduler.jobs.name", message: error.displayDetail
            )
        }
        guard let job = error.jobName else {
            return ConfigError.validationError(
                field: "scheduler.jobs.name", message: error.displayDetail
            )
        }
        let prefix = "scheduler.jobs[\(normalizedSchedulerJobName(job))]"
        if let suffix = error.fieldSuffix {
            return ConfigError.validationError(
                field: "\(prefix).\(suffix)", message: error.displayDetail
            )
        }
        return ConfigError.validationError(field: prefix, message: error.displayDetail)
    }

    private static func validateURLField(_ value: String, field: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: field, message: "must not be empty when set")
        }
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            throw ConfigError.validationError(
                field: field, message: "must be an absolute URL (e.g. http://localhost:8080)"
            )
        }
    }

    /// Validates an http(s) URL field, rejecting non-web schemes fail-closed.
    private static func validateHTTPURLField(_ value: String, field: String) throws {
        try validateURLField(value, field: field)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ConfigError.validationError(
                field: field, message: "must be an absolute http(s) URL (e.g. http://127.0.0.1:8888)"
            )
        }
    }
}

// swiftformat:enable extensionAccessControl
