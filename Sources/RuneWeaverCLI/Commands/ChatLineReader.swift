// Rune Weaver CLI — Interactive line editing and prompt history for chat.

#if canImport(Bestline)
    import Bestline
#endif
import Foundation
import os
import RuneWeaverCore

// MARK: - ChatHistoryStore

/// Persistent prompt history for the chat REPL, separate from episodic memory.
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
    static func defaultHistoryFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".runeweaver/history/chat_history")
    }

    /// Serial queue for history file I/O.
    private static let persistenceQueue = DispatchQueue(
        label: "com.runeweaver.chat-history.persistence", qos: .utility
    )

    /// Parses raw history file text into entries.
    static func parseHistoryLines(_ text: String, maxEntries: Int) -> [String] {
        let clamped = max(1, maxEntries)
        // Shared fold keeps history boundaries identical to TOML and archive
        // parsing, so CRLF/CR files recall the same prompts as LF files.
        let lines = NormalizedText.splitLines(text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(lines.suffix(clamped))
    }

    /// Renders entries as history file text.
    static func historyFileText(_ entries: [String]) -> String {
        entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    /// Restricts history directory and file permissions.
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
    mutating func load() {
        guard let fileURL else { return }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        entries = Self.parseHistoryLines(text, maxEntries: maxEntries)
    }

    /// Loads persisted entries off the cooperative pool.
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
    @discardableResult
    mutating func record(_ line: String) -> Bool {
        // Single fold source keeps history recording on the same line boundaries
        // as parsing; folded to one line so multi-line pastes recall as one prompt.
        let folded = NormalizedText.normalizedLineEndings(line).replacingOccurrences(of: "\n", with: " ")
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
final class CLIExactlyOnceReadState: Sendable {
    private struct State: Sendable {
        var didResume = false
        var continuation: CheckedContinuation<String?, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Stores the continuation awaiting the background read.
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
/// Reads must serialize so concurrent callers cannot race on stdin and steal each other's lines.
private let chatLineReadQueue = DispatchQueue(label: "com.runeweaver.chat-line-read", qos: .userInitiated)

/// Reads one line via a blocking reader without blocking the cooperative pool.
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
enum ChatLineEditing {
    /// Preloads prior prompts into the editor so up/down recalls them.
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
    static func note(_ line: String) {
        #if canImport(Bestline)
            Bestline.addToHistory(line)
        #else
            _ = line
        #endif
    }

    /// Reads one REPL line without blocking the cooperative pool.
    static func readLine(prompt: String) async -> String? {
        await cliBlockingRead { chatEditedRead(prompt: prompt) }
    }
}
