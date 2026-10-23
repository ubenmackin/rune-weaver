// Rune Weaver Core — Mail indexer helper methods and extensions.

import CryptoKit
import Dispatch
import Foundation

// MARK: - Value helpers

extension MailIndexer {
    /// Watermark update policy when indexing a page of mail messages.
    enum PageWatermarkMode: Sendable {
        /// Advance the watermark to each message's UID when `uid > 0`.
        case advancePerUID
        /// Hold the watermark at a fixed value for fresh messages when `uid > 0`.
        case fixedFresh(Int)
        /// Hold the watermark at a fixed value during historical backfill.
        case backfill(Int)
    }

    /// Prepared message ready for page-batched embedding and SQLite commit.
    struct PreparedMailMessage {
        let message: MailIndexMessage
        var outcome: MessageOutcome
        let document: IndexedDocument?
        let chunks: [DocumentChunk]
        let precomputedVectors: [Int: [Float]]
        let indicesToEmbed: [Int]
        let textsToEmbed: [String]
    }

    /// Reports whether a mailbox joins the Trash-class denylist.
    public static func isMailboxDenied(_ mailbox: String, patterns: [String]) -> Bool {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMailbox.isEmpty else { return false }
        let loweredMailbox = trimmedMailbox.lowercased()
        let segments = loweredMailbox.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var candidates = [loweredMailbox]
        candidates.append(contentsOf: segments)
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            for candidate in candidates where SharedGlobMatching.matches(pattern: pattern, relativePath: candidate) {
                return true
            }
        }
        return false
    }

    /// Whether a mail fetch error is worth retrying.
    public static func isRetryableMailError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        if MailErrorClassification.isAuthFailureDetail(described) {
            return false
        }
        return MailErrorClassification.isTransportFailureDetail(described)
    }

    /// Whether a STATUS probe failure must skip the mailbox without paging.
    static func isSkippableStatusError(_ error: Error) -> Bool {
        if let indexError = error as? MailIndexError {
            switch indexError {
            case .validationFailed, .unknownAccount:
                return true
            case .stagingFailed:
                return false
            }
        }
        let described: String = if let localized = (error as? LocalizedError)?.errorDescription {
            localized + " " + String(describing: error)
        } else {
            error.localizedDescription + " " + String(describing: error)
        }
        return MailErrorClassification.isAuthFailureDetail(described)
    }

    /// Closes a pooled mailbox session without inheriting cancellation.
    static func closeMailboxSessionAssumingOpen(
        gateway: any MailIndexGateway,
        credentials: MailIndexCredentials,
        mailbox: String
    ) async {
        await gateway.closeMailboxSession(credentials: credentials, mailbox: mailbox)
    }

    /// Parses an IMAP UID, returning zero for anything non-numeric.
    /// - Parameter id: Message identifier from the gateway.
    /// - Returns: The UID, or zero when the identifier is not numeric.
    static func uid(of id: String) -> Int {
        Int(id.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Filters to UIDs above the watermark and sorts ascending for contiguous advance. Newest-first
    /// pages are re-sorted so the watermark only advances past messages that were actually
    /// considered, never jumping a gap.
    static func freshSortedMessages(_ fetched: [MailIndexMessage], watermark: Int) -> [MailIndexMessage] {
        fetched
            .filter { Self.uid(of: $0.id) > watermark }
            .sorted { Self.uid(of: $0.id) < Self.uid(of: $1.id) }
    }

    /// Whether the watermark must be held over an unfetched gap.
    static func holdsWatermark(windowComplete: Bool, fresh: [MailIndexMessage], watermark: Int) -> Bool {
        let minFreshUID = fresh.map { Self.uid(of: $0.id) }.filter { $0 > 0 }.min()
        return !windowComplete && (minFreshUID ?? watermark + 1) > watermark + 1
    }

    /// Composes the source-scoped identifier for one message.
    static func documentExternalID(account: String, mailbox: String, messageID: String) -> String {
        let trimmedMailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(account)/\(trimmedMailbox)/\(messageID)"
    }

    /// Joins a subject and body into the indexed message text. subject: Decoded
    /// subject header.
    static func messageText(subject: String, body: String) -> String {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubject.isEmpty {
            return trimmedBody
        }
        if trimmedBody.isEmpty {
            return trimmedSubject
        }
        return "\(trimmedSubject)\n\n\(trimmedBody)"
    }

    /// Hashes message text for change detection and duplicate suppression.
    /// - Parameter text: Normalized message text.
    /// - Returns: Lowercase SHA-256 hex digest.
    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Human-readable name for a message document.
    /// - Parameter subject: Decoded subject header.
    /// - Returns: The trimmed subject, or a placeholder when blank.
    static func displayName(subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no subject)" : trimmed
    }

    /// Classifies how completely a message was extracted. hasText: Whether any
    /// chunk text was produced.
    static func extractStatus(hasText: Bool, degraded: Bool) -> ExtractStatus {
        guard hasText else { return .metadataOnly }
        return degraded ? .partial : .extracted
    }

    /// Reduces an attachment filename to a safe base name. The staged binary is only ever read back
    /// for extraction and then deleted, so this only needs to prevent path traversal and control
    /// characters.
    static func sanitizedFilename(_ filename: String, fallback: String) -> String {
        let base = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = base
            .replacingOccurrences(of: "\0", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        cleaned = cleaned.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if value < 32 || value == 127 {
                return "_"
            }
            return String(scalar)
        }.joined()
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 255 {
            cleaned = String(cleaned.prefix(255))
        }
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            return fallback
        }
        return cleaned
    }
}

