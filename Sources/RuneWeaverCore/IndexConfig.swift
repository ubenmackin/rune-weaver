// Rune Weaver Core — Document index configuration.
//
// Source toggles narrow what an enabled indexer may touch, roots/exclude
// bound the file walk, and the remaining knobs cap per-item work and where the
// index database lives. Secrets never appear here; the index stores content
// and derived vectors only.

import Foundation

/// Source toggles narrow what an enabled indexer may touch, `roots`/`exclude`
/// bound the file walk, and the remaining knobs cap per-item work and where the
/// index database lives. Secrets never appear here; the index stores content
/// and derived vectors only.
public struct IndexConfig: Sendable, Codable, Equatable {
    /// Whether the background indexer runs at all. Defaults to off.
    public var enabled: Bool
    /// Whether local files are indexed. On by default once the indexer is enabled.
    public var files: Bool
    /// Whether mail is indexed. Off by default so enabling the indexer never
    /// silently reads a mailbox.
    public var mail: Bool
    /// Whether Apple Messages are indexed. Off by default.
    public var messages: Bool
    /// Whether calendar events are indexed. Off by default.
    public var calendars: Bool
    /// Whether reminders are indexed. Off by default.
    public var reminders: Bool
    /// Root directories scanned for files (`~` expands to home).
    public var roots: [String]
    /// Glob patterns skipped during a file scan (VCS directories, build output,
    /// caches) so the walk never descends into material it should not index.
    public var exclude: [String]
    /// Largest file the indexer will read, in megabytes. Defaults to 20 MB.
    public var maxFileMB: Int
    /// How far back mail is vectorized: a window token (``allowedMailVectorWindows``)
    /// or `all`. Defaults to `2y` to keep the local store bounded.
    public var mailVectorWindow: String
    /// Policy for iCloud files whose bytes are evicted: `skip` or `download`.
    /// Defaults to `skip` so an index run never silently pulls a file down.
    public var iCloudEvicted: String
    /// Whether image files are described with the configured LLM. Off by
    /// default; enabling it sends image content to the active provider.
    public var describeImagesWithLLM: Bool
    /// Maximum number of items processed per nightly index run. `0` means
    /// unlimited. Defaults to unlimited.
    public var nightlyBudget: Int
    /// SQLite path for the index database.
    public var dbPath: String
    /// Indexing effort preset: `light`, `balanced`, `performance`, or `custom`.
    /// Defaults to `balanced` so stock installs stay cool and responsive.
    public var effort: String
    /// Explicit worker count for the `custom` effort preset. `0` means derive
    /// from the preset; non-custom presets must leave this at `0`. Custom
    /// counts validate against a static 1...64 ceiling and clamp to the live
    /// core count at resolve time.
    public var workers: Int
    /// Whether indexing backs off when the system reports thermal pressure.
    /// Defaults to on so stock installs stay cool under sustained load.
    public var thermalBackoff: Bool
    /// Whether indexing pauses while running on battery power. Defaults to off
    /// so plugged-in and portable schedules behave the same until opted in.
    public var pauseOnBattery: Bool
    /// Maximum vector chunks stored per document. Bounds per-document embedding
    /// work so one text-dense document cannot fan an outsized batch; chunks
    /// beyond the cap stay keyword-only.
    public var maxVectorChunksPerDocument: Int
    /// Glob patterns for mailboxes the mail indexer skips without dialing.
    /// Defaults to Trash-class mailboxes so transient deletes never enter the
    /// index; denied mailboxes retire on the next complete run and re-index
    /// from scratch when re-allowed.
    public var mailboxDeny: [String]
    /// Directory and file names the files walker always skips, even when they
    /// are absent from `exclude`. Read-only: always populated from the walker's
    /// prune list (`FilesIndexer.alwaysSkippedPatterns`) so the dashboard copy
    /// cannot drift from what is actually pruned. The `[files]` deny patterns
    /// stay out of this list and are described generically in the UI.
    public let alwaysSkipped: [String]

