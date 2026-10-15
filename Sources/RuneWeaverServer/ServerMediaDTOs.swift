// Rune Weaver Server — Media settings DTOs for the settings API.
//
// Purpose: carries the partial Sonarr, Radarr, and combined media patches for
// `PUT /settings` so dashboard edits preserve untouched fields and services.
// Scope: REST patch bodies only; the settings request type owns merge policy
// while validation and persistence stay with the config layer.
// Architectural role: keeps media Codable contracts version-tolerant and
// decoupled from the broader settings surface.

import Foundation
import RuneWeaverCore
import Vapor

/// Partial Arr patch for `PUT /settings`.
/// Sonarr and Radarr share the same five-field shape, so one struct backs both
/// sides and the per-service names stay as aliases below. Every field stays
/// optional so a request carrying only one key leaves the stored toggle, URL,
/// and defaults untouched instead of resetting them.
public struct ArrSettingsUpdate: Content, Equatable {
    public var enabled: Bool?
    public var url: String?
    public var apiKeyEnv: String?
    public var defaultQualityProfile: String?
    public var defaultRootFolder: String?

    public init(
        enabled: Bool? = nil,
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

    /// Builds a patch carrying every field of a full snapshot so programmatic
    /// callers holding a complete config can reuse the merge path.
    public init(_ config: ArrInstanceConfig) {
        self.enabled = config.enabled
        self.url = config.url
        self.apiKeyEnv = config.apiKeyEnv
        self.defaultQualityProfile = config.defaultQualityProfile
        self.defaultRootFolder = config.defaultRootFolder
    }
}

/// Partial Sonarr patch, sharing the Arr shape so the two services cannot drift.
public typealias SonarrSettingsUpdate = ArrSettingsUpdate

/// Partial Radarr patch, sharing the Arr shape so the two services cannot drift.
public typealias RadarrSettingsUpdate = ArrSettingsUpdate

/// Partial media patch for `PUT /settings`.
/// A nil side preserves that service entirely, so updating Sonarr never clears
/// an untouched Radarr entry (and vice versa).
public struct MediaSettingsUpdate: Content, Equatable {
    public var sonarr: SonarrSettingsUpdate?
    public var radarr: RadarrSettingsUpdate?
    public var timeoutSeconds: Int?

    public init(
        sonarr: SonarrSettingsUpdate? = nil,
        radarr: RadarrSettingsUpdate? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.sonarr = sonarr
        self.radarr = radarr
        self.timeoutSeconds = timeoutSeconds
    }

    /// Builds a patch from a full snapshot so callers holding a complete
    /// `MediaConfig` can reuse the merge path without hand-mapping fields.
    public init(_ config: MediaConfig) {
        self.sonarr = SonarrSettingsUpdate(config.sonarr)
        self.radarr = RadarrSettingsUpdate(config.radarr)
        self.timeoutSeconds = config.timeoutSeconds
    }
}

extension UpdateSettingsRequest {
    /// Builds a request from a full media snapshot, routing through the same
    /// merge path so snapshot callers keep working without hand-mapping fields.
    public init(media: MediaConfig) {
        self.init(media: MediaSettingsUpdate(media))
    }
}

// MARK: - Media Settings Merge

extension UpdateSettingsRequest {
    /// Merges a partial media patch onto the stored config, preserving every
    /// field and every service the request omits. A nil patch or a nil side
    /// is a no-op, so touching Sonarr never resets Radarr.
    ///
    /// Internal so the shared settings `apply(to:)` keeps one merge path while
    /// the media-specific logic lives beside its DTOs.
    func applyMedia(to media: inout MediaConfig) {
        guard let update = self.media else { return }
        if let timeoutSeconds = update.timeoutSeconds {
            media.timeoutSeconds = timeoutSeconds
        }
        if let sonarr = update.sonarr {
            applyArr(sonarr, to: &media.sonarr)
        }
        if let radarr = update.radarr {
            applyArr(radarr, to: &media.radarr)
        }
    }

    /// Merges one Arr patch key-by-key; omitted keys keep their stored values
    /// and stored secrets are never cleared by an absent key. Blank text reads
    /// as absent (cleared to nil) so a dashboard-cleared field falls through to
    /// server auto-detect instead of persisting as an empty override. Sonarr and
    /// Radarr share this path so the two services cannot drift.
    func applyArr(_ update: ArrSettingsUpdate, to config: inout ArrInstanceConfig) {
        if let enabled = update.enabled {
            config.enabled = enabled
        }
        if let url = update.url {
            config.url = NormalizedText.value(url)
        }
        if let apiKeyEnv = update.apiKeyEnv {
            config.apiKeyEnv = NormalizedText.value(apiKeyEnv)
        }
        if let defaultQualityProfile = update.defaultQualityProfile {
            config.defaultQualityProfile = NormalizedText.value(defaultQualityProfile)
        }
        if let defaultRootFolder = update.defaultRootFolder {
            config.defaultRootFolder = NormalizedText.value(defaultRootFolder)
        }
    }
}
