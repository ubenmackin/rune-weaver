// Rune Weaver Tools — Adapter binding the shared file access guard to the files indexer seam.

import Foundation
import RuneWeaverCore

/// Adapts the shared `[files]` deny patterns to the core files indexer seam. Index roots drive the
/// walk, so allow roots are ignored here; only deny patterns can refuse a candidate.
public struct FilesIndexPolicyGuard: FilesIndexAccessGuard, Sendable {
    /// `[files]` policy consulted for every candidate path.
    private let filesConfig: FilesConfig

    /// Creates a guard adapter over one `[files]` policy.
    /// - Parameter filesConfig: Policy the indexer walk enforces.
    public init(filesConfig: FilesConfig = FilesConfig()) {
        self.filesConfig = filesConfig
    }

    /// Evaluates one candidate path against the `[files]` deny patterns only. path:
    /// Raw candidate path.
    public func evaluate(path: String, homeDirectoryURL: URL?) -> FilesIndexAccessDecision {
        // Widen allow roots to the filesystem root so only deny patterns can
        // refuse: an index candidate outside `[files]` allow roots but matching
        // no deny pattern stays allowed, while a deny match still stays skipped.
        let denyOnlyConfig = FilesConfig(
            denyPatterns: filesConfig.denyPatterns,
            allowRoots: ["/"],
            requireApprovalOnDeny: filesConfig.requireApprovalOnDeny
        )
        let decision = FilesAccessGuard.evaluate(
            path: path,
            homeDirectoryURL: homeDirectoryURL,
            filesConfig: denyOnlyConfig
        )
        return FilesIndexAccessDecision(
            allowed: decision.allowed,
            requiresApproval: decision.requiresApproval,
            reason: decision.reason,
            resolvedPath: decision.resolvedPath
        )
    }
}
