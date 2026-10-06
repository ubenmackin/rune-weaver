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
        try validateBashSection()
        try validateProactiveSection()
        try validateIdeasSection()
        try validateFanoutSection()
        try validateWorkspaceSection()
        try validatePersonaSection()
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
        // Decode and the settings PUT trim before storing, so the stored form
        // never carries padding; the hostname check validates the trimmed
        // form under the same exact-host rules as `allowed_hosts` and the
        // Host gate so file-load and PUT agree before persisting.
        try Self.validateServerHostname(server.hostname)
        // Mirrors `ServerConfig.validPortRange` without linking the server
        // transport into the config layer, so a bad port fails at load.
        if server.port < 1 || server.port > 65535 {
            throw ConfigError.validationError(
                field: "server.port", message: "must be between 1 and 65535"
            )
        }
        try Self.validateAllowedHosts(server.allowedHosts)
    }

    /// Validates `server.hostname` as an exact host matching `allowed_hosts`
    /// and Host-gate semantics.
    ///
    /// The Host gate matches the bind hostname after lowercasing (plus
    /// bracket-canonicalized IPv6), so validation rejects shapes that could
    /// never match exactly or would widen the gate: schemes, wildcards, CIDR
    /// ranges or paths, userinfo, query or fragment, interior whitespace,
    /// and control characters. A `:port` suffix on a non-IPv6 literal is
    /// rejected because the port lives in `server.port`: persisting
    /// `example.com:8082` as the hostname would never match the normalized
    /// Host yet read as configured (spurious 403) or fail at bind time.
    /// - Parameter hostname: Raw configured hostname.
    /// - Throws: ``ConfigError/validationError(field:message:)`` on any widening shape.
    public static func validateServerHostname(_ hostname: String) throws {
        let field = "server.hostname"
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConfigError.validationError(field: field, message: "must not be empty")
        }
        if trimmed.count > ServerEndpointConfig.maxAllowedHostLength {
            throw ConfigError.validationError(
                field: field,
                message: "must not exceed \(ServerEndpointConfig.maxAllowedHostLength) characters (got \(trimmed.count))"
            )
        }
        // Single-sourced through `validateExactHost` so hostname and allowlist
        // agree on every widening shape; length and port checks stay local.
        try Self.validateExactHost(trimmed: trimmed, original: hostname, field: field)
        // Fail closed on `host:port` spellings for non-IPv6 literals: the
        // port belongs in `server.port`, and the Host gate compares the
        // port-stripped form, so persisting the suffix would never match yet
        // read as configured. Unbracketed IPv6 literals carry multiple
        // colons and keep them; a single colon (or a bracketed `:port`
        // after `]`) is a port suffix, not an address.
        if Self.isHostWithPortSuffix(trimmed) {
            throw ConfigError.validationError(
                field: field,
                message: "must be a host without a port (got '\(hostname)'); configure the port via server.port instead"
            )
        }
        // Fail closed on values that normalize to empty (e.g. `:8082`): the
        // Host gate compares the lowercased, port-stripped form, so a
        // port-only hostname would never match yet read as configured.
        if Self.normalizedAllowedHostForValidation(trimmed).isEmpty {
            throw ConfigError.validationError(field: field, message: "must not be empty")
        }
    }

    /// Whether a trimmed hostname carries a `:port` suffix.
    ///
    /// Bracketed literals (`[::1]`) keep their brackets; a colon after the
    /// closing `]` counts as a port only for a numeric port, mirroring the
    /// normalization strip rule. Unbracketed values with more than one colon
    /// are IPv6 literals and keep their colons, while a single colon marks
    /// `host:port` only for an empty or numeric suffix.
    /// - Parameter trimmed: Whitespace-trimmed hostname.
    /// - Returns: True when the value carries a port suffix.
    private static func isHostWithPortSuffix(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("[") {
            guard let closingBracketIndex = trimmed.firstIndex(of: "]") else {
                return false
            }
            let after = trimmed[trimmed.index(after: closingBracketIndex)...]
            guard after.hasPrefix(":") else {
                return false
            }
            let portPart = after.dropFirst()
            return !portPart.isEmpty && portPart.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
        if trimmed.filter({ $0 == ":" }).count != 1 {
            return false
        }
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return false
        }
        let suffix = trimmed[trimmed.index(after: colonIndex)...]
        if suffix.isEmpty {
            return true
        }
        return suffix.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// Validates one exact host against the shared Host-gate semantics.
    ///
    /// Single-sources the widening-shape guards shared by
    /// `validateServerHostname` and `validateAllowedHosts` (scheme, bare `*`,
    /// wildcards, CIDR/paths, userinfo, query/fragment, whitespace, controls)
    /// plus the unbalanced-bracket, bracketed non-IPv6, empty-bracket, and
    /// trailing-dot fail-closed checks so file-load, the settings PUT, and
    /// the Host gate agree. Length, empty, port-suffix, and normalized-empty
    /// checks stay with the callers because the hostname rejects `:port`
    /// while the allowlist strips it.
    /// - Parameters:
    ///   - trimmed: Whitespace-trimmed host value.
    ///   - original: Raw value echoed in diagnostics.
    ///   - field: Dotted field name for diagnostics.
    /// - Throws: ``ConfigError/validationError(field:message:)`` on any widening shape.
    private static func validateExactHost(trimmed: String, original: String, field: String) throws {
        let lowered = trimmed.lowercased()
        if lowered.contains("://") {
            throw ConfigError.validationError(
                field: field, message: "must not contain a scheme (got '\(original)'); list the host instead"
            )
        }
        if lowered == "*" {
            throw ConfigError.validationError(
                field: field, message: "must not contain bare \"*\" (would allow every host)"
            )
        }
        // Wildcard and CIDR hints keep their per-field wording so existing
        // diagnostics do not drift: the hostname suggests the singular host
        // while the allowlist suggests exact hosts.
        let listHint = (field == "server.allowed_hosts") ? "list exact hosts instead" : "list the host instead"
        if lowered.contains("*") {
            throw ConfigError.validationError(
                field: field, message: "must not contain wildcards (got '\(original)'); \(listHint)"
            )
        }
        if lowered.contains("/") {
            throw ConfigError.validationError(
                field: field, message: "must not contain CIDR or paths (got '\(original)'); \(listHint)"
            )
        }
        if trimmed.contains("@") {
            throw ConfigError.validationError(
                field: field, message: "must not contain userinfo (got '\(original)')"
            )
        }
        if trimmed.contains("?") || trimmed.contains("#") {
            throw ConfigError.validationError(
                field: field, message: "must be a host without query or fragment (got '\(original)')"
            )
        }
        if trimmed.contains(" ") || trimmed.contains("\t") {
            throw ConfigError.validationError(
                field: field, message: "must not contain whitespace (got '\(original)')"
            )
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw ConfigError.validationError(
                field: field, message: "must not contain control characters (got '\(original)')"
            )
        }
        try validateBracketedHost(trimmed: trimmed, original: original, field: field)

        // Fail closed on unbracketed `host:suffix` with a non-numeric suffix:
        // normalization strips only an empty or numeric port, so
        // `evil.com:evil` would otherwise persist verbatim garbage that never
        // matches yet reads as configured. Empty or numeric suffixes pass
        // through for the hostname port-suffix rejection and the allowlist
        // strip respectively; IPv6 literals keep their colons above.
        if !trimmed.hasPrefix("[") {
            if trimmed.filter({ $0 == ":" }).count == 1,
               let colonIndex = trimmed.firstIndex(of: ":")
            {
                let suffix = trimmed[trimmed.index(after: colonIndex)...]
                if !suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                    if field == "server.hostname" {
                        throw ConfigError.validationError(
                            field: field,
                            message: "must be a host without a port (got '\(original)'); configure the port via server.port instead"
                        )
                    }
                    throw ConfigError.validationError(
                        field: field,
                        message: "must be a host with an optional numeric port (got '\(original)'); list exact hosts instead"
                    )
                }
            }
        }
        // Fail closed on a trailing FQDN dot: the gate compares exact
        // normalized hosts, so `example.com.` would never match `example.com`
        // yet read as allowed. Loopback classification strips the dot first,
        // while every other host must drop it before configuring.
        if trimmed.hasSuffix(".") {
            throw ConfigError.validationError(
                field: field, message: "must not end with '.' (got '\(original)'); list the host without the trailing dot instead"
            )
        }
    }

    private static func validateBracketedHost(trimmed: String, original: String, field: String) throws {
        if trimmed.contains("[") != trimmed.contains("]") {
            throw ConfigError.validationError(
                field: field, message: "must not contain unbalanced brackets (got '\(original)')"
            )
        }
        guard trimmed.contains("[") || trimmed.contains("]") else { return }
        guard trimmed.hasPrefix("["),
              trimmed.filter({ $0 == "[" }).count == 1,
              trimmed.filter({ $0 == "]" }).count == 1,
              let closingBracketIndex = trimmed.firstIndex(of: "]")
        else {
            throw ConfigError.validationError(
                field: field, message: "must not contain bracketed non-IPv6 (got '\(original)'); brackets are only for IPv6 literals"
            )
        }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< closingBracketIndex])
        guard !inner.isEmpty else {
            throw ConfigError.validationError(
                field: field, message: "must not contain empty brackets (got '\(original)')"
            )
        }
        guard inner.contains(":") else {
            throw ConfigError.validationError(
                field: field, message: "must not contain bracketed non-IPv6 (got '\(original)'); list the host without brackets instead"
            )
        }
        let afterBracket = String(trimmed[trimmed.index(after: closingBracketIndex)...])
        if !afterBracket.isEmpty {
            guard afterBracket.hasPrefix(":") else {
                throw ConfigError.validationError(
                    field: field, message: "must not contain bracketed non-IPv6 (got '\(original)'); brackets are only for IPv6 literals"
                )
            }
            let portPart = afterBracket.dropFirst()
            guard !portPart.isEmpty, portPart.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
                throw ConfigError.validationError(
                    field: field, message: "must not contain bracketed non-IPv6 (got '\(original)'); brackets are only for IPv6 literals"
                )
            }
        }
    }

    /// Validates explicit `server.allowed_hosts` entries as exact hostnames only.
    ///
    /// The Host gate matches entries after lowercasing plus port stripping, so
    /// validation rejects shapes that could never match exactly or would widen
    /// the gate: schemes, wildcards, CIDR ranges, and a bare `*`. Bounds keep
    /// the allowlist auditable and within the DNS name limit.
    /// - Parameter hosts: Raw configured entries.
    /// - Throws: ``ConfigError/validationError(field:message:)`` on any widening shape.
    public static func validateAllowedHosts(_ hosts: [String]) throws {
        let field = "server.allowed_hosts"
        if hosts.count > ServerEndpointConfig.maxAllowedHosts {
            throw ConfigError.validationError(
                field: field,
                message: "must contain at most \(ServerEndpointConfig.maxAllowedHosts) entries (got \(hosts.count))"
            )
        }
        for entry in hosts {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ConfigError.validationError(field: field, message: "must not contain empty strings")
            }
            if trimmed.count > ServerEndpointConfig.maxAllowedHostLength {
                throw ConfigError.validationError(
                    field: field,
                    message: "must not exceed \(ServerEndpointConfig.maxAllowedHostLength) characters (got \(trimmed.count))"
                )
            }
            // Single-sourced through `validateExactHost` so allowlist and hostname
            // agree on every widening shape; bounds stay local.
            try Self.validateExactHost(trimmed: trimmed, original: entry, field: field)
            // Fail closed on entries that normalize to empty (e.g. `:8082`):
            // the Host gate compares the lowercased, port-stripped form, so a
            // port-only entry would never match yet read as configured. The
            // settings PUT already rejects this shape after normalization, so
            // rejecting here keeps file-load and PUT in agreement.
            if Self.normalizedAllowedHostForValidation(trimmed).isEmpty {
                throw ConfigError.validationError(field: field, message: "must not contain empty strings")
            }
        }
    }

    /// Normalizes one `allowed_hosts` entry to the compared Host form for validation.
    ///
    /// Single-sourced through `ServerEndpointConfig.normalizeHost` so file-load
    /// validation and the settings PUT reject the same normalized-empty shapes
    /// fail-closed without linking the server transport into the config layer.
    /// - Parameter entry: Raw configured entry.
    /// - Returns: Lowercased, port-stripped host.
    private static func normalizedAllowedHostForValidation(_ entry: String) -> String {
        ServerEndpointConfig.normalizeHost(entry)
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
        // Recall budgets deliberately fail open, unlike the fail-closed
        // neighboring bounds: file-load already clamped in `decodeMemory` and
        // the settings PUT clamps on merge, so an out-of-range `recall_*`
        // reaches here at the nearest bound and never throws — a stray digit
        // degrades recall fan-out instead of refusing to boot or save. Live
        // engine paths clamp again at use via `RecallBudgets.clamped()` for
        // hand-built configs. No range throw here by design.
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
        // Closed effort set keeps worker derivation predictable; a typo would
        // otherwise silently fall back to the balanced formula.
        if !IndexConfig.allowedEfforts.contains(index.effort) {
            throw ConfigError.validationError(
                field: "index.effort",
                message: "must be one of \(IndexConfig.allowedEfforts.joined(separator: ", ")) (got '\(index.effort)')"
            )
        }
        // Custom carries an explicit count while presets derive it, so a
        // preset with a stray count and a custom without one both fail here.
        // The custom count validates against a static ceiling so the same
        // file loads on any machine; resolution clamps to the live cores.
        if index.effort == "custom" {
            if index.workers < 1 || index.workers > IndexConfig.maxAllowedWorkers {
                throw ConfigError.validationError(
                    field: "index.workers",
                    message: "must be between 1 and \(IndexConfig.maxAllowedWorkers) when effort is custom (got \(index.workers))"
                )
            }
        } else if index.workers != 0 {
            throw ConfigError.validationError(
                field: "index.workers",
                message: "must be 0 unless effort is custom (got \(index.workers))"
            )
        }
        // The cap bounds per-document embedding work so one text-dense
        // document cannot schedule a huge batch; a typo outside 1...4096
        // fails at load instead of fanning thousands of embeddings.
        if index.maxVectorChunksPerDocument < 1 || index.maxVectorChunksPerDocument > IndexConfig.maxAllowedVectorChunksPerDocument {
            throw ConfigError.validationError(
                field: "index.max_vector_chunks_per_document",
                message: "must be between 1 and \(IndexConfig.maxAllowedVectorChunksPerDocument) (got \(index.maxVectorChunksPerDocument))"
            )
        }
        // Trash-class denylist stays a plain list of non-blank globs: empty
        // opts back into every mailbox while a blank entry fails instead of
        // matching nothing yet reading as configured.
        try Self.validateMailboxDeny(index.mailboxDeny)
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
        if browser.timeoutSeconds < 5 || browser.timeoutSeconds > 300 {
            throw ConfigError.validationError(
                field: "browser.timeout_seconds", message: "must be between 5 and 300"
            )
        }
        if browser.fetchTimeoutSeconds < 1 || browser.fetchTimeoutSeconds > 120 {
            throw ConfigError.validationError(
                field: "browser.fetch_timeout_seconds", message: "must be between 1 and 120"
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

    /// Parses a raw `files.write_mode` string into the closed posture set.
    ///
    /// The single source of truth for `files.write_mode` acceptance: the TOML
    /// decoder and the settings route both delegate here, so trim/lowercase
    /// normalization and the rejection field/message cannot drift between
    /// file-load and runtime updates. An unknown value throws instead of
    /// falling back to the model posture, because a typo would otherwise read
    /// as "agent chooses" and silently unforce the owner's posture.
    /// - Parameters:
    ///   - raw: Raw value from TOML or the settings payload.
    ///   - field: Dotted field name carried by the thrown error.
    /// - Returns: The matching write mode after trim and lowercase normalization.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when the value
    ///   is not one of `model`, `staged`, or `live`.
    public static func validateFilesWriteMode(_ raw: String, field: String = "files.write_mode") throws -> FilesWriteMode {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = FilesWriteMode(rawValue: lowered) else {
            throw ConfigError.validationError(
                field: field,
                message: "must be one of \(FilesWriteMode.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')"
            )
        }
        return mode
    }

    /// Validates the Trash-class mailbox denylist as non-blank globs.
    ///
    /// Empty opts every mailbox back in, so only blank entries fail: a blank
    /// would otherwise read as configured yet match nothing.
    /// - Parameter patterns: Raw denylist entries.
    /// - Throws: ``ConfigError/validationError(field:message:)`` on any blank entry.
    public static func validateMailboxDeny(_ patterns: [String]) throws {
        let field = "index.mailbox_deny"
        for pattern in patterns where pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(field: field, message: "must not contain empty patterns")
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
        if scheduler.defaultMaxToolIterations < 1 || scheduler.defaultMaxToolIterations > 100 {
            throw ConfigError.validationError(
                field: "scheduler.max_tool_iterations",
                message: "must be between 1 and 100 (got \(scheduler.defaultMaxToolIterations))"
            )
        }
        for job in scheduler.jobs {
            if let maxIter = job.maxToolIterations, !(1 ... 100).contains(maxIter) {
                throw ConfigError.validationError(
                    field: "scheduler.jobs[\(job.name)].max_tool_iterations",
                    message: "must be between 1 and 100 (got \(maxIter))"
                )
            }
            if let onLimit = job.onToolLimit, !["fail", "park"].contains(onLimit) {
                throw ConfigError.validationError(
                    field: "scheduler.jobs[\(job.name)].on_tool_limit",
                    message: "must be 'fail' or 'park' (got '\(onLimit)')"
                )
            }
        }
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
        if media.timeoutSeconds < 5 || media.timeoutSeconds > 120 {
            throw ConfigError.validationError(
                field: "media.timeout_seconds", message: "must be between 5 and 120"
            )
        }
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
        if goals.maxTriggersPerGoal < GoalsConfig.minTriggersPerGoalBound
            || goals.maxTriggersPerGoal > GoalsConfig.maxTriggersPerGoalBound
        {
            throw ConfigError.validationError(
                field: "goals.max_triggers_per_goal",
                message: "must be between \(GoalsConfig.minTriggersPerGoalBound) and \(GoalsConfig.maxTriggersPerGoalBound) (got \(goals.maxTriggersPerGoal))"
            )
        }
        if goals.planTimeoutSeconds < 1 {
            throw ConfigError.validationError(
                field: "goals.plan_timeout_seconds",
                message: "must be positive (got \(goals.planTimeoutSeconds))"
            )
        }
        if goals.maxToolIterations < 1 || goals.maxToolIterations > 100 {
            throw ConfigError.validationError(
                field: "goals.max_tool_iterations",
                message: "must be between 1 and 100 (got \(goals.maxToolIterations))"
            )
        }
        if goals.maxStepBudgetExceededRetries < 1 || goals.maxStepBudgetExceededRetries > 10 {
            throw ConfigError.validationError(
                field: "goals.max_step_budget_exceeded_retries",
                message: "must be between 1 and 10 (got \(goals.maxStepBudgetExceededRetries))"
            )
        }
    }

    private func validateBashSection() throws {
        try bash.validate()
    }

    /// Validates the `[proactive]` section.
    ///
    /// The judge budget bounds one guarded model round trip so a stray digit
    /// fails at load instead of holding the scheduler tick; the mode itself
    /// is already closed by its enum, with the TOML decoder rejecting unknown
    /// strings at the same dotted field.
    private func validateProactiveSection() throws {
        if proactive.judgeTimeoutSeconds < ProactiveConfig.minJudgeTimeoutSeconds
            || proactive.judgeTimeoutSeconds > ProactiveConfig.maxJudgeTimeoutSeconds
        {
            let minSeconds = ProactiveConfig.minJudgeTimeoutSeconds
            let maxSeconds = ProactiveConfig.maxJudgeTimeoutSeconds
            throw ConfigError.validationError(
                field: "proactive.judge_timeout_seconds",
                message: "must be between \(minSeconds) and \(maxSeconds) (got \(proactive.judgeTimeoutSeconds))"
            )
        }
    }

    /// Validates the `[ideas]` section.
    ///
    /// Bounds keep proactive suggestions cheap: an unbounded per-cycle cap
    /// would flood the ideas list, and a non-positive or overlong review
    /// budget would either never call the model or hold the trigger that asked
    /// too long. The engine clamps again at use so an unvalidated hand-built
    /// config never waits forever.
    private func validateIdeasSection() throws {
        if ideas.maxPerCycle < IdeasConfig.minMaxPerCycle || ideas.maxPerCycle > IdeasConfig.maxMaxPerCycle {
            throw ConfigError.validationError(
                field: "ideas.max_per_cycle",
                message: "must be between \(IdeasConfig.minMaxPerCycle) and \(IdeasConfig.maxMaxPerCycle) (got \(ideas.maxPerCycle))"
            )
        }
        if ideas.timeoutSeconds < IdeasConfig.minTimeoutSeconds || ideas.timeoutSeconds > IdeasConfig.maxTimeoutSeconds {
            throw ConfigError.validationError(
                field: "ideas.timeout_seconds",
                message: "must be between \(IdeasConfig.minTimeoutSeconds) and \(IdeasConfig.maxTimeoutSeconds) (got \(ideas.timeoutSeconds))"
            )
        }
    }

    /// Validates the `[fanout]` section.
    ///
    /// The worker cap bounds simultaneous model rounds so a wide subtask list
    /// cannot oversubscribe the serving model. The timeout accepts zero for
    /// unlimited (no wall-clock bound, intentional for slow local models and
    /// ended by cancellation) and otherwise stays within
    /// `1...maxWorkerTimeoutSeconds` so a stray digit fails at load instead of
    /// holding a run open beyond any plausible model round. The engine clamps
    /// again at init so an unvalidated hand-built config degrades to the
    /// nearest sane bound instead of refusing to run.
    private func validateFanoutSection() throws {
        if fanOut.maxWorkers < FanOutConfig.minMaxWorkers || fanOut.maxWorkers > FanOutConfig.maxMaxWorkers {
            throw ConfigError.validationError(
                field: "fanout.max_workers",
                message: "must be between \(FanOutConfig.minMaxWorkers) and \(FanOutConfig.maxMaxWorkers) (got \(fanOut.maxWorkers))"
            )
        }
        // Local bounds keep the range check and its diagnostic on short lines.
        let lower = FanOutConfig.unlimitedWorkerTimeoutSeconds
        let upper = FanOutConfig.maxWorkerTimeoutSeconds
        let timeout = fanOut.workerTimeoutSeconds
        if timeout < lower || timeout > upper {
            throw ConfigError.validationError(
                field: "fanout.worker_timeout_seconds",
                message: "must be between \(lower) and \(upper) (got \(timeout))"
            )
        }
    }

    /// Validates the `[workspace]` section.
    ///
    /// Quotas bound shell scratch so a stray download cannot fill the disk and
    /// a quota walk cannot dominate a turn; the temp TTL bounds `tmp/` growth
    /// without manual cleanup. The store clamps again at use so an unvalidated
    /// hand-built config degrades to the nearest sane bound instead of
    /// refusing to run.
    private func validateWorkspaceSection() throws {
        try WorkspaceConfig.validateQuotaMB(workspace.quotaMB)
        try WorkspaceConfig.validateQuotaFiles(workspace.quotaFiles)
        try WorkspaceConfig.validateTmpTTLDays(workspace.tmpTTLDays)
    }

    /// Validates the `[persona]` section through the shared normalizers.
    ///
    /// Decode and merge paths already repaired at their own boundaries, so this
    /// enforces the same bounds fail-closed for hand-built configs: a blank
    /// assistant name and overlong style guidance that would have fallen back
    /// or truncated on load instead throw here, because the non-mutating check
    /// cannot repair the stored value and passing would leave a broken identity
    /// line. Bounds that cannot be repaired on any path throw with the dotted
    /// field via the shared normalizers. Tone and avatar are closed enums, so
    /// nothing beyond their decode-time rejection can drift here. The composer
    /// additionally clamps at render so a prompt never splices even when
    /// validation is bypassed.
    private func validatePersonaSection() throws {
        if persona.assistantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "persona.assistant_name", message: "must not be blank"
            )
        }
        _ = try PersonaConfig.normalizedAssistantName(persona.assistantName)
        _ = try PersonaConfig.normalizedUserName(persona.userName)
        let sanitizedStyle = NormalizedText.singleLineSanitized(persona.style)
        if sanitizedStyle.count > PersonaConfig.maxStyleLength {
            throw ConfigError.validationError(
                field: "persona.style",
                message: "must not exceed \(PersonaConfig.maxStyleLength) characters (got \(sanitizedStyle.count))"
            )
        }
        _ = PersonaConfig.normalizedStyle(persona.style)
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
            planTimeoutSeconds: max(1, planTimeoutSeconds),
            maxTriggersPerGoal: min(max(maxTriggersPerGoal, Self.minTriggersPerGoalBound), Self.maxTriggersPerGoalBound),
            maxToolIterations: min(max(maxToolIterations, 1), 100),
            maxStepBudgetExceededRetries: min(max(maxStepBudgetExceededRetries, 1), 10)
        )
    }
}

