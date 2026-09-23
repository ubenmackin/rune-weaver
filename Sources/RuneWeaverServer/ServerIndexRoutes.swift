// Rune Weaver Server — Local document index status and control routes.
//
// Thin HTTP adapters over the injected `IndexCoordinator` and `DocIndexStore`:
// status reports aggregate counts, the last watermark, per-source enablement,
// recent failures, and live run state; run executes one on-demand pass; cancel
// asks an in-flight pass to stop at its next safe point; prune removes
// documents older than a cutoff; and reset clears the store. Run progress needs
// no new transport: it already rides the shared `ToolProgress`/WebSocket path
// and the `run_logs` audit stream the coordinator reports through.
//
// Policy stays single-sourced: the coordinator owns sequencing, cancellation,
// and the watermark; the store owns persistence; and config validation owns
// range and closed-set checks. These routes only translate outcomes to HTTP
// shapes and fail closed with a 503 when no index component is wired.

import Foundation
import RuneWeaverCore
import Vapor

/// Registers the local document index routes.
/// - Parameter app: Application receiving the routes.
func registerIndexRoutes(_ app: Application) {
    registerIndexStatusRoute(app)
    registerIndexRunRoute(app)
    registerIndexCancelRoute(app)
    registerIndexPruneRoute(app)
    registerIndexResetRoute(app)
}

/// Registers the status probe behind `GET /index/status`.
/// - Parameter app: Application receiving the route.
private func registerIndexStatusRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.get(PathComponent.constant(ServerPaths.indexStatus)) { req async throws -> IndexStatusResponse in
        let context = req.application.runeWeaver
        let config = try loadedIndexConfiguration()
        // A missing store or coordinator is a real absent component, not an
        // error: the probe reports zeroed counts and a stopped run so a stock
        // install still renders an honest empty state.
        let stats = try await context.indexStore?.stats()
        let running = await context.indexCoordinator?.isRunning ?? false
        // One shared bounded fetch per poll: both derivations below read the
        // same snapshot, so status performs a single store query with a fixed
        // cap instead of two full-history scans that could race new rows.
        let indexRuns = await recentIndexRuns(context: context)
        var lastErrors = recentIndexErrors(from: indexRuns)
        // Fail-closed pre-run hint: there is no prompt API for Full Disk
        // Access, so a fresh install that enabled Messages would otherwise
        // waste its first Rebuild before learning access is missing. The probe
        // is a single read-only open with no copy, cheap enough to run on
        // every status poll the dashboard performs. It checks the same path
        // the next run will copy so a custom-path run never disagrees with a
        // default-path probe.
        if config.messages, !MessagesIndexer.hasMessagesDatabaseAccess(chatDatabasePath: messagesDatabasePathForProbe()) {
            let alreadyWarned = lastErrors.contains {
                $0.range(of: "Full Disk Access", options: .caseInsensitive) != nil
            }
            if !alreadyWarned {
                // Appended, not prepended: `lastErrors` is newest-first from
                // the run log and the probe hint carries no timestamp, so
                // inserting at zero would masquerade as the newest failure.
                // The hint trails run-log errors instead.
                lastErrors.append(messagesFullDiskAccessWarning)
            }
        }
        let lastRun = latestIndexRun(from: indexRuns)
        return makeIndexStatusResponse(config: config, stats: stats, running: running, lastErrors: lastErrors, lastRun: lastRun)
    }
}

/// Registers the on-demand run route behind `POST /index/run`.
///
/// The run is awaited like a chat turn: it can take minutes, and the matching
/// `POST /index/cancel` arrives on a concurrent request to stop it, so the
/// response always carries the terminal summary the dashboard renders.
/// - Parameter app: Application receiving the route.
private func registerIndexRunRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexRun)) { req async throws -> IndexRunResponse in
        let context = req.application.runeWeaver
        guard let coordinator = context.indexCoordinator else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        let summary = await coordinator.run(trigger: .onDemand)
        return IndexRunResponse(summary)
    }
}

