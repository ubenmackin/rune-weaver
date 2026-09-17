// Rune Weaver Server — Search lifecycle DTOs for the local SearXNG engine.
//
// Purpose: carries the health, ensure, and stop shapes for the `/search`
// routes so the dashboard can poll one contract for reachability, the live
// Start stage, and retry-aware failure detail.
// Scope: REST request/response bodies only; lifecycle policy and cascade
// budgets stay single-sourced in the shared ensurer.
// Architectural role: keeps the Vapor search adapters decoupled from the
// engine core by translating ensurer outcomes into version-tolerant Codable
// contracts.

import Foundation
import Vapor

/// Search engine health response for `GET /search/health`.
/// Encodes both `baseURL` (canonical) and `url` plus `status` so dashboard
/// clients reading either contract keep the custom port instead of falling
/// back to the default. Carries the live Start stage plus Start time while an
/// ensure flight runs so the dashboard can poll this one endpoint about 1s
/// for the amber Starting line; both decode to nil on idle or older engines.
public struct SearchHealthResponse: Content, Equatable {
    /// Whether the SearXNG base URL answered with 2xx/3xx.
    public let reachable: Bool
    /// Configured SearXNG base URL that was probed.
    public let baseURL: String
    /// Container name backing the lifecycle, when managed.
    public let containerName: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (`"running"` when reachable, else `"stopped"`).
    public let status: String
    /// In-flight Start stage (`resolving`, `daemon`, `pulling`, `starting`,
    /// `waiting`), nil when no Start is running.
    public let stage: String?
    /// Unix seconds when the in-flight Start began, nil when idle.
    /// A number (not a Date) so every dashboard decodes it without sharing a
    /// date strategy with the engine.
    public let startedAt: Double?

    /// Creates a health response.
    public init(reachable: Bool, baseURL: String, containerName: String, url: String? = nil, status: String? = nil, stage: String? = nil, startedAt: Double? = nil) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.containerName = containerName
        self.url = url ?? baseURL
        self.status = status ?? (reachable ? "running" : "stopped")
        let trimmedStage = (stage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.stage = trimmedStage.isEmpty ? nil : trimmedStage
        if let startedAt, startedAt.isFinite, startedAt > 0 {
            self.startedAt = startedAt
        } else {
            self.startedAt = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reachable
        case baseURL
        case containerName
        case url
        case status
        case stage
        case startedAt
    }

    /// Decodes tolerantly across `baseURL`/`url` shapes plus optional stage keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        let alias = try container.decodeIfPresent(String.self, forKey: .url)
        let resolved = base ?? alias ?? ""
        baseURL = resolved
        url = alias ?? resolved
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? (reachable ? "running" : "stopped")
        let rawStage = try container.decodeIfPresent(String.self, forKey: .stage)
        let trimmedStage = (rawStage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        stage = trimmedStage.isEmpty ? nil : trimmedStage
        let rawStartedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
        if let rawStartedAt, rawStartedAt.isFinite, rawStartedAt > 0 {
            startedAt = rawStartedAt
        } else {
            startedAt = nil
        }
    }

    /// Encodes both `baseURL` and `url` plus `status` for dual-contract reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(stage, forKey: .stage)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
    }
}

/// Search engine ensure response for `POST /search/ensure`.
/// `message` carries the single trimmed banner (one retry-aware terminal cause
/// plus one hatch command: pull timeout names cached-layer retry, pull failure
/// names Hub reachability, run failure names the exit plus tail) for inline
/// error slots, while `diagnostics` carries the full per-stage detail (stage,
/// exit, capped tail, timeout, including the pull stage ahead of run) for warn
/// logs plus the collapsed Settings diagnostics element. Older engines omit
/// `diagnostics`, which decodes to nil.
public struct SearchEnsureResponse: Content, Equatable {
    /// Whether the engine answers after the ensure attempt.
    public let reachable: Bool
    /// Configured SearXNG base URL that was ensured.
    public let baseURL: String
    /// Whether a start was attempted during this call.
    public let started: Bool
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (`"running"` when reachable, else `"stopped"`).
    public let status: String
    /// Trimmed banner (terminal cause plus one remediation) when unreachable.
    public let message: String?
    /// Full per-stage detail for logs plus collapsed diagnostics, when unreachable.
    public let diagnostics: String?

