// Rune Weaver Server — Local document index status and control routes.
//
// Thin HTTP adapters over the injected `IndexCoordinator` and `DocIndexStore`:
// status reports aggregate counts, true on-disk and logical sizes, the
// resolved effort block, the last watermark, per-source enablement,
// recent failures, and live run state; run executes one on-demand pass; cancel
// asks an in-flight pass to stop at its next safe point; prune removes
// documents older than a cutoff; reset clears the store plus its mail
// checkpoint and Messages watermark through context-owned paths, so tests
// inject scratch targets while production keeps the real defaults; and reclaim runs
// `VACUUM` reporting before and after byte figures. Live progress is
// poll-snapshot primary: the status probe carries the additive `live` snapshot
// derived from the coordinator's `liveTotals` (null when idle) that the menu
// and page poll about every 2s while a run is in flight; WebSocket
// `tool_progress` plus `run_started`/`run_completed` frames are poll-now
// wake-up triggers only, never the data carrier. Terminal outcomes persist in
// the `run_logs` audit stream the coordinator reports through.
//
// Policy stays single-sourced: the coordinator owns sequencing, cancellation,
// and the watermark; the store owns persistence; and config validation owns
// range and closed-set checks. These routes only translate outcomes to HTTP
// shapes and fail closed with a 503 when no index component is wired.

import Foundation
import RuneWeaverCore
import RuneWeaverTools
import Vapor
#if canImport(EventKit)
    import EventKit
#endif

extension ServerPaths {
    public static let indexRequestAccess = "request-access"
}

/// Registers the local document index routes.
/// - Parameter app: Application receiving the routes.
func registerIndexRoutes(_ app: Application) {
    registerIndexStatusRoute(app)
    registerIndexStorageRoute(app)
    registerIndexRunRoute(app)
    registerIndexCancelRoute(app)
    registerIndexPruneRoute(app)
    registerIndexResetRoute(app)
    registerIndexReclaimRoute(app)
    registerIndexRequestAccessRoute(app)
}

/// Registers the fast status probe behind `GET /index/status`.
///
/// Owned by the index routes: serves true counts, true sizes, watermark,
/// running, sources with silent access posture, last run, live, and effort
/// from the persisted single row in well under the dashboard budget, serving
/// single-row reads forever with the TTL never gating correctness. A missing
/// store reports zeroed counts and a stopped run instead of failing.
/// - Parameter app: Application receiving the route.
private func registerIndexStatusRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.get(PathComponent.constant(ServerPaths.indexStatus)) { req async throws -> IndexStatusResponse in
        let context = req.application.runeWeaver
        let config = try loadedIndexConfiguration()
        // A missing store or coordinator is a real absent component, not an
        // error: the probe reports zeroed counts and a stopped run so a stock
        // install still renders an honest empty state.
        async let fastStatsTask = context.indexStore?.fastStats()
        async let runningTask = context.indexCoordinator?.isRunning ?? false
        // Live snapshot rides the coordinator's cached counters, so polling
        // never touches run state or the document store; nil when idle.
        async let liveTask = context.indexCoordinator?.liveTotals.map(IndexLiveStatus.init)
        // Kind-filtered store lookup: bounded to the 50 most recent index runs
        // so a status poll never pulls Int.max rows through the actor hop. One
        // shared fetch feeds both the latest strip and the failure list so
        // they agree on the same snapshot.
        async let kindRunsTask = context.runs.list(limit: 50, kind: ServerIndexRunReporter.kind)
        // Slow sizes ride the persisted single row directly with no TTL gate:
        // a memory hit returns with zero I/O, otherwise the persisted row
        // projects frozen with zero aggregate passes, so the fast poll never
        // triggers a slow aggregate pass and a cold poll still serves true
        // sizes. Nil only when no refresh has ever run.
        async let cachedStorageTask = context.indexStore?.cachedStorageIfFresh()

        // Fast counts and sizes ride the persisted row with no `dbstat` or
        // `LENGTH` pass; in-run freshness rides `liveTotals` only.
        let fastStats = try await fastStatsTask
        // Flatten the double optional from chaining an optional store over an
        // optional persisted breakdown: nil store and an absent row both
        // degrade to nil storage, which renders as fail-closed zeros.
        let cachedDouble: IndexStorageBreakdown?? = await cachedStorageTask
        let storage: IndexStorageBreakdown? = cachedDouble ?? nil
        let running = await runningTask
        let live = await liveTask
        let kindRuns = await kindRunsTask
        let latestEntry = kindRuns.first
        var lastErrors = recentIndexErrors(from: kindRuns)
        // Fail-closed pre-run hint: there is no prompt API for Full Disk
        // Access, so a fresh install that enabled Messages would otherwise
        // waste its first Rebuild before learning access is missing. The probe
        // is a single read-only open with no copy, cheap enough to run on
        // every status poll the dashboard performs. It checks the same path
        // the next run will copy so a custom-path run never disagrees with a
        // default-path probe.
        let messagesAccessBool = MessagesIndexer.hasMessagesDatabaseAccess(chatDatabasePath: messagesDatabasePathForProbe())
        if config.messages, !messagesAccessBool {
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
        let lastRun = latestIndexRun(from: latestEntry)
        // Silent per-source access posture, re-read on every poll so the
        // dashboard pills flip green with no save when the owner grants
        // access elsewhere. The EventKit reads never prompt and the Messages
        // probe is the same read-only open the next run performs.
        #if canImport(EventKit)
            let calendarAccess = indexEventKitSourceAccess(for: .event)
            let remindersAccess = indexEventKitSourceAccess(for: .reminder)
        #else
            let calendarAccess = "unavailable"
            let remindersAccess = "unavailable"
        #endif
        let messagesAccess = messagesAccessBool ? "granted" : "denied"
        return makeIndexStatusResponse(
            config: config,
            stats: fastStats,
            running: running,
            lastErrors: lastErrors,
            lastRun: lastRun,
            live: live,
            storage: storage,
            calendarAccess: calendarAccess,
            remindersAccess: remindersAccess,
            messagesAccess: messagesAccess
        )
    }
}

