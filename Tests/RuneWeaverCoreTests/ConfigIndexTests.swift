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
        #expect(RuneWeaverConfig.default.index.enabled == false)
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