    /// Default file source toggle.
    public static let defaultFilesEnabled = true
    /// Default mail source toggle.
    public static let defaultMailEnabled = false
    /// Default Messages source toggle.
    public static let defaultMessagesEnabled = false
    /// Default Calendars source toggle.
    public static let defaultCalendarsEnabled = false
    /// Default Reminders source toggle.
    public static let defaultRemindersEnabled = false
    /// Default file roots (home directory).
    public static let defaultRoots = ["~"]
    /// Default exclude patterns skipped during a file scan.
    ///
    /// The visible, editable list that seeds the Index Policy "Exclude patterns"
    /// editor: ordinary globs the owner can read and change. Machine-output
    /// files (`*.log`, `*.tmp`, `.DS_Store`) and package-manager, build, model,
    /// and agent tool caches ship here so a fresh index skips them. Distinct from
    /// `FilesIndexer.alwaysSkippedPatterns`: the walker's traversal-safety entries
    /// (`Music`, `Pictures`, `Movies`, `Library`,
    /// `.Trash`, `.runeweaver`, `.git`, `node_modules`, `DerivedData`,
    /// `__pycache__`, `.venv`) are applied unconditionally outside this list and
    /// cannot be removed by configuration.
    public static let defaultExcludePatterns = [
        ".build",
        "*.app",
        "*.log",
        "*.tmp",
        ".DS_Store",
        ".bun",
        ".cocoapods",
        ".npm",
        ".npm-packages",
        ".nvm",
        ".cache",
        ".gradle",
        ".swiftpm",
        ".swiftly",
        ".gem",
        ".rvm",
        ".cpan",
        ".local",
        ".docker",
        ".ollama",
        ".terraform.d",
        ".ipynb_checkpoints",
        ".ipython",
        ".jupyter",
        ".matplotlib",
        ".vscode",
        ".vscode-insiders",
        ".zsh_sessions",
        "gopath",
        "go",
        "nltk_data"
    ]
    /// Default maximum file size in megabytes.
    public static let defaultMaxFileMB = 20
    /// Hard upper bound for `max_file_mb`, keeping a typo from admitting a
    /// multi-gigabyte file into the index.
    public static let maxAllowedFileMB = 10240
    /// Default `mail_vector_window` value.
    public static let defaultMailVectorWindow = "2y"
    /// Closed set of valid `mail_vector_window` values; `all` disables the window.
    public static let allowedMailVectorWindows = ["30d", "6m", "1y", "2y", "all"]
    /// Default `icloud_evicted` policy.
    public static let defaultICloudEvicted = "skip"
    /// Closed set of valid `icloud_evicted` policies.
    public static let allowedICloudEvictions = ["skip", "download"]
    /// Default `nightly_budget` value (unlimited).
    public static let defaultNightlyBudget = 0
    /// Hard upper bound for `nightly_budget`, keeping a stray extra digit from
    /// scheduling an unbounded night's work.
    public static let maxAllowedNightlyBudget = 100_000
    /// Default SQLite path for the index database.
    /// This is the single source for the on-disk index location;
    /// `DocIndexStore.defaultDBPath` aliases this value.
    public static let defaultDBPath = "~/.runeweaver/index.db"
    /// Default `effort` preset.
    public static let defaultEffort = "balanced"
    /// Closed set of valid `effort` presets; `custom` reads `workers`.
    public static let allowedEfforts = ["light", "balanced", "performance", "custom"]
    /// Default `workers` value (`0` means derive from the effort preset).
    public static let defaultWorkers = 0
    /// Static ceiling for a `custom` worker count. Validation uses this fixed
    /// bound so the same file loads on a laptop and a studio machine;
    /// resolution clamps to the live core count, so a large-but-valid count
    /// never oversubscribes the current hardware.
    public static let maxAllowedWorkers = 64
    /// Default `thermal_backoff` value.
    public static let defaultThermalBackoff = true
    /// Default `pause_on_battery` value.
    public static let defaultPauseOnBattery = false
    /// Default `max_vector_chunks_per_document` value.
    public static let defaultMaxVectorChunksPerDocument = 128
    /// Hard upper bound for `max_vector_chunks_per_document`, keeping a typo
    /// from admitting an unbounded embedding batch per document.
    public static let maxAllowedVectorChunksPerDocument = 4096
    /// Default Trash-class mailbox denylist.
    ///
    /// Trash-like mail is transient by nature, so a fresh install skips it
    /// without dialing; clearing the list opts back into indexing every
    /// mailbox.
    public static let defaultMailboxDeny = ["Trash", "Junk", "Spam", "Deleted*"]

