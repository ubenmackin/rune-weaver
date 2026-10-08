// Rune Weaver Core — Container operation errors.
//
// Purpose: single error shape for container CLI lifecycle failures.
// Scope: missing runtime plus failed operation causes.
// Architectural role: shared error beside the other Core sandbox helpers;
// every container caller throws these instead of minting local errors.

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