// MARK: - Page-batched indexing & attachment staging

extension MailIndexer {
    /// Indexes a page of messages by preparing bodies/attachments, cross-message batching
    /// embeddings, committing all documents and chunks in a single SQLite transaction, and
    /// flushing checkpoints once for the page.
    func indexMailPageBatch(
        page: [MailIndexMessage],
        context: MailboxContext,
        watermarkMode: PageWatermarkMode,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        let limit = min(page.count, cursor.budget)
        guard limit > 0 else { return }
        let slice = Array(page.prefix(limit))
        // One bulk fingerprint read serves the whole page; when it fails the
        // per-message lookup below still decides, never assuming unchanged.
        let preloadedFingerprints = try? await store.storedFingerprints(source: .mail)

        var seenBatchHashes = Set<String>()
        var prepared: [PreparedMailMessage] = []
        prepared.reserveCapacity(slice.count)

        for message in slice {
            try Task.checkCancellation()
            let item = try await prepareMailMessage(
                message: message,
                context: context,
                seenBatchHashes: &seenBatchHashes,
                preloadedFingerprints: preloadedFingerprints
            )
            prepared.append(item)
        }

        let vectorsByMessage = try await embedPreparedMailBatch(prepared)
        var batchEntries: [DocBatchUpsertEntry] = []
        for (msgIndex, item) in prepared.enumerated() {
            guard let document = item.document else { continue }
            var expanded: [[Float]] = Array(repeating: [], count: item.chunks.count)
            for (idx, vec) in item.precomputedVectors where idx < item.chunks.count {
                expanded[idx] = vec
            }
            if let embedded = vectorsByMessage[msgIndex], embedded.count == item.indicesToEmbed.count {
                for (pos, chunkIdx) in item.indicesToEmbed.enumerated() where chunkIdx < expanded.count {
                    expanded[chunkIdx] = embedded[pos]
                }
            }
            let indexedChunks = item.chunks.enumerated().map { index, chunk in
                IndexedChunk(documentID: document.id, ordinal: index, text: chunk.text, embedding: expanded[index])
            }
            prepared[msgIndex].outcome.indexed = true
            prepared[msgIndex].outcome.chunks = indexedChunks.count
            prepared[msgIndex].outcome.vectors = indexedChunks.reduce(0) { $0 + ($1.isVector ? 1 : 0) }
            batchEntries.append(DocBatchUpsertEntry(
                document: document,
                chunks: indexedChunks,
                replaceChunksWhenUnchanged: true
            ))
        }

        if !batchEntries.isEmpty {
            _ = try await store.upsertDocumentsWithChunks(batchEntries)
        }
        try await recordPageOutcomesAndCheckpoints(
            prepared,
            context: context,
            watermarkMode: watermarkMode,
            cursor: &cursor,
            reporter: reporter
        )
    }

