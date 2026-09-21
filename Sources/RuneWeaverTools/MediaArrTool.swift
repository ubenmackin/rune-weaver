// Rune Weaver Tools — Media management tool for Sonarr & Radarr.
//
// Purpose: exposes the Sonarr/Radarr library to the model as approval-gated
// writes plus approval-free reads, with dry-run previews that never dial.
// Scope: argument decoding plus client dispatch only; HTTP, validation, and
// secrets live with the client layer. Architectural role: the split read/write
// surface for media — the read tool stays read-only so search, queue, and
// status never park, while adds stay gated. Secrets resolve via
// `SecretsManager` at execution time and never enter schemas or logs; network
// dials stay behind the client's timeout, byte-cap, and redirect bounds.

import Foundation
import RuneWeaverCore

/// Tool for managing TV shows (Sonarr) and movies (Radarr) in home media library.
public struct MediaArrTool: Tool, Sendable {
    public let name = "media.arr"
    public let description =
        "Manages home media library across Sonarr (TV shows) and Radarr (movies). "
            + "Supports searching titles, adding series or movies with automatic monitoring and downloads, "
            + "viewing the active download queue, and checking service health. "
            + "Specify service: 'sonarr' for TV shows or 'radarr' for movies. "
            + "Action can be 'search', 'add', 'queue', or 'status'. "
            + "For approval-free reads prefer 'media.arr.read'."

