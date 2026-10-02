// Rune Weaver Tools — Models and DTOs for Sonarr and Radarr media automation.
//
// Purpose: decodes `media.arr` arguments across the canonical service, action,
// query, id, qualityProfile, and rootFolder keys with compatibility-only aliases for model drift.
// Scope: argument shapes only; transport, gating, and execution live with the
// client and tool layers. Architectural role: the single argument contract
// shared by the read and write tools so both validate identically. Decoder
// tolerance is intentionally kept out of the strict schema: schemas advertise
// canonical keys only with `type:object` plus explicit `required` plus
// `additionalProperties:false`, while `init(from:)` accepts legacy aliases
// (`app`/`target`, `command`, `title`/`term`, `tvdbId`/`tmdbId`, snake-case
// `quality_profile`/`root_folder`) so older model output still decodes without
// widening the wire contract.

import Foundation

/// Target *arr service for media operations.
public enum MediaArrService: String, Sendable, Codable, CaseIterable {
    /// Sonarr for TV show management.
    case sonarr
    /// Radarr for movie management.
    case radarr
}

/// Supported action on the *arr service.
public enum MediaArrAction: String, Sendable, Codable, CaseIterable {
    /// Search / lookup titles from TVDB/TMDB via the service.
    case search
    /// Add a title to the library and optionally start monitoring/download.
    case add
    /// Check current download activity / queue.
    case queue
    /// Check connectivity and system status.
    case status
}

/// Decoded arguments for `media.arr`.
public struct MediaArrArgs: Sendable, Equatable, Decodable {
    /// Target service (sonarr or radarr).
    public let service: MediaArrService
    /// Action to execute (search, add, queue, status).
    public let action: MediaArrAction
    /// Search query or title name.
    public let query: String?
    /// External database ID (TVDB ID for Sonarr, TMDB ID for Radarr).
    public let id: Int?
    /// Optional quality profile override.
    public let qualityProfile: String?
    /// Optional root folder override.
    public let rootFolder: String?

    public init(
        service: MediaArrService,
        action: MediaArrAction,
        query: String? = nil,
        id: Int? = nil,
        qualityProfile: String? = nil,
        rootFolder: String? = nil
    ) {
        self.service = service
        self.action = action
        self.query = query
        self.id = id
        self.qualityProfile = qualityProfile
        self.rootFolder = rootFolder
    }

    // Canonical-to-alias key map for compatibility-only decoding.
    // Canonical wire keys are `service`, `action`, `query`, `id`,
    // `qualityProfile`, and `rootFolder`; every other case here is a legacy
    // alias (`app`/`target` for service, `command` for action, `title`/`term`
    // for query, `tvdbId`/`tmdbId` for id, snake-case `quality_profile`/
    // `root_folder` alongside camelCase) kept so older model output still
    // decodes. Aliases never appear in either tool schema, so a strict
    // `additionalProperties:false` validator accepts exactly the canonical
    // shape while the decoder stays forgiving.
    private enum CodingKeys: String, CodingKey {
        case service
        case app
        case target
        case action
        case command
        case query
        case title
        case term
        case id
        case tvdbId
        case tmdbId
        case qualityProfile = "quality_profile"
        case qualityProfileName = "qualityProfile"
        case rootFolder = "root_folder"
        case rootFolderPath = "rootFolder"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Compatibility-only service aliases kept out of the strict schema:
        // canonical `service` wins, then legacy `app`/`target`, so drifted
        // model output still decodes while the wire contract stays canonical-only.
        let rawService = try container.decodeIfPresent(String.self, forKey: .service)
            ?? container.decodeIfPresent(String.self, forKey: .app)
            ?? container.decodeIfPresent(String.self, forKey: .target)
        guard let rawService, let service = MediaArrService(rawValue: rawService.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw DecodingError.dataCorruptedError(
                forKey: .service,
                in: container,
                debugDescription: "Invalid service: expected 'sonarr' or 'radarr'"
            )
        }
        self.service = service

        // Compatibility-only action alias kept out of the strict schema:
        // canonical `action` wins, then legacy `command` for the same drift reason.
        let rawAction = try container.decodeIfPresent(String.self, forKey: .action)
            ?? container.decodeIfPresent(String.self, forKey: .command)
        guard let rawAction, let action = MediaArrAction(rawValue: rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Invalid action: expected 'search', 'add', 'queue', or 'status'"
            )
        }
        self.action = action

        // Compatibility-only title aliases kept out of the strict schema:
        // canonical `query` wins, then `title`/`term`.
        self.query = try container.decodeIfPresent(String.self, forKey: .query)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .term)

        // External IDs stay service-scoped so a cross-service alias cannot
        // silently reinterpret: Sonarr reads TVDB IDs while Radarr reads TMDB
        // IDs, and the mismatched alias fails with guidance instead of
        // masquerading as the other service's identifier.
        let genericId = try container.decodeIfPresent(Int.self, forKey: .id)
        let tvdbId = try container.decodeIfPresent(Int.self, forKey: .tvdbId)
        let tmdbId = try container.decodeIfPresent(Int.self, forKey: .tmdbId)
        switch service {
        case .sonarr:
            if tmdbId != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .tmdbId,
                    in: container,
                    debugDescription: "Invalid id alias 'tmdbId' for Sonarr: use 'id' or 'tvdbId' (TMDB IDs belong with Radarr)."
                )
            }
            self.id = genericId ?? tvdbId
        case .radarr:
            if tvdbId != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .tvdbId,
                    in: container,
                    debugDescription: "Invalid id alias 'tvdbId' for Radarr: use 'id' or 'tmdbId' (TVDB IDs belong with Sonarr)."
                )
            }
            self.id = genericId ?? tmdbId
        }

        // Compatibility-only profile and folder spellings kept out of the strict
        // schema: the wire advertises camelCase `qualityProfile`/`rootFolder`
        // while the decoder also accepts snake-case `quality_profile`/
        // `root_folder` for drifted callers.
        self.qualityProfile = try container.decodeIfPresent(String.self, forKey: .qualityProfile)
            ?? container.decodeIfPresent(String.self, forKey: .qualityProfileName)

        self.rootFolder = try container.decodeIfPresent(String.self, forKey: .rootFolder)
            ?? container.decodeIfPresent(String.self, forKey: .rootFolderPath)
    }
}
