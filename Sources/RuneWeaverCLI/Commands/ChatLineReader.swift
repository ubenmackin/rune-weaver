// Rune Weaver CLI — Interactive line editing and prompt history for chat.
//
// Wraps terminal line editing with persistent per-prompt history under
// `~/.runeweaver/history/`, separate from episodic memory. Keeps editing and
// TTY interaction isolated from history persistence so recall stays testable
// without a terminal attached.

#if canImport(Bestline)
    import Bestline
#endif
import Foundation
import os

// MARK: - ChatHistoryStore

/// Persistent prompt history for the chat REPL, separate from episodic memory.
///
/// Stores one submitted prompt per line under `~/.runeweaver/history/`,
/// outside the episodic SQLite file (`memory/episodes.db`) and the semantic
/// vector directory, so arrow-key recall never pollutes memory recall.
/// The file is plain UTF-8 with one prompt per line, making it easy to
/// inspect, back up, or delete without touching conversation memory.
///
/// The editing layer (Bestline, a maintained wrapper around the `bestline`
/// line-editing library) provides left/right in-place edits and up/down
/// history navigation when attached to a TTY. This store owns persistence
/// and the in-memory entry list; `ChatLineEditing` owns the TTY interaction
/// so history logic stays testable without a terminal.
struct ChatHistoryStore: Sendable {
    /// Filesystem location of the history file, if persistence is enabled.
    let fileURL: URL?
    /// Maximum entries kept in memory and on disk.
    let maxEntries: Int
    /// Stored prompts, oldest first.
    private(set) var entries: [String]

    /// Default cap keeping the file small while covering months of prompts.
    static let defaultMaxEntries = 500

    /// Creates a store.
    /// - Parameters:
    ///   - fileURL: History file to load and save. Nil disables persistence
    ///     while keeping in-memory history for the session.
    ///   - maxEntries: Maximum entries to keep. Values below one clamp to one.
    ///   - entries: Starting entries, oldest first. Longer inputs keep only
    ///     the newest `maxEntries` so resumed history never grows unbounded.
    init(fileURL: URL? = nil, maxEntries: Int = Self.defaultMaxEntries, entries: [String] = []) {
        self.fileURL = fileURL
        let clamped = max(1, maxEntries)
        self.maxEntries = clamped
        if entries.count > clamped {
            self.entries = Array(entries.suffix(clamped))
        } else {
            self.entries = entries
        }
    }

