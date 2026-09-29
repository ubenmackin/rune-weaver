// Rune Weaver Core — Subsystem configurations (Home, Plugins, Browser, Desktop, Security, Goals, Proactive).

import Foundation

// MARK: - Home automation integrations

/// One `[[home.homekit]]` entry.
public struct HomeKitConfig: Sendable, Codable, Equatable {
    /// Whether HomeKit control is enabled.
    public var enabled: Bool

    /// Creates a HomeKit config.
    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// One `[[home.home_assistant]]` entry. Tokens live in the Keychain
/// or environment, never in TOML.
public struct HomeAssistantConfig: Sendable, Codable, Equatable {
    /// Whether Home Assistant control is enabled.
    public var enabled: Bool
    /// Home Assistant base URL.
    public var url: String?
    /// Environment variable holding the long-lived access token.
    public var tokenEnv: String?

    /// Creates a Home Assistant config.
    public init(enabled: Bool = true, url: String? = nil, tokenEnv: String? = nil) {
        self.enabled = enabled
        self.url = url
        self.tokenEnv = tokenEnv
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case url
        case tokenEnv = "token_env"
    }
}

/// `[home]` — home automation integrations.
public struct HomeConfig: Sendable, Codable, Equatable {
    /// HomeKit entries.
    public var homekit: [HomeKitConfig]
    /// Home Assistant entries.
    public var homeAssistant: [HomeAssistantConfig]

    /// Creates a home config.
    public init(
        homekit: [HomeKitConfig] = [],
        homeAssistant: [HomeAssistantConfig] = []
    ) {
        self.homekit = homekit
        self.homeAssistant = homeAssistant
    }

    private enum CodingKeys: String, CodingKey {
        case homekit
        case homeAssistant = "home_assistant"
    }
}

// MARK: - Plugin discovery and marketplace

/// `[plugins]` — plugin discovery and marketplace configuration.
public struct PluginConfig: Sendable, Codable, Equatable {
    /// Directory where installed and discovered plugins reside (defaults to `~/.runeweaver/plugins`).
    public var pluginsDir: String
    /// Remote marketplace index URL for browsing and downloading runes.
    public var marketplaceIndexURL: String
    /// Whether to automatically scan the plugins directory on server startup.
    public var autoRescan: Bool

    /// Creates a plugin configuration.
    public init(
        pluginsDir: String = "~/.runeweaver/plugins",
        marketplaceIndexURL: String = "https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json",
        autoRescan: Bool = true
    ) {
        self.pluginsDir = pluginsDir
        self.marketplaceIndexURL = marketplaceIndexURL
        self.autoRescan = autoRescan
    }

    private enum CodingKeys: String, CodingKey {
        case pluginsDir = "plugins_dir"
        case marketplaceIndexURL = "marketplace_index_url"
        case autoRescan = "auto_rescan"
    }
}

// MARK: - Browser configuration

/// `[browser]` — local web search and fetch policy.
public struct BrowserConfig: Sendable, Codable, Equatable {
    /// SearXNG base URL (e.g. `http://127.0.0.1:8888`). Requests append `/search`.
    public var searxngURL: String
    /// Per-search HTTP timeout in seconds, bounding one SearXNG round trip.
    public var searchTimeoutSeconds: Int
    /// Maximum results returned per `web.search` call, bounding context fan-out.
    public var maxResults: Int

    /// Default SearXNG base URL for local-first installs.
    public static let defaultSearxngURL = "http://127.0.0.1:8888"
    /// Default per-search timeout in seconds.
    public static let defaultSearchTimeoutSeconds = 10
    /// Default result cap per search.
    public static let defaultMaxResults = 10
    /// Hard upper bound for `max_results`, mirroring mail search caps.
    public static let maxAllowedResults = 50