/// Registers the cancellation route behind `POST /index/cancel`.
/// - Parameter app: Application receiving the route.
private func registerIndexCancelRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexCancel)) { req async throws -> IndexCancelResponse in
        let context = req.application.runeWeaver
        guard let coordinator = context.indexCoordinator else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        // Read liveness before asking to cancel: the flag is set immediately,
        // so a later probe could not distinguish a real abort from an idle
        // request, and the dashboard keys its notice off this one bit.
        let wasRunning = await coordinator.isRunning
        await coordinator.cancel()
        return IndexCancelResponse(cancelled: wasRunning)
    }
}

/// Registers the prune route behind `POST /index/prune`.
///
/// The cutoff is required: an absent `before` fails with 400 rather than
/// defaulting to now, so a bare prune can never silently clear the store.
/// - Parameter app: Application receiving the route.
private func registerIndexPruneRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexPrune)) { req async throws -> IndexPruneResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        // A missing cutoff and a malformed cutoff are distinct 400s: an empty
        // body carries no cutoff at all, so it keeps the missing-cutoff
        // message, while any present-but-undecodable body is a malformed
        // cutoff that must not masquerade as a missing one.
        let body: IndexPruneRequest
        do {
            body = try req.content.decode(IndexPruneRequest.self)
        } catch {
            let isEmpty = (req.body.data?.readableBytes ?? 0) == 0
            if isEmpty {
                throw Abort(.badRequest, reason: "Missing required cutoff: provide `before`.")
            }
            throw Abort(.badRequest, reason: "Invalid cutoff: 'before' must be an ISO-8601 date")
        }
        guard let cutoff = body.before else {
            throw Abort(.badRequest, reason: "Missing required cutoff: provide `before`.")
        }
        let removed = try await store.prune(before: cutoff)
        return IndexPruneResponse(removed: removed, before: cutoff)
    }
}

/// Registers the reset route behind `POST /index/reset`.
/// - Parameter app: Application receiving the route.
private func registerIndexResetRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexReset)) { req async throws -> IndexResetResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        try await store.reset()
        return IndexResetResponse(reset: true)
    }
}

/// Loads the active index policy, translating config failures into HTTP shapes.
/// - Returns: The `[index]` section of the stored configuration.
/// - Throws: `Abort(.badRequest)` for a rejected config and
///   `Abort(.internalServerError)` for an unreadable one.
private func loadedIndexConfiguration() throws -> IndexConfig {
    do {
        return try RuneWeaverConfig.loadDefault().index
    } catch let error as ConfigError {
        throw Abort(.badRequest, reason: String(describing: error))
    } catch {
        throw Abort(.internalServerError, reason: error.localizedDescription)
    }
}

/// Fixed newest-row scan window for the status probe.
///
/// Bounds per-poll work independent of retained history size: the probe reads
/// at most this many newest run rows and filters to the `index` kind in
/// memory, instead of sizing the fetch from the live `count`. A larger window
/// finds sparse index rows more often but costs more per poll; 100 sits above
/// the 50-row window known to drop index rows under chat traffic while staying
/// well below the 500-row store capacity. A kind-filtered store query would
/// remove the window tradeoff entirely, but that needs a `RunLogStore` API
/// change outside this route file.
/// - Note: Single-sourced here so the shared fetch and its derivations agree.
private enum IndexStatusScan {
    /// Maximum newest run rows examined per status poll.
    static let cap = 100
}

/// Pre-run warning surfaced in `lastErrors` when Messages is enabled but the
/// chat database is unreadable.
///
/// Kept as a single shared string so the dashboard's Full Disk Access
/// detection matches on one stable phrase whether the warning came from this
/// cheap status probe or from a run-time denial recorded in the run log.
private let messagesFullDiskAccessWarning =
    "Messages indexing needs Full Disk Access to read ~/Library/Messages/chat.db. "
        + "Grant it in System Settings > Privacy & Security > Full Disk Access, then run Rebuild / Run Now."

/// Resolves the Messages database path the status probe checks.
///
/// Single-sourced so the probe and the next run agree: boot builds its
/// Messages stage over the indexer's default path, and this helper returns
/// that same path. Holders of a custom-path indexer must probe through the
/// instance `hasMessagesDatabaseAccess()` instead, otherwise a custom-path run
/// would disagree with a default-path probe.
/// - Returns: Live Messages database path the next run will copy.
private func messagesDatabasePathForProbe() -> String {
    MessagesIndexer.defaultChatDatabasePath
}