/// Bounds enforcement for recall budgets at every fail-open clamp site.
///
/// File-load clamps in `decodeMemory`, the settings PUT clamps on merge, and
/// this covers hand-built configs plus live engine paths, so a stray digit
/// degrades to the nearest bound rather than refusing to boot, save, or run.
/// All sites share the same range constants on `RecallBudgets` so the
/// fail-open posture cannot drift.
public extension RecallBudgets {
    /// Returns a copy clamped into the documented ranges.
    /// - Returns: Budgets with limits pulled inside `1...50`, threshold and
    ///   weight inside `0...1`, `maxChars` inside `200...16000`,
    ///   `perHitChars` inside `100...2000`, and multiplier inside `1...8`.
    func clamped() -> RecallBudgets {
        RecallBudgets(
            perTierLimit: min(max(perTierLimit, Self.limitBounds.lowerBound), Self.limitBounds.upperBound),
            autoLimit: min(max(autoLimit, Self.limitBounds.lowerBound), Self.limitBounds.upperBound),
            threshold: min(max(threshold, Self.scoreBounds.lowerBound), Self.scoreBounds.upperBound),
            maxChars: min(max(maxChars, Self.maxCharsBounds.lowerBound), Self.maxCharsBounds.upperBound),
            perHitChars: min(max(perHitChars, Self.perHitCharsBounds.lowerBound), Self.perHitCharsBounds.upperBound),
            docPoolMultiplier: min(max(docPoolMultiplier, Self.docPoolMultiplierBounds.lowerBound), Self.docPoolMultiplierBounds.upperBound),
            episodicWeight: min(max(episodicWeight, Self.scoreBounds.lowerBound), Self.scoreBounds.upperBound)
        )
    }
}