    /// Folds prepared message outcomes into the run report, updates in-memory checkpoints, and
    /// flushes the checkpoint file once at the end of the page.
    private func recordPageOutcomesAndCheckpoints(
        _ prepared: [PreparedMailMessage],
        context: MailboxContext,
        watermarkMode: PageWatermarkMode,
        cursor: inout MailRunCursor,
        reporter: ToolProgressReporter
    ) async throws {
        var dirtyCheckpoints = false
        for item in prepared {
            cursor.budget -= 1
            cursor.report.messagesSeen += 1
            let outcome = item.outcome
            cursor.report.messagesIndexed += outcome.indexed ? 1 : 0
            cursor.report.messagesUnchanged += outcome.unchanged ? 1 : 0
            cursor.report.messagesDeduplicated += outcome.deduplicated ? 1 : 0
            cursor.report.attachmentsStaged += outcome.staged
            cursor.report.attachmentsSkippedOversize += outcome.oversize
            cursor.report.attachmentsMetadataOnly += outcome.metadataOnly
            cursor.report.chunksWritten += outcome.chunks
            cursor.report.vectorsWritten += outcome.vectors

            switch watermarkMode {
            case .advancePerUID:
                let uid = Self.uid(of: item.message.id)
                if uid > 0 {
                    await checkpoints.recordInMemory(
                        account: context.account.name,
                        mailbox: context.mailbox,
                        watermark: uid,
                        contentHash: outcome.contentHash
                    )
                    dirtyCheckpoints = true
                }
            case let .fixedFresh(watermark):
                let uid = Self.uid(of: item.message.id)
                if uid > 0 {
                    await checkpoints.recordInMemory(
                        account: context.account.name,
                        mailbox: context.mailbox,
                        watermark: watermark,
                        contentHash: outcome.contentHash
                    )
                    dirtyCheckpoints = true
                }
            case let .backfill(watermark):
                if let hash = outcome.contentHash.isEmpty ? nil : outcome.contentHash {
                    await checkpoints.recordInMemory(
                        account: context.account.name,
                        mailbox: context.mailbox,
                        watermark: watermark,
                        contentHash: hash
                    )
                    dirtyCheckpoints = true
                }
            }

            let stamp = DispatchTime.now().uptimeNanoseconds
            if stamp &- cursor.lastReport >= ToolProgress.minimumReportIntervalNanoseconds {
                cursor.lastReport = stamp
                await reporter(Self.progress(
                    report: cursor.report,
                    account: context.account.name,
                    mailbox: context.mailbox,
                    messageID: item.message.id
                ))
            }
        }
        if dirtyCheckpoints {
            try await checkpoints.flush()
        }
    }