/// Cached count patterns for the durable run summary line.
///
/// Compiled once instead of per request: the previous implementation built a
/// fresh `NSRegularExpression` for each of the three counts on every status
/// poll. Patterns stay case-insensitive and keyword-anchored so minor
/// capitalization drift still matches; a line whose wording drifted past the
/// patterns yields nil counts rather than a missing strip. Persisting
/// structured counts on the run log would remove the wording dependency
/// entirely, but that needs a `RunLogEntry` schema change outside this route
/// file, so the bounded fix here is shared compilation plus a
/// message-then-response fallback in `latestIndexRun(from:)`.
private enum IndexRunCountPatterns {
    /// Matches `<n> indexed` in the summary line, compiled once.
    static let indexed: NSRegularExpression? = try? NSRegularExpression(pattern: "(\\d+)\\s+indexed", options: .caseInsensitive)
    /// Matches `<n> scanned` in the summary line, compiled once.
    static let scanned: NSRegularExpression? = try? NSRegularExpression(pattern: "(\\d+)\\s+scanned", options: .caseInsensitive)
    /// Matches `<n> errors` in the summary line, compiled once.
    static let errors: NSRegularExpression? = try? NSRegularExpression(pattern: "(\\d+)\\s+errors", options: .caseInsensitive)
}

/// Fetches the recent `index`-kind run rows for the status probe.
///
/// Single bounded query shared by `recentIndexErrors(from:)` and
/// `latestIndexRun(from:)`: one `list(limit:)` with a fixed cap, filtered by
/// kind, with no preceding count query so new rows cannot slip between a
/// separate count and the list.
/// - Parameter context: Server context owning the run log.
/// - Returns: Newest `index`-kind rows within the scan window, newest first.
private func recentIndexRuns(context: ServerContext) async -> [RunLogEntry] {
    let recent = await context.runs.list(limit: IndexStatusScan.cap)
    return recent.filter { $0.kind == ServerIndexRunReporter.kind }
}

/// Collects the most recent index run failures from a shared run snapshot.
///
/// Pure derivation over `recentIndexRuns(context:)` output: filters to error
/// rows and renders detail strings, newest first. Only the `index`-kind rows
/// already written by `ServerIndexRunReporter` are consulted, so the status
/// shape reuses the durable run log instead of adding a second failure
/// channel; rendering is bounded and carries no content.
/// - Parameters:
///   - runs: Newest `index`-kind rows from `recentIndexRuns(context:)`.
///   - limit: Maximum failures to return, newest first.
/// - Returns: Failure detail strings, newest first.
private func recentIndexErrors(from runs: [RunLogEntry], limit: Int = 5) -> [String] {
    runs
        .filter { $0.status == IndexRunStatus.error.rawValue }
        .prefix(limit)
        .map { entry in
            let detail = entry.response?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (detail?.isEmpty == false ? detail : nil) ?? entry.message
        }
}

/// Distills the newest `index`-kind run row into the last-run strip.
///
/// Pure derivation over `recentIndexRuns(context:)` output. The coordinator's
/// summary line (`Index run <status>: <n> indexed, ... <n> scanned, <n>
/// errors`) carries the outcome counts, so the strip parses them back out of
/// the durable text; each count falls back from the message to the response
/// detail line (both carry the same summary first line), and a row whose
/// wording drifted past both still reports its status and finish time with
/// nil counts instead of disappearing. The trigger token is parsed the same
/// way: the start message carries `Index run started (<trigger>)` while the
/// completion response carries a `Trigger: <trigger>` detail line, so either
/// shape yields the machine-readable token the dashboard maps to display copy.
/// - Parameter runs: Newest `index`-kind rows from `recentIndexRuns(context:)`.
/// - Returns: The latest run outcome, or nil when no run has been recorded.
private func latestIndexRun(from runs: [RunLogEntry]) -> IndexLastRunStatus? {
    guard let entry = runs.first else {
        return nil
    }
    let message = entry.message
    let fallback = entry.response ?? ""
    return IndexLastRunStatus(
        status: entry.status,
        indexed: firstRunCount(keyword: "indexed", in: message) ?? firstRunCount(keyword: "indexed", in: fallback),
        scanned: firstRunCount(keyword: "scanned", in: message) ?? firstRunCount(keyword: "scanned", in: fallback),
        errors: firstRunCount(keyword: "errors", in: message) ?? firstRunCount(keyword: "errors", in: fallback),
        finishedAt: entry.timestamp,
        trigger: indexRunTriggerToken(from: entry)
    )
}