    /// Creates an ensure response.
    public init(reachable: Bool, baseURL: String, started: Bool, url: String? = nil, status: String? = nil, message: String? = nil, diagnostics: String? = nil) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.started = started
        self.url = url ?? baseURL
        self.status = status ?? (reachable ? "running" : "stopped")
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed.isEmpty ? nil : trimmed
        let trimmedDiagnostics = (diagnostics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.diagnostics = trimmedDiagnostics.isEmpty ? nil : trimmedDiagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case reachable
        case baseURL
        case started
        case url
        case status
        case message
        case diagnostics
    }

    /// Decodes tolerantly across `baseURL`/`url` shapes plus optional message and diagnostics.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        let alias = try container.decodeIfPresent(String.self, forKey: .url)
        let resolved = base ?? alias ?? ""
        baseURL = resolved
        url = alias ?? resolved
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? (reachable ? "running" : "stopped")
        let rawMessage = try container.decodeIfPresent(String.self, forKey: .message)
        let trimmed = (rawMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        message = trimmed.isEmpty ? nil : trimmed
        let rawDiagnostics = try container.decodeIfPresent(String.self, forKey: .diagnostics)
        let trimmedDiagnostics = (rawDiagnostics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics = trimmedDiagnostics.isEmpty ? nil : trimmedDiagnostics
    }

    /// Encodes both `baseURL` and `url` plus `status` for dual-contract reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(started, forKey: .started)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
    }
}

/// Search engine stop response for `POST /search/stop`.
/// Carries a failure detail in `message` when the engine still answers after
/// the stop, so the dashboard can render why the halt did not take instead of
/// falling back to a generic notice.
public struct SearchStopResponse: Content, Equatable {
    /// Whether the container is stopped (honest re-probe: false when the engine still answers).
    public let stopped: Bool
    /// Container name that was stopped.
    public let containerName: String
    /// Whether the engine answers after the stop (honest re-probe; true when the stop failed or the engine still answers).
    public let reachable: Bool
    /// Configured SearXNG base URL for dashboard fallback display.
    public let baseURL: String
    /// Alias of `baseURL` for dashboard clients expecting `url`.
    public let url: String
    /// Collapsed status (honest re-probe: `"running"` when still reachable, else `"stopped"`).
    public let status: String
    /// Failure detail when the engine still answers after the stop.
    public let message: String?

    /// Creates a stop response.
    public init(stopped: Bool, containerName: String, reachable: Bool = false, baseURL: String = "", url: String? = nil, status: String? = nil, message: String? = nil) {
        self.stopped = stopped
        self.containerName = containerName
        self.reachable = reachable
        self.baseURL = baseURL
        self.url = url ?? baseURL
        self.status = status ?? (reachable ? "running" : "stopped")
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case stopped
        case containerName
        case reachable
        case baseURL
        case url
        case status
        case message
    }

    /// Decodes tolerantly so dashboard `SearchHealthResponse` shapes still parse.
    /// An absent `stopped` derives from the honest `reachable` probe instead
    /// of optimistically assuming stopped on shape drift.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? !reachable
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName) ?? ""
        let base = try container.decodeIfPresent(String.self, forKey: .baseURL)
        let alias = try container.decodeIfPresent(String.self, forKey: .url)
        let resolved = base ?? alias ?? ""
        baseURL = resolved
        url = alias ?? resolved
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? (reachable ? "running" : "stopped")
        let rawMessage = try container.decodeIfPresent(String.self, forKey: .message)
        let trimmed = (rawMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        message = trimmed.isEmpty ? nil : trimmed
    }

    /// Encodes the full shape so health-style readers keep working.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stopped, forKey: .stopped)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(url, forKey: .url)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
    }
}
