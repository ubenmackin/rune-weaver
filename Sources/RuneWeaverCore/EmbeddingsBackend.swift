// Rune Weaver Core — Pluggable vector-embedding seam for semantic memory.

import Foundation

/// Failures raised by an ``EmbeddingsBackend``.
public enum EmbeddingsError: Error, Sendable, Equatable {
    /// No embeddings model is configured or reachable.
    case unavailable
    /// An input batch was rejected before any embedding work.
    case invalidInput
    /// The model failed to embed an otherwise valid batch.
    case embeddingFailed
}

/// Abstraction over a vector-embedding backend.
public protocol EmbeddingsBackend: Sendable {
    /// Stable model identifier (e.g. `"embeddinggemma-2"`, `"disabled"`).
    var modelID: String { get }

    /// Embedding width, or nil when unknown until the first output.
    var dimension: Int? { get async }

    /// Embeds a batch of texts.
    func embed(_ texts: [String]) async throws -> [[Float]]

    /// Embeds an image file at the specified URL into a vector representation.
    func embedImage(at imageURL: URL) async throws -> [Float]
}

extension EmbeddingsBackend {
    /// Default implementation for backends without native multimodal support.
    public func embedImage(at _: URL) async throws -> [Float] {
        throw EmbeddingsError.unavailable
    }

    /// Embeds one query best-effort, preserving cancellation.
    public func embedQuery(_ text: String) async throws -> [Float]? {
        do {
            let vectors = try await embed([text])
            guard let vector = vectors.first, !vector.isEmpty else { return nil }
            return vector
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }
}

/// Disabled backend preserving keyword-only recall by construction.
public struct DisabledEmbeddingsBackend: EmbeddingsBackend, Sendable {
    /// Stable identifier marking vectors as never-embedded.
    public let modelID: String
    /// Always nil: a disabled backend has no width to advertise.
    public let dimension: Int? = nil

    /// Creates a disabled backend.
    /// - Parameter modelID: Identifier reported in diagnostics.
    ///   Defaults to `"disabled"`.
    public init(modelID: String = "disabled") {
        self.modelID = modelID
    }

    /// Rejects non-empty batches as unavailable.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        throw EmbeddingsError.unavailable
    }
}