/// Bounds enforcement for idea suggestions when the config bypasses load-time validation.
///
/// Load-time validation above fails closed; this clamps instead so live
/// engine paths constructed from hand-built configs degrade to the nearest
/// sane bound rather than refusing to run. Both share the same range
/// constants so the two postures cannot drift.
public extension IdeasConfig {
    /// Returns a copy clamped into the validated ranges.
    /// - Returns: Config with the per-cycle cap and review timeout pulled inside bounds.
    func clamped() -> IdeasConfig {
        IdeasConfig(
            enabled: enabled,
            maxPerCycle: min(max(maxPerCycle, Self.minMaxPerCycle), Self.maxMaxPerCycle),
            timeoutSeconds: min(max(timeoutSeconds, Self.minTimeoutSeconds), Self.maxTimeoutSeconds)
        )
    }
}

/// Single-sourced bash rule validation shared by file-load, the settings
/// PUT, and TOML decoding so the three paths cannot drift on fields or
/// messages.
public extension BashRule {
    /// Validates one rule's pattern, rejecting blank values.
    ///
    /// The matcher trims surrounding whitespace before comparing, so a
    /// whitespace-only pattern never matches and fails closed here instead
    /// of persisting a dead rule.
    /// - Parameter index: Position in `BashConfig.rules` for diagnostics.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when the pattern is blank.
    func validate(index: Int) throws {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigError.validationError(
                field: "bash.rules[\(index)].pattern",
                message: "must not be blank"
            )
        }
    }
}