/// Registers the slow storage probe behind `GET /index/storage`.
///
/// Owned by the index routes: serves byte-exact totals plus per-source bytes
/// from the persisted single row frozen, so mid-run polls never trigger a
/// repairing scan and only an absent row pays for one repairing refresh that
/// also persists. Per-source bytes ride the frozen `stats().bySource` rows;
/// a missing store reports a zeroed payload rather than failing so older
/// dashboards keep rendering.
/// - Parameter app: Application receiving the route.
private func registerIndexStorageRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.get(PathComponent.constant(ServerPaths.indexStorage)) { req async throws -> IndexStorageResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            // No store is an honest empty state, never an error, matching the
            // status probe's missing-store posture.
            return IndexStorageResponse()
        }
        // Single frozen snapshot fetch projecting both views locally: the
        // persisted row carries every size leg with zero aggregate passes
        // when present, so a mid-run poll never pays for a content scan and
        // only an absent row pays for one repairing refresh that also
        // persists.
        let stats = try await store.stats()
        // Per-source bytes come from the frozen stats rows, which carry true
        // logical totals from the persisted single row.
        let bySource = stats.bySource.map { row in
            IndexSourceCounts(kind: row.source.rawValue, documents: row.documents, chunks: row.chunks, bytes: row.bytes)
        }
        // Breakdown legs project from the same snapshot: `textBytes` equals
        // `bytes` when the split is present and falls back to `bytes` when
        // the `dbstat` probe is unavailable; `vectorBytes` falls back to the
        // content-minus-text difference so the unavailable split still
        // reports true embedding bytes; `ftsBytes` degrades to zero.
        let textBytes = stats.textBytes ?? stats.bytes
        let vectorBytes = stats.vectorBytes ?? max(stats.contentBytes - stats.bytes, 0)
        return IndexStorageResponse(
            bytes: stats.bytes,
            textBytes: textBytes,
            vectorBytes: vectorBytes,
            ftsBytes: stats.ftsBytes ?? 0,
            freeBytes: stats.freeBytes,
            dbFileBytes: stats.dbFileBytes,
            walBytes: stats.walBytes,
            contentBytes: stats.contentBytes,
            bySource: bySource
        )
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
///
/// The document store owns both sidecar resets through the context-owned
/// paths, so a test-wired context can never delete the operator's live mail
/// checkpoint or Messages watermark.
/// - Parameter app: Application receiving the route.
private func registerIndexResetRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexReset)) { req async throws -> IndexResetResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        struct ResetQuery: Decodable {
            let source: String?
        }
        let query = try? req.query.decode(ResetQuery.self)
        if let rawSource = query?.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !rawSource.isEmpty, rawSource != "all"
        {
            guard let source = IndexSource(rawValue: rawSource) else {
                throw Abort(.badRequest, reason: "Unknown index source '\(rawSource)'. Supported sources: files, mail, messages.")
            }
            _ = try await store.clearSource(
                source,
                mailCheckpointPath: context.indexMailCheckpointPath,
                messagesStatePath: context.indexMessagesStatePath
            )
            return IndexResetResponse(reset: true)
        }
        try await store.reset(
            mailCheckpointPath: context.indexMailCheckpointPath,
            messagesStatePath: context.indexMessagesStatePath
        )
        if let coordinator = context.indexCoordinator {
            do {
                try await coordinator.reset()
            } catch {
                RuneWeaverLog.server.warning("ServerIndexRoutes: failed to reset index coordinator: \(error.localizedDescription)")
            }
        }
        return IndexResetResponse(reset: true)
    }
}

