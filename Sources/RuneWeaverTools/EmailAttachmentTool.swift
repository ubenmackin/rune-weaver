// Rune Weaver Tools — Email attachment download, staging, and detonation tool.

import Foundation
import RuneWeaverCore

/// `email.attachment` tool over IMAP.
public struct EmailAttachmentTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.attachment"
    /// When the LLM should use this tool.
    public let description =
        "Downloads one email attachment by index. "
            + "Use when the user asks to save or open an attachment listed by email.read. "
            + "Pass the mailbox labeled on the email.search hit. "
            + "Documents and images stage under isolated temp with inline extracted text or vision payloads; "
            + "archives detonate in an ephemeral zero-mount container "
            + "(no host mounts; stdin in, stdout out; read-only rootfs with tmpfs tmp and no DNS) "
            + "returning only a manifest. "
            + "Pass preview true to inline the first 2000 chars for small text parts (binaries are never inlined); "
            + "pass subpath to inspect one file inside a detonated archive, or saveToPath for an approval-gated workspace export."
    /// Function-calling contract for `account`, `id`, `index`, `mailbox`, `preview`, `subpath`, and
    /// `saveToPath`.
    public let inputSchema =
        JSONSchema(
            rawValue: """
            {
              "type": "object",
              "properties": {
                "account": {
                  "type": "string",
                  "description": "Account nickname from [email.accounts] (e.g. volcrypt, icloud)"
                },
                "id": {
                  "type": "string",
                  "description": "IMAP message id from email.search"
                },
                "index": {
                  "type": "integer",
                  "description": "Zero-based attachment position from email.read",
                  "minimum": 0
                },
                "mailbox": {
                  "type": "string",
                  "description": "Mailbox from the email.search hit (e.g. INBOX, Archive, Deleted Messages)"
                },
                "preview": {
                  "type": "boolean",
                  "description": "When true, inline the first 2000 chars for small text parts (binaries are never inlined)"
                },
                "subpath": {
                  "type": "string",
                  "description": "Relative entry path inside a detonated archive to inspect"
                },
                "saveToPath": {
                  "type": "string",
                  "description": "Workspace destination for an approval-gated archive export"
                }
              },
              "required":["account","id","index","mailbox"],
              "additionalProperties": false
            }
            """
        )
    /// Gated: downloads stage files and always prompt without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval
    /// Network-derived bytes may carry injected directives, so results enter as labeled data.
    public var contentTrustLevel: ContentTrustLevel {
        .untrustedExternal
    }

    /// Maximum decoded bytes staged per attachment (10 MB).
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Subdirectory of the isolated temp area holding downloaded attachments.
    public static let attachmentsSubdirectory = "attachments"

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway
    /// Containers runtime policy for archive detonation. Document previews stay inline with bounded caps.
    private let containersConfig: ContainersConfig
    /// `[files]` policy guarding approval-gated archive exports. Defaults to the built-in defaults.
    private let filesConfig: FilesConfig
    /// Home boundary override forwarded to the guard. Nil means the real home.
    private let homeDirectoryURL: URL?
    /// Archive detonator override (stub in tests). Nil defers to the shared registry ledger.
    private let archiveDetonator: any EmailArchiveDetonator?
    /// Ledger override for the default detonator. Nil defers to the shared registry ledger.
    private let ephemeralLedger: EphemeralContainerLedger?

    /// Creates an attachment tool.
    public init(
        emailConfig: EmailConfig,
        gateway: any EmailIMAPGateway? = nil,
        containersConfig: ContainersConfig = ContainersConfig(),
        filesConfig: FilesConfig = FilesConfig(),
        homeDirectoryURL: URL? = nil,
        archiveDetonator: any EmailArchiveDetonator? = nil,
        ephemeralLedger: EphemeralContainerLedger? = nil
    ) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
        self.containersConfig = containersConfig
        self.filesConfig = filesConfig
        self.homeDirectoryURL = homeDirectoryURL
        self.archiveDetonator = archiveDetonator
        self.ephemeralLedger = ephemeralLedger
    }

    /// Downloads one attachment part, detonating archives in isolation.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        do {
            let args = try decodedArgs(from: input)
            let target = try validatedTarget(from: args)
            let account = try resolvedAccount(named: target.accountName)
            let credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
            let effectiveMailbox = try await resolvedMailbox(credentials: credentials, requested: target.mailbox)
            let effectiveTarget = AttachmentTarget(
                accountName: target.accountName,
                messageID: target.messageID,
                attachmentIndex: target.attachmentIndex,
                mailbox: effectiveMailbox,
                preview: target.preview,
                subpath: target.subpath,
                saveToPath: target.saveToPath
            )
            let fetched = try await fetchedAttachment(
                credentials: credentials,
                mailbox: effectiveMailbox,
                messageID: effectiveTarget.messageID,
                index: effectiveTarget.attachmentIndex
            )
            if fetched.sizeBytes > Self.maxAttachmentBytes || fetched.data.count > Self.maxAttachmentBytes {
                return oversizedEnvelope(target: effectiveTarget, accountName: account.name, fetched: fetched, callID: input.callID)
            }
            let classification = AttachmentSecurity.classify(
                data: fetched.data,
                contentType: fetched.contentType,
                filename: fetched.filename
            )
            if case let .executable(reason) = classification {
                return executableBlockedEnvelope(
                    target: effectiveTarget,
                    accountName: account.name,
                    fetched: fetched,
                    reason: reason,
                    callID: input.callID
                )
            }
            // Single archive decision via AttachmentSecurity; the lifecycle
            // filename/MIME check delegates to the same table, so one call covers
            // MIME, extension, and magic-byte matches without drift.
            if AttachmentSecurity.requiresZeroMountDetonation(data: fetched.data, contentType: fetched.contentType, filename: fetched.filename) {
                if context.dryRun {
                    return archiveDryRunEnvelope(
                        target: effectiveTarget,
                        accountName: account.name,
                        fetched: fetched,
                        callID: input.callID
                    )
                }
                return try await detonatedArchiveEnvelope(
                    target: effectiveTarget,
                    accountName: account.name,
                    fetched: fetched,
                    callID: input.callID
                )
            }
            if effectiveTarget.subpath != nil || effectiveTarget.saveToPath != nil {
                throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'subpath' and 'saveToPath' are only valid for archives.")
            }
            let destination = try stagedDestinationURL(
                target: effectiveTarget,
                accountName: account.name,
                filename: fetched.filename
            )
            if context.dryRun {
                // A dry run only names the would-be path, so the per-request
                // temp created above is removed before reporting.
                let requestTemp = destination.deletingLastPathComponent().deletingLastPathComponent()
                SeatbeltTempStaging.discardTemp(at: requestTemp)
                return dryRunEnvelope(
                    target: effectiveTarget,
                    accountName: account.name,
                    fetched: fetched,
                    destination: destination,
                    callID: input.callID
                )
            }
            return storedEnvelope(
                target: effectiveTarget,
                accountName: account.name,
                fetched: fetched,
                destination: destination,
                callID: input.callID
            )
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Trimmed attachment routing for `email.attachment`.
private struct AttachmentTarget {
    let accountName: String
    let messageID: String
    let attachmentIndex: Int
    let mailbox: String
    /// Whether the caller requested an inline text preview.
    let preview: Bool
    /// Validated relative entry path inside a detonated archive, if any.
    let subpath: String?
    /// Validated workspace export destination for a detonated archive, if any.
    let saveToPath: String?
}