/// Single-sourced bash policy validation shared by file-load, the settings
/// PUT, and TOML decoding so the three paths agree on fields and messages.
public extension BashConfig {
    /// Minimum execution timeout in seconds, keeping runs bounded.
    static var minTimeoutSeconds: Int {
        1
    }

    /// Maximum execution timeout in seconds, keeping runs bounded.
    static var maxTimeoutSeconds: Int {
        3600
    }

    /// Smallest CPU budget that still allows one useful burst of work.
    static var minCPUSeconds: Int {
        1
    }

    /// Largest CPU budget before a stray digit holds a run past any plausible shell turn.
    static var maxCPUSeconds: Int {
        3600
    }

    /// Smallest address-space budget that still fits a shell plus one child.
    static var minMemoryMB: Int {
        64
    }

    /// Largest address-space budget before scratch rivals the host's memory.
    static var maxMemoryMB: Int {
        8192
    }

    /// Validates the stored bash policy, throwing a descriptive error on failure.
    ///
    /// Covers the rule list, the wall-clock timeout, and the resource bounds
    /// together so file-load and any full-snapshot check share one contract.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when the rule
    ///   list is empty, a rule pattern is blank, or any bound is out of range.
    func validate() throws {
        try Self.validateRules(rules)
        try Self.validateTimeoutSeconds(timeoutSeconds)
        try Self.validateCPUSeconds(cpuSeconds)
        try Self.validateMemoryMB(memoryMB)
    }