    /// Creates an index config.
    public init(
        enabled: Bool = false,
        files: Bool = defaultFilesEnabled,
        mail: Bool = defaultMailEnabled,
        messages: Bool = defaultMessagesEnabled,
        calendars: Bool = defaultCalendarsEnabled,
        reminders: Bool = defaultRemindersEnabled,
        roots: [String] = defaultRoots,
        exclude: [String] = defaultExcludePatterns,
        maxFileMB: Int = defaultMaxFileMB,
        mailVectorWindow: String = defaultMailVectorWindow,
        iCloudEvicted: String = defaultICloudEvicted,
        describeImagesWithLLM: Bool = false,
        nightlyBudget: Int = defaultNightlyBudget,
        dbPath: String = defaultDBPath,
        effort: String = defaultEffort,
        workers: Int = defaultWorkers,
        thermalBackoff: Bool = defaultThermalBackoff,
        pauseOnBattery: Bool = defaultPauseOnBattery,
        maxVectorChunksPerDocument: Int = defaultMaxVectorChunksPerDocument,
        mailboxDeny: [String] = defaultMailboxDeny
    ) {
        self.enabled = enabled
        self.files = files
        self.mail = mail
        self.messages = messages
        self.calendars = calendars
        self.reminders = reminders
        self.roots = roots
        self.exclude = exclude
        self.maxFileMB = maxFileMB
        self.mailVectorWindow = mailVectorWindow
        self.iCloudEvicted = iCloudEvicted
        self.describeImagesWithLLM = describeImagesWithLLM
        self.nightlyBudget = nightlyBudget
        self.dbPath = dbPath
        self.effort = effort
        self.workers = workers
        self.thermalBackoff = thermalBackoff
        self.pauseOnBattery = pauseOnBattery
        self.maxVectorChunksPerDocument = maxVectorChunksPerDocument
        self.mailboxDeny = mailboxDeny
        self.alwaysSkipped = FilesIndexer.alwaysSkippedPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case files
        case mail
        case messages
        case calendars
        case reminders
        case roots
        case exclude
        case maxFileMB = "max_file_mb"
        case mailVectorWindow = "mail_vector_window"
        case iCloudEvicted = "icloud_evicted"
        case describeImagesWithLLM = "describe_images_with_llm"
        case nightlyBudget = "nightly_budget"
        case dbPath = "db_path"
        case effort
        case workers
        case thermalBackoff = "thermal_backoff"
        case pauseOnBattery = "pause_on_battery"
        case maxVectorChunksPerDocument = "max_vector_chunks_per_document"
        case mailboxDeny = "mailbox_deny"
        case alwaysSkipped = "always_skipped"
    }