    /// Extracts and stages one mail message prior to cross-message batched embedding and SQLite commit.
    /// preloadedFingerprints: Page-scoped bulk fingerprints, or nil when the preload failed.
    func prepareMailMessage(
        message: MailIndexMessage,
        context: MailboxContext,
        seenBatchHashes: inout Set<String>,
        preloadedFingerprints: [String: DocStoredFingerprint]?
    ) async throws -> PreparedMailMessage {
        var outcome = MessageOutcome()
        let bodyText = Self.messageText(subject: message.subject, body: message.body)
        let contentHash = Self.contentHash(bodyText)
        outcome.contentHash = contentHash

        let isDuplicate = if seenBatchHashes.contains(contentHash) {
            true
        } else {
            await checkpoints.containsContentHash(contentHash)
        }
        if isDuplicate {
            outcome.deduplicated = true
            return PreparedMailMessage(
                message: message,
                outcome: outcome,
                document: nil,
                chunks: [],
                precomputedVectors: [:],
                indicesToEmbed: [],
                textsToEmbed: []
            )
        }
        seenBatchHashes.insert(contentHash)
        let externalID = Self.documentExternalID(
            account: context.account.name,
            mailbox: context.mailbox,
            messageID: message.id
        )
        let isUnchanged: Bool
        if let preloaded = preloadedFingerprints {
            // In-memory content-hash plus extract-status comparison; a missing
            // entry counts as changed, never unchanged.
            let stored = preloaded[externalID]
            isUnchanged = stored?.contentHash == contentHash && stored?.extractStatus != .failed
        } else {
            isUnchanged = try await !(store.needsReindex(source: .mail, externalID: externalID, contentHash: contentHash))
        }
        if isUnchanged {
            outcome.unchanged = true
            return PreparedMailMessage(
                message: message,
                outcome: outcome,
                document: nil,
                chunks: [],
                precomputedVectors: [:],
                indicesToEmbed: [],
                textsToEmbed: []
            )
        }

        let bodyExtraction = extractor.extract(
            data: Data(bodyText.utf8),
            fileName: "message.txt",
            contentType: "text/plain"
        )
        let eligible = context.window.includes(date: message.date, now: context.runDate)
        var staging = AttachmentStaging(
            chunks: bodyExtraction.chunks,
            precomputedVectors: [:],
            metadata: ["account": context.account.name],
            outcome: outcome,
            degraded: bodyExtraction.status != .extracted
        )
        try await collectAttachmentChunks(
            message: message,
            context: context,
            eligible: eligible,
            staging: &staging
        )
        let chunks = staging.chunks
        outcome = staging.outcome
        let document = IndexedDocument(
            source: .mail,
            externalID: externalID,
            displayName: Self.displayName(subject: message.subject),
            messageID: message.id,
            mailbox: context.mailbox,
            mtime: message.date,
            sizeBytes: message.sizeBytes.map { Int64($0) },
            contentHash: contentHash,
            mime: "message/rfc822",
            extractStatus: Self.extractStatus(hasText: !chunks.isEmpty, degraded: staging.degraded),
            indexedAt: context.runDate,
            metadata: staging.metadata
        )

        var indicesToEmbed: [Int] = []
        var textsToEmbed: [String] = []
        if eligible, embedder != nil, !chunks.isEmpty {
            let maxChunks = indexConfig.maxVectorChunksPerDocument
            for index in 0 ..< min(chunks.count, maxChunks) where staging.precomputedVectors[index] == nil {
                indicesToEmbed.append(index)
                textsToEmbed.append(EmbeddingGemmaPrompts.document(title: message.subject, text: chunks[index].text))
            }
        }
        return PreparedMailMessage(
            message: message,
            outcome: outcome,
            document: document,
            chunks: chunks,
            precomputedVectors: staging.precomputedVectors,
            indicesToEmbed: indicesToEmbed,
            textsToEmbed: textsToEmbed
        )
    }

    private struct MailPromptSlice {
        let messageIndex: Int
        let start: Int
        let count: Int
    }

    /// Embeds pending chunk texts across a page of prepared messages in sub-batches
    /// of up to 32 chunks / 12,000 UTF-8 bytes via `FilesIndexer.nextEmbeddingSubBatchEnd`.
    private func embedPreparedMailBatch(_ prepared: [PreparedMailMessage]) async throws -> [Int: [[Float]]] {
        guard let embedder else { return [:] }
        var flatTexts: [String] = []
        var slices: [MailPromptSlice] = []
        for (index, item) in prepared.enumerated() where !item.textsToEmbed.isEmpty {
            let start = flatTexts.count
            flatTexts.append(contentsOf: item.textsToEmbed)
            slices.append(MailPromptSlice(messageIndex: index, start: start, count: item.textsToEmbed.count))
        }
        guard !flatTexts.isEmpty else { return [:] }

        var allVectors: [[Float]] = []
        allVectors.reserveCapacity(flatTexts.count)
        var offset = 0
        while offset < flatTexts.count {
            try Task.checkCancellation()
            let end = FilesIndexer.nextEmbeddingSubBatchEnd(in: flatTexts, from: offset)
            let subBatch = Array(flatTexts[offset ..< end])
            do {
                let vectors = try await embedder.embed(subBatch)
                if vectors.count == subBatch.count {
                    allVectors.append(contentsOf: vectors)
                } else {
                    allVectors.append(contentsOf: Array(repeating: [], count: subBatch.count))
                }
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                RuneWeaverLog.stores.info("MailIndexer: batched embedding failed for page: \(error.localizedDescription)")
                allVectors.append(contentsOf: Array(repeating: [], count: subBatch.count))
            }
            offset = end
        }

        var result: [Int: [[Float]]] = [:]
        for slice in slices {
            result[slice.messageIndex] = Array(allVectors[slice.start ..< (slice.start + slice.count)])
        }
        return result
    }