    /// Returns a copy clamped into the validated ranges.
    ///
    /// The shell clamps at use so a hand-built config degrades to the nearest
    /// sane bound instead of refusing to run; load-time validation fails
    /// closed, and both postures share the same range constants so they cannot
    /// drift.
    /// - Returns: Config with the timeout and resource bounds pulled inside bounds.
    func clamped() -> BashConfig {
        BashConfig(
            enabled: enabled,
            defaultAction: defaultAction,
            rules: rules,
            timeoutSeconds: min(max(timeoutSeconds, Self.minTimeoutSeconds), Self.maxTimeoutSeconds),
            allowNetwork: allowNetwork,
            cpuSeconds: min(max(cpuSeconds, Self.minCPUSeconds), Self.maxCPUSeconds),
            memoryMB: min(max(memoryMB, Self.minMemoryMB), Self.maxMemoryMB)
        )
    }

    /// Validates an ordered rule list, requiring at least one non-blank pattern.
    ///
    /// A present list replaces the built-in default in stored order, so an
    /// empty list fails closed instead of persisting a policy that reloads
    /// as the default star rule.
    /// - Parameter rules: Ordered permission rules evaluated last-match-wins.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when the list
    ///   is empty or a pattern is blank.
    static func validateRules(_ rules: [BashRule]) throws {
        if rules.isEmpty {
            throw ConfigError.validationError(
                field: "bash.rules",
                message: "must contain at least one rule"
            )
        }
        for (index, rule) in rules.enumerated() {
            try rule.validate(index: index)
        }
    }

