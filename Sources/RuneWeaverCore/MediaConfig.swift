// Rune Weaver Core — Media automation configuration (Sonarr & Radarr).
//
// Purpose: single source for self-hosted TV and movie manager settings backing
// the `media.arr` tool, TOML decoding, validation, and serialization.
// Scope: plain value types only; HTTP, secrets resolution, and tool gating live
// with the client and tool layers. Architectural role: the `[media]` section
// shape shared by config load, settings routes, and media execution.
// Secrets live in the Keychain or environment and never in TOML — only
// `apiKeyEnv` names persist and resolve at execution time. Network dials never
// happen here; an enabled entry with a blank or missing URL stays unconfigured
// (guidance error, no dial) so stock installs fail closed until a base URL is set.

import Foundation

/// One self-hosted Arr instance (Sonarr for TV, Radarr for movies).
///
/// Sonarr and Radarr share the same five-field shape, so a single struct backs
/// both sections and the per-service key names stay with the factories and the
/// `MediaConfig` defaults below. Only env-var names persist; key values resolve
/// via `SecretsManager` at execution time. A blank or missing `url` with
/// `enabled` true means unconfigured rather than active: callers report guidance
/// and never dial.
public struct ArrInstanceConfig: Sendable, Codable, Equatable {
    /// Whether this service integration is enabled.
    public var enabled: Bool
    /// Service base URL (e.g. `http://localhost:8989`). Nil or blank means unconfigured.
    public var url: String?
    /// Environment variable holding the API key (e.g. `SONARR_API_KEY`).
    public var apiKeyEnv: String?
    /// Optional default quality profile name (e.g. `HD-1080p`).
    public var defaultQualityProfile: String?
    /// Optional default root folder path (e.g. `/data/media/tv`).
    public var defaultRootFolder: String?

    /// Env-var name holding the Sonarr API key when no override is set.
    public static let defaultSonarrAPIKeyEnv = "SONARR_API_KEY"
    /// Env-var name holding the Radarr API key when no override is set.
    public static let defaultRadarrAPIKeyEnv = "RADARR_API_KEY"

    public init(
        enabled: Bool = true,
        url: String? = nil,
        apiKeyEnv: String? = nil,
        defaultQualityProfile: String? = nil,
        defaultRootFolder: String? = nil
    ) {
        self.enabled = enabled
        self.url = url
        self.apiKeyEnv = apiKeyEnv
        self.defaultQualityProfile = defaultQualityProfile
        self.defaultRootFolder = defaultRootFolder
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case url
        case apiKeyEnv = "api_key_env"
        case defaultQualityProfile = "default_quality_profile"
        case defaultRootFolder = "default_root_folder"
    }

    /// Stock Sonarr entry: enabled with no URL (unconfigured until set) and the
    /// conventional key name.
    public static func makeSonarr(
        enabled: Bool = true,
        url: String? = nil,
        apiKeyEnv: String? = defaultSonarrAPIKeyEnv,
        defaultQualityProfile: String? = nil,
        defaultRootFolder: String? = nil
    ) -> ArrInstanceConfig {
        ArrInstanceConfig(
            enabled: enabled,
            url: url,
            apiKeyEnv: apiKeyEnv,
            defaultQualityProfile: defaultQualityProfile,
            defaultRootFolder: defaultRootFolder
        )
    }

    /// Stock Radarr entry: enabled with no URL (unconfigured until set) and the
    /// conventional key name.
    public static func makeRadarr(
        enabled: Bool = true,
        url: String? = nil,
        apiKeyEnv: String? = defaultRadarrAPIKeyEnv,
        defaultQualityProfile: String? = nil,
        defaultRootFolder: String? = nil
    ) -> ArrInstanceConfig {
        ArrInstanceConfig(
            enabled: enabled,
            url: url,
            apiKeyEnv: apiKeyEnv,
            defaultQualityProfile: defaultQualityProfile,
            defaultRootFolder: defaultRootFolder
        )
    }

    /// Stock Sonarr defaults shared by `MediaConfig` so absent TOML keeps the
    /// conventional key name instead of drifting to nil.
    public static var defaultSonarr: ArrInstanceConfig {
        makeSonarr()
    }

    /// Stock Radarr defaults shared by `MediaConfig` so absent TOML keeps the
    /// conventional key name instead of drifting to nil.
    public static var defaultRadarr: ArrInstanceConfig {
        makeRadarr()
    }

    /// Whether this entry differs from stock in a way that must persist.
    ///
    /// Blank and missing values read identically (nil, empty, and whitespace all
    /// mean absent), and a nil/blank/default key name all read as stock since the
    /// client falls back to the conventional name — so a nil-only entry collapses
    /// to stock instead of emitting a section that would decode back as default.
    /// - Parameter defaultAPIKeyEnv: Conventional key name for this service.
    /// - Returns: True when the entry carries user intent worth writing.
    func isCustomized(defaultAPIKeyEnv: String) -> Bool {
        if !enabled {
            return true
        }
        if NormalizedText.value(url) != nil {
            return true
        }
        if let env = NormalizedText.value(apiKeyEnv), env != defaultAPIKeyEnv {
            return true
        }
        if NormalizedText.value(defaultQualityProfile) != nil {
            return true
        }
        if NormalizedText.value(defaultRootFolder) != nil {
            return true
        }
        return false
    }
}

/// One Sonarr instance configuration. Tokens live in the Keychain
/// or environment, never in TOML.
public typealias SonarrConfig = ArrInstanceConfig

/// One Radarr instance configuration. Tokens live in the Keychain
/// or environment, never in TOML.
public typealias RadarrConfig = ArrInstanceConfig

/// `[media]` — Media automation configurations (Sonarr & Radarr).
///
/// Both sides default to enabled-but-unconfigured (no URL, conventional key
/// name): the tool reports guidance and never dials until a base URL is set.
public struct MediaConfig: Sendable, Codable, Equatable {
    /// Sonarr configuration.
    public var sonarr: SonarrConfig
    /// Radarr configuration.
    public var radarr: RadarrConfig
    /// HTTP request timeout in seconds for media automation calls.
    public var timeoutSeconds: Int

    /// Default request timeout for media calls.
    public static let defaultTimeoutSeconds = 15

    public init(
        sonarr: SonarrConfig = .defaultSonarr,
        radarr: RadarrConfig = .defaultRadarr,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) {
        self.sonarr = sonarr
        self.radarr = radarr
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case sonarr
        case radarr
        case timeoutSeconds = "timeout_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sonarr = try container.decodeIfPresent(SonarrConfig.self, forKey: .sonarr) ?? .defaultSonarr
        radarr = try container.decodeIfPresent(RadarrConfig.self, forKey: .radarr) ?? .defaultRadarr
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Self.defaultTimeoutSeconds
    }
}