    /// Environment variable overriding the browser Python executable.
    /// Single source for the override name so the gateway, the managed venv
    /// ensurer, and health copy never drift; pipx and Homebrew installs do not
    /// satisfy `import playwright` for the server python, so an explicit path
    /// here always wins over the managed venv and the PATH fallback.
    public static let pythonBinEnvVar = "RUNEWEAVER_PYTHON_BIN"
    /// Managed virtual-environment directory for browser automation.
    /// Kept under `~/.runeweaver` so provisioning never touches a user-owned
    /// venv elsewhere and an existing managed entry is reused, never clobbered.
    public static let managedPythonVenvDir = "~/.runeweaver/python"
    /// Relative path of the interpreter inside the managed venv.
    public static let managedPythonRelativeBin = "bin/python"

    /// Managed venv directory with `~` expanded to the home directory.
    /// - Returns: Directory hosting the managed `bin/python`.
    public static func managedPythonVenvDirURL() -> URL {
        URL(fileURLWithPath: (managedPythonVenvDir as NSString).expandingTildeInPath)
    }

    /// Interpreter path inside the managed venv.
    /// - Returns: `~/.runeweaver/python/bin/python` expanded for the current user.
    public static func managedPythonExecutableURL() -> URL {
        managedPythonVenvDirURL().appendingPathComponent(managedPythonRelativeBin)
    }

    /// Display path for the managed venv directory (unexpanded, for copy).
    /// - Returns: `~/.runeweaver/python` as configured.
    public static func managedPythonVenvDisplayPath() -> String {
        managedPythonVenvDir
    }

    /// Display path for the managed interpreter (unexpanded, for copy).
    /// - Returns: `~/.runeweaver/python/bin/python` as configured.
    public static func managedPythonDisplayPath() -> String {
        (managedPythonVenvDir as NSString).appendingPathComponent(managedPythonRelativeBin)
    }

    /// Additional allowed homelab domains, hostnames, or IP patterns for browser/web navigation.
    public var allowedOrigins: [String]

    /// Default allowed origins for fresh installs.
    public static let defaultAllowedOrigins: [String] = []

    /// Creates a browser config.
    public init(
        searxngURL: String = defaultSearxngURL,
        searchTimeoutSeconds: Int = defaultSearchTimeoutSeconds,
        maxResults: Int = defaultMaxResults,
        allowedOrigins: [String] = defaultAllowedOrigins
    ) {
        self.searxngURL = searxngURL
        self.searchTimeoutSeconds = searchTimeoutSeconds
        self.maxResults = maxResults
        self.allowedOrigins = allowedOrigins
    }

    private enum CodingKeys: String, CodingKey {
        case searxngURL = "searxng_url"
        case searchTimeoutSeconds = "search_timeout_seconds"
        case maxResults = "max_results"
        case allowedOrigins = "allowed_origins"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searxngURL = try container.decodeIfPresent(String.self, forKey: .searxngURL) ?? Self.defaultSearxngURL
        searchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .searchTimeoutSeconds) ?? Self.defaultSearchTimeoutSeconds
        maxResults = try container.decodeIfPresent(Int.self, forKey: .maxResults) ?? Self.defaultMaxResults
        allowedOrigins = try container.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? Self.defaultAllowedOrigins
    }
}

// MARK: - Desktop vision and control

/// `[desktop]` — macOS desktop vision and control capture policy.
///
/// Both desktop tools always register so they stay visible in `GET /tools`,
/// but they ship disabled and go live only through the persisted tool-state
/// toggle, which is the sole authority for enablement. The `[desktop]`
/// section carries only capture knobs (dimensions, quality, blocklist), so
/// a stock install exposes no approval-free capture until an operator
/// enables `desktop.screenshot`. The screenshot tool is read-only, while
/// `desktop.action` requires approval per-invocation through the permission
/// gate.
public struct DesktopConfig: Sendable, Equatable {
    /// Longest edge of the downscaled screenshot in pixels. Bounds token cost.
    public var maxImageDimension: Int
    /// JPEG compression quality for downscaled screenshots (0.0–1.0).
    public var jpegQuality: Double
    /// Application names where `desktop.action` will refuse to dispatch input.
    /// Protects sensitive apps from automated clicks and keystrokes.
    public var blockedApps: [String]

