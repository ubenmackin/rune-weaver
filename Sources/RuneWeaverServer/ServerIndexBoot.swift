// Rune Weaver Server — Boot wiring for the local document index.
//
// Builds the `[index]` pipeline once per boot so serve and the menu-bar app share
// one construction path: a `DocIndexStore` over the configured `db_path`, one
// source stage per corpus (files, mail, messages, calendars, reminders), and
// the `IndexCoordinator` sequencing them. A
// disabled `[index]` section returns nil so boot keeps the previous no-index
// posture and the index routes keep failing closed. Credentials are never
// resolved here; the mail stage reads through the shared IMAP gateway seam and
// resolves account passwords at execution time through `SecretsManager`.

import Foundation
import RuneWeaverCore
import RuneWeaverTools

/// Document index collaborators built once at boot from `[index]`.
public struct ServerIndexComponents: Sendable {
    /// Document store backing status, prune, reset, and recall.
    public let store: DocIndexStore
    /// Coordinator sequencing the enabled source stages.
    public let coordinator: IndexCoordinator
    /// Configured `db_path` spelling shared with the memory engine.
    public let docIndexDBPath: String

    /// Creates boot index collaborators.
    /// - Parameters:
    ///   - store: Document store the stages write into.
    ///   - coordinator: Coordinator sequencing the stages.
    ///   - docIndexDBPath: Configured `db_path` spelling for recall wiring.
    public init(store: DocIndexStore, coordinator: IndexCoordinator, docIndexDBPath: String) {
        self.store = store
        self.coordinator = coordinator
        self.docIndexDBPath = docIndexDBPath
    }
}

/// Single-sourced `[index]` boot construction for serve and the menu-bar app.
public enum ServerIndexBoot {
    /// Builds the document store plus the coordinator for an enabled `[index]`.
    ///
    /// Files walk through the shared `[files]` policy adapter, mail reads through
    /// the shared IMAP gateway adapter, messages use their bundled defaults,
    /// and calendars and reminders read through the shared live EventKit
    /// store. Each stage still gates on its own toggle, so an
    /// enabled indexer with every source off runs an honest empty pass. The run
    /// reporter adapts the coordinator lifecycle onto the same run store the
    /// status probe reads plus the live socket hub, so a manual run leaves one
    /// start row updated in place by its completion instead of vanishing.
    /// - Parameters:
    ///   - config: Root config carrying the `[index]` section plus source policies.
    ///   - runs: Durable run audit trail the status probe reads; receives the start plus completion rows.
    ///   - hub: Live sockets receiving the run start plus completion broadcasts.
    ///   - embedder: Embeddings backend shared with recall, or nil for keyword-only.
    ///   - makeEmbeddingsBackend: Per-slot backend factory for the files pool, or nil to share `embedder`.
    /// - Returns: Store plus coordinator, or nil when `[index] enabled` is false.
    public static func makeComponents(
        config: RuneWeaverConfig,
        runs: RunLogStore,
        hub: WSHub,
        embedder: (any EmbeddingsBackend)?,
        makeEmbeddingsBackend: (@Sendable () -> (any EmbeddingsBackend)?)? = nil
    ) -> ServerIndexComponents? {
        guard config.index.enabled else { return nil }
        let indexConfig = config.index
        let dbPath = indexConfig.dbPath
        let store = DocIndexStore(dbPath: dbPath)
        let filesStage = IndexClosureStage.files(
            config: indexConfig,
            store: store,
            embedder: embedder,
            makeEmbeddingsBackend: makeEmbeddingsBackend,
            accessGuard: FilesIndexPolicyGuard(filesConfig: config.files)
        )
        let mailStage = IndexClosureStage.mail(
            config: indexConfig,
            emailConfig: config.email,
            gateway: EmailIMAPMailIndexGateway(gateway: SubprocessIMAPGateway(), securityConfig: config.security),
            store: store,
            embedder: embedder
        )
        let messagesStage = IndexClosureStage.messages(config: indexConfig, store: store, embedder: embedder)
        let liveStore = LiveEventKitStore()
        let calendarsStage = CalendarIndexer.makeCalendarStage(
            config: indexConfig,
            store: store,
            calendarStore: liveStore,
            embedder: embedder
        )
        let remindersStage = RemindersIndexer.makeRemindersStage(
            config: indexConfig,
            store: store,
            reminderStore: liveStore,
            embedder: embedder
        )
        let stages: [any IndexSourceStage] = [filesStage, mailStage, messagesStage, calendarsStage, remindersStage]
        let coordinator = IndexCoordinator(
            config: indexConfig,
            stages: stages,
            store: store,
            reporter: ServerIndexRunReporter(runs: runs, hub: hub)
        )
        return ServerIndexComponents(store: store, coordinator: coordinator, docIndexDBPath: dbPath)
    }
}
