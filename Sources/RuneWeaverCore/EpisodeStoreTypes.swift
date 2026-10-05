// Rune Weaver Core — Types and summarizers for episodic memory.

import Foundation

/// A single episodic memory record: one turn of conversation history.
public struct Episode: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this episode.
    public let id: UUID
    /// Owning conversation session.
    public let sessionID: UUID
    /// Who produced the content.
    public let role: Message.Role
    /// Text content of the turn.
    public let content: String
    /// When the turn occurred.
    public let timestamp: Date
    /// Caller-supplied key/value annotations (never secrets).
    public let metadata: [String: String]

    /// Creates an episode.
    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: Message.Role,
        content: String,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.metadata = metadata
    }

    /// Coding keys matching the SQLite `episodes` column names.
    enum CodingKeys: String, CodingKey {
        /// Episode identifier (`id` column).
        case id
        /// Owning session (`session_id` column).
        case sessionID = "session_id"
        /// Author role (`role` column).
        case role
        /// Text content (`content` column).
        case content
        /// Occurrence time (`timestamp` column).
        case timestamp
        /// JSON metadata (`metadata` column).
        case metadata
    }
}

/// Rolled-up summary of one session's old episodes.
public struct EpisodeSummary: Sendable, Codable, Equatable {
    /// Session the summarized episodes belong to.
    public let sessionID: UUID
    /// Summary text covering the compacted episodes.
    public let summary: String
    /// How many episodes were folded in.
    public let messageCount: Int
    /// Oldest episode timestamp in the group.
    public let oldest: Date
    /// Newest episode timestamp in the group.
    public let newest: Date

    /// Creates a summary.
    public init(sessionID: UUID, summary: String, messageCount: Int, oldest: Date, newest: Date) {
        self.sessionID = sessionID
        self.summary = summary
        self.messageCount = messageCount
        self.oldest = oldest
        self.newest = newest
    }
}

/// Failures raised by ``EpisodeStore``.
public enum EpisodeStoreError: Error, Sendable, Equatable {
    /// The SQLite store could not be opened or migrated.
    case storeUnavailable(String)
    /// A read or write against the store failed.
    case persistenceFailed(String)
}

/// Summarizes a batch of episodes into short text.
public typealias EpisodeSummarizer = @Sendable ([Episode]) -> String

/// Default extractive summarizer used when no LLM is wired in.
public func defaultEpisodeSummarizer(_ episodes: [Episode]) -> String {
    let parts = episodes.map { episode -> String in
        // Shared split keeps episode first lines on the same boundaries as session summaries.
        let firstLine = NormalizedText.splitLines(episode.content).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(episode.role.rawValue)] \(trimmed)"
    }
    return extractiveSummary(lines: parts, truncationLength: 4000)
}

/// Builds an extractive summary from preformatted lines.
func extractiveSummary(lines: [String], truncationLength: Int) -> String {
    guard truncationLength > 0 else { return "" }
    let joined = lines.joined(separator: "; ")
    guard joined.count > truncationLength else { return joined }
    if truncationLength == 1 {
        return "…"
    }
    return String(joined.prefix(truncationLength - 1)) + "…"
}

