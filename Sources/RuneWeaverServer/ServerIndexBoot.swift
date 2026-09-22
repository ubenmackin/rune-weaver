// Rune Weaver Server — Boot wiring for the local document index.
//
// Builds the `[index]` pipeline once per boot so serve and the menu-bar app share
// one construction path: a `DocIndexStore` over the configured `db_path`, one
// source stage per corpus (files, mail, messages, plus the opt-in vision describe
// stage), and the `IndexCoordinator` sequencing them. A disabled `[index]` section
// returns nil so boot keeps the previous no-index posture and the index routes
// keep failing closed. Credentials are never resolved here; the mail stage reads
// through the shared IMAP gateway seam and resolves account passwords at
// execution time through `SecretsManager`.

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
    /// the shared IMAP gateway adapter, messages use their bundled defaults, and
    /// the vision stage describes only when the opt-in flag is set and an active
    /// provider is available. Each stage still gates on its own toggle, so an
    /// enabled indexer with every source off runs an honest empty pass.
    /// - Parameters:
    ///   - config: Root config carrying the `[index]` section plus source policies.
    ///   - embedder: Embeddings backend shared with recall, or nil for keyword-only.
    ///   - visionLLM: Active provider backing image description, or nil to skip vision.
    /// - Returns: Store plus coordinator, or nil when `[index] enabled` is false.
    public static func makeComponents(
        config: RuneWeaverConfig,
        embedder: (any EmbeddingsBackend)?,
        visionLLM: (any LLMProvider)?
    ) -> ServerIndexComponents? {
        guard config.index.enabled else { return nil }
        let indexConfig = config.index
        let dbPath = indexConfig.dbPath
        let store = DocIndexStore(dbPath: dbPath)
        let filesStage = IndexClosureStage.files(
            config: indexConfig,
            store: store,
            embedder: embedder,
            accessGuard: FilesIndexPolicyGuard(filesConfig: config.files)
        )
        let mailStage = IndexClosureStage.mail(
            config: indexConfig,
            emailConfig: config.email,
            gateway: EmailIMAPMailIndexGateway(gateway: SubprocessIMAPGateway()),
            store: store,
            embedder: embedder
        )
        let messagesStage = IndexClosureStage.messages(config: indexConfig, store: store)
        var stages: [any IndexSourceStage] = [filesStage, mailStage, messagesStage]
        if indexConfig.describeImagesWithLLM, let visionLLM {
            // The store exposes no pending-image listing, so boot wires an empty
            // backlog: the stage stays toggle-gated and reports an honest empty
            // pass until explicit backlog plumbing supplies candidates.
            stages.append(IndexClosureStage.vision(
                config: indexConfig,
                store: store,
                provider: LLMVisionDescribeAdapter(llm: visionLLM),
                pendingDocuments: { [] },
                imageData: { _ in nil }
            ))
        }
        let coordinator = IndexCoordinator(config: indexConfig, stages: stages, store: store)
        return ServerIndexComponents(store: store, coordinator: coordinator, docIndexDBPath: dbPath)
    }
}

/// Adapts the active chat provider to the vision description seam.
///
/// The seam lives in core beside the indexer so no module boundary is crossed:
/// the adapter only forwards `modelInfo` and the bounded image URL the indexer
/// already prepared, collecting one chat turn into description text. A text-only
/// provider never reaches the network because the indexer applies the shared
/// vision gate before calling.
private struct LLMVisionDescribeAdapter: VisionDescribeProvider {
    /// Active provider answering description requests.
    private let llm: any LLMProvider

    /// Creates an adapter over the active provider.
    fileprivate init(llm: any LLMProvider) {
        self.llm = llm
    }

    /// Metadata for the active model.
    var modelInfo: ModelInfo {
        llm.modelInfo
    }

    /// Describes one bounded image via a single chat turn.
    /// - Parameters:
    ///   - imageDataURL: Bounded `data:image/jpeg;base64,...` content.
    ///   - prompt: Instruction describing the desired output.
    /// - Returns: Description text, or nil when the provider cannot answer.
    func describeImage(_ imageDataURL: String, prompt: String) async -> String? {
        guard llm.modelInfo.supportsVision else { return nil }
        guard !Task.isCancelled else { return nil }
        let trimmedURL = imageDataURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        let messages = [Message(role: .user, content: prompt + "\n" + trimmedURL)]
        var collected = ""
        for await chunk in llm.chat(messages: messages, tools: []) {
            if Task.isCancelled {
                return nil
            }
            if chunk.isError {
                break
            }
            collected += chunk.delta
            if chunk.isFinished {
                break
            }
        }
        let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
