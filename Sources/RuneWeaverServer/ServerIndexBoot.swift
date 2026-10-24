// Rune Weaver Server — Boot wiring for the local document index.

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
    public init(store: DocIndexStore, coordinator: IndexCoordinator, docIndexDBPath: String) {
        self.store = store
        self.coordinator = coordinator
        self.docIndexDBPath = docIndexDBPath
    }
}

/// Single-sourced `[index]` boot construction for serve and the menu-bar app.
public enum ServerIndexBoot {
    /// Builds the failure-notifying reporter sharing one run store, hub, and combined notifier.
    public static func makeReporterWithNotifier(
        runs: RunLogStore,
        hub: WSHub,
        notifier: any SchedulerNotifier?
    ) -> ServerIndexRunReporter {
        ServerIndexRunReporter(runs: runs, hub: hub, notifier: notifier)
    }

    /// Builds the document store plus the coordinator for an enabled `[index]`. - embedder:
    /// Embeddings backend shared with recall, or nil for keyword-only.
    public static func makeComponents(
        config: RuneWeaverConfig,
        runs: RunLogStore,
        hub: WSHub,
        embedder: any EmbeddingsBackend?,
        makeEmbeddingsBackend: (@Sendable () -> (any EmbeddingsBackend)?)? = nil,
        notifier: any SchedulerNotifier? = nil
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
            reporter: makeReporterWithNotifier(runs: runs, hub: hub, notifier: notifier)
        )
        return ServerIndexComponents(store: store, coordinator: coordinator, docIndexDBPath: dbPath)
    }
}
