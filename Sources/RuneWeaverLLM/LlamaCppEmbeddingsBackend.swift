// Rune Weaver LLM — Local llama.cpp Metal embeddings backend for EmbeddingGemma 2.

import Foundation
import RuneWeaverCore

#if canImport(Darwin)
    import Darwin
#endif
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// Embeddings backend running Google DeepMind's EmbeddingGemma 2 locally via `llama-server`.
public actor LlamaCppEmbeddingsBackend: EmbeddingsBackend {
    /// Stable model identifier reported to stores and diagnostics.
    public nonisolated let modelID: String = "embeddinggemma-2"

    /// Dimension of the EmbeddingGemma 2 model (768-dim).
    public nonisolated let dimension: Int? = 768

    /// UNIX domain socket path, or nil if using TCP.
    public nonisolated let socketPath: String?
    /// HTTP endpoint URL if using TCP/HTTP directly.
    public nonisolated let httpURL: URL?
    /// Optional supervisor managing the server lifecycle.
    public nonisolated let supervisor: LlamaEmbeddingSupervisor?

    /// Default maximum image file size accepted for visual embedding (30 MB).
    public static let defaultMaxImageBytes = 30 * 1024 * 1024

    /// Maximum image file size accepted for visual embedding in bytes.
    public nonisolated let maxImageBytes: Int

    /// Injected vector embedder for deterministic unit testing.
    private let customEmbedder: (@Sendable ([String]) async throws -> [[Float]])?
    /// Injected image vector embedder for deterministic unit testing.
    private let customImageEmbedder: (@Sendable (URL) async throws -> [Float])?

    /// Creates a backend connecting via UNIX domain socket.
    public init(
        socketPath: String = LlamaEmbeddingSupervisor.defaultSocketPath,
        supervisor: LlamaEmbeddingSupervisor? = LlamaEmbeddingSupervisor.shared,
        maxImageBytes: Int = defaultMaxImageBytes,
        customEmbedder: (@Sendable ([String]) async throws -> [[Float]])? = nil,
        customImageEmbedder: (@Sendable (URL) async throws -> [Float])? = nil
    ) {
        self.socketPath = socketPath
        self.httpURL = nil
        self.supervisor = supervisor
        self.maxImageBytes = maxImageBytes
        self.customEmbedder = customEmbedder
        self.customImageEmbedder = customImageEmbedder
    }

    /// Creates a backend connecting via standard HTTP endpoint.
    public init(
        httpURL: URL,
        supervisor: LlamaEmbeddingSupervisor? = nil,
        maxImageBytes: Int = defaultMaxImageBytes,
        customEmbedder: (@Sendable ([String]) async throws -> [[Float]])? = nil,
        customImageEmbedder: (@Sendable (URL) async throws -> [Float])? = nil
    ) {
        self.socketPath = nil
        self.httpURL = httpURL
        self.supervisor = supervisor
        self.maxImageBytes = maxImageBytes
        self.customEmbedder = customEmbedder
        self.customImageEmbedder = customImageEmbedder
    }

    /// Embeds a batch of texts using EmbeddingGemma 2.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        if let custom = customEmbedder {
            let vectors = try await custom(texts)
            let expectedDim = dimension ?? 768
            guard vectors.count == texts.count, vectors.allSatisfy({ $0.count == expectedDim }) else {
                throw EmbeddingsError.embeddingFailed
            }
            return vectors
        }

        if let supervisor {
            do {
                try await supervisor.ensureRunning()
            } catch {
                RuneWeaverLog.stores.error("LlamaCppEmbeddingsBackend: supervisor failed to ensure running: \(error.localizedDescription)")
                throw error
            }
        }

        let requestBody = EmbeddingRequestPayload(input: texts, model: modelID)
        let jsonData = try JSONEncoder().encode(requestBody)

        let responseData: Data
        if let socketPath {
            let expandedPath = (socketPath as NSString).expandingTildeInPath
            try Task.checkCancellation()
            // Socket I/O blocks for seconds, so it stays off the actor on a
            // detached task; cancellation propagates cooperatively so a stopped
            // index run aborts the in-flight request instead of waiting it out.
            let socketTask = Task.detached {
                try Self.sendHTTPRequestOverUnixSocket(
                    socketPath: expandedPath,
                    path: "/v1/embeddings",
                    body: jsonData
                )
            }
            do {
                responseData = try await withTaskCancellationHandler {
                    try await socketTask.value
                } onCancel: {
                    socketTask.cancel()
                }
            } catch {
                socketTask.cancel()
                throw error
            }
        } else if let httpURL {
            var request = URLRequest(url: httpURL.appendingPathComponent("v1/embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
                throw EmbeddingsError.embeddingFailed
            }
            responseData = data
        } else {
            throw EmbeddingsError.unavailable
        }

        let parsed: EmbeddingResponsePayload
        do {
            parsed = try JSONDecoder().decode(EmbeddingResponsePayload.self, from: responseData)
        } catch {
            throw EmbeddingsError.embeddingFailed
        }

        let sorted = parsed.data.sorted { $0.index < $1.index }
        let result = sorted.map(\.embedding)
        let expectedDim = dimension ?? 768
        guard result.count == texts.count, result.allSatisfy({ $0.count == expectedDim }) else {
            throw EmbeddingsError.embeddingFailed
        }
        return result
    }

    /// Direct multimodal image embedding for an image file at the specified URL.
    /// Reads and validates raw image bytes bounded by maxImageBytes with cancellation support.
    private func readBoundedImageData(at imageURL: URL) async throws -> Data {
        let size = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            ?? (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? NSNumber)?.intValue
        if let size, size > maxImageBytes {
            RuneWeaverLog.stores.warning(
                "LlamaCppEmbeddingsBackend: image at \(imageURL.path) is \(size) bytes, exceeding maxImageBytes \(maxImageBytes)."
            )
            throw EmbeddingsError.embeddingFailed
        }

        try Task.checkCancellation()
        let fileReadTask = Task.detached {
            try Data(contentsOf: imageURL)
        }
        let rawImageData: Data
        do {
            rawImageData = try await withTaskCancellationHandler {
                try await fileReadTask.value
            } onCancel: {
                fileReadTask.cancel()
            }
        } catch {
            fileReadTask.cancel()
            if error is CancellationError {
                throw error
            }
            throw EmbeddingsError.embeddingFailed
        }
        guard rawImageData.count <= maxImageBytes else {
            RuneWeaverLog.stores.warning(
                "LlamaCppEmbeddingsBackend: loaded image at \(imageURL.path) is \(rawImageData.count) bytes, exceeding maxImageBytes \(maxImageBytes)."
            )
            throw EmbeddingsError.embeddingFailed
        }
        return rawImageData
    }

    /// Dispatches an encoded JSON embedding request over unix domain socket or HTTP.
    private func sendEmbeddingRequest(jsonData: Data) async throws -> Data {
        if let socketPath {
            let expandedPath = (socketPath as NSString).expandingTildeInPath
            try Task.checkCancellation()
            let imageSocketTask = Task.detached {
                try Self.sendHTTPRequestOverUnixSocket(
                    socketPath: expandedPath,
                    path: "/v1/embeddings",
                    body: jsonData
                )
            }
            do {
                return try await withTaskCancellationHandler {
                    try await imageSocketTask.value
                } onCancel: {
                    imageSocketTask.cancel()
                }
            } catch {
                imageSocketTask.cancel()
                throw error
            }
        }
        if let httpURL {
            var request = URLRequest(url: httpURL.appendingPathComponent("v1/embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
                throw EmbeddingsError.embeddingFailed
            }
            return data
        }
        throw EmbeddingsError.unavailable
    }

    /// Extracts a dimension-matching embedding vector from OpenAI-compatible or native responses.
    nonisolated func parseEmbeddingVector(from responseData: Data, expectedDim: Int) -> [Float]? {
        if let parsed = try? JSONDecoder().decode(EmbeddingResponsePayload.self, from: responseData),
           let vector = parsed.data.first?.embedding, vector.count == expectedDim
        {
            return vector
        }
        if let parsedArray = try? JSONDecoder().decode([NativeEmbeddingArrayItem].self, from: responseData),
           let vector = parsedArray.first?.embedding.first, vector.count == expectedDim
        {
            return vector
        }
        if let parsed = try? JSONDecoder().decode(NativeEmbeddingResponse.self, from: responseData) {
            if let vector = parsed.embedding?.first, vector.count == expectedDim {
                return vector
            }
            if let vector = parsed.data?.first?.embedding, vector.count == expectedDim {
                return vector
            }
        }
        return nil
    }

    /// Resolves an `image/*` MIME type for a given image file URL.
    static func imageMIMEType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        #if canImport(UniformTypeIdentifiers)
            if !ext.isEmpty,
               let utType = UTType(filenameExtension: ext),
               let mime = utType.preferredMIMEType,
               mime.hasPrefix("image/")
            {
                return mime
            }
        #endif
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        default: return "image/jpeg"
        }
    }

    /// Direct multimodal image embedding for an image file at the specified URL.
    public func embedImage(at imageURL: URL) async throws -> [Float] {
        if let custom = customImageEmbedder {
            let vec = try await custom(imageURL)
            let expectedDim = dimension ?? 768
            guard vec.count == expectedDim else { throw EmbeddingsError.embeddingFailed }
            return vec
        }

        if let supervisor {
            do {
                try await supervisor.ensureRunning()
            } catch {
                RuneWeaverLog.stores.error("LlamaCppEmbeddingsBackend: supervisor failed to ensure running: \(error.localizedDescription)")
                throw error
            }
        }

        let rawImageData = try await readBoundedImageData(at: imageURL)
        let base64String = rawImageData.base64EncodedString()
        let mimeType = Self.imageMIMEType(for: imageURL)
        let dataURI = "data:\(mimeType);base64,\(base64String)"

        let payload = MultimodalEmbeddingRequest(
            model: modelID,
            input: [
                MultimodalEmbeddingInput(
                    content: [
                        MultimodalContentPart(
                            type: "image_url",
                            imageURL: MultimodalImageURL(url: dataURI)
                        )
                    ]
                )
            ]
        )
        let jsonData = try JSONEncoder().encode(payload)
        let responseData = try await sendEmbeddingRequest(jsonData: jsonData)

        let expectedDim = dimension ?? 768
        guard let vector = parseEmbeddingVector(from: responseData, expectedDim: expectedDim) else {
            throw EmbeddingsError.embeddingFailed
        }
        return vector
    }

    /// Backwards-compatible overload for multimodal image embedding.
    public func embedImage(_ imageURL: URL) async throws -> [Float] {
        try await embedImage(at: imageURL)
    }

    /// Embeds a search query with task prompt steering for EmbeddingGemma 2.
    public func embedQuery(_ text: String) async throws -> [Float]? {
        let steered = EmbeddingGemmaPrompts.query(text)
        do {
            let vectors = try await embed([steered])
            guard let vector = vectors.first, !vector.isEmpty else { return nil }
            return vector
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    // MARK: - Unix Domain Socket Transport

    private static func sendHTTPRequestOverUnixSocket(
        socketPath: String,
        path: String,
        body: Data
    ) throws -> Data {
        try UnixSocketHTTPClient.send(
            socketPath: socketPath,
            method: "POST",
            path: path,
            body: body
        )
    }
}

private struct EmbeddingRequestPayload: Encodable {
    let input: [String]
    let model: String
}

private struct EmbeddingResponsePayload: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }

    let data: [Item]
}

private struct MultimodalImageURL: Encodable {
    let url: String
}

private struct MultimodalContentPart: Encodable {
    let type: String
    let imageURL: MultimodalImageURL

    enum CodingKeys: String, CodingKey {
        case type
        case imageURL = "image_url"
    }
}

private struct MultimodalEmbeddingInput: Encodable {
    let content: [MultimodalContentPart]
}

private struct MultimodalEmbeddingRequest: Encodable {
    let model: String
    let input: [MultimodalEmbeddingInput]
}

private struct NativeEmbeddingArrayItem: Decodable {
    let index: Int?
    let embedding: [[Float]]
}

private struct NativeEmbeddingResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Float]
    }

    let embedding: [[Float]]?
    let data: [Item]?
}
