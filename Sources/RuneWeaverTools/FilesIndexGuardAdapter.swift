// Rune Weaver Tools — Adapter binding the shared file access guard to the files indexer seam.
//
// The core files indexer walks candidate paths through a narrow protocol seam so it
// stays free of the tool layer. This adapter maps that seam onto the shared
// `FilesAccessGuard`, which owns the `[files]` deny/allow policy, so boot-time
// indexing enforces exactly the same policy as the file tools. Denied paths stay
// skipped by the indexer; escalation never fires from a background run.

import Foundation
import RuneWeaverCore

/// Adapts the shared `[files]` guard to the core files indexer seam.
public struct FilesIndexPolicyGuard: FilesIndexAccessGuard, Sendable {
    /// `[files]` policy consulted for every candidate path.
    private let filesConfig: FilesConfig

    /// Creates a guard adapter over one `[files]` policy.
    /// - Parameter filesConfig: Policy the indexer walk enforces.
    public init(filesConfig: FilesConfig = FilesConfig()) {
        self.filesConfig = filesConfig
    }

    /// Evaluates one candidate path against the shared `[files]` policy.
    /// - Parameters:
    ///   - path: Raw candidate path.
    ///   - homeDirectoryURL: Home boundary override, or nil for the real home.
    /// - Returns: The policy decision for the path.
    public func evaluate(path: String, homeDirectoryURL: URL?) -> FilesIndexAccessDecision {
        let decision = FilesAccessGuard.evaluate(
            path: path,
            homeDirectoryURL: homeDirectoryURL,
            filesConfig: filesConfig
        )
        return FilesIndexAccessDecision(
            allowed: decision.allowed,
            requiresApproval: decision.requiresApproval,
            reason: decision.reason,
            resolvedPath: decision.resolvedPath
        )
    }
}
