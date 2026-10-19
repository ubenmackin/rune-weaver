// Rune Weaver Tools — Models and DTOs for Sonarr and Radarr media automation.

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

    /// Wire key map for decoding.
    private enum CodingKeys: String, CodingKey {
        case service
        case action
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

        let rawService = try container.decodeIfPresent(String.self, forKey: .service)
        guard let rawService, let service = MediaArrService(rawValue: rawService.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw DecodingError.dataCorruptedError(
                forKey: .service,
                in: container,
                debugDescription: "Invalid service: expected 'sonarr' or 'radarr'"
            )
        }
        self.service = service

        let rawAction = try container.decodeIfPresent(String.self, forKey: .action)
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

        // External IDs stay service-scoped so a cross-service alias cannot silently reinterpret:
        // Sonarr reads TVDB IDs while Radarr reads TMDB IDs, and the mismatched alias fails with
        // guidance instead of masquerading as the other service's identifier.
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

        // Compatibility-only profile and folder spellings kept out of the strict schema: the wire
        // advertises camelCase `qualityProfile`/`rootFolder` while the decoder also accepts
        // snake-case `quality_profile`/ `root_folder` for drifted callers.
        self.qualityProfile = try container.decodeIfPresent(String.self, forKey: .qualityProfile)
            ?? container.decodeIfPresent(String.self, forKey: .qualityProfileName)

        self.rootFolder = try container.decodeIfPresent(String.self, forKey: .rootFolder)
            ?? container.decodeIfPresent(String.self, forKey: .rootFolderPath)
    }
}
