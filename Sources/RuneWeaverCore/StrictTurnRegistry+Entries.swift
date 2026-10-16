// Rune Weaver Core — Strict turn registry entries plus park helpers.

import Foundation

// MARK: - StrictTurnRegistry Entries

extension StrictTurnRegistry {
    /// Live strict turn entry.
    public struct Entry: Sendable, Equatable {
        /// Owning session.
        public let sessionID: UUID
        /// Isolated container name.
        public let containerName: String
        /// Fresh scratch leaf mounted into the container.
        public let scratchURL: URL
        /// Creation instant driving the sweep age.
        public let createdAt: Date
        /// Mount point inside the guest.
        public let guestPath: String
        /// Working directory inside the guest.
        public let workdir: String
        /// Whether the container runs without DNS.
        public let networkDenied: Bool

        /// Creates an entry.
        public init(
            sessionID: UUID,
            containerName: String,
            scratchURL: URL,
            createdAt: Date = Date(),
            guestPath: String = "/workspace",
            workdir: String = "/workspace",
            networkDenied: Bool = true
        ) {
            self.sessionID = sessionID
            self.containerName = containerName
            self.scratchURL = scratchURL
            self.createdAt = createdAt
            self.guestPath = guestPath
            self.workdir = workdir
            self.networkDenied = networkDenied
        }
    }

    /// Outcome of one park-aware sweep.
    public struct SweepResult: Sendable, Equatable {
        /// Strict containers stopped plus deleted.
        public let containersRemoved: Int
        /// Scratch leaves deleted.
        public let scratchRemoved: Int

        /// Creates a sweep result.
        public init(containersRemoved: Int = 0, scratchRemoved: Int = 0) {
            self.containersRemoved = containersRemoved
            self.scratchRemoved = scratchRemoved
        }
    }

    /// Time-to-live for registry entries plus orphan scratch.
    public static let sweepTTLSeconds: TimeInterval = 24 * 60 * 60
    /// Shared registry used by live turns.
    public static let shared = StrictTurnRegistry()

    /// Pure reap verdict: parked turns keep their container, terminal turns reap it.
    /// - Parameter isParked: Whether the turn parked awaiting approval.
    /// - Returns: True when the caller must reap.
    public static func shouldReapAfterOutcome(isParked: Bool) -> Bool {
        !isParked
    }

    /// Derives parked session IDs from the live approvals list.
    public static func parkedSessionIDs(from requests: [PermissionRequest]) -> Set<UUID> {
        Set(requests.compactMap(\.sessionID))
    }
}