    /// Function-calling contract for the combined tool.
    /// Every decoder alias (`app`/`target`, `command`, `title`/`term`,
    /// `tvdbId`/`tmdbId`, `quality_profile`, `root_folder`) is advertised so a
    /// strict `additionalProperties:false` validator accepts exactly what
    /// `MediaArrArgs` decodes.
    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "service": {
              "type": "string",
              "enum": ["sonarr", "radarr"],
              "description": "Target service: 'sonarr' for TV shows or 'radarr' for movies"
            },
            "app": {
              "type": "string",
              "enum": ["sonarr", "radarr"],
              "description": "Alias for service"
            },
            "target": {
              "type": "string",
              "enum": ["sonarr", "radarr"],
              "description": "Alias for service"
            },
            "action": {
              "type": "string",
              "enum": ["search", "add", "status", "queue"],
              "description": "Action: 'search' to find titles, 'add' to library, 'queue' to view downloads, or 'status' to check health"
            },
            "command": {
              "type": "string",
              "enum": ["search", "add", "status", "queue"],
              "description": "Alias for action"
            },
            "query": {
              "type": "string",
              "description": "Title or keyword for search or add (e.g. 'Shogun', 'Fallout', 'Gladiator II')"
            },
            "title": {
              "type": "string",
              "description": "Alias for query"
            },
            "term": {
              "type": "string",
              "description": "Alias for query"
            },
            "id": {
              "type": "integer",
              "description": "Optional TVDB ID (for Sonarr) or TMDB ID (for Radarr) when adding a specific title"
            },
            "tvdbId": {
              "type": "integer",
              "description": "Alias for id (Sonarr TVDB ID)"
            },
            "tmdbId": {
              "type": "integer",
              "description": "Alias for id (Radarr TMDB ID)"
            },
            "qualityProfile": {
              "type": "string",
              "description": "Optional quality profile name override (e.g. 'HD-1080p', 'Ultra-HD')"
            },
            "quality_profile": {
              "type": "string",
              "description": "Alias for qualityProfile"
            },
            "rootFolder": {
              "type": "string",
              "description": "Optional root folder path override"
            },
            "root_folder": {
              "type": "string",
              "description": "Alias for rootFolder"
            }
          },
          "allOf": [
            {"anyOf": [{"required": ["service"]}, {"required": ["app"]}, {"required": ["target"]}]},
            {"anyOf": [{"required": ["action"]}, {"required": ["command"]}]}
          ],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    private let client: MediaArrClient

    public init(
        mediaConfig: MediaConfig,
        transport: (any MediaArrTransport)? = nil,
        secrets: SecretsManager? = nil
    ) {
        self.client = MediaArrClient(mediaConfig: mediaConfig, transport: transport, secrets: secrets)
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: MediaArrArgs
        do {
            args = try JSONDecoder().decode(MediaArrArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid media.arr arguments: \(error.localizedDescription)", callID: input.callID)
        }

        // Dry-run previews for reads stay local so planning never dials: the
        // gated path still parks through the approval handler, while the
        // read-only sibling never parks. Mutating previews flow through the
        // client, which also avoids dialing for adds.
        if context.dryRun, args.action != .add {
            return .success(MediaArrDryRun.preview(for: args), callID: input.callID)
        }
        do {
            let output = try await client.execute(args: args, dryRun: context.dryRun)
            return .success(output, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Approval-free read surface for Sonarr & Radarr library state.
///
/// Search, queue, and status never change library state, so they run without
/// parking; any `add` routed here fails with guidance to use the gated
/// `media.arr` tool instead. Dry runs preview without dialing.
public struct MediaArrReadTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "media.arr.read"
    /// When the LLM should use this tool.
    public let description =
        "Reads home media library state across Sonarr (TV shows) and Radarr (movies). "
            + "Use for searching titles, viewing the download queue, or checking service health. "
            + "Approval-free; adding titles requires 'media.arr'."

    /// Function-calling contract for reads.
    /// Mirrors the combined schema's aliases so the same model drift works on
    /// both surfaces; `add` is absent here so strict validators route mutations
    /// to the gated tool.
    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "service": {
              "type": "string",
              "enum": ["sonarr", "radarr"],
              "description": "Target service: 'sonarr' for TV shows or 'radarr' for movies"
            },
            "app": {
              "type": "string",
              "enum": ["sonarr", "radarr"],
              "description": "Alias for service"
            },
            "target": {
              "type": "string",
              "enum": ["sonarr", "radarr"],
              "description": "Alias for service"
            },
            "action": {
              "type": "string",
              "enum": ["search", "status", "queue"],
              "description": "Read action: 'search' to find titles, 'queue' to view downloads, or 'status' to check health"
            },
            "command": {
              "type": "string",
              "enum": ["search", "status", "queue"],
              "description": "Alias for action"
            },
            "query": {
              "type": "string",
              "description": "Title or keyword for search (e.g. 'Shogun', 'Fallout')"
            },
            "title": {
              "type": "string",
              "description": "Alias for query"
            },
            "term": {
              "type": "string",
              "description": "Alias for query"
            },
            "id": {
              "type": "integer",
              "description": "Optional TVDB ID (for Sonarr) or TMDB ID (for Radarr)"
            },
            "tvdbId": {
              "type": "integer",
              "description": "Alias for id (Sonarr TVDB ID)"
            },
            "tmdbId": {
              "type": "integer",
              "description": "Alias for id (Radarr TMDB ID)"
            },
            "qualityProfile": {
              "type": "string",
              "description": "Ignored for reads; kept so shared call shapes validate"
            },
            "quality_profile": {
              "type": "string",
              "description": "Alias for qualityProfile"
            },
            "rootFolder": {
              "type": "string",
              "description": "Ignored for reads; kept so shared call shapes validate"
            },
            "root_folder": {
              "type": "string",
              "description": "Alias for rootFolder"
            }
          },
          "allOf": [
            {"anyOf": [{"required": ["service"]}, {"required": ["app"]}, {"required": ["target"]}]},
            {"anyOf": [{"required": ["action"]}, {"required": ["command"]}]}
          ],
          "additionalProperties": false
        }
        """
    )

    /// Always allowed: reads distill without changing library state.
    public let permissionLevel = PermissionLevel.readOnly

    private let client: MediaArrClient

    public init(
        mediaConfig: MediaConfig,
        transport: (any MediaArrTransport)? = nil,
        secrets: SecretsManager? = nil
    ) {
        self.client = MediaArrClient(mediaConfig: mediaConfig, transport: transport, secrets: secrets)
    }

    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        let args: MediaArrArgs
        do {
            args = try JSONDecoder().decode(MediaArrArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid media.arr.read arguments: \(error.localizedDescription)", callID: input.callID)
        }
        // The read surface never mutates: an `add` routed here fails closed
        // with guidance instead of dialing a write through a read-only grant.
        guard args.action != .add else {
            let message =
                "Action 'add' changes library state and requires the 'media.arr' tool (approval-gated); "
                    + "'media.arr.read' handles only 'search', 'queue', and 'status'."
            return .failure(message, callID: input.callID)
        }
        // Dry-run previews stay local so planning never dials for reads.
        if context.dryRun {
            return .success(MediaArrDryRun.preview(for: args), callID: input.callID)
        }
        do {
            let output = try await client.execute(args: args, dryRun: false)
            return .success(output, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Dry-run previews for media reads that never dial.
///
/// Single-sourced so the gated tool and the read-only tool describe the same
/// would-do shape; mutating previews stay with the client, which already
/// avoids dialing for adds.
enum MediaArrDryRun: Sendable {
    /// Builds a no-dial preview for one read action.
    static func preview(for args: MediaArrArgs) -> String {
        let serviceName = args.service.rawValue.capitalized
        switch args.action {
        case .status:
            return "[DRY RUN] Would check \(serviceName) status without dialing."
        case .queue:
            return "[DRY RUN] Would fetch \(serviceName) download queue without dialing."
        case .search:
            let term = args.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if term.isEmpty {
                return "[DRY RUN] Would search \(serviceName) without dialing (missing query)."
            }
            return "[DRY RUN] Would search \(serviceName) for '\(term)' without dialing."
        case .add:
            return "[DRY RUN] Would search and add '\(args.query ?? "ID: \(args.id ?? 0)")' to \(serviceName)."
        }
    }
}

/// Helper for constructing Media tools.
public enum MediaTools {
    public static var toolNames: [String] {
        ["media.arr.read", "media.arr"]
    }

    public static func makeTools(
        mediaConfig: MediaConfig = MediaConfig(),
        transport: (any MediaArrTransport)? = nil,
        secrets: SecretsManager? = nil
    ) -> [any Tool] {
        [
            MediaArrReadTool(mediaConfig: mediaConfig, transport: transport, secrets: secrets),
            MediaArrTool(mediaConfig: mediaConfig, transport: transport, secrets: secrets)
        ]
    }
}