    /// Default longest edge for downscaled screenshots.
    public static let defaultMaxImageDimension = 1280
    /// Hard upper bound for `maxImageDimension`.
    public static let maxAllowedImageDimension = 3840
    /// Default JPEG quality.
    public static let defaultJpegQuality: Double = 0.75
    /// Default sensitive-app blocklist.
    public static let defaultBlockedApps = [
        "Terminal",
        "iTerm2",
        "Keychain Access",
        "System Settings",
        "System Preferences",
        "1Password",
        "Bitwarden"
    ]

    /// Creates a desktop config.
    public init(
        maxImageDimension: Int = defaultMaxImageDimension,
        jpegQuality: Double = defaultJpegQuality,
        blockedApps: [String] = defaultBlockedApps
    ) {
        self.maxImageDimension = maxImageDimension
        self.jpegQuality = jpegQuality
        self.blockedApps = blockedApps
    }

    private enum CodingKeys: String, CodingKey {
        case maxImageDimension = "max_image_dimension"
        case jpegQuality = "jpeg_quality"
        case blockedApps = "blocked_apps"
    }
}

extension DesktopConfig: Codable {
    /// Decodes a desktop config, defaulting omitted keys.
    /// Unknown keys (including retired allow toggles) are ignored so old
    /// files load without migration.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxImageDimension = try container.decodeIfPresent(Int.self, forKey: .maxImageDimension) ?? Self.defaultMaxImageDimension
        jpegQuality = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? Self.defaultJpegQuality
        blockedApps = try container.decodeIfPresent([String].self, forKey: .blockedApps) ?? Self.defaultBlockedApps
    }

    /// Encodes a desktop config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxImageDimension, forKey: .maxImageDimension)
        try container.encode(jpegQuality, forKey: .jpegQuality)
        try container.encode(blockedApps, forKey: .blockedApps)
    }
}

// MARK: - Untrusted-content labeling policy

/// `[security]` — harness-level defense policy for external content.
///
/// Labeling stays default-ON: untrusted tool output is wrapped as data so the
/// model cannot mistake it for instructions, at roughly twenty tokens per
/// result. The labeling key is a debugging off-switch, not a hardening knob —
/// turning it off restores the pre-labeling context shape byte-identically.
/// The credential filter stays default-ON so one-time codes, magic links, and
/// password-reset links never reach the agent; the human inbox is untouched
/// and only agent-visible mail plus the local index carry the redacted form.
public struct SecurityConfig: Sendable, Equatable {
    /// Whether untrusted external tool output is wrapped before model context.
    /// Defaults to true; false disables labeling for debugging only.
    public var untrustedLabeling: Bool
    /// Whether agent-visible mail redacts one-time codes and credential links.
    /// Defaults to true; false passes mail through byte-identically.
    public var emailCredentialFilter: Bool

    /// Default keeps labeling on so stock installs stay hardened.
    public static let defaultUntrustedLabeling = true
    /// Default keeps credential redaction on so stock installs stay hardened.
    public static let defaultEmailCredentialFilter = true

    /// Creates a security config.
    public init(
        untrustedLabeling: Bool = defaultUntrustedLabeling,
        emailCredentialFilter: Bool = defaultEmailCredentialFilter
    ) {
        self.untrustedLabeling = untrustedLabeling
        self.emailCredentialFilter = emailCredentialFilter
    }

    private enum CodingKeys: String, CodingKey {
        case untrustedLabeling = "untrusted_labeling"
        case emailCredentialFilter = "email_credential_filter"
    }
}

extension SecurityConfig: Codable {
    /// Decodes a security config, defaulting omitted keys so existing files load untouched.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        untrustedLabeling = try container.decodeIfPresent(Bool.self, forKey: .untrustedLabeling) ?? Self.defaultUntrustedLabeling
        emailCredentialFilter = try container.decodeIfPresent(Bool.self, forKey: .emailCredentialFilter) ?? Self.defaultEmailCredentialFilter
    }

    /// Encodes a security config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(untrustedLabeling, forKey: .untrustedLabeling)
        try container.encode(emailCredentialFilter, forKey: .emailCredentialFilter)
    }
}

