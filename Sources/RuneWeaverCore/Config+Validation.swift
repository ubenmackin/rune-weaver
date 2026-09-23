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
        try validateServerSection()
        try validateAuthSection()
        try validateLLMSection()
        try validateMemorySection()
        try validateVoiceSection()
        try validateSandboxSection()
        try validateFilesSection()
        try validateIndexSection()
        try validateBrowserSection()
        try validateEmailSection()
        try validateHomeSection()
        try validateSchedulerSection()
        try validatePluginsSection()
        try validateMediaSection()
        try validateDesktopSection()
        try validateSecuritySection()
        try validateGoalsSection()
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

    private func validateServerSection() throws {
        if server.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: "server.hostname", message: "must not be empty")
        }
        // Mirrors `ServerConfig.validPortRange` without linking the server
        // transport into the config layer, so a bad port fails at load.
        if server.port < 1 || server.port > 65535 {
            throw ConfigError.validationError(
                field: "server.port", message: "must be between 1 and 65535"
            )
        }
    }

    private func validateAuthSection() throws {
        // Fail closed on blank source names: a whitespace typo must not read as
        // a configured credential for a non-loopback bind.
        if let env = auth.tokenEnv, env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: "auth.token_env", message: "must not be empty when set")
        }
        if let file = auth.tokenFile, file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: "auth.token_file", message: "must not be empty when set")
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

    private func validateIndexSection() throws {
        // Roots and excludes share the files-guard rules so a `..` escape or a
        // blank entry fails at load rather than widening the walk at runtime.
        try Self.validateFilesPatterns(index.roots, field: "index.roots")
        try Self.validateFilesPatterns(index.exclude, field: "index.exclude")
        if index.maxFileMB < 1 || index.maxFileMB > IndexConfig.maxAllowedFileMB {
            throw ConfigError.validationError(
                field: "index.max_file_mb",
                message: "must be between 1 and \(IndexConfig.maxAllowedFileMB) (got \(index.maxFileMB))"
            )
        }
        // Closed window set keeps the vector store bounded; a typo would
        // otherwise silently widen to an unintended span.
        if !IndexConfig.allowedMailVectorWindows.contains(index.mailVectorWindow) {
            throw ConfigError.validationError(
                field: "index.mail_vector_window",
                message: "must be one of \(IndexConfig.allowedMailVectorWindows.joined(separator: ", ")) (got '\(index.mailVectorWindow)')"
            )
        }
        // Closed eviction set keeps network downloads an explicit decision.
        if !IndexConfig.allowedICloudEvictions.contains(index.iCloudEvicted) {
            throw ConfigError.validationError(
                field: "index.icloud_evicted",
                message: "must be one of \(IndexConfig.allowedICloudEvictions.joined(separator: ", ")) (got '\(index.iCloudEvicted)')"
            )
        }
        if index.nightlyBudget < 0 || index.nightlyBudget > IndexConfig.maxAllowedNightlyBudget {
            throw ConfigError.validationError(
                field: "index.nightly_budget",
                message: "must be between 0 and \(IndexConfig.maxAllowedNightlyBudget) (got \(index.nightlyBudget))"
            )
        }
        if index.dbPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "index.db_path", message: "must not be empty"
            )
        }
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
        for origin in browser.allowedOrigins {
            try Self.validateAllowedOrigin(origin)
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

    /// Validates one `browser.allowed_origins` entry against the same host semantics the guard enforces.
    /// A universal `*` would silently disable SSRF vetting, path-scoped URLs would silently
    /// broaden to their whole host, and control bytes or misplaced wildcards would never match
    /// yet look authorized, so each shape fails closed here with the entry echoed for repair.
    private static func validateAllowedOrigin(_ origin: String) throws {
        let field = "browser.allowed_origins"
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConfigError.validationError(field: field, message: "must not contain empty strings")
        }
        let lowered = trimmed.lowercased()
        if AllowedOriginPattern.isBareUniversal(lowered) {
            throw ConfigError.validationError(
                field: field, message: "must not contain \"*\" (would allow every host)"
            )
        }
        if AllowedOriginPattern.isUniversalWildcardShape(lowered) {
            throw ConfigError.validationError(
                field: field, message: "must not contain universal wildcard pattern '\(origin)'"
            )
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw ConfigError.validationError(
                field: field, message: "must not contain control characters (got '\(origin)')"
            )
        }
        if trimmed.contains(" ") || trimmed.contains("\t") {
            // Internal whitespace never survives URL parsing, so the entry could never
            // match yet would read as configured; fail closed instead of ignoring it.
            throw ConfigError.validationError(
                field: field, message: "must not contain whitespace (got '\(origin)')"
            )
        }
        if trimmed.count > 2048 {
            throw ConfigError.validationError(
                field: field, message: "must not exceed 2048 characters (got \(trimmed.count))"
            )
        }
        if lowered.contains("://") {
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
            else {
                throw ConfigError.validationError(
                    field: field, message: "URL entries must be absolute http(s) URLs with a host (got '\(origin)')"
                )
            }
            // Credentials never belong in the config file: userinfo would persist
            // secrets in plaintext and diverge from the Keychain-backed contract,
            // so any URL entry carrying it fails closed here.
            if url.user != nil || url.password != nil || trimmed.contains("@") {
                throw ConfigError.validationError(
                    field: field,
                    message: "URL entries must not contain userinfo (got '\(origin)')"
                )
            }
            // A path-scoped entry never constrains the guard to that path: matching is
            // origin/host only, so accepting it would silently broaden to the whole host.
            let path = url.path
            if !path.isEmpty, path != "/" {
                throw ConfigError.validationError(
                    field: field,
                    message: "URL entries must not carry a path (got '\(origin)'); list the host instead"
                )
            }
            if url.query != nil || url.fragment != nil {
                throw ConfigError.validationError(
                    field: field,
                    message: "URL entries must not carry a query or fragment (got '\(origin)')"
                )
            }
            return
        }
        if trimmed.contains("@") {
            // A bare entry with userinfo would allowlist a different host than
            // written once the guard parses it, so it fails closed here.
            throw ConfigError.validationError(
                field: field, message: "must not contain userinfo (got '\(origin)')"
            )
        }
        if trimmed.contains("/") || trimmed.contains("?") || trimmed.contains("#") {
            throw ConfigError.validationError(
                field: field, message: "must be a host, host:port, wildcard, or http(s) URL without a path (got '\(origin)')"
            )
        }
        if trimmed.contains("[") || trimmed.contains("]") {
            // Bracketed IPv6 literals (`[::1]`, `[fe80::1]:8080`) are legitimate hosts;
            // other bracket use belongs to file globs and stays denied.
            let isBracketedIPv6 = (trimmed.hasPrefix("[") && trimmed.contains("]:")) || (
                trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.contains(":")
            )
            if !isBracketedIPv6 {
                throw ConfigError.validationError(
                    field: field, message: "must not contain glob syntax (got '\(origin)')"
                )
            }
        }
        // Wildcard shape stays single-sourced with the SSRF matcher so the two
        // cannot drift on which edge patterns are dialable. Port-qualified
        // wildcards fail through the shared classifier, leaving exact
        // `host:port` to the origin-key check.
        switch AllowedOriginPattern.classifyWildcard(lowered) {
        case .none, .leading, .trailing:
            break
        case .invalidShape:
            throw ConfigError.validationError(
                field: field,
                message: "wildcards must be a single leading \"*.\" or trailing \".*\" (got '\(origin)')"
            )
        case .invalidSuffix:
            throw ConfigError.validationError(
                field: field, message: "wildcard suffix must name a host (got '\(origin)')"
            )
        case .invalidStem:
            throw ConfigError.validationError(
                field: field, message: "wildcard prefix must name a host or IP stem (got '\(origin)')"
            )
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

    private func validateMediaSection() throws {
        if let sonarrURL = media.sonarr.url, !sonarrURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Self.validateHTTPURLField(sonarrURL, field: "media.sonarr.url")
        }
        if let radarrURL = media.radarr.url, !radarrURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Self.validateHTTPURLField(radarrURL, field: "media.radarr.url")
        }
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

    private func validateDesktopSection() throws {
        if desktop.maxImageDimension < 256 || desktop.maxImageDimension > DesktopConfig.maxAllowedImageDimension {
            throw ConfigError.validationError(
                field: "desktop.max_image_dimension",
                message: "must be between 256 and \(DesktopConfig.maxAllowedImageDimension) (got \(desktop.maxImageDimension))"
            )
        }
        if desktop.jpegQuality < 0.1 || desktop.jpegQuality > 1.0 {
            throw ConfigError.validationError(
                field: "desktop.jpeg_quality",
                message: "must be between 0.1 and 1.0 (got \(desktop.jpegQuality))"
            )
        }
    }

    /// Validates the `[security]` section.
    ///
    /// Both flags are plain booleans with no range to bound, so there is
    /// nothing to reject: the method exists so the section joins the same
    /// validate-every-section contract as all prior sections.
    private func validateSecuritySection() throws {}

    /// Validates the `[goals]` section.
    ///
    /// Bounds keep steady pursuit steady: a sub-five-minute cadence would
    /// busy-loop the scheduler, a multi-week cadence reads as abandoned, and
    /// unbounded active goals or plan lengths would crowd execution context.
    /// The planning timeout only needs to stay positive here; the engine
    /// clamps it again at use so an unvalidated path never waits forever.
    private func validateGoalsSection() throws {
        if goals.stepIntervalMinutes < GoalsConfig.minStepIntervalMinutes
            || goals.stepIntervalMinutes > GoalsConfig.maxStepIntervalMinutes
        {
            throw ConfigError.validationError(
                field: "goals.step_interval_minutes",
                message: "must be between \(GoalsConfig.minStepIntervalMinutes) and \(GoalsConfig.maxStepIntervalMinutes) (got \(goals.stepIntervalMinutes))"
            )
        }
        if goals.maxActiveGoals < GoalsConfig.minActiveGoalsBound
            || goals.maxActiveGoals > GoalsConfig.maxActiveGoalsBound
        {
            throw ConfigError.validationError(
                field: "goals.max_active_goals",
                message: "must be between \(GoalsConfig.minActiveGoalsBound) and \(GoalsConfig.maxActiveGoalsBound) (got \(goals.maxActiveGoals))"
            )
        }
        if goals.maxStepsPerGoal < GoalsConfig.minStepsPerGoalBound
            || goals.maxStepsPerGoal > GoalsConfig.maxStepsPerGoalBound
        {
            throw ConfigError.validationError(
                field: "goals.max_steps_per_goal",
                message: "must be between \(GoalsConfig.minStepsPerGoalBound) and \(GoalsConfig.maxStepsPerGoalBound) (got \(goals.maxStepsPerGoal))"
            )
        }
        if goals.planTimeoutSeconds < 1 {
            throw ConfigError.validationError(
                field: "goals.plan_timeout_seconds",
                message: "must be positive (got \(goals.planTimeoutSeconds))"
            )
        }
    }
}

/// Bounds enforcement for goal pursuit when the config bypasses load-time validation.
///
/// Load-time validation above fails closed; this clamps instead so live
/// engine paths constructed from hand-built configs degrade to the nearest
/// sane bound rather than refusing to run. Both share the same range
/// constants so the two postures cannot drift.
public extension GoalsConfig {
    /// Returns a copy clamped into the validated ranges.
    /// - Returns: Config with interval, caps, and timeout pulled inside bounds.
    func clamped() -> GoalsConfig {
        GoalsConfig(
            enabled: enabled,
            stepIntervalMinutes: min(max(stepIntervalMinutes, Self.minStepIntervalMinutes), Self.maxStepIntervalMinutes),
            maxActiveGoals: min(max(maxActiveGoals, Self.minActiveGoalsBound), Self.maxActiveGoalsBound),
            maxStepsPerGoal: min(max(maxStepsPerGoal, Self.minStepsPerGoalBound), Self.maxStepsPerGoalBound),
            planTimeoutSeconds: max(1, planTimeoutSeconds)
        )
    }
}

// swiftformat:enable extensionAccessControl