    /// Default history file outside episodic memory.
    ///
    /// Resolves to `~/.runeweaver/history/chat_history`, a sibling of
    /// `memory/` (which holds `episodes.db` and vectors) so REPL recall
    /// and episodic recall never share a file.
    /// - Returns: History file URL with `~` already expanded.
    static func defaultHistoryFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".runeweaver/history/chat_history")
    }

    /// Serial queue for history file I/O.
    ///
    /// Blocking reads and writes run here (matching the
    /// `ConversationManager.persistenceQueue` pattern) so the REPL's
    /// async context never blocks the cooperative pool, and writes
    /// execute in call order. The file is rewritten at most once per
    /// submitted prompt.
    private static let persistenceQueue = DispatchQueue(
        label: "com.runeweaver.chat-history.persistence", qos: .utility
    )

    /// Parses raw history file text into entries.
    ///
    /// Shared by `load()` and `loadAsync()` so sync and async reads agree:
    /// splits on newlines, strips stray `\r`, drops empty and
    /// whitespace-only lines, and keeps only the newest `maxEntries`.
    /// - Parameters:
    ///   - text: Raw file contents.
    ///   - maxEntries: Maximum entries to keep. Values below one clamp to one.
    /// - Returns: Parsed prompts, oldest first.
    static func parseHistoryLines(_ text: String, maxEntries: Int) -> [String] {
        let clamped = max(1, maxEntries)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(lines.suffix(clamped))
    }

    /// Renders entries as history file text.
    ///
    /// Shared by `save()` and `saveAsync()` so both paths write identical
    /// bytes: one prompt per line with a trailing newline, empty for no
    /// entries.
    /// - Parameter entries: Prompts to persist, oldest first.
    /// - Returns: File text to write.
    static func historyFileText(_ entries: [String]) -> String {
        entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    /// Restricts history directory and file permissions.
    ///
    /// Prompts may hold sensitive data, so the history directory is `0700`
    /// and the history file is `0600` (instead of the `write(atomically:)`
    /// and `createDirectory` defaults). Called after every write; throws
    /// on failure so callers surface it via the existing best-effort
    /// warning path.
    /// - Parameter fileURL: History file whose parent and self to restrict.
    /// - Throws: File-system errors from permission changes.
    private static func restrictHistoryPermissions(fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// Loads persisted entries best-effort, replacing in-memory history.
    ///
    /// Missing or unreadable files keep existing entries so a fresh install
    /// or a permissions hiccup still starts the REPL. Empty and
    /// whitespace-only lines are skipped, and only the newest `maxEntries`
    /// are kept so a hand-edited oversized file cannot grow memory.
    mutating func load() {
        guard let fileURL else { return }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        entries = Self.parseHistoryLines(text, maxEntries: maxEntries)
    }

    /// Loads persisted entries off the cooperative pool.
    ///
    /// Same best-effort semantics as `load()`, but the blocking file read
    /// runs on the serial history persistence queue so the REPL's async
    /// context never blocks. Missing or unreadable files keep existing
    /// entries.
    mutating func loadAsync() async {
        guard let fileURL else { return }
        let maxEntries = self.maxEntries
        let loaded: [String]? = await withCheckedContinuation { continuation in
            Self.persistenceQueue.async {
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.parseHistoryLines(text, maxEntries: maxEntries))
            }
        }
        if let loaded {
            entries = loaded
        }
    }

    /// Persists entries, creating the parent directory when needed.
    ///
    /// Writes one prompt per line with a trailing newline, atomically so a
    /// crash never leaves a torn file. The directory is created `0700` and
    /// the file is restricted to `0600` after the write since prompts may
    /// hold sensitive data. Callers treat failures best-effort
    /// (a dim REPL warning) so history problems never interrupt chat.
    /// - Throws: File-system errors from directory creation, the write, or
    ///   permission restriction.
    func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.historyFileText(entries).write(to: fileURL, atomically: true, encoding: .utf8)
        try Self.restrictHistoryPermissions(fileURL: fileURL)
    }

    /// Persists entries off the cooperative pool.
    ///
    /// Same atomic write as `save()`, but directory creation and the write
    /// run on the serial history persistence queue so the REPL's async
    /// context never blocks. The file is restricted to `0600` (directory
    /// `0700`) after the write since prompts may hold sensitive data.
    /// At most one save runs per submitted prompt.
    /// - Throws: File-system errors from directory creation, the write, or
    ///   permission restriction.
    func saveAsync() async throws {
        guard let fileURL else { return }
        let snapshot = entries
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.persistenceQueue.async {
                do {
                    try FileManager.default.createDirectory(
                        at: fileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try Self.historyFileText(snapshot).write(to: fileURL, atomically: true, encoding: .utf8)
                    try Self.restrictHistoryPermissions(fileURL: fileURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Records one submitted prompt.
    ///
    /// Embedded newlines fold to spaces to keep the one-prompt-per-line
    /// invariant (the REPL reads single lines, so this only triggers for
    /// programmatic callers). Empty and whitespace-only prompts are skipped,
    /// and consecutive duplicates are skipped so holding enter on the same
    /// prompt does not flood up/down navigation. Older entries fall off the
    /// front past `maxEntries`.
    /// - Parameter line: Submitted prompt, typically already trimmed.
    /// - Returns: True when the prompt was appended.
    @discardableResult
    mutating func record(_ line: String) -> Bool {
        let folded = line
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !folded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard entries.last != folded else {
            return false
        }
        entries.append(folded)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        return true
    }
}

// MARK: - CLIExactlyOnceReadState

/// Exactly-once resume state for a blocking line read.
///
/// Blocking reads (`readLine`, Bestline) cannot be cancelled mid-read, so
/// both the background completion and task cancellation race to resume. The
/// locked flag guarantees the continuation resumes exactly once: a
/// cancelled REPL unblocks promptly with nil while the late background
/// read is ignored, and a completed read wins when it finishes first.
/// All state is guarded by `lock` with `defer`-guarded unlock.
///
/// Single shared type for every CLI blocking read (REPL input via
/// `ChatLineEditing.readLine(prompt:)` and plain standard-input reads)
/// so the two paths never drift.
final class CLIExactlyOnceReadState: Sendable {
    private struct State: Sendable {
        var didResume = false
        var continuation: CheckedContinuation<String?, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Stores the continuation awaiting the background read.
    ///
    /// When cancellation already won the race, resumes immediately with nil
    /// so the waiter never hangs on a stored-but-never-resumed continuation.
    /// - Parameter continuation: Continuation to resume exactly once.
    func set(_ continuation: CheckedContinuation<String?, Never>) {
        let alreadyResumed = state.withLock { lockState -> Bool in
            if lockState.didResume {
                return true
            }
            lockState.continuation = continuation
            return false
        }
        if alreadyResumed {
            continuation.resume(returning: nil)
        }
    }

    /// Resumes exactly once, ignoring late racers.
    /// - Parameter value: Line without the newline, or nil on EOF or cancellation.
    func resume(returning value: String?) {
        let pending = state.withLock { lockState -> CheckedContinuation<String?, Never>? in
            guard !lockState.didResume else { return nil }
            lockState.didResume = true
            let cont = lockState.continuation
            lockState.continuation = nil
            return cont
        }
        pending?.resume(returning: value)
    }
}

// MARK: - Blocking line reads

/// Serial queue for all line-editor blocking reads.
///
/// Bestline edits the TTY and its in-memory history, so concurrent
/// REPL and approval reads on a concurrent queue could interleave.
/// Every `ChatLineEditing` read funnels through this serial queue so
/// only one TTY read is ever in flight.
private let chatLineReadQueue = DispatchQueue(label: "com.runeweaver.chat-line-read", qos: .userInitiated)

/// Reads one line via a blocking reader without blocking the cooperative pool.
///
/// Single shared helper for every CLI blocking read: dispatches the
/// blocking closure to the serial line-read queue and suspends until it
/// returns, so async REPL and approval paths never block the executor
/// and never interleave TTY reads. Task
/// cancellation resumes with nil exactly once via
/// `CLIExactlyOnceReadState` while the late background read is ignored;
/// the background completion path is the only other resumer.
/// - Parameter blockingRead: Synchronous line reader (e.g. Swift
///   `readLine(strippingNewline:)` or the line-editor read below).
/// - Returns: The line without the newline, or nil on EOF or cancellation.
func cliBlockingRead(_ blockingRead: @Sendable @escaping () -> String?) async -> String? {
    let state = CLIExactlyOnceReadState()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            state.set(continuation)
            chatLineReadQueue.async {
                state.resume(returning: blockingRead())
            }
        }
    } onCancel: {
        state.resume(returning: nil)
    }
}

// MARK: - Edited line read

/// Reads one line via the editing layer, falling back to standard input.
///
/// When linked against Bestline, always delegates to
/// `Bestline.readLine(prompt:)` for emacs-style left/right edits and
/// up/down history — Bestline itself falls back to basic input mode on
/// piped or dumb terminals, so no manual `isatty` gate is needed. Without
/// the dependency, prints `prompt` and uses Swift `readLine` so those
/// builds keep working with plain line reading.
/// - Parameter prompt: Prompt text to display (may hold ANSI styling).
/// - Returns: The line without the newline, or nil on EOF.
private func chatEditedRead(prompt: String) -> String? {
    #if canImport(Bestline)
        return Bestline.readLine(prompt: prompt)
    #else
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine(strippingNewline: true)
    #endif
}

// MARK: - ChatLineEditing

/// Line-editing interaction for the chat REPL.
///
/// Thin namespace over Bestline so `ChatCommand` never imports the
/// dependency directly: history persistence stays in `ChatHistoryStore`
/// (fully testable without a terminal) while TTY specifics stay here.
/// Every method is a no-op without Bestline except `readLine(prompt:)`,
/// which falls back to standard input.
///
/// Dual-store rationale: the `ChatHistoryStore` file
/// (`~/.runeweaver/history/chat_history`) is the single durable source —
/// plain UTF-8, one prompt per line, owned by the CLI so it loads, saves,
/// and stays testable with or without the Bestline dependency. Bestline's
/// own history is only the session's in-memory editable view for up/down
/// recall, mirrored best-effort (`preload` at startup, `note` per accepted
/// line) and never read back from disk, so the two cannot diverge: the
/// file wins on every launch.
/// - Note: Interactive editing itself needs a real TTY and is not covered
///   by automated tests; persistence, dedup, caps, and the history-file
///   location are covered in `RuneWeaverCLITests`.
enum ChatLineEditing {
    /// Preloads prior prompts into the editor so up/down recalls them.
    ///
    /// Called once at REPL startup after `ChatHistoryStore.loadAsync()`. Order
    /// is preserved oldest first so the most recent entry is the first
    /// up-arrow hit. Best-effort without Bestline.
    /// - Parameter entries: Prior prompts, oldest first.
    static func preload(_ entries: [String]) {
        #if canImport(Bestline)
            for entry in entries {
                Bestline.addToHistory(entry)
            }
        #else
            _ = entries
        #endif
    }

    /// Adds one submitted prompt to the editor history.
    ///
    /// Called after `ChatHistoryStore.record(_:)` reports a new entry so
    /// the file and the in-memory editor stay in sync. Best-effort without
    /// Bestline.
    /// - Parameter line: Submitted prompt already accepted for history.
    static func note(_ line: String) {
        #if canImport(Bestline)
            Bestline.addToHistory(line)
        #else
            _ = line
        #endif
    }

    /// Reads one REPL line without blocking the cooperative pool.
    ///
    /// Dispatches the blocking editor read to a background queue and
    /// suspends until input arrives via the shared `cliBlockingRead`
    /// helper. Task cancellation resumes with nil exactly once via
    /// `CLIExactlyOnceReadState` so a cancelled REPL unblocks promptly
    /// while the late background read is ignored; the background
    /// completion path is the only other resumer. Used for both the main
    /// prompt and approval prompts so arrow keys never echo escape codes
    /// on any interactive read.
    /// - Parameter prompt: Prompt text to display (may hold ANSI styling).
    /// - Returns: The line without the newline, or nil on EOF or cancellation.
    static func readLine(prompt: String) async -> String? {
        await cliBlockingRead { chatEditedRead(prompt: prompt) }
    }
}
