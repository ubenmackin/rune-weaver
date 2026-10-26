// Rune Weaver Core — Subsystem TOML decoding for config.toml.

import Foundation

// MARK: - Subsystem TOML decoding

extension RuneWeaverConfig {
    static func decodeDesktop(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let desktop = root.tables["desktop"] else { return }
        // Enablement flows solely through the persisted tool-state toggle; this section
        // decodes capture knobs only.
        if let dim = try desktop.strictInt("max_image_dimension", field: "desktop.max_image_dimension") {
            config.desktop.maxImageDimension = dim
        }
        if let quality = desktop.values["jpeg_quality"] {
            switch quality {
            case let .double(value):
                config.desktop.jpegQuality = value
            case let .integer(value):
                config.desktop.jpegQuality = Double(value)
            default:
                throw ConfigError.validationError(field: "desktop.jpeg_quality", message: "must be a number")
            }
        }
        if let blocked = try desktop.strictStringArray("blocked_apps", field: "desktop.blocked_apps") {
            config.desktop.blockedApps = blocked
        }
    }

    /// Decodes the additive `[security]` section, defaulting omitted keys.
    static func decodeSecurity(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let security = root.tables["security"] else { return }
        if let labeling = try security.strictBool("untrusted_labeling", field: "security.untrusted_labeling") {
            config.security.untrustedLabeling = labeling
        }
        if let credentialFilter = try security.strictBool("email_credential_filter", field: "security.email_credential_filter") {
            config.security.emailCredentialFilter = credentialFilter
        }
    }

    /// Decodes the additive `[goals]` section, defaulting omitted keys.
    static func decodeGoals(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let goals = root.tables["goals"] else { return }
        if let enabled = try goals.strictBool("enabled", field: "goals.enabled") {
            config.goals.enabled = enabled
        }
        if let interval = try goals.strictInt("step_interval_minutes", field: "goals.step_interval_minutes") {
            config.goals.stepIntervalMinutes = interval
        }
        if let maxActive = try goals.strictInt("max_active_goals", field: "goals.max_active_goals") {
            config.goals.maxActiveGoals = maxActive
        }
        if let maxSteps = try goals.strictInt("max_steps_per_goal", field: "goals.max_steps_per_goal") {
            config.goals.maxStepsPerGoal = maxSteps
        }
        if let timeout = try goals.strictInt("plan_timeout_seconds", field: "goals.plan_timeout_seconds") {
            config.goals.planTimeoutSeconds = timeout
        }
        if let maxTriggers = try goals.strictInt("max_triggers_per_goal", field: "goals.max_triggers_per_goal") {
            config.goals.maxTriggersPerGoal = maxTriggers
        }
        if let maxToolIterations = try goals.strictInt("max_tool_iterations", field: "goals.max_tool_iterations") {
            config.goals.maxToolIterations = maxToolIterations
        }
        if let maxRetries = try goals.strictInt("max_step_budget_exceeded_retries", field: "goals.max_step_budget_exceeded_retries") {
            config.goals.maxStepBudgetExceededRetries = maxRetries
        }
    }

    /// Decodes the additive `[bash]` section, defaulting omitted keys.
    static func decodeBash(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let bash = root.tables["bash"] else { return }
        if let enabled = try bash.strictBool("enabled", field: "bash.enabled") {
            config.bash.enabled = enabled
        }
        if let defaultActionStr = try bash.strictString("default_action", field: "bash.default_action") {
            guard let action = BashPermissionAction(rawValue: defaultActionStr.lowercased()) else {
                throw ConfigError.validationError(field: "bash.default_action", message: "must be allow, ask, or deny")
            }
            config.bash.defaultAction = action
        }
        if let timeout = try bash.strictInt("timeout_seconds", field: "bash.timeout_seconds") {
            config.bash.timeoutSeconds = timeout
        }
        if let allowNetwork = try bash.strictBool("allow_network", field: "bash.allow_network") {
            config.bash.allowNetwork = allowNetwork
        }
        // Resource bounds stay type-only here like the wall-clock timeout;
        // range checks land in validation so decode never invents a clamp
        // that would hide a typo from the dotted-field diagnostic.
        if let cpuSeconds = try bash.strictInt("cpu_seconds", field: "bash.cpu_seconds") {
            config.bash.cpuSeconds = cpuSeconds
        }
        if let memoryMB = try bash.strictInt("memory_mb", field: "bash.memory_mb") {
            config.bash.memoryMB = memoryMB
        }
        if let rawMode = try bash.strictString("sandbox_mode", field: "bash.sandbox_mode") {
            let trimmed = rawMode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let mode = BashSandboxMode(rawValue: trimmed) else {
                throw ConfigError.validationError(
                    field: "bash.sandbox_mode",
                    message: "must be one of \(BashSandboxMode.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(rawMode)')"
                )
            }
            config.bash.sandboxMode = mode
        }
        if let patterns = try bash.strictStringArray("host_allow_patterns", field: "bash.host_allow_patterns") {
            try BashConfig.validateHostAllowPatterns(patterns)
            config.bash.hostAllowPatterns = patterns
        }
        if let ruleTables = root.arrays["bash.rules"] ?? root.tables["bash"]?.arrays["rules"] {
            var rules: [BashRule] = []
            for (idx, node) in ruleTables.enumerated() {
                guard let pattern = try node.strictString("pattern", field: "bash.rules[\(idx)].pattern") else {
                    throw ConfigError.validationError(field: "bash.rules[\(idx)].pattern", message: "missing required")
                }
                // Single-sourced through `BashRule.validate(index:)` so file-load, the settings
                // PUT, and core validation agree on the blank-pattern field and message.
                try BashRule(pattern: pattern, action: .ask).validate(index: idx)
                let actionStr = try node.strictString("action", field: "bash.rules[\(idx)].action") ?? "ask"
                guard let action = BashPermissionAction(rawValue: actionStr.lowercased()) else {
                    throw ConfigError.validationError(field: "bash.rules[\(idx)].action", message: "must be allow, ask, or deny")
                }
                rules.append(BashRule(pattern: pattern, action: action))
            }
            // A present rule list replaces the built-in default in stored order; an absent key
            // preserves the default.
            config.bash.rules = rules
        }
    }