    /// Validates the default execution timeout in seconds.
    ///
    /// Bounds keep a zero hang or an unbounded run from persisting through
    /// any write path.
    /// - Parameter timeoutSeconds: Default execution timeout in seconds.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when outside 1-3600.
    static func validateTimeoutSeconds(_ timeoutSeconds: Int) throws {
        if timeoutSeconds < minTimeoutSeconds || timeoutSeconds > maxTimeoutSeconds {
            throw ConfigError.validationError(
                field: "bash.timeout_seconds",
                message: "must be between \(minTimeoutSeconds) and \(maxTimeoutSeconds) (got \(timeoutSeconds))"
            )
        }
    }

    /// Validates the CPU time budget in seconds.
    ///
    /// Bounds keep a zero budget (which would kill every command instantly)
    /// or an unbounded budget from persisting through any write path.
    /// - Parameter cpuSeconds: CPU time budget in seconds.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when outside 1-3600.
    static func validateCPUSeconds(_ cpuSeconds: Int) throws {
        if cpuSeconds < minCPUSeconds || cpuSeconds > maxCPUSeconds {
            throw ConfigError.validationError(
                field: "bash.cpu_seconds",
                message: "must be between \(minCPUSeconds) and \(maxCPUSeconds) (got \(cpuSeconds))"
            )
        }
    }

    /// Validates the address-space budget in megabytes.
    ///
    /// Bounds keep a trivially small budget (which would fail every spawn)
    /// or a host-scale budget from persisting through any write path.
    /// - Parameter memoryMB: Address-space budget in megabytes.
    /// - Throws: ``ConfigError/validationError(field:message:)`` when outside 64-8192.
    static func validateMemoryMB(_ memoryMB: Int) throws {
        if memoryMB < minMemoryMB || memoryMB > maxMemoryMB {
            throw ConfigError.validationError(
                field: "bash.memory_mb",
                message: "must be between \(minMemoryMB) and \(maxMemoryMB) (got \(memoryMB))"
            )
        }
    }
}

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