#if canImport(SQLite3)
    import SQLite3

    /// Allowlisted tables eligible for schema probing.
    ///
    /// The probe builds its `PRAGMA` from fixed constants so callers can
    /// never inject an arbitrary identifier; adding a case here is the
    /// only way to make another table queryable.
    package enum SQLiteKnownTable: Sendable {
        /// Conversation sessions.
        case sessions
        /// Messages belonging to a session.
        case messages
        /// Graduated-trust grants.
        case trustGrants
        /// Execution audit log shared by chat turns, scheduler runs, and goal advancements.
        case runLogs

        /// Fixed `PRAGMA` statement for the table.
        package var pragmaSQL: String {
            switch self {
            case .sessions: "PRAGMA table_info(sessions);"
            case .messages: "PRAGMA table_info(messages);"
            case .trustGrants: "PRAGMA table_info(trust_grants);"
            case .runLogs: "PRAGMA table_info(run_logs);"
            }
        }
    }

    /// Shared SQLite primitives for the episode, session, scheduler, and run-log stores.
    ///
    /// `openHandle` is the single open path on this type: it creates parent
    /// directories and applies the shared busy-timeout/WAL policy, mapping
    /// failures through the caller's error factory. There is no `openLogged`
    /// helper here — the log-on-open fallback some server stores use lives
    /// separately as `SQLiteOpenHelper.openLogged` in the server layer, which
    /// wraps this handle opener with one consistent log line.
    package enum SQLiteHelpers {
        /// Opens a database handle, creating parent directories.
        package static func openHandle(dbPath: String, unavailable: (String) -> some Error) throws -> OpaquePointer? {
            let expanded = (dbPath as NSString).expandingTildeInPath
            let directory = (expanded as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            var handle: OpaquePointer?
            let status = expanded.withCString { sqlite3_open($0, &handle) }
            guard status == SQLITE_OK, handle != nil else {
                if let handle {
                    sqlite3_close(handle)
                }
                throw unavailable("Could not open SQLite store at \(dbPath)")
            }
            do {
                try exec(
                    handle: handle,
                    sql: "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;",
                    failure: unavailable
                )
            } catch {
                sqlite3_close(handle)
                throw error
            }
            return handle
        }

        /// Executes a multi-statement SQL string.
        package static func exec(handle: OpaquePointer?, sql: String, failure: (String) -> some Error) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sql.withCString { sqlite3_exec(handle, $0, nil, nil, &errorMessage) }
            defer { sqlite3_free(errorMessage) }
            guard status == SQLITE_OK else {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown error"
                throw failure(detail)
            }
        }

        /// Binds optional text, mapping nil to NULL.
        package static func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
            if let value {
                _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Column-text helper returning nil for NULL columns.
        package static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }

        /// Binds optional 64-bit integer, mapping nil to NULL.
        package static func bindInt64(_ statement: OpaquePointer?, index: Int32, value: Int64?) {
            if let value {
                sqlite3_bind_int64(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }

        /// Column-int64 helper returning nil for NULL columns.
        package static func columnInt64(_ statement: OpaquePointer?, index: Int32) -> Int64? {
            if sqlite3_column_type(statement, index) == SQLITE_NULL {
                return nil
            }
            return sqlite3_column_int64(statement, index)
        }

        /// Binds double value.
        package static func bindDouble(_ statement: OpaquePointer?, index: Int32, value: Double) {
            sqlite3_bind_double(statement, index, value)
        }

        /// Column-double helper.
        package static func columnDouble(_ statement: OpaquePointer?, index: Int32) -> Double {
            sqlite3_column_double(statement, index)
        }

        /// Clamps a row limit to the SQLite bind range.
        /// Shared so episode and run-log reads agree that oversized caller
        /// limits cap at the 32-bit bound and non-positive limits bind as zero
        /// instead of wrapping into a negative LIMIT with wrong rows.
        package static func sqliteLimit(_ limit: Int) -> Int32 {
            Int32(min(max(limit, 0), Int(Int32.max)))
        }

        /// Lists declared columns for a table, lowercased for case-tolerant migration checks.
        /// - Parameters:
        ///   - handle: Open database handle being migrated or projected.
        ///   - table: Allowlisted table; its fixed `PRAGMA` is the only SQL issued.
        /// - Returns: Lowercased column names, or empty when the probe cannot prepare so callers attempt migration.
        package static func columnNames(handle: OpaquePointer?, table: SQLiteKnownTable) -> Set<String> {
            var names: Set<String> = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, table.pragmaSQL, -1, &statement, nil) == SQLITE_OK else {
                return names
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = columnText(statement, index: 1) {
                    names.insert(name.lowercased())
                }
            }
            return names
        }
    }
#endif

// MARK: - JSON Fallback Store

#if !canImport(SQLite3)
    /// JSON-file fallback used where the SQLite3 module is unavailable.
    enum JSONEpisodeStore {
        /// Directory holding one JSON file per episode.
        /// - Parameter dbPath: Configured database path used as anchor.
        /// - Returns: Sidecar directory URL.
        private static func directory(dbPath: String) -> URL {
            let expanded = (dbPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded + ".episodes", isDirectory: true)
        }

        /// Reads every stored episode, oldest first.
        private static func readAll(dbPath: String) throws -> [Episode] {
            try readEntries(dbPath: dbPath).sorted {
                if $0.episode.timestamp != $1.episode.timestamp {
                    return $0.episode.timestamp < $1.episode.timestamp
                }
                switch ($0.created, $1.created) {
                case let (lhs?, rhs?):
                    if lhs != rhs {
                        return lhs < rhs
                    }
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case (nil, nil):
                    break
                }
                return $0.episode.id.uuidString < $1.episode.id.uuidString
            }.map(\.episode)
        }

        /// Maximum JSON episode files retained or decoded simultaneously.
        static let maxJSONFiles = 2000

        /// Reads every stored episode with its file creation date.
        private static func readEntries(dbPath: String) throws -> [(episode: Episode, created: Date?)] {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.creationDateKey],
                    options: []
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let jsonFiles = files.filter { $0.pathExtension == "json" }
                let candidateFiles = if jsonFiles.count > maxJSONFiles {
                    jsonFiles.sorted {
                        let creationDate1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        let creationDate2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        return creationDate1 > creationDate2
                    }.prefix(maxJSONFiles).reversed()
                } else {
                    jsonFiles
                }
                var entries: [(episode: Episode, created: Date?)] = []
                entries.reserveCapacity(candidateFiles.count)
                for file in candidateFiles {
                    let episode = try decoder.decode(Episode.self, from: Data(contentsOf: file))
                    let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    entries.append((episode: episode, created: created))
                }
                return entries
            } catch let error as EpisodeStoreError {
                throw error
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not read episodes: \(error.localizedDescription)")
            }
        }

        /// Writes episodes as JSON files (upsert by `id`).
        static func write(episodes: [Episode], dbPath: String, merge: Bool) throws {
            let directoryURL = directory(dbPath: dbPath)
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !merge {
                    for file in (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [] {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                for episode in episodes {
                    let data = try encoder.encode(episode)
                    try data.write(to: directoryURL.appendingPathComponent("\(episode.id.uuidString).json"), options: .atomic)
                }
                let allFiles = (try? FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.creationDateKey]
                ))?.filter { $0.pathExtension == "json" } ?? []
                if allFiles.count > maxJSONFiles {
                    let sorted = allFiles.sorted {
                        let creationDate1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        let creationDate2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        return creationDate1 < creationDate2
                    }
                    let excess = sorted.prefix(allFiles.count - maxJSONFiles)
                    for file in excess {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } catch let error as EpisodeStoreError {
                throw error
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not write episodes: \(error.localizedDescription)")
            }
        }

        /// Reads one session's episodes, oldest first.
        static func episodes(sessionID: UUID, dbPath: String, limit: Int?) throws -> [Episode] {
            if let limit, limit <= 0 {
                return []
            }
            let matching = try readAll(dbPath: dbPath).filter { $0.sessionID == sessionID }
            guard let limit else { return matching }
            return Array(matching.prefix(limit))
        }

        /// Reads one session's newest episodes, oldest first.
        static func recentEpisodes(sessionID: UUID, dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let matching = try readAll(dbPath: dbPath).filter { $0.sessionID == sessionID }
            return Array(matching.suffix(limit))
        }

        /// Reads episodes at or before a cutoff, oldest first.
        static func episodes(olderThan: Date, dbPath: String) throws -> [Episode] {
            try readAll(dbPath: dbPath).filter { $0.timestamp <= olderThan }
        }

        /// Reads the newest episodes across all sessions.
        static func recent(dbPath: String, limit: Int) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let sorted = try readEntries(dbPath: dbPath).sorted {
                if $0.episode.timestamp != $1.episode.timestamp {
                    return $0.episode.timestamp > $1.episode.timestamp
                }
                switch ($0.created, $1.created) {
                case let (lhs?, rhs?):
                    if lhs != rhs {
                        return lhs > rhs
                    }
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    break
                }
                return $0.episode.id.uuidString > $1.episode.id.uuidString
            }.map(\.episode)
            return Array(sorted.prefix(limit))
        }

        /// Token-overlap search over episode content.
        static func search(query: String, dbPath: String, limit: Int, since: Date? = nil, until: Date? = nil) throws -> [Episode] {
            guard limit > 0 else { return [] }
            let all = try readAll(dbPath: dbPath)
            let queryTokens = Tokenization.tokenize(query)
            guard !queryTokens.isEmpty else { return [] }
            // The dated window filters before scoring so the JSON fallback
            // matches the SQLite predicates (`since` inclusive, `until` exclusive).
            let windowed = all.filter { episode in
                if let since, episode.timestamp < since {
                    return false
                }
                if let until, episode.timestamp >= until {
                    return false
                }
                return true
            }
            let scored = windowed.compactMap { episode -> (Episode, Int)? in
                let contentTokens = Tokenization.tokenize(episode.content)
                guard let raw = Tokenization.keywordScore(
                    queryTokens: queryTokens,
                    contentTokens: contentTokens,
                    content: episode.content,
                    query: query
                ) else { return nil }
                return (episode, raw)
            }
            return scored
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.timestamp > $1.0.timestamp }
                .prefix(limit)
                .map(\.0)
        }

        /// All session identifiers with stored episodes.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Session identifiers.
        static func sessionIDs(dbPath: String) throws -> [UUID] {
            try Array(Set(readAll(dbPath: dbPath).map(\.sessionID)))
        }

        /// Total stored episode count.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Episode count.
        static func count(dbPath: String) throws -> Int {
            try readAll(dbPath: dbPath).count
        }

        /// Deletes one episode file. Missing files are a no-op.
        static func delete(id: UUID, dbPath: String) throws {
            let fileURL = directory(dbPath: dbPath).appendingPathComponent("\(id.uuidString).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not delete episode: \(error.localizedDescription)")
            }
        }

        /// Deletes every episode file for a session.
        static func deleteSession(_ sessionID: UUID, dbPath: String) throws {
            for episode in try readAll(dbPath: dbPath) where episode.sessionID == sessionID {
                try delete(id: episode.id, dbPath: dbPath)
            }
        }

        /// Deletes one session's episodes at or before a cutoff.
        static func deleteSession(beforeOrAt: Date, sessionID: UUID, dbPath: String) throws {
            for episode in try readAll(dbPath: dbPath)
                where episode.sessionID == sessionID && episode.timestamp <= beforeOrAt
            {
                try delete(id: episode.id, dbPath: dbPath)
            }
        }

        /// Replaces one session's old episodes with a summary episode.
        static func compact(sessionID: UUID, beforeOrAt: Date, replacement: Episode, dbPath: String) throws {
            try write(episodes: [replacement], dbPath: dbPath, merge: true)
            for episode in try readAll(dbPath: dbPath)
                where episode.sessionID == sessionID && episode.timestamp <= beforeOrAt && episode.id != replacement.id
            {
                try delete(id: episode.id, dbPath: dbPath)
            }
        }

        /// Deletes all episode files.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        static func clear(dbPath: String) throws {
            let directoryURL = directory(dbPath: dbPath)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: directoryURL)
            } catch {
                throw EpisodeStoreError.persistenceFailed("Could not clear episodes: \(error.localizedDescription)")
            }
        }

        /// Counts then deletes all episode files.
        /// - Parameter dbPath: Anchor path for the sidecar directory.
        /// - Returns: Episode count measured immediately before clearing; zero when empty.
        static func clearReturningCount(dbPath: String) throws -> Int {
            let measured = try count(dbPath: dbPath)
            try clear(dbPath: dbPath)
            return measured
        }
    }
#endif