    /// Stages and extracts attachment bodies into shared chunks. message: Message
    /// whose attachments are processed.
    func collectAttachmentChunks(
        message: MailIndexMessage,
        context: MailboxContext,
        eligible: Bool,
        staging: inout AttachmentStaging
    ) async throws {
        for (index, info) in message.attachments.enumerated() {
            try Task.checkCancellation()
            if (info.sizeBytes ?? 0) > context.attachmentCap {
                staging.outcome.oversize += 1
                staging.metadata["attachment.\(index).skipped"] = "oversize"
                staging.degraded = true
                continue
            }
            let attachmentData: MailIndexAttachmentData
            do {
                attachmentData = try await gateway.attachment(
                    credentials: context.credentials,
                    mailbox: context.mailbox,
                    messageID: message.id,
                    attachmentIndex: index,
                    mode: .peek
                )
            } catch let cancel as CancellationError {
                throw cancel
            } catch {
                staging.degraded = true
                continue
            }
            guard attachmentData.data.count <= context.attachmentCap else {
                staging.outcome.oversize += 1
                staging.metadata["attachment.\(index).skipped"] = "oversize"
                staging.degraded = true
                continue
            }
            let filename = NormalizedText.value(info.filename) ?? attachmentData.filename
            let staged: (directory: URL, file: URL)
            do {
                staged = try stage(bytes: attachmentData.data, filename: filename)
            } catch {
                staging.degraded = true
                continue
            }
            defer { discardStaged(at: staged.directory) }

            let contentType = NormalizedText.value(info.contentType) ?? attachmentData.contentType
            let extraction: DocumentExtraction
            do {
                extraction = try await extractor.extract(
                    fileURL: staged.file,
                    contentType: contentType
                )
            } catch is CancellationError {
                // A cancelled read must abort the page so cooperative cancellation stays observable.
                throw CancellationError()
            } catch {
                // One unreadable attachment degrades the message only; the deferred staging cleanup still runs.
                staging.degraded = true
                continue
            }
            staging.outcome.staged += 1

            if extraction.format == .image, eligible, let embedder {
                let dim = await embedder.dimension
                if let visual = try? await FilesIndexer.embedImageVisualVector(
                    fileURL: staged.file,
                    fileName: filename,
                    expectedDimension: dim,
                    embedImage: { try await embedder.embedImage(at: staged.file) }
                ), let vector = visual.first {
                    let chunkIndex = staging.chunks.count
                    let chunkText = extraction.chunks.first?.text ?? filename
                    let chunk = DocumentChunk(
                        index: chunkIndex,
                        text: chunkText,
                        estimatedTokens: max(1, chunkText.count / 4)
                    )
                    staging.chunks.append(chunk)
                    staging.precomputedVectors[chunkIndex] = vector
                    continue
                }
            }

            if extraction.status == .metadataOnly || extraction.status == .failed || extraction.status == .unsupported {
                staging.outcome.metadataOnly += 1
                staging.metadata["attachment.\(index).vision"] = extraction.status.rawValue
                staging.degraded = true
                continue
            }
            if extraction.status == .partial {
                staging.degraded = true
            }
            for chunk in extraction.chunks {
                staging.chunks.append(DocumentChunk(index: staging.chunks.count, text: chunk.text, estimatedTokens: chunk.estimatedTokens))
            }
        }
    }

    /// Writes attachment bytes into Seatbelt-confined temp. bytes: Attachment
    /// bytes.
    func stage(bytes: Data, filename: String) throws -> (directory: URL, file: URL) {
        let directory: URL
        if let stagingRoot {
            let candidate = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            directory = candidate
        } else {
            directory = try SeatbeltProfileBuilder.makeConfinedTempDirectory(prefix: "runeweaver-mail-index-")
        }
        try requireConfinedTempAllow(directory)
        let file = directory.appendingPathComponent(Self.sanitizedFilename(filename, fallback: "attachment"))
        try bytes.write(to: file, options: .atomic)
        return (directory, file)
    }

    /// Fails closed unless the Seatbelt profile permits the staging temp.
    /// - Parameter directory: Confined temp directory.
    /// - Throws: `MailIndexError.stagingFailed` when the profile omits it.
    func requireConfinedTempAllow(_ directory: URL) throws {
        let profile = SeatbeltProfileBuilder(allowedTempPaths: [directory.path]).buildProfile()
        guard profile.contains(directory.path) else {
            throw MailIndexError.stagingFailed("Attachment staging confined temp rejected by the Seatbelt profile")
        }
    }

    /// Deletes a staging directory and its staged binary.
    /// - Parameter directory: Confined temp directory to remove.
    func discardStaged(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