/// Extracts the machine-readable trigger token from an index run row.
///
/// Prefers the start-message shape `Index run started (<trigger>)`, then the
/// completion-response shape `Trigger: <trigger>` on its own detail line. A
/// row carrying neither shape yields nil so older payloads degrade to an
/// unlabeled strip instead of disappearing.
/// - Parameter entry: Newest `index`-kind row from `recentIndexRuns(context:)`.
/// - Returns: The trigger token (`"nightly"`, `"catchUp"`, `"onDemand"`), or nil.
private func indexRunTriggerToken(from entry: RunLogEntry) -> String? {
    if let started = firstParenthesizedToken(in: entry.message) {
        return started
    }
    if let response = entry.response, let detail = firstTriggerDetailToken(in: response) {
        return detail
    }
    return nil
}

/// Extracts the parenthesized token from a start message.
///
/// Matches `Index run started (<trigger>)` anchored to that case-sensitive
/// prefix and validates the token against the known triggers; any other
/// parenthesized suffix yields nil instead of mislabeling the run.
/// - Parameter message: Run message carrying the start shape.
/// - Returns: The validated trigger token, or nil.
private func firstParenthesizedToken(in message: String) -> String? {
    guard let prefixRange = message.range(of: "Index run started (") else {
        return nil
    }
    let rest = message[prefixRange.upperBound...]
    guard let close = rest.firstIndex(of: ")") else {
        return nil
    }
    let token = rest[..<close].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, IndexRunTrigger(rawValue: String(token)) != nil else {
        return nil
    }
    return String(token)
}

/// Extracts the trigger token from a completion detail line.
///
/// Scans lines for a `Trigger:` prefix (case-insensitive) and returns the
/// first whitespace-delimited token after it only when it matches a known
/// trigger; a response without such a line yields nil.
/// - Parameter response: Completion detail text.
/// - Returns: The validated trigger token, or nil.
private func firstTriggerDetailToken(in response: String) -> String? {
    for line in response.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("trigger:") else { continue }
        let after = trimmed.dropFirst("Trigger:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = after.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        if let token, IndexRunTrigger(rawValue: token) != nil {
            return token
        }
    }
    return nil
}

/// Extracts the first `<n> <keyword>` count from a run summary line.
///
/// Uses the shared compiled patterns, so the status probe performs no
/// per-request regex compilation. Only the three status keywords are
/// recognized; any other keyword yields nil without compiling.
/// - Parameters:
///   - keyword: Count label to find (`"indexed"`, `"scanned"`, `"errors"`).
///   - message: Summary line carrying the counts.
/// - Returns: The parsed count, or nil when the wording drifted.
private func firstRunCount(keyword: String, in message: String) -> Int? {
    guard !message.isEmpty else { return nil }
    let cached: NSRegularExpression?
    switch keyword.lowercased() {
    case "indexed":
        cached = IndexRunCountPatterns.indexed
    case "scanned":
        cached = IndexRunCountPatterns.scanned
    case "errors":
        cached = IndexRunCountPatterns.errors
    default:
        return nil
    }
    guard let expression = cached else {
        return nil
    }
    let range = NSRange(message.startIndex ..< message.endIndex, in: message)
    guard let match = expression.firstMatch(in: message, options: [], range: range),
          match.numberOfRanges > 1,
          let countRange = Range(match.range(at: 1), in: message)
    else {
        return nil
    }
    return Int(message[countRange])
}