/// Registers the reclaim route behind `POST /index/reclaim`.
///
/// Runs `VACUUM` without touching documents or chunks and reports the on-disk
/// total before and after plus the reclaimed delta. Progress keeps riding the
/// existing status poll and WebSocket wake-up frames; reclaim itself is a
/// short synchronous maintenance call with no new transport.
private func registerIndexReclaimRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexReclaim)) { req async throws -> IndexReclaimResponse in
        let context = req.application.runeWeaver
        guard let store = context.indexStore else {
            throw Abort(.serviceUnavailable, reason: "Indexing is not configured.")
        }
        let result = try await store.reclaim()
        return IndexReclaimResponse(result)
    }
}

struct IndexRequestAccessRequest: Content {
    var kind: String?
    var source: String?
}

struct IndexRequestAccessResponse: Content {
    var kind: String
    var granted: Bool
    var access: String

    /// Creates a request-access response from the full access token.
    ///
    /// Carries the truth read from the store (`"granted"`, `"denied"`,
    /// `"notDetermined"`, or `"unavailable"`) instead of deriving posture
    /// from the prompt Bool, so a thrown prompt keeps `notDetermined` and a
    /// non-EventKit platform reports `unavailable` rather than `denied`.
    /// - Parameters:
    ///   - kind: Source kind token (`"calendars"` or `"reminders"`).
    ///   - access: Truth access token observed from the store.
    init(kind: String, access: String) {
        self.kind = kind
        self.access = access
        self.granted = (access == "granted")
    }
}

private func normalizeIndexRequestAccessKind(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard token == "calendars" || token == "reminders" else { return nil }
    return token
}

private func shouldPromptCalendarRequestAccess(status: CalendarAuthorizationStatus) -> Bool {
    status == .notDetermined
}

private func shouldPromptReminderRequestAccess(status: EventKitReminderAuthorization) -> Bool {
    status == .notDetermined
}

/// Maps a live calendar authorization read onto the request-access token.
///
/// Mirrors the silent status probe: authorized reads granted, notDetermined
/// stays promptable, and denied plus restricted both read denied; there is no
/// restricted token on the wire.
/// - Parameter status: Live calendar authorization observed from the store.
/// - Returns: `"granted"`, `"notDetermined"`, or `"denied"`.
private func indexRequestAccessToken(_ status: CalendarAuthorizationStatus) -> String {
    switch status {
    case .authorized:
        "granted"
    case .notDetermined:
        "notDetermined"
    case .denied, .restricted:
        "denied"
    }
}

/// Maps a live reminders authorization read onto the request-access token.
///
/// Mirrors the calendar mapping so both EventKit sources share one token
/// contract on the wire.
/// - Parameter status: Live reminders authorization observed from the store.
/// - Returns: `"granted"`, `"notDetermined"`, or `"denied"`.
private func indexRequestAccessToken(_ status: EventKitReminderAuthorization) -> String {
    switch status {
    case .authorized:
        "granted"
    case .notDetermined:
        "notDetermined"
    case .denied, .restricted:
        "denied"
    }
}