// MARK: - Long-horizon goal pursuit

/// `[goals]` — steady pursuit of long-horizon goals.
///
/// Goals stay opt-in so a fresh install never schedules background
/// advancement or spends planning calls until the owner enables them.
/// `stepIntervalMinutes` is the cadence hint stored on each new goal and
/// reused when the engine bumps `next_due_at` after a run; the remaining
/// caps bound how many goals stay active at once, how long a decomposed
/// plan may grow, and how long planning may wait on the model before the
/// resilient fallback keeps the goal.
public struct GoalsConfig: Sendable, Equatable {
    /// Whether goal creation and advancement run at all. Off by default.
    public var enabled: Bool
    /// Cadence hint in minutes stored on each new goal. Defaults to daily.
    public var stepIntervalMinutes: Int
    /// Maximum goals in the active state at once. Bounds scheduler fan-out.
    public var maxActiveGoals: Int
    /// Maximum steps in one decomposed plan. Bounds planning context.
    public var maxStepsPerGoal: Int
    /// Seconds the planner waits on the model before falling back.
    public var planTimeoutSeconds: Int
    /// Maximum event triggers armed on one goal. Bounds trigger fan-out.
    public var maxTriggersPerGoal: Int

    /// Default keeps goals off so stock installs stay quiet.
    public static let defaultEnabled = false
    /// Default cadence is daily, matching the scheduler's overnight rhythm.
    public static let defaultStepIntervalMinutes = 1440
    /// Default active-goal cap keeps the due scan small.
    public static let defaultMaxActiveGoals = 10
    /// Default plan length fits one screen of numbered steps.
    public static let defaultMaxStepsPerGoal = 12
    /// Default planning budget waits out slow local models without stalling creation.
    public static let defaultPlanTimeoutSeconds = 60
    /// Smallest cadence that still counts as steady rather than busy-looping.
    public static let minStepIntervalMinutes = 5
    /// Largest cadence before a goal reads as abandoned rather than paced.
    public static let maxStepIntervalMinutes = 20160
    /// Fewest active goals worth configuring.
    public static let minActiveGoalsBound = 1
    /// Most active goals before due advancement fans out unbounded.
    public static let maxActiveGoalsBound = 50
    /// Shortest plan worth decomposing.
    public static let minStepsPerGoalBound = 1
    /// Longest plan before the prompt crowds out execution context.
    public static let maxStepsPerGoalBound = 24
    /// Default trigger budget keeps event wake-ups from swamping the due scan.
    public static let defaultMaxTriggersPerGoal = 8
    /// Fewest triggers worth configuring (zero disables event wake-ups).
    public static let minTriggersPerGoalBound = 0
    /// Most triggers per goal before wake-up fan-out is abandoned.
    public static let maxTriggersPerGoalBound = 32
    /// Default debounce window between two fires of the same trigger.
    public static let defaultTriggerCooldownMinutes = 60
    /// Shortest debounce that still prevents a tight re-fire loop.
    public static let minTriggerCooldownMinutes = 1

    /// Creates a goals config.
    public init(
        enabled: Bool = defaultEnabled,
        stepIntervalMinutes: Int = defaultStepIntervalMinutes,
        maxActiveGoals: Int = defaultMaxActiveGoals,
        maxStepsPerGoal: Int = defaultMaxStepsPerGoal,
        planTimeoutSeconds: Int = defaultPlanTimeoutSeconds,
        maxTriggersPerGoal: Int = defaultMaxTriggersPerGoal
    ) {
        self.enabled = enabled
        self.stepIntervalMinutes = stepIntervalMinutes
        self.maxActiveGoals = maxActiveGoals
        self.maxStepsPerGoal = maxStepsPerGoal
        self.planTimeoutSeconds = planTimeoutSeconds
        self.maxTriggersPerGoal = maxTriggersPerGoal
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case stepIntervalMinutes = "step_interval_minutes"
        case maxActiveGoals = "max_active_goals"
        case maxStepsPerGoal = "max_steps_per_goal"
        case planTimeoutSeconds = "plan_timeout_seconds"
        case maxTriggersPerGoal = "max_triggers_per_goal"
    }
}