    /// Decodes an index config, defaulting every omitted key.
    /// - Parameter decoder: Decoder for the config document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        files = try container.decodeIfPresent(Bool.self, forKey: .files) ?? Self.defaultFilesEnabled
        mail = try container.decodeIfPresent(Bool.self, forKey: .mail) ?? Self.defaultMailEnabled
        messages = try container.decodeIfPresent(Bool.self, forKey: .messages) ?? Self.defaultMessagesEnabled
        calendars = try container.decodeIfPresent(Bool.self, forKey: .calendars) ?? Self.defaultCalendarsEnabled
        reminders = try container.decodeIfPresent(Bool.self, forKey: .reminders) ?? Self.defaultRemindersEnabled
        roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? Self.defaultRoots
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? Self.defaultExcludePatterns
        maxFileMB = try container.decodeIfPresent(Int.self, forKey: .maxFileMB) ?? Self.defaultMaxFileMB
        mailVectorWindow = try container.decodeIfPresent(String.self, forKey: .mailVectorWindow) ?? Self.defaultMailVectorWindow
        iCloudEvicted = try container.decodeIfPresent(String.self, forKey: .iCloudEvicted) ?? Self.defaultICloudEvicted
        describeImagesWithLLM = try container.decodeIfPresent(Bool.self, forKey: .describeImagesWithLLM) ?? false
        nightlyBudget = try container.decodeIfPresent(Int.self, forKey: .nightlyBudget) ?? Self.defaultNightlyBudget
        dbPath = try container.decodeIfPresent(String.self, forKey: .dbPath) ?? Self.defaultDBPath
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? Self.defaultEffort
        workers = try container.decodeIfPresent(Int.self, forKey: .workers) ?? Self.defaultWorkers
        thermalBackoff = try container.decodeIfPresent(Bool.self, forKey: .thermalBackoff) ?? Self.defaultThermalBackoff
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? Self.defaultPauseOnBattery
        maxVectorChunksPerDocument = try container.decodeIfPresent(Int.self, forKey: .maxVectorChunksPerDocument) ?? Self.defaultMaxVectorChunksPerDocument
        mailboxDeny = try container.decodeIfPresent([String].self, forKey: .mailboxDeny) ?? Self.defaultMailboxDeny
        // Read-only: any written value is discarded so the walker list stays
        // single-sourced and a client echo cannot drift the stored policy.
        _ = try container.decodeIfPresent([String].self, forKey: .alwaysSkipped)
        alwaysSkipped = FilesIndexer.alwaysSkippedPatterns
    }

    /// Encodes an index config using the canonical `workers` key.
    /// - Parameter encoder: Encoder receiving the config.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(files, forKey: .files)
        try container.encode(mail, forKey: .mail)
        try container.encode(messages, forKey: .messages)
        try container.encode(calendars, forKey: .calendars)
        try container.encode(reminders, forKey: .reminders)
        try container.encode(roots, forKey: .roots)
        try container.encode(exclude, forKey: .exclude)
        try container.encode(maxFileMB, forKey: .maxFileMB)
        try container.encode(mailVectorWindow, forKey: .mailVectorWindow)
        try container.encode(iCloudEvicted, forKey: .iCloudEvicted)
        try container.encode(describeImagesWithLLM, forKey: .describeImagesWithLLM)
        try container.encode(nightlyBudget, forKey: .nightlyBudget)
        try container.encode(dbPath, forKey: .dbPath)
        try container.encode(effort, forKey: .effort)
        try container.encode(workers, forKey: .workers)
        try container.encode(thermalBackoff, forKey: .thermalBackoff)
        try container.encode(pauseOnBattery, forKey: .pauseOnBattery)
        try container.encode(maxVectorChunksPerDocument, forKey: .maxVectorChunksPerDocument)
        try container.encode(mailboxDeny, forKey: .mailboxDeny)
        try container.encode(alwaysSkipped, forKey: .alwaysSkipped)
    }

    /// Resolves the effort preset to a concrete worker count on this machine.
    /// - Returns: Worker count derived from the active processor count.
    public func resolvedWorkerCount() -> Int {
        resolvedWorkerCount(cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Resolves the effort preset to a concrete worker count for a core count.
    ///
    /// `light` pins one worker, `balanced` takes half the cores up to four,
    /// `performance` takes all but one core, and `custom` clamps the stored
    /// count into 1...64 and then to the available cores so a value carried
    /// over from a larger machine never oversubscribes this one. `balanced` is
    /// an explicit case; unknown strings bypassing `validate()` fall back to
    /// the balanced formula as a defensive default so a typo degrades to the
    /// stock preset instead of oversubscribing.
    /// - Parameter cores: Logical core count to resolve against.
    /// - Returns: Deterministic worker count for the given core count.
    public func resolvedWorkerCount(cores: Int) -> Int {
        let safeCores = max(1, cores)
        switch effort {
        case "light":
            return 1
        case "balanced":
            return max(1, min(4, safeCores / 2))
        case "performance":
            return max(1, safeCores - 1)
        case "custom":
            let capped = min(max(workers, 1), Self.maxAllowedWorkers)
            return min(capped, safeCores)
        default:
            return max(1, min(4, safeCores / 2))
        }
    }
}
