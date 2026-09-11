import Foundation
import RuneWeaverCore

/// Read-only `email.search` tool over self-hosted IMAP.
///
/// Searches subject, sender, and body through the `python3 imaplib`
/// bridge and returns headers plus a short text snippet per hit.
/// Always `readOnly`: it opens the mailbox read-only with `BODY.PEEK`
/// fetches and never mutates flags or messages.
public struct EmailSearchTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.search"
    /// When the LLM should use this tool.
    public let description =
        "Searches a self-hosted IMAP mailbox (subject, sender, and body). "
            + "Use when the user asks to find or summarize email. "
            + "Returns matching message ids, headers, and snippets."
    /// Function-calling contract for `account`, `query`, and `limit`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. personal)"},"query":{"type":"string","description":"Free-text query "#
                + #"matched against subject, sender, and body"},"limit":{"type":"integer","description":"Maximum hits "#
                + #"(1-50, default 10)","minimum":1,"maximum":50}},"required":["account","query"],"additionalProperties":false}"#
        )
    /// Always allowed: search never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway

    /// Creates a search tool.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: IMAP gateway. Defaults to the `python3` subprocess bridge.
    public init(emailConfig: EmailConfig, gateway: (any EmailIMAPGateway)? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Runs the search, resolving credentials at execution time.
    /// - Parameters:
    ///   - input: Invocation with `account`, `query`, and optional `limit`.
    ///   - context: Ambient execution context.
    /// - Returns: JSON envelope with hits, or a failure without secrets.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Smart raw pre-check plus decoded CR/LF validation before ANY
        // account lookup or credential resolution so invalid input reports
        // "Invalid search query" even when the password is missing. The raw
        // check looks for unescaped JSON escapes (`\r`, `\n`, `\u000d`,
        // `\u000a` with an odd backslash count) so legitimate queries with
        // literal backslash+r/n (Windows paths like `C:\new\report` encoded
        // as double backslash in JSON) pass while injection with single
        // backslash escapes fails. Decoded checks below catch real CR/LF
        // characters (including `\u000d` escapes decoded by the JSON parser).
        // Never logs or echoes input values or secrets.
        if EmailIMAPValidation.containsEncodedCRLF(in: input.argumentsJSON) {
            return .failure(
                EmailIMAPError.bridgeFailed("Invalid search query: query must not contain CR or LF").localizedDescription,
                callID: input.callID
            )
        }
        let args: EmailSearchArgs
        do {
            args = try JSONDecoder().decode(EmailSearchArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure(
                "Invalid email.search arguments: expected {\"account\": \"<name>\", \"query\": \"<text>\", \"limit\": <1-50>}.",
                callID: input.callID
            )
        }
        // Fail fast on decoded injection before touching accounts or
        // credentials so invalid input reports "Invalid search query" even
        // when the password is missing. Checks the raw value first (before
        // trimming) to mirror the bridge, then the trimmed value. Catches
        // actual CR/LF characters (including "\\u000d" escapes decoded by
        // the JSON parser).
        do {
            try EmailIMAPValidation.validateSearchQuery(args.query)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let accountName = args.trimmedAccount
        let query = args.trimmedQuery
        guard !accountName.isEmpty else {
            return .failure("Invalid email.search arguments: 'account' must not be empty.", callID: input.callID)
        }
        guard !query.isEmpty else {
            return .failure("Invalid email.search arguments: 'query' must not be empty.", callID: input.callID)
        }
        do {
            try EmailIMAPValidation.validateSearchQuery(query)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        guard let account = emailConfig.account(named: accountName) else {
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
            let hits = try await gateway.search(credentials: credentials, query: query, limit: args.limit)
            let content = try EmailBridgeParsing.encodeSearchEnvelope(account: account.name, query: query, messages: hits)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Read-only `email.read` tool over self-hosted IMAP.
///
/// Returns headers plus the decoded text body. Attachment bytes are
/// never returned: skipped parts are listed by filename with a note
/// that downloads are deferred to phase two. Always `readOnly`.
public struct EmailReadTool: Tool, Sendable {
    /// Stable tool name referenced by the LLM and memory.
    public let name = "email.read"
    /// When the LLM should use this tool.
    public let description =
        "Reads one email by id from a self-hosted IMAP mailbox. "
            + "Use when the user asks to open or summarize a specific message. "
            + "Returns headers plus the text body; attachments are listed but not downloaded (deferred to phase two)."
    /// Function-calling contract for `account` and `id`.
    public let inputSchema =
        JSONSchema(
            rawValue: #"{"type":"object","properties":{"account":{"type":"string","description":"Account nickname "#
                + #"from [email.accounts] (e.g. personal)"},"id":{"type":"string","description":"IMAP message id "#
                + #"from email.search"}},"required":["account","id"],"additionalProperties":false}"#
        )
    /// Always allowed: reading never changes mailbox state.
    public let permissionLevel = PermissionLevel.readOnly

    /// Configured mail accounts.
    private let emailConfig: EmailConfig
    /// IMAP gateway (subprocess bridge by default, stub in tests).
    private let gateway: any EmailIMAPGateway

    /// Creates a read tool.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: IMAP gateway. Defaults to the `python3` subprocess bridge.
    public init(emailConfig: EmailConfig, gateway: (any EmailIMAPGateway)? = nil) {
        self.emailConfig = emailConfig
        self.gateway = gateway ?? SubprocessIMAPGateway()
    }

    /// Reads one message, resolving credentials at execution time.
    /// - Parameters:
    ///   - input: Invocation with `account` and `id` (plus `messageId` aliases).
    ///   - context: Ambient execution context.
    /// - Returns: JSON envelope with headers and body, or a failure without secrets.
    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        // Decoded-only UID allowlisting happens after JSON decoding: the
        // strict `^[0-9][0-9:,]*$` check on the decoded id rejects real
        // CR/LF (including "\\u000d" escapes decoded by the JSON parser)
        // before ANY account lookup or credential resolution, so invalid
        // input reports "Invalid message id" even when the password is
        // missing. No raw-document pre-check: legitimate ids never contain
        // backslash escapes, and raw checks false-positive on them.
        let args: EmailReadArgs
        do {
            args = try JSONDecoder().decode(EmailReadArgs.self, from: Data(input.argumentsJSON.utf8))
        } catch {
            return .failure("Invalid email.read arguments: expected {\"account\": \"<name>\", \"id\": \"<message-id>\"}.", callID: input.callID)
        }
        // Fail fast on allowlist before touching accounts or credentials
        // so invalid input reports "Invalid message id" even when the
        // password is missing. Checks the raw value first, then trimmed.
        // Catches actual control characters (including "\\u000d" escapes
        // decoded by the JSON parser).
        do {
            try EmailIMAPValidation.validateMessageID(args.messageID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        let accountName = args.trimmedAccount
        let messageID = args.trimmedMessageID
        guard !accountName.isEmpty else {
            return .failure("Invalid email.read arguments: 'account' must not be empty.", callID: input.callID)
        }
        guard !messageID.isEmpty else {
            return .failure("Invalid email.read arguments: 'id' must not be empty.", callID: input.callID)
        }
        do {
            try EmailIMAPValidation.validateMessageID(messageID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
        guard let account = emailConfig.account(named: accountName) else {
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
            let message = try await gateway.fetch(credentials: credentials, messageID: messageID)
            let content = try EmailBridgeParsing.encodeReadEnvelope(account: account.name, message: message)
            return .success(content, callID: input.callID)
        } catch {
            return .failure(error.localizedDescription, callID: input.callID)
        }
    }
}

/// Factory registering the read-only email tools on a `ToolBus`.
///
/// Both tools integrate with `EmailCredentialResolver` (environment
/// first, Keychain service `com.runeweaver.secrets` second) so
/// passwords never live in `config.toml` and never reach the LLM
/// prompt. iCloud accounts resolve through the same path but stay
/// untested until phase two.
public enum EmailTools {
    /// Tool names in registration order.
    public static let toolNames = ["email.search", "email.read"]

    /// Builds the read-only email tools for an email config.
    /// - Parameters:
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: Shared IMAP gateway. Defaults to the `python3` subprocess bridge.
    /// - Returns: Search and read tools in registration order.
    public static func makeTools(
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil
    ) -> [any Tool] {
        let shared: any EmailIMAPGateway = gateway ?? SubprocessIMAPGateway()
        let search: any Tool = EmailSearchTool(emailConfig: emailConfig, gateway: shared)
        let read: any Tool = EmailReadTool(emailConfig: emailConfig, gateway: shared)
        return [search, read]
    }

    /// Registers the email tools, replacing same-named entries.
    /// - Parameters:
    ///   - bus: Bus receiving the tools (surfaced via `status`).
    ///   - emailConfig: Decoded `[email]` section.
    ///   - gateway: Shared IMAP gateway. Defaults to the `python3` subprocess bridge.
    public static func register(
        on bus: ToolBus,
        emailConfig: EmailConfig,
        gateway: (any EmailIMAPGateway)? = nil
    ) async {
        for tool in makeTools(emailConfig: emailConfig, gateway: gateway) {
            await bus.register(tool: tool)
        }
    }
}
