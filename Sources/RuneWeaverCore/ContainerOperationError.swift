// Rune Weaver Core — Container operation errors.

import Foundation

/// Errors relating to container operations.
public enum ContainerOperationError: LocalizedError, Sendable {
    case runtimeNotFound(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .runtimeNotFound(runtime):
            // Name the searched directories so the failure alone explains the
            // miss; the ordering mirrors the resolver (PATH first, then the
            // Homebrew fallbacks) instead of a bare "not in PATH".
            let searched = StrictContainerRunner.runtimeSearchDirectories().joined(separator: ", ")
            return "Apple container CLI ('\(runtime)') was not found in PATH. Install via https://github.com/apple/container. Searched: \(searched)."
        case let .operationFailed(reason):
            return reason
        }
    }
}