extension EmailAttachmentTool {
    /// Decodes attachment arguments, rejecting bad ids and indexes early.
    private func decodedArgs(from input: ToolInput) throws -> EmailAttachmentArgs {
        let args: EmailAttachmentArgs
        do {
            args = try JSONDecoder().decode(EmailAttachmentArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            throw EmailIMAPError.bridgeFailed(
                "Invalid email.attachment arguments: "
                    + "expected {\"account\": \"<name>\", \"id\": \"<message-id>\", \"index\": <0-based>, \"mailbox\": \"<mailbox>\"}."
            )
        }
        try EmailIMAPValidation.validateMessageID(args.messageID)
        try EmailIMAPValidation.validateAttachmentIndex(args.attachmentIndex)
        try EmailIMAPValidation.validateMailbox(args.trimmedMailbox)
        if let rawSubpath = args.trimmedSubpath {
            _ = try EmailAttachmentLifecycle.validateArchiveSubpath(rawSubpath)
        }
        if let rawSaveToPath = args.trimmedSaveToPath {
            try Self.validateSaveToPathSyntax(rawSaveToPath)
        }
        return args
    }

    /// Trims and re-validates decoded attachment routing.
    private func validatedTarget(from args: EmailAttachmentArgs) throws -> AttachmentTarget {
        let accountName = args.trimmedAccount
        let messageID = args.trimmedMessageID
        let attachmentIndex = args.attachmentIndex
        let mailbox = args.trimmedMailbox
        guard !accountName.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'account' must not be empty.")
        }
        guard !messageID.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'id' must not be empty.")
        }
        guard !mailbox.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.attachment arguments: 'mailbox' must not be empty.")
        }
        try EmailIMAPValidation.validateMessageID(messageID)
        try EmailIMAPValidation.validateAttachmentIndex(attachmentIndex)
        try EmailIMAPValidation.validateMailbox(mailbox)
        var validatedSubpath: String?
        if let rawSubpath = args.trimmedSubpath {
            validatedSubpath = try EmailAttachmentLifecycle.validateArchiveSubpath(rawSubpath)
        }
        var validatedSaveToPath: String?
        if let rawSaveToPath = args.trimmedSaveToPath {
            try Self.validateSaveToPathSyntax(rawSaveToPath)
            let decision = FilesAccessGuard.evaluate(path: rawSaveToPath, homeDirectoryURL: homeDirectoryURL, filesConfig: filesConfig)
            guard decision.allowed else {
                throw EmailIMAPError.bridgeFailed(decision.reason ?? "Invalid saveToPath: path is not in the permitted workspace")
            }
            validatedSaveToPath = decision.resolvedPath
        }
        return AttachmentTarget(
            accountName: accountName,
            messageID: messageID,
            attachmentIndex: attachmentIndex,
            mailbox: mailbox,
            preview: args.preview,
            subpath: validatedSubpath,
            saveToPath: validatedSaveToPath
        )
    }

    /// Resolves the configured account by exact then case-insensitive name.
    private func resolvedAccount(named accountName: String) throws -> EmailAccount {
        if let account = emailConfig.account(matching: accountName) {
            return account
        }
        throw EmailIMAPError.unknownAccount(name: accountName, available: emailConfig.accounts.map(\.name))
    }

    /// Resolves the requested mailbox against the selectable list.
    private func resolvedMailbox(credentials: ResolvedEmailCredentials, requested: String) async throws -> String {
        let listed = try await gateway.listMailboxes(credentials: credentials)
        let available = EmailBridgeParsing.selectableMailboxes(from: listed.map { name in (flags: "", mailbox: name) })
        return try EmailBridgeParsing.resolveMailboxAgainstList(requested: requested, available: available)
    }

    /// Fetches attachment bytes through the gateway with shared credentials.
    private func fetchedAttachment(
        credentials: ResolvedEmailCredentials,
        mailbox: String,
        messageID: String,
        index: Int
    ) async throws -> EmailAttachmentData {
        try await gateway.attachment(
            credentials: credentials,
            mailbox: mailbox,
            messageID: messageID,
            attachmentIndex: index
        )
    }

    /// Encodes an attachment envelope as a success result.
    private func successEnvelope(_ envelope: EmailAttachmentEnvelope, callID: String) -> ToolOutput {
        do {
            let content = try EmailBridgeParsing.encodeAttachmentEnvelope(envelope)
            return .success(content, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }

    /// Builds the skip result for a part over the size cap.
    private func oversizedEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        callID: String
    ) -> ToolOutput {
        let note = Self.oversizeNote(sizeBytes: fetched.sizeBytes)
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: nil,
            skipped: true,
            note: note,
            mailbox: target.mailbox
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Builds the skip result for an attachment identified as an executable or script.
    private func executableBlockedEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        reason: String,
        callID: String
    ) -> ToolOutput {
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: nil,
            skipped: true,
            note: "Attachment download blocked: Executable or script detected (\(reason)).",
            mailbox: target.mailbox,
            nextSteps: "Executable files and scripts cannot be downloaded or staged for security reasons."
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Resolves the isolated-temp destination for a download.
    private func stagedDestinationURL(
        target: AttachmentTarget,
        accountName: String,
        filename: String
    ) throws -> URL {
        let requestTemp = try SeatbeltTempStaging.makeTempDirectory(prefix: "runeweaver-attachments-")
        do {
            try requireSeatbeltTempAllow(requestTemp)
            let base = requestTemp.appendingPathComponent(Self.attachmentsSubdirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return try Self.stagedDestination(
                stagingPath: requestTemp.path,
                account: accountName,
                messageID: target.messageID,
                index: target.attachmentIndex,
                filename: filename
            )
        } catch {
            SeatbeltTempStaging.discardTemp(at: requestTemp)
            throw error
        }
    }

    /// Fails closed unless the Seatbelt profile allows the staging temp.
    private func requireSeatbeltTempAllow(_ tempDir: URL) throws {
        let profile = SeatbeltProfileBuilder(allowedTempPaths: [tempDir.path]).buildProfile()
        guard profile.contains(tempDir.path) else {
            throw EmailIMAPError.bridgeFailed("Attachment staging confined temp rejected by Seatbelt profile")
        }
    }

    /// Builds the dry-run result without writing any bytes.
    private func dryRunEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        destination: URL,
        callID: String
    ) -> ToolOutput {
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: nil,
            skipped: true,
            note: "Dry run: would save to \(destination.path) without downloading.",
            mailbox: target.mailbox
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Stages document and image bytes under Seatbelt-confined isolated temp and builds the success
    /// result.
    private func storedEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        destination: URL,
        callID: String
    ) -> ToolOutput {
        do {
            // The destination already sits inside a per-request temp from `stagedDestinationURL`;
            // re-assert the Seatbelt allow here so a relocated path fails closed instead of writing
            // outside cover. Staged bytes stay readable and writable but never executable.
            let requestTemp = destination.deletingLastPathComponent().deletingLastPathComponent()
            try requireSeatbeltTempAllow(requestTemp)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fetched.data.write(to: destination, options: .atomic)
            AttachmentSecurity.applyQuarantine(to: destination)
        } catch {
            let requestTemp = destination.deletingLastPathComponent().deletingLastPathComponent()
            SeatbeltTempStaging.discardTemp(at: requestTemp)
            return .failure("Could not stage attachment: \(error.localizedDescription)", callID: callID)
        }
        let category = EmailAttachmentLifecycle.mimeCategory(for: fetched.contentType)
        let expiry = EmailAttachmentLifecycle.expiryString(
            from: EmailAttachmentLifecycle.expiryDate(retentionDays: EmailAttachmentLifecycle.defaultRetentionDays)
        )
        // Inline previews stay strictly opt-in and text-only: binaries never
        // inline even when the flag is set, and oversized text stays out so
        // a preview request cannot balloon the tool output.
        var previewText: String?
        var previewWasTruncated: Bool?
        if target.preview,
           EmailAttachmentLifecycle.isPreviewable(
               contentType: fetched.contentType,
               sizeBytes: fetched.sizeBytes,
               dataCount: fetched.data.count
           ),
           let inline = EmailAttachmentLifecycle.inlinePreview(for: fetched.data)
        {
            previewText = inline.text
            previewWasTruncated = inline.truncated ? true : false
        }
        var extractedText: String?
        var imageDataBase64: String?
        var inlineNote: String?
        if category == "text" {
            if let capped = Self.cappedExtractedText(for: fetched.data) {
                extractedText = capped.text
                if capped.truncated {
                    inlineNote = "Extracted text truncated to \(EmailAttachmentLifecycle.maxPreviewChars) chars; "
                        + "use files.read with path \"\(destination.path)\" for the full text."
                }
            }
        } else if category == "image" {
            if let vision = Self.cappedVisionBase64(for: fetched.data) {
                imageDataBase64 = vision
            } else {
                inlineNote = "Image omitted from inline vision payload (invalid image or over 500KB budget); "
                    + "use files.read with path \"\(destination.path)\" to inspect it."
            }
        }

        let hint = EmailAttachmentLifecycle.nextStepsHint(
            path: destination.path,
            expiresAt: expiry,
            mimeCategory: category,
            previewTruncated: previewWasTruncated,
            archiveSessionId: nil
        )
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: destination.path,
            skipped: false,
            note: inlineNote,
            mailbox: target.mailbox,
            expiresAt: expiry,
            mimeCategory: category,
            nextSteps: hint,
            preview: previewText,
            previewTruncated: previewText == nil ? nil : previewWasTruncated,
            extractedText: extractedText,
            imageDataBase64: imageDataBase64,
            archiveSessionId: nil,
            archiveManifest: nil,
            subpath: nil
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Builds the dry-run result for an archive without spawning a container.
    private func archiveDryRunEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        callID: String
    ) -> ToolOutput {
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: nil,
            skipped: true,
            note: "Dry run: would detonate archive in an isolated zero-mount container without staging to the host.",
            mailbox: target.mailbox
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Resolves the detonator on the shared ledger so concurrent admissions serialize.
    private func resolvedDetonator() async -> any EmailArchiveDetonator {
        if let archiveDetonator {
            return archiveDetonator
        }
        if let ephemeralLedger {
            return LiveEmailArchiveDetonator(containersConfig: containersConfig, ephemeralLedger: ephemeralLedger)
        }
        return await LiveEmailArchiveDetonator(
            containersConfig: containersConfig,
            ephemeralLedger: StrictTurnRegistry.shared.ephemeralLedger
        )
    }

    /// Detonates an archive in an ephemeral zero-mount container and builds the manifest result.
    private func detonatedArchiveEnvelope(
        target: AttachmentTarget,
        accountName: String,
        fetched: EmailAttachmentData,
        callID: String
    ) async throws -> ToolOutput {
        let detonator = await resolvedDetonator()
        let result = try await detonator.detonate(
            filename: fetched.filename,
            contentType: fetched.contentType,
            data: fetched.data,
            subpath: target.subpath
        )
        var extractedText: String?
        var imageDataBase64: String?
        var inlineNote: String?
        if let subpath = target.subpath {
            guard let entryData = result.entryData else {
                throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
            }
            guard entryData.count <= Self.maxAttachmentBytes else {
                throw EmailIMAPError.bridgeFailed(Self.oversizeNote(sizeBytes: entryData.count))
            }
            let entryCategory = EmailAttachmentLifecycle.archiveEntryCategory(forPath: subpath)
            if entryCategory == "image" {
                if let vision = Self.cappedVisionBase64(for: entryData) {
                    imageDataBase64 = vision
                } else {
                    inlineNote = "Image entry omitted from inline vision payload (invalid image or over 500KB budget); use 'saveToPath' to export it."
                }
            } else if let capped = Self.cappedExtractedText(for: entryData) {
                extractedText = capped.text
                if capped.truncated {
                    inlineNote = "Extracted text truncated to \(EmailAttachmentLifecycle.maxPreviewChars) chars; use 'saveToPath' to export the full entry."
                }
            }
        }
        var exportedPath: String?
        if let saveToPath = target.saveToPath {
            exportedPath = try exportArchiveBytes(
                for: target,
                fetched: fetched,
                entryData: result.entryData,
                saveToPath: saveToPath
            )
        }
        // Workspace exports carry no staging expiry, so the session hint is
        // built pathless (avoiding an empty "expires" tail) with the export
        // destination prepended when present.
        let sessionHint = EmailAttachmentLifecycle.nextStepsHint(
            path: nil,
            expiresAt: nil,
            mimeCategory: "archive",
            previewTruncated: nil,
            archiveSessionId: result.sessionId
        )
        let hint = exportedPath.map { "Exported to \"\($0)\". \(sessionHint)" } ?? sessionHint
        var notes: [String] = []
        if result.manifestTruncated {
            notes.append("Archive manifest truncated to \(EmailAttachmentLifecycle.maxArchiveManifestEntries) entries; narrow with 'subpath'.")
        }
        if let inlineNote {
            notes.append(inlineNote)
        }
        let envelope = EmailAttachmentEnvelope(
            account: accountName,
            id: target.messageID,
            index: target.attachmentIndex,
            filename: fetched.filename,
            contentType: fetched.contentType,
            sizeBytes: fetched.sizeBytes,
            path: exportedPath,
            skipped: false,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            mailbox: target.mailbox,
            expiresAt: nil,
            mimeCategory: "archive",
            nextSteps: hint,
            preview: nil,
            previewTruncated: nil,
            extractedText: extractedText,
            imageDataBase64: imageDataBase64,
            archiveSessionId: result.sessionId,
            archiveManifest: result.manifest,
            subpath: target.subpath
        )
        return successEnvelope(envelope, callID: callID)
    }

    /// Exports detonated archive bytes through confined-temp staging.
    private func exportArchiveBytes(
        for target: AttachmentTarget,
        fetched: EmailAttachmentData,
        entryData: Data?,
        saveToPath: String
    ) throws -> String {
        let bytesToWrite: Data
        if target.subpath != nil {
            guard let entryData else {
                throw EmailIMAPError.bridgeFailed("Invalid subpath: entry not found in archive")
            }
            bytesToWrite = entryData
        } else {
            bytesToWrite = fetched.data
        }
        guard bytesToWrite.count <= Self.maxAttachmentBytes else {
            throw EmailIMAPError.bridgeFailed(Self.oversizeNote(sizeBytes: bytesToWrite.count))
        }
        let stagingDir = try SeatbeltTempStaging.makeTempDirectory(prefix: "runeweaver-attachments-")
        defer { SeatbeltTempStaging.discardTemp(at: stagingDir) }
        try requireSeatbeltTempAllow(stagingDir)
        let staged: URL
        do {
            staged = try SeatbeltTempStaging.stageBytes(bytesToWrite, filename: fetched.filename, in: stagingDir)
        } catch {
            throw EmailIMAPError.bridgeFailed("Could not export archive entry: \(error.localizedDescription)")
        }
        do {
            let savedPath = try SeatbeltTempStaging.atomicMoveTempFile(
                at: staged,
                to: saveToPath,
                homeDirectoryURL: homeDirectoryURL,
                filesConfig: filesConfig
            )
            AttachmentSecurity.applyQuarantine(to: URL(fileURLWithPath: savedPath))
            return savedPath
        } catch let staging as SeatbeltTempStaging.StagingError {
            throw EmailIMAPError.bridgeFailed(staging.message)
        } catch {
            throw EmailIMAPError.bridgeFailed("Could not export archive entry: \(error.localizedDescription)")
        }
    }
}