extension GoalsConfig: Codable {
    /// Decodes a goals config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.defaultEnabled
        stepIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .stepIntervalMinutes) ?? Self.defaultStepIntervalMinutes
        maxActiveGoals = try container.decodeIfPresent(Int.self, forKey: .maxActiveGoals) ?? Self.defaultMaxActiveGoals
        maxStepsPerGoal = try container.decodeIfPresent(Int.self, forKey: .maxStepsPerGoal) ?? Self.defaultMaxStepsPerGoal
        planTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .planTimeoutSeconds) ?? Self.defaultPlanTimeoutSeconds
        maxTriggersPerGoal = try container.decodeIfPresent(Int.self, forKey: .maxTriggersPerGoal) ?? Self.defaultMaxTriggersPerGoal
    }

    /// Encodes a goals config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(stepIntervalMinutes, forKey: .stepIntervalMinutes)
        try container.encode(maxActiveGoals, forKey: .maxActiveGoals)
        try container.encode(maxStepsPerGoal, forKey: .maxStepsPerGoal)
        try container.encode(planTimeoutSeconds, forKey: .planTimeoutSeconds)
        try container.encode(maxTriggersPerGoal, forKey: .maxTriggersPerGoal)
    }
}

// MARK: - Proactive surfacing policy

/// Surfacing mode for proactive background interruptions.
///
/// The gate filters macOS notifications and dashboard interruption frames
/// only; run history, WebSocket run frames, and the approvals inbox always
/// record regardless of mode so auditing never loses a turn.
public enum ProactiveMode: String, Sendable, Codable, CaseIterable, Equatable {
    /// Surface every background outcome.
    case all
    /// Surface goal milestones, errors, and parked turns only.
    case milestones
    /// Milestones plus a judge call for routine scheduler successes.
    case guarded
    /// Never surface an interruption.
    case off
}

/// `[proactive]` — interruption policy for background scheduler and goal turns.
///
/// Stock installs surface everything so behavior matches the pre-gate
/// notifier byte-for-byte; owners quiet routine successes by moving to
/// `milestones` (milestones plus errors plus parked only) or `guarded`
/// (milestones plus one judge call for routine scheduler successes), or
/// silence interruptions entirely with `off`. The judge timeout bounds the
/// single model call the guarded path may spend before failing open.
public struct ProactiveConfig: Sendable, Equatable {
    /// Surfacing mode. Defaults to `all` for byte-for-byte legacy behavior.
    public var mode: ProactiveMode
    /// Seconds the guarded judge may spend before the gate fails open.
    public var judgeTimeoutSeconds: Int

    /// Default keeps every interruption surfacing like the legacy notifier.
    public static let defaultMode = ProactiveMode.all
    /// Default judge budget waits out slow local models without stalling the tick.
    public static let defaultJudgeTimeoutSeconds = 15
    /// Smallest judge budget that still allows one model round trip.
    public static let minJudgeTimeoutSeconds = 1
    /// Largest judge budget before a routine success holds the tick too long.
    public static let maxJudgeTimeoutSeconds = 120

    /// Creates a proactive config.
    public init(
        mode: ProactiveMode = defaultMode,
        judgeTimeoutSeconds: Int = defaultJudgeTimeoutSeconds
    ) {
        self.mode = mode
        self.judgeTimeoutSeconds = judgeTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case judgeTimeoutSeconds = "judge_timeout_seconds"
    }
}

extension ProactiveConfig: Codable {
    /// Decodes a proactive config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(ProactiveMode.self, forKey: .mode) ?? Self.defaultMode
        judgeTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .judgeTimeoutSeconds) ?? Self.defaultJudgeTimeoutSeconds
    }

    /// Encodes a proactive config.
    /// - Parameter encoder: Encoder for the config document.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(judgeTimeoutSeconds, forKey: .judgeTimeoutSeconds)
    }
}