private func registerIndexRequestAccessRoute(_ app: Application) {
    let index = app.grouped(PathComponent.constant(ServerPaths.index))

    index.post(PathComponent.constant(ServerPaths.indexRequestAccess)) { req async throws -> IndexRequestAccessResponse in
        let decoded = try? req.content.decode(IndexRequestAccessRequest.self)
        let queryKind: String? = req.query[String.self, at: "kind"] ?? req.query[String.self, at: "source"]
        let rawKind = decoded?.kind ?? decoded?.source ?? queryKind
        guard let kind = normalizeIndexRequestAccessKind(rawKind) else {
            let received = (rawKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if received.isEmpty {
                throw Abort(.badRequest, reason: "Missing required source kind: provide `kind` as `calendars` or `reminders`.")
            }
            throw Abort(.badRequest, reason: "Unknown index source '\(received)'. Supported sources: calendars, reminders.")
        }
        #if canImport(EventKit)
            let liveStore = LiveEventKitStore()
            if kind == "calendars" {
                let current = liveStore.authorizationStatus()
                if current == .authorized {
                    return IndexRequestAccessResponse(kind: kind, access: "granted")
                }
                guard shouldPromptCalendarRequestAccess(status: current) else {
                    return IndexRequestAccessResponse(kind: kind, access: indexRequestAccessToken(current))
                }
                // Re-read truth after prompting instead of trusting the Bool:
                // a thrown prompt leaves the store at notDetermined, which
                // must not masquerade as denied.
                _ = await (try? liveStore.requestAccess())
                let updated = liveStore.authorizationStatus()
                return IndexRequestAccessResponse(kind: kind, access: indexRequestAccessToken(updated))
            } else {
                let current = liveStore.reminderAuthorizationStatus()
                if current == .authorized {
                    return IndexRequestAccessResponse(kind: kind, access: "granted")
                }
                guard shouldPromptReminderRequestAccess(status: current) else {
                    return IndexRequestAccessResponse(kind: kind, access: indexRequestAccessToken(current))
                }
                // Re-read truth after prompting instead of trusting the Bool,
                // matching the calendars path above.
                _ = await (try? liveStore.requestReminderAccess())
                let updated = liveStore.reminderAuthorizationStatus()
                return IndexRequestAccessResponse(kind: kind, access: indexRequestAccessToken(updated))
            }
        #else
            return IndexRequestAccessResponse(kind: kind, access: "unavailable")
        #endif
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

/// Directory and file names the files walker always skips, even when absent
/// from `exclude`.
///
/// Single-sourced from the walker's prune list so the index settings payload
/// cannot drift from what the walker actually prunes. The `[files]` deny
/// patterns stay out of this list and are described generically in the UI.
/// - Returns: Walker prune names in walk order.
func indexAlwaysSkippedPatterns() -> [String] {
    FilesIndexer.alwaysSkippedPatterns
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

#if canImport(EventKit)
    /// Maps one silent EventKit authorization read onto the status access token.
    ///
    /// The class-level `authorizationStatus(for:)` read never prompts, so
    /// status polls stay silent; prompting stays behind the explicit
    /// owner-driven enable path. Write-only still reads denied because
    /// indexing needs full access, matching the gateway seam.
    /// - Parameter entity: EventKit entity (`.event` for calendars, `.reminder` for reminders).
    /// - Returns: `"granted"`, `"denied"`, or `"notDetermined"`.
    private func indexEventKitSourceAccess(for entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess:
            return "granted"
        case .notDetermined:
            return "notDetermined"
        case .denied, .writeOnly, .restricted:
            return "denied"
        @unknown default:
            return "denied"
        }
    }
#endif

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
    /// Matches `<n> retired` in the summary line, compiled once.
    static let retired: NSRegularExpression? = try? NSRegularExpression(pattern: "(\\d+)\\s+retired", options: .caseInsensitive)
    /// Matches `<n> truncated` in the summary line, compiled once.
    static let truncated: NSRegularExpression? = try? NSRegularExpression(pattern: "(\\d+)\\s+truncated", options: .caseInsensitive)
}

/// Collects every index run failure plus per-file warning lines.
///
/// Pure derivation over the kind-filtered store lookup in the status route:
/// every run-level error row comes first, newest first, followed by every
/// `Warning:` detail line from the newest run's response. Only the `index`-kind rows
/// already written by `ServerIndexRunReporter` are consulted, so the status
/// shape reuses the durable run log instead of adding a second failure
/// channel. Warning lines stay content-free because the coordinator's
/// detail text carries only counts and short reasons, never file bytes.
/// A run with no warnings contributes no tail, so the empty state renders
/// no block exactly as before.
/// - Parameter runs: Every `index`-kind row from the kind-filtered lookup, newest first.
/// - Returns: Failure and warning detail strings, newest errors first.
func recentIndexErrors(from runs: [RunLogEntry]) -> [String] {
    guard !runs.isEmpty else { return [] }
    let errorRows = runs
        .filter { $0.status == IndexRunStatus.error.rawValue }
        .map { entry in
            let detail = entry.response?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (detail?.isEmpty == false ? detail : nil) ?? entry.message
        }
    var combined = errorRows
    // The newest run carries the freshest per-file signal, so its warnings
    // trail the run-level errors; older runs' warnings stay out to keep the
    // block current rather than accumulating stale lines.
    if let newestResponse = runs.first?.response {
        let warnings = indexWarningDetailLines(from: newestResponse)
        combined.append(contentsOf: warnings)
    }
    return combined
}

/// Extracts content-free `Warning:` detail lines from a run response.
///
/// Matches the coordinator's detail contract line by line, so summary,
/// trigger, retired, and skip lines never leak into the failure list. The
/// match is case-insensitive on the prefix only; the remainder is kept
/// verbatim because it already holds just counts and short reasons.
/// - Parameter response: Completion detail text from the newest run.
/// - Returns: Trimmed warning lines in run order, oldest first.
private func indexWarningDetailLines(from response: String) -> [String] {
    response
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && $0.lowercased().hasPrefix("warning:") }
}

/// Distills the newest `index`-kind run row into the last-run strip.
///
/// Pure derivation over the kind-filtered store lookup in the status route.
/// The coordinator's summary line
/// (`Index run <status>: <n> indexed, ... <n> scanned, <n> errors, <n> retired, <n> truncated`)
/// carries the outcome counts, so the strip parses them back out of the
/// durable text; each count falls back from the message to the response detail
/// line (both carry the same summary first line), and a row whose wording
/// drifted past both still reports its status and finish time with nil counts
/// instead of disappearing. Retired and truncated prefer the explicit
/// `Retired:`/`Truncated:` detail lines (written by
/// `IndexCoordinator.detailLine`) with the summary wording as fallback, so the
/// strip stays honest even when the summary is pruned. Cancelled runs persist
/// the same way: the completion event carries partial counts with status
/// `cancelled`, so the strip renders the work done so far rather than
/// vanishing. The trigger token is parsed the same way: the start message
/// carries `Index run started (<trigger>)` while the completion response
/// carries a `Trigger: <trigger>` detail line, so either shape yields the
/// machine-readable token the dashboard maps to display copy.
/// The skip reason follows the same detail-line contract: the completion
/// response carries a `Skipped: <reason>` line (written by
/// `IndexCoordinator.detailLine`), parsed like the trigger line and validated
/// non-empty so the strip renders the same reason the run notice shows.
/// Per-source outcomes follow the `Source:` detail lines so every source
/// reports did-run plus reason; a response without such lines degrades to nil
/// so older engines still render.
/// - Parameter entry: Newest `index`-kind row from the store lookup, or nil.
/// - Returns: The latest run outcome, or nil when no run has been recorded.
private func latestIndexRun(from entry: RunLogEntry?) -> IndexLastRunStatus? {
    guard let entry else {
        return nil
    }
    let message = entry.message
    let fallback = entry.response ?? ""
    let skippedReason: String? = entry.response.flatMap { firstSkippedDetailToken(in: $0) }
    let retired: Int? = entry.response.flatMap { firstCountDetailToken(prefix: "Retired:", in: $0) }
        ?? firstRunCount(keyword: "retired", in: message)
        ?? firstRunCount(keyword: "retired", in: fallback)
    let truncated: Int? = entry.response.flatMap { firstCountDetailToken(prefix: "Truncated:", in: $0) }
        ?? firstRunCount(keyword: "truncated", in: message)
        ?? firstRunCount(keyword: "truncated", in: fallback)
    let sources: [IndexSourceRunOutcome]? = entry.response.flatMap { parseIndexSourceOutcomes(from: $0) }
    return IndexLastRunStatus(
        status: entry.status,
        indexed: firstRunCount(keyword: "indexed", in: message) ?? firstRunCount(keyword: "indexed", in: fallback),
        scanned: firstRunCount(keyword: "scanned", in: message) ?? firstRunCount(keyword: "scanned", in: fallback),
        errors: firstRunCount(keyword: "errors", in: message) ?? firstRunCount(keyword: "errors", in: fallback),
        finishedAt: entry.timestamp,
        trigger: indexRunTriggerToken(from: entry),
        skippedReason: skippedReason,
        retiredCount: retired,
        truncatedCount: truncated,
        sources: sources
    )
}

/// Extracts the machine-readable trigger token from an index run row.
///
/// Prefers the start-message shape `Index run started (<trigger>)`, then the
/// completion-response shape `Trigger: <trigger>` on its own detail line. A
/// row carrying neither shape yields nil so older payloads degrade to an
/// unlabeled strip instead of disappearing.
/// - Parameter entry: Newest `index`-kind row from the kind-filtered store lookup.
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

/// Extracts the skip reason from a completion detail line.
///
/// Scans lines for a `Skipped:` prefix (case-insensitive), mirroring
/// `firstTriggerDetailToken`, and returns the remainder only when it is
/// non-empty after trimming; a response without such a line, or with a blank
/// reason, yields nil so the strip renders no reason instead of an empty one.
/// - Parameter response: Completion detail text.
/// - Returns: The validated skip reason, or nil.
private func firstSkippedDetailToken(in response: String) -> String? {
    for line in response.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("skipped:") else { continue }
        let after = trimmed.dropFirst("Skipped:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty else { continue }
        return after
    }
    return nil
}

/// Extracts per-source outcomes from completion detail lines.
///
/// Scans lines for a `Source <kind>:` prefix (case-insensitive) carrying
/// `didRun` plus counts, mirroring the coordinator's detail contract. A
/// response without such lines yields nil so older engines degrade to no
/// per-source notes instead of failing.
/// - Parameter response: Completion detail text.
/// - Returns: Outcomes in file order, or nil when absent.
private func parseIndexSourceOutcomes(from response: String) -> [IndexSourceRunOutcome]? {
    var outcomes: [IndexSourceRunOutcome] = []
    for line in response.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased().hasPrefix("source ") else { continue }
        let afterSource = trimmed.dropFirst("Source ".count)
        guard let colon = afterSource.firstIndex(of: ":") else { continue }
        let kind = afterSource[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else { continue }
        let remainder = String(afterSource[afterSource.index(after: colon)...])
        let scanned = firstRunCount(keyword: "scanned", in: remainder) ?? 0
        let indexed = firstRunCount(keyword: "indexed", in: remainder) ?? 0
        let lowerRemainder = remainder.lowercased()
        let didRun: Bool? = if lowerRemainder.contains("didrun true") {
            true
        } else if lowerRemainder.contains("didrun false") {
            false
        } else {
            nil
        }
        var skippedReason: String?
        if let skippedRange = remainder.range(of: "skipped", options: .caseInsensitive) {
            var after = String(remainder[skippedRange.upperBound...])
            after = after.trimmingCharacters(in: .whitespacesAndNewlines)
            if after.hasPrefix(":") {
                after = String(after.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !after.isEmpty {
                skippedReason = after
            }
        }
        outcomes.append(IndexSourceRunOutcome(
            kind: String(kind),
            didRun: didRun ?? (skippedReason == nil),
            scanned: scanned,
            indexed: indexed,
            skippedReason: skippedReason
        ))
    }
    return outcomes.isEmpty ? nil : outcomes
}

/// Extracts the first `<n> <keyword>` count from a run summary line.
///
/// Uses the shared compiled patterns, so the status probe performs no
/// per-request regex compilation.
/// - Parameters:
///   - keyword: Count label to find (`"indexed"`, `"scanned"`, `"errors"`, `"retired"`, `"truncated"`).
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
    case "retired":
        cached = IndexRunCountPatterns.retired
    case "truncated":
        cached = IndexRunCountPatterns.truncated
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

/// Extracts a non-negative integer from a completion detail line.
///
/// Scans lines for the given prefix (case-insensitive) and returns the leading
/// integer after it, so `Retired:` and `Truncated:` lines parse like the
/// trigger and skip lines. A response without such a line, or with a
/// non-numeric value, yields nil so the strip omits the count instead of
/// inventing one.
/// - Parameters:
///   - prefix: Detail-line prefix including the colon (for example `"Retired:"`).
///   - response: Completion detail text.
/// - Returns: The parsed count, or nil.
private func firstCountDetailToken(prefix: String, in response: String) -> Int? {
    for line in response.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { continue }
        let after = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = after.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        if let token, let value = Int(token), value >= 0 {
            return value
        }
    }
    return nil
}