    /// Decodes the additive `[proactive]` section, defaulting omitted keys.
    static func decodeProactive(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let proactive = root.tables["proactive"] else { return }
        if let rawMode = try proactive.strictString("mode", field: "proactive.mode") {
            let lowered = rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let mode = ProactiveMode(rawValue: lowered) else {
                throw ConfigError.validationError(
                    field: "proactive.mode",
                    message: "must be one of \(ProactiveMode.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(rawMode)')"
                )
            }
            config.proactive.mode = mode
        }
        if let timeout = try proactive.strictInt("judge_timeout_seconds", field: "proactive.judge_timeout_seconds") {
            config.proactive.judgeTimeoutSeconds = timeout
        }
    }

    /// Decodes the additive `[ideas]` section, defaulting omitted keys.
    static func decodeIdeas(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let ideas = root.tables["ideas"] else { return }
        if let enabled = try ideas.strictBool("enabled", field: "ideas.enabled") {
            config.ideas.enabled = enabled
        }
        if let maxPerCycle = try ideas.strictInt("max_per_cycle", field: "ideas.max_per_cycle") {
            config.ideas.maxPerCycle = maxPerCycle
        }
        if let timeout = try ideas.strictInt("timeout_seconds", field: "ideas.timeout_seconds") {
            config.ideas.timeoutSeconds = timeout
        }
    }

    /// Decodes the additive `[fanout]` section, defaulting omitted keys.
    static func decodeFanout(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let fanout = root.tables["fanout"] else { return }
        if let maxWorkers = try fanout.strictInt("max_workers", field: "fanout.max_workers") {
            config.fanOut.maxWorkers = maxWorkers
        }
        if let timeout = try fanout.strictInt("worker_timeout_seconds", field: "fanout.worker_timeout_seconds") {
            config.fanOut.workerTimeoutSeconds = timeout
        }
        if let fullTools = try fanout.strictBool("full_tools", field: "fanout.full_tools") {
            config.fanOut.fullTools = fullTools
        }
    }

    /// Decodes the additive `[workspace]` section, defaulting omitted keys.
    static func decodeWorkspace(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let workspace = root.tables["workspace"] else { return }
        if let quotaMB = try workspace.strictInt("quota_mb", field: "workspace.quota_mb") {
            config.workspace.quotaMB = quotaMB
        }
        if let quotaFiles = try workspace.strictInt("quota_files", field: "workspace.quota_files") {
            config.workspace.quotaFiles = quotaFiles
        }
        if let ttlDays = try workspace.strictInt("tmp_ttl_days", field: "workspace.tmp_ttl_days") {
            config.workspace.tmpTTLDays = ttlDays
        }
    }

    /// Decodes the additive `[persona]` section, defaulting omitted keys.
    static func decodePersona(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let persona = root.tables["persona"] else { return }
        // One leading `try` per assignment covers the throwing strict read,
        // plus the normalizer where it throws, mirroring the neighboring additive decoders.
        config.persona.assistantName = try PersonaConfig.normalizedAssistantName(
            persona.strictString("assistant_name", field: "persona.assistant_name")
        )
        config.persona.tone = try PersonaConfig.normalizedTone(
            persona.strictString("tone", field: "persona.tone")
        )
        config.persona.style = try PersonaConfig.normalizedStyle(
            persona.strictString("style", field: "persona.style")
        )
        config.persona.userName = try PersonaConfig.normalizedUserName(
            persona.strictString("user_name", field: "persona.user_name")
        )
        config.persona.avatar = try PersonaConfig.normalizedAvatar(
            persona.strictString("avatar", field: "persona.avatar")
        )
    }

    /// Decodes the additive `[notifications]` section, defaulting omitted keys.
    static func decodeNotifications(_ root: TOMLNode, into config: inout RuneWeaverConfig) throws {
        guard let notifications = root.tables["notifications"] else { return }
        // Fail-closed on unknown keys so a typo never silently disables filtering.
        try Self.validateNotificationsKeys(notifications)
        if let approvalRequested = try notifications.strictBool("approval_requested", field: "notifications.approval_requested") {
            config.notifications.approvalRequested = approvalRequested
        }
        if let schedulerRun = try notifications.strictBool("scheduler_run", field: "notifications.scheduler_run") {
            config.notifications.schedulerRun = schedulerRun
        }
        if let goalAdvance = try notifications.strictBool("goal_advance", field: "notifications.goal_advance") {
            config.notifications.goalAdvance = goalAdvance
        }
        if let ideaProposed = try notifications.strictBool("idea_proposed", field: "notifications.idea_proposed") {
            config.notifications.ideaProposed = ideaProposed
        }
        if let indexFailed = try notifications.strictBool("index_failed", field: "notifications.index_failed") {
            config.notifications.indexFailed = indexFailed
        }
        if let chatFailed = try notifications.strictBool("chat_failed", field: "notifications.chat_failed") {
            config.notifications.chatFailed = chatFailed
        }
        if let pushContact = try notifications.strictString("push_contact", field: "notifications.push_contact") {
            config.notifications.pushContact = pushContact
        }
    }
}
