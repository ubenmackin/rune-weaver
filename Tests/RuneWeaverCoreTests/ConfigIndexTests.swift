// Rune Weaver Core Tests — Config index tests.
import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Config Index")
struct ConfigIndexTests {
    @Test
    func `IndexConfig defaults are disabled with bounded sources`() {
        let config = IndexConfig()
        #expect(config.enabled == false)
        #expect(config.files == true)
        #expect(config.mail == false)
        #expect(config.messages == false)
        #expect(config.roots == ["~"])
        #expect(config.exclude == IndexConfig.defaultExcludePatterns)
        #expect(config.maxFileMB == 20)
        #expect(config.mailVectorWindow == "2y")
        #expect(config.iCloudEvicted == "skip")
        #expect(config.describeImagesWithLLM == false)
        #expect(config.nightlyBudget == 0)
        #expect(config.dbPath == "~/.runeweaver/index.db")
        #expect(config.mailboxDeny == ["Trash", "Junk", "Spam", "Deleted*"])
        #expect(config.mailboxDeny == IndexConfig.defaultMailboxDeny)
        #expect(RuneWeaverConfig.default.index.enabled == false)
    }

    @Test
    func `Default excludes ship machine output and tool caches`() throws {
        let defaults = IndexConfig.defaultExcludePatterns
        for expected in [
            ".build", "*.app", "*.log", "*.tmp", ".DS_Store", ".bun", ".cocoapods",
            ".npm", ".npm-packages", ".nvm", ".cache", ".gradle", ".swiftpm", ".swiftly",
            ".gem", ".rvm", ".cpan", ".local", ".docker", ".ollama", ".terraform.d",
            ".ipynb_checkpoints", ".ipython", ".jupyter", ".matplotlib", ".vscode",
            ".vscode-insiders", ".zsh_sessions", "gopath", "go", "nltk_data"
        ] {
            #expect(defaults.contains(expected), "Expected default excludes to include \(expected)")
        }
        for removed in [".git", "node_modules", "DerivedData", "Library", ".Trash"] {
            #expect(!defaults.contains(removed), "Expected default excludes to omit walker built-in \(removed)")
        }

        let config = RuneWeaverConfig.default
        #expect(config.index.exclude == defaults)
        try config.validate()

        let rendered = config.renderTOML()
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.index.exclude == defaults)
        for expected in ["*.log", "*.tmp", ".DS_Store", ".nvm", ".cache", "gopath"] {
            #expect(reparsed.index.exclude.contains(expected), "Expected round-trip to keep \(expected)")
        }
        try reparsed.validate()
    }

    @Test
    func `Absent index section decodes to defaults`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.index == IndexConfig())
        try config.validate()
    }

    @Test
    func `Explicit index section decodes and validates`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [index]
        enabled = true
        files = true
        mail = true
        messages = false
        roots = ["~/Documents", "~/Projects"]
        exclude = [".git", "*.tmp"]
        max_file_mb = 50
        mail_vector_window = "all"
        icloud_evicted = "download"
        describe_images_with_llm = true
        nightly_budget = 250
        db_path = "~/.runeweaver/index/custom.db"
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.index.enabled == true)
        #expect(config.index.files == true)
        #expect(config.index.mail == true)
        #expect(config.index.messages == false)
        #expect(config.index.roots == ["~/Documents", "~/Projects"])
        #expect(config.index.exclude == [".git", "*.tmp"])
        #expect(config.index.maxFileMB == 50)
        #expect(config.index.mailVectorWindow == "all")
        #expect(config.index.iCloudEvicted == "download")
        #expect(config.index.describeImagesWithLLM == true)
        #expect(config.index.nightlyBudget == 250)
        #expect(config.index.dbPath == "~/.runeweaver/index/custom.db")
        try config.validate()
    }

    @Test
    func `Index config round-trips through TOML`() throws {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(
            enabled: true,
            files: false,
            mail: true,
            messages: true,
            roots: ["~/Notes", "~/Code"],
            exclude: [".git", "*.o"],
            maxFileMB: 64,
            mailVectorWindow: "1y",
            iCloudEvicted: "download",
            describeImagesWithLLM: true,
            nightlyBudget: 500,
            dbPath: "~/.runeweaver/index.db"
        )
        try config.validate()

        let rendered = config.renderTOML()
        #expect(rendered.contains("[index]"))
        #expect(rendered.contains("mail_vector_window = \"1y\""))
        #expect(rendered.contains("icloud_evicted = \"download\""))

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.index == config.index)
        try reparsed.validate()
    }

    @Test
    func `Unknown mail_vector_window fails validation`() {
        expectIndexValidationFailure({ $0.mailVectorWindow = "carrier-pigeon" }, field: "index.mail_vector_window")
    }

    @Test
    func `Unknown icloud_evicted policy fails validation`() {
        expectIndexValidationFailure({ $0.iCloudEvicted = "delete" }, field: "index.icloud_evicted")
    }

    @Test
    func `Out of range max_file_mb fails validation`() {
        expectIndexValidationFailure({ $0.maxFileMB = 0 }, field: "index.max_file_mb")
        expectIndexValidationFailure(
            { $0.maxFileMB = IndexConfig.maxAllowedFileMB + 1 },
            field: "index.max_file_mb"
        )
    }

    @Test
    func `Negative nightly_budget fails validation`() {
        expectIndexValidationFailure({ $0.nightlyBudget = -1 }, field: "index.nightly_budget")
    }

    @Test
    func `Empty db_path fails validation`() {
        expectIndexValidationFailure({ $0.dbPath = "  " }, field: "index.db_path")
    }

    @Test
    func `Directory escape in roots fails validation`() {
        expectIndexValidationFailure({ $0.roots = ["../etc"] }, field: "index.roots")
    }

    @Test
    func `Blank exclude pattern fails validation`() {
        expectIndexValidationFailure({ $0.exclude = [""] }, field: "index.exclude")
    }

    @Test
    func `Index effort defaults to balanced with derived workers`() {
        let config = IndexConfig()
        #expect(config.effort == "balanced")
        #expect(config.effort == IndexConfig.defaultEffort)
        #expect(config.workers == 0)
        #expect(config.thermalBackoff == true)
        #expect(config.pauseOnBattery == false)
    }

    @Test
    func `Index effort presets resolve deterministically`() {
        var light = IndexConfig()
        light.effort = "light"
        #expect(light.resolvedWorkerCount(cores: 8) == 1)
        #expect(light.resolvedWorkerCount(cores: 24) == 1)

        var balanced = IndexConfig()
        balanced.effort = "balanced"
        #expect(balanced.resolvedWorkerCount(cores: 8) == 4)
        #expect(balanced.resolvedWorkerCount(cores: 24) == 4)

        var performance = IndexConfig()
        performance.effort = "performance"
        #expect(performance.resolvedWorkerCount(cores: 8) == 7)
        #expect(performance.resolvedWorkerCount(cores: 24) == 23)

        var custom = IndexConfig()
        custom.effort = "custom"
        custom.workers = 6
        #expect(custom.resolvedWorkerCount(cores: 8) == 6)
        #expect(custom.resolvedWorkerCount(cores: 24) == 6)
        custom.workers = 100
        #expect(custom.resolvedWorkerCount(cores: 8) == 8)
        #expect(custom.resolvedWorkerCount(cores: 24) == 24)
        // The static ceiling binds before the core clamp so a value carried
        // from a larger machine never oversubscribes even a large host.
        #expect(custom.resolvedWorkerCount(cores: 128) == IndexConfig.maxAllowedWorkers)

        let liveCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        #expect(balanced.resolvedWorkerCount() == balanced.resolvedWorkerCount(cores: liveCores))
    }

    @Test
    func `Explicit effort keys decode`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [index]
        enabled = true
        effort = "performance"
        workers = 0
        thermal_backoff = false
        pause_on_battery = true
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.index.effort == "performance")
        #expect(config.index.workers == 0)
        #expect(config.index.thermalBackoff == false)
        #expect(config.index.pauseOnBattery == true)
        try config.validate()
    }

    @Test
    func `Invalid effort fails validation`() {
        expectIndexValidationFailure({ $0.effort = "turbo" }, field: "index.effort")
        // Legacy frontend and example tokens never pass the closed set; they
        // must arrive canonicalized instead of validating in place.
        expectIndexValidationFailure({ $0.effort = "eco" }, field: "index.effort")
        expectIndexValidationFailure({ $0.effort = "standard" }, field: "index.effort")
    }

    @Test
    func `Workers decodes into the canonical field`() throws {
        let payload = """
        {"effort":"custom","workers":5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IndexConfig.self, from: payload)
        #expect(decoded.workers == 5)
        let encoded = try JSONEncoder().encode(IndexConfig(effort: "custom", workers: 2))
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        #expect(object["workers"] as? Int == 2)
    }

    @Test
    func `Custom workers out of range fails validation`() {
        // The custom count validates against a static ceiling so the same
        // file loads on any machine; the live core count only clamps at
        // resolve time.
        expectIndexValidationFailure({
            $0.effort = "custom"
            $0.workers = 0
        }, field: "index.workers")
        expectIndexValidationFailure({
            $0.effort = "custom"
            $0.workers = IndexConfig.maxAllowedWorkers + 1
        }, field: "index.workers")
        expectIndexValidationFailure({
            $0.effort = "balanced"
            $0.workers = 2
        }, field: "index.workers")
        // A large-but-valid count passes validation even on a small machine.
        var config = RuneWeaverConfig.default
        config.index.effort = "custom"
        config.index.workers = IndexConfig.maxAllowedWorkers
        do {
            try config.validate()
        } catch {
            Issue.record("Expected custom workers at the static ceiling to validate, got \(error)")
        }
    }

    @Test
    func `Index effort round-trips through TOML`() throws {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(
            enabled: true,
            files: true,
            mail: false,
            messages: false,
            roots: ["~"],
            exclude: [".git"],
            maxFileMB: 20,
            mailVectorWindow: "2y",
            iCloudEvicted: "skip",
            describeImagesWithLLM: false,
            nightlyBudget: 0,
            dbPath: "~/.runeweaver/index.db",
            effort: "custom",
            workers: 1,
            thermalBackoff: false,
            pauseOnBattery: true
        )
        try config.validate()

        let rendered = config.renderTOML()
        #expect(rendered.contains("effort = \"custom\""))
        #expect(rendered.contains("workers = 1"))
        #expect(rendered.contains("thermal_backoff = false"))
        #expect(rendered.contains("pause_on_battery = true"))

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.index == config.index)
        try reparsed.validate()
    }

    @Test
    func `Max vector chunks defaults to a bounded cap`() {
        let config = IndexConfig()
        #expect(config.maxVectorChunksPerDocument == 128)
        #expect(config.maxVectorChunksPerDocument == IndexConfig.defaultMaxVectorChunksPerDocument)
        #expect(IndexConfig.maxAllowedVectorChunksPerDocument == 4096)
    }

    @Test
    func `Explicit max_vector_chunks_per_document decodes`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [index]
        enabled = true
        max_vector_chunks_per_document = 64
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.index.maxVectorChunksPerDocument == 64)
        try config.validate()
    }

    @Test
    func `Out of range max_vector_chunks_per_document fails validation`() {
        expectIndexValidationFailure({ $0.maxVectorChunksPerDocument = 0 }, field: "index.max_vector_chunks_per_document")
        expectIndexValidationFailure(
            { $0.maxVectorChunksPerDocument = IndexConfig.maxAllowedVectorChunksPerDocument + 1 },
            field: "index.max_vector_chunks_per_document"
        )
    }

    @Test
    func `Max vector chunks round-trips through TOML`() throws {
        var config = RuneWeaverConfig.default
        config.index = IndexConfig(
            enabled: true,
            files: true,
            mail: false,
            messages: false,
            roots: ["~"],
            exclude: [".git"],
            maxFileMB: 20,
            mailVectorWindow: "2y",
            iCloudEvicted: "skip",
            describeImagesWithLLM: false,
            nightlyBudget: 0,
            dbPath: "~/.runeweaver/index.db",
            effort: "balanced",
            workers: 0,
            thermalBackoff: true,
            pauseOnBattery: false,
            maxVectorChunksPerDocument: 64
        )
        try config.validate()

        let rendered = config.renderTOML()
        #expect(rendered.contains("max_vector_chunks_per_document = 64"))

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.index == config.index)
        try reparsed.validate()
    }

    @Test
    func `Files deny defaults include credential and history patterns`() {
        let patterns = FilesConfig.defaultDenyPatterns
        // Long-standing entries stay denied so the widened list never trades
        // an old boundary for a new one.
        for expected in [
            ".env*", ".netrc", "secrets.json", "config.toml", "*.pem", "*.key",
            "*keychain*", ".ssh/*", ".aws/*", ".runeweaver/memory/vectors/*"
        ] {
            #expect(patterns.contains(expected), "Expected default deny list to keep \(expected)")
        }
        // Newly protected credential files, cloud CLIs, and shell histories
        // whose pasted tokens would otherwise ride index chunks to the model.
        for expected in [
            ".git-credentials", ".gitcookies", ".rclone.conf", ".npmrc", ".pypirc",
            ".Xauthority", ".emulator_console_auth_token", ".gnupg/*", ".kube/*",
            ".docker/*", ".config/gcloud/*", ".chia_keys/*", "*_history", ".zsh_sessions/*"
        ] {
            #expect(patterns.contains(expected), "Expected default deny list to include \(expected)")
        }
    }

    @Test
    func `Files deny patterns survive a TOML round-trip`() throws {
        // The default file policy renders into the saved document and parses
        // back byte-identical, so a restart never silently drops a boundary.
        let config = RuneWeaverConfig.default
        #expect(config.files.denyPatterns == FilesConfig.defaultDenyPatterns)
        try config.validate()

        let rendered = config.renderTOML()
        #expect(rendered.contains("[files]"))

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.files == config.files)
        #expect(reparsed.files.denyPatterns == FilesConfig.defaultDenyPatterns)
        try reparsed.validate()
    }

    @Test
    func `Mailbox deny defaults to Trash-class globs`() {
        #expect(IndexConfig.defaultMailboxDeny == ["Trash", "Junk", "Spam", "Deleted*"])
        #expect(IndexConfig().mailboxDeny == IndexConfig.defaultMailboxDeny)
    }

    @Test
    func `Mailbox deny round-trips through TOML`() throws {
        var config = RuneWeaverConfig.default
        config.index.mailboxDeny = ["Trash", "Custom*"]
        try config.validate()

        let rendered = config.renderTOML()
        #expect(rendered.contains("mailbox_deny"))

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.index.mailboxDeny == ["Trash", "Custom*"])
        try reparsed.validate()
    }

    @Test
    func `Explicit mailbox_deny decodes`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [index]
        enabled = true
        mailbox_deny = ["Trash", "Deleted*"]
        """
        let root = try TOMLParser.parse(text)
        let config = try RuneWeaverConfig(decoding: root)
        #expect(config.index.mailboxDeny == ["Trash", "Deleted*"])
        try config.validate()
    }

    @Test
    func `Empty mailbox_deny opts every mailbox back in`() throws {
        var config = RuneWeaverConfig.default
        config.index.mailboxDeny = []
        try config.validate()

        let rendered = config.renderTOML()
        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.index.mailboxDeny == [])
        try reparsed.validate()
    }

    @Test
    func `Blank mailbox_deny entry fails validation`() {
        expectIndexValidationFailure({ $0.mailboxDeny = ["Trash", "  "] }, field: "index.mailbox_deny")
        expectIndexValidationFailure({ $0.mailboxDeny = [""] }, field: "index.mailbox_deny")
    }
}

/// Mutates one index field on a default config and asserts validation fails
/// with the expected dotted field name.
private func expectIndexValidationFailure(
    _ mutate: (inout IndexConfig) -> Void,
    field: String
) {
    var config = RuneWeaverConfig.default
    mutate(&config.index)
    do {
        try config.validate()
        Issue.record("Expected ConfigError for \(field)")
    } catch let error as ConfigError {
        guard case let .validationError(failedField, _) = error else {
            Issue.record("Expected validationError, got \(error)")
            return
        }
        #expect(failedField == field)
    } catch {
        Issue.record("Expected ConfigError, got \(error)")
    }
}
