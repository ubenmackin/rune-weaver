// Rune Weaver Tools — Email mailbox listing and move tools over IMAP.

import Foundation
import RuneWeaverCore

/// Read-only `email.listMailboxes` tool over IMAP.
public struct EmailListMailboxesTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.listMailboxes"
    /// When the LLM should use this tool.
    public let description =
        "Lists selectable IMAP mailboxes for an account. "
            + "Use when the user asks what folders exist or to confirm a destination before email.move. "
            + "Returns folder names in server order with the hierarchy delimiter."
    /// Function-calling contract for `account`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. volcrypt, icloud)"}},"required":["account"],"additionalProperties":false}"#
        )
    /// Always allowed: listing never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway

    /// Creates a listing tool.
    public init(emailConfig: EmailConfig, gateway: any EmailIMAPGateway? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Lists selectable mailboxes, resolving credentials at execution time.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        let args: EmailListMailboxesArgs
        do {
            args = try JSONDecoder().decode(EmailListMailboxesArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid email.listMailboxes arguments: expected {\"account\": \"<name>\"}.",
                callID: input.callID
            )
        }
        // Fail fast on an empty account before touching accounts or credentials.
        let accountName = args.trimmedAccount
        guard !accountName.isEmpty else {
            return .failure("Invalid email.listMailboxes arguments: 'account' must not be empty.", callID: input.callID)
        }
        guard let account = emailConfig.account(matching: accountName) else {
            let available = emailConfig.accounts.map(\.name)
            return .failure(EmailIMAPError.unknownAccount(name: accountName, available: available).localizedDescription, callID: input.callID)
        }
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            let listing = try await gateway.mailboxListing(credentials: credentials)
            let content = try EmailBridgeParsing.encodeListMailboxesEnvelope(
                account: account.name,
                mailboxes: listing.mailboxes,
                delimiter: listing.delimiter
            )
            return .success(content, callID: input.callID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Validated `email.move` request without touching accounts or credentials.
private struct ValidatedMoveRequest: Sendable {
    /// Trimmed account nickname.
    let accountName: String
    /// Trimmed message id.
    let messageID: String
    /// Trimmed destination mailbox.
    let requestedDestination: String
}

/// Approval-gated `email.move` tool over IMAP.
public struct EmailMoveTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.move"
    /// When the LLM should use this tool.
    public let description =
        "Moves one email between IMAP mailboxes by id. "
            + "Use when the user asks to file, archive, or organize a message found by email.search. "
            + "UIDs are per-folder, so pass the source mailbox labeled on the hit (omitted means INBOX). "
            + "The destination must already exist: unknown names fail with the available folders and nothing is created. "
            + "Pass markAsRead true to set Seen on the moved message; "
            + "passing the same folder as source and destination marks the message read without moving it."
    /// Function-calling contract for `account`, `id`, source `mailbox`, `destination`, and
    /// `markAsRead`.
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
                "mailbox": {
                  "type": "string",
                  "description": "Source mailbox from the email.search hit (e.g. INBOX); omitted means INBOX"
                },
                "destination": {
                  "type": "string",
                  "description": "Destination mailbox (must already exist; unknown names fail without creating folders)"
                },
                "markAsRead": {
                  "type": "boolean",
                  "description": "When true, set Seen on the moved message (default false)"
                }
              },
              "required": ["account", "id", "destination"],
              "additionalProperties": false
            }
            """
        )
    /// Gated: moving relocates mail and always prompts without a trust grant.
    public let permissionLevel = PermissionLevel.requiresApproval

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway

    /// Creates a move tool.
    public init(emailConfig: EmailConfig, gateway: any EmailIMAPGateway? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Moves one message, resolving credentials at execution time.
    public func execute(input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        // Encoded CR/LF pre-check before ANY account lookup or credential resolution so
        // injection reports a move validation failure even when the password is missing.
        if EmailIMAPValidation.containsEncodedCRLF(in: input.argumentsJSON) {
            return .failure(
                "Invalid message id or mailbox: message id and mailboxes must not contain CR or LF",
                callID: input.callID
            )
        }
        let args: EmailMoveArgs
        do {
            args = try JSONDecoder().decode(EmailMoveArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid email.move arguments: expected {\"account\": \"<name>\", \"id\": \"<message-id>\", \"destination\": \"<mailbox>\"}.",
                callID: input.callID
            )
        }
        // Fail fast on decoded injection before touching accounts or credentials so invalid
        // input reports without leaking lookup results. Checks the raw value first, then trimmed.
        let validated: ValidatedMoveRequest
        do {
            validated = try validatedMoveRequest(from: args)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        guard let account = emailConfig.account(matching: validated.accountName) else {
            let available = emailConfig.accounts.map(\.name)
            return .failure(EmailIMAPError.unknownAccount(name: validated.accountName, available: available).localizedDescription, callID: input.callID)
        }
        let credentials: ResolvedEmailCredentials
        do {
            credentials = try await EmailCredentialResolver.resolvedCredentials(for: account)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        do {
            // Canonicalize both ends against the live selectable list so an unknown
            // destination fails listing the available folders instead of creating one.
            let listing = try await gateway.mailboxListing(credentials: credentials)
            let endpoints = try resolveMoveEndpoints(
                requestedSource: args.trimmedMailbox,
                requestedDestination: validated.requestedDestination,
                available: listing.mailboxes
            )
            if context.dryRun {
                return moveEnvelope(
                    EmailMoveEnvelope(
                        account: account.name,
                        id: validated.messageID,
                        mailbox: endpoints.source,
                        destination: endpoints.destination,
                        moved: false,
                        markedAsRead: false,
                        note: dryRunNote(
                            messageID: validated.messageID,
                            source: endpoints.source,
                            destination: endpoints.destination,
                            markAsRead: args.markAsRead
                        )
                    ),
                    callID: input.callID
                )
            }
            // Same-folder moves relocate nothing, so skip the COPY path: without a read
            // request this is a pure no-op, while a read request falls through to the
            // flag-only update so the Seen bit still applies without duplicating mail.
            if endpoints.source == endpoints.destination, !args.markAsRead {
                return moveEnvelope(
                    EmailMoveEnvelope(
                        account: account.name,
                        id: validated.messageID,
                        mailbox: endpoints.source,
                        destination: endpoints.destination,
                        moved: false,
                        markedAsRead: false,
                        note: "Message '\(validated.messageID)' is already in '\(endpoints.destination)'; nothing moved."
                    ),
                    callID: input.callID
                )
            }
            let result = try await gateway.move(
                credentials: credentials,
                mailbox: endpoints.source,
                messageID: validated.messageID,
                destination: endpoints.destination,
                markAsRead: args.markAsRead
            )
            return moveEnvelope(
                EmailMoveEnvelope(
                    account: account.name,
                    id: validated.messageID,
                    mailbox: result.mailbox,
                    destination: result.destination,
                    moved: result.moved,
                    markedAsRead: result.markedAsRead,
                    note: nil
                ),
                callID: input.callID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }

    /// Validates decoded move arguments without touching accounts or credentials.
    private func validatedMoveRequest(from args: EmailMoveArgs) throws -> ValidatedMoveRequest {
        if let requestedSource = args.trimmedMailbox {
            try EmailIMAPValidation.validateMailbox(requestedSource)
        }
        // The destination is required at the tool layer: the bridge never creates folders,
        // so a missing destination fails here instead of relocating nowhere.
        guard let requestedDestination = args.trimmedDestination else {
            throw EmailIMAPError.bridgeFailed("Invalid email.move arguments: 'destination' must not be empty.")
        }
        try EmailIMAPValidation.validateMailbox(requestedDestination)
        let accountName = args.trimmedAccount
        let messageID = args.trimmedMessageID
        guard !accountName.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.move arguments: 'account' must not be empty.")
        }
        guard !messageID.isEmpty else {
            throw EmailIMAPError.bridgeFailed("Invalid email.move arguments: 'id' must not be empty.")
        }
        try EmailIMAPValidation.validateMessageID(messageID)
        return ValidatedMoveRequest(accountName: accountName, messageID: messageID, requestedDestination: requestedDestination)
    }

    /// Canonicalizes both ends against the live selectable list.
    private func resolveMoveEndpoints(
        requestedSource: String?,
        requestedDestination: String,
        available: [String]
    ) throws -> (source: String, destination: String) {
        let source = try EmailBridgeParsing.resolveMailboxAgainstList(
            requested: requestedSource ?? "INBOX",
            available: available
        )
        let destination = try EmailBridgeParsing.resolveMailboxAgainstList(
            requested: requestedDestination,
            available: available
        )
        return (source, destination)
    }
}

extension EmailMoveTool {
    /// Builds the dry-run preview note without touching mailbox state.
    private func dryRunNote(messageID: String, source: String, destination: String, markAsRead: Bool) -> String {
        let preview = if source == destination {
            "Dry run: message '\(messageID)' is already in '\(destination)'; nothing would move."
        } else {
            "Dry run: would move message '\(messageID)' from '\(source)' to '\(destination)' without changing mailboxes."
        }
        if markAsRead {
            return preview + " Would set Seen."
        }
        return preview
    }

    /// Encodes a move envelope as a success result, failing closed on encode errors.
    private func moveEnvelope(_ envelope: EmailMoveEnvelope, callID: String) -> ToolOutput {
        do {
            let content = try EmailBridgeParsing.encodeMoveEnvelope(envelope)
            return .success(content, callID: callID)
        } catch {
            return .failure(error.localizedDescription, callID: callID)
        }
    }
}
