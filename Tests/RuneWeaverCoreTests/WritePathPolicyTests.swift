// Rune Weaver Tests — Write-path policy precedence and the [files] write_path_rules section.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Isolated filesystem helpers for the policy suites.
private enum PolicyTestSupport {
    /// Creates a fresh temp base with an isolated fake home.
    /// - Returns: Base directory plus the fake home boundary.
    static func makeBaseAndHome() throws -> (base: URL, home: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-writepath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = base.resolvingSymlinksInPath().standardizedFileURL
        let home = canonical.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (canonical, home)
    }

    /// Removes a temp base best-effort.
    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }
}

@Suite("Write Path Policy")
struct WritePathPolicyTests {
    // MARK: - Defaults and explicit-empty seeding

    @Test
    func `Default write path rules cover personal and working directories`() {
        let defaults = FilesWritePathRule.defaultRules
        #expect(defaults.count == 5)
        #expect(defaults.map(\.path) == ["~/Library", "~/Photos", "~/Documents", "~/Desktop", "~/Downloads"])
        #expect(defaults.map(\.posture) == [.ask, .ask, .stage, .stage, .stage])
        #expect(FilesConfig().writePathRules == defaults)
        #expect(RuneWeaverConfig.default.files.writePathRules == defaults)
        #expect(FilesWritePathPosture.allCases.map(\.rawValue) == ["live", "stage", "ask", "deny"])
    }

    @Test
    func `Absent write path rules key seeds defaults while explicit empty stays empty`() throws {
        let decoder = JSONDecoder()
        // An absent key seeds the documented defaults so an existing settings
        // payload keeps the personal-data asks and working-directory stages.
        let absent = try decoder.decode(FilesConfig.self, from: Data(#"{"allow_roots":["~"]}"#.utf8))
        #expect(absent.writePathRules == FilesWritePathRule.defaultRules)
        // An explicit empty array stays empty: an owner who cleared every rule
        // opted out rather than silently getting five back.
        let empty = try decoder.decode(FilesConfig.self, from: Data(#"{"writePathRules":[]}"#.utf8))
        #expect(empty.writePathRules.isEmpty)
        // A populated list decodes exactly as written.
        let populatedJSON = #"{"writePathRules":[{"path":"~/Notes","posture":"live"}]}"#
        let populated = try decoder.decode(FilesConfig.self, from: Data(populatedJSON.utf8))
        #expect(populated.writePathRules == [FilesWritePathRule(path: "~/Notes", posture: .live)])
        // Encoding carries the rules back out under the schema key, so the
        // decoded round-trip is the same rule and not a silently dropped one.
        let encoded = try JSONEncoder().encode(populated)
        let decodedBack = try decoder.decode(FilesConfig.self, from: encoded)
        #expect(decodedBack == populated)
        #expect(decodedBack.writePathRules == [FilesWritePathRule(path: "~/Notes", posture: .live)])
    }

    // MARK: - TOML section shape

    @Test
    func `Write path rules round-trip through TOML`() throws {
        var config = RuneWeaverConfig.default
        config.files.writePathRules = [
            FilesWritePathRule(path: "~/Notes", posture: .live),
            FilesWritePathRule(path: "~/Archive/2025", posture: .ask)
        ]
        try config.validate()

        let rendered = config.renderTOML()
        #expect(rendered.contains("[[files.write_paths]]"))
        #expect(rendered.contains("path = \(RuneWeaverConfig.tomlQuoted("~/Notes"))"))
        #expect(rendered.contains("posture = \(RuneWeaverConfig.tomlQuoted("live"))"))

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.files.writePathRules == config.files.writePathRules)
        #expect(reparsed.files == config.files)
        try reparsed.validate()

        // The stock default document round-trips its five seeded rules too, so
        // a resave never silently drops the personal-data asks.
        let stockRendered = RuneWeaverConfig.default.renderTOML()
        let stockReparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(stockRendered))
        #expect(stockReparsed.files.writePathRules == FilesWritePathRule.defaultRules)
    }

    @Test
    func `Empty write path rule list renders no entries and reseeds defaults on reload`() throws {
        // TOML has no spelling for an empty array-of-tables, so an emptied list
        // renders no entry and the next load reseeds the documented defaults.
        var config = RuneWeaverConfig.default
        config.files.writePathRules = []
        let rendered = config.renderTOML()
        #expect(rendered.contains("[[files.write_paths]]") == false)

        let reparsed = try RuneWeaverConfig(decoding: TOMLParser.parse(rendered))
        #expect(reparsed.files.writePathRules == FilesWritePathRule.defaultRules)
    }

    @Test
    func `Explicit write path rules decode from TOML replacing the defaults`() throws {
        let text = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [files]
        write_mode = "live"

        [[files.write_paths]]
        path = "~/Notes"
        posture = " LIVE "

        [[files.write_paths]]
        path = "~/Archive"
        posture = "ask"
        """
        let config = try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        #expect(config.files.writePathRules == [
            FilesWritePathRule(path: "~/Notes", posture: .live),
            FilesWritePathRule(path: "~/Archive", posture: .ask)
        ])
        #expect(config.files.writeMode == .live)
        try config.validate()
    }

    // MARK: - Bounds and malformed entries

    @Test
    func `Write path rule list rejects beyond its entry bound`() throws {
        func toml(withRuleCount count: Int, pathLength: Int = 8) -> String {
            var lines = [
                "[llm]",
                "default_provider = \"mlx\"",
                "",
                "[llm.providers.mlx]",
                "enabled = true",
                "model = \"gemma-4-9b\"",
                "server_url = \"http://localhost:8080\"",
                "",
                "[files]",
                "write_mode = \"staged\"",
                ""
            ]
            for index in 0 ..< count {
                lines.append("[[files.write_paths]]")
                lines.append("path = \(RuneWeaverConfig.tomlQuoted(String(repeating: "d", count: pathLength - 1) + "\(index % 10)"))")
                lines.append("posture = \"stage\"")
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }

        // Fifty entries sit exactly on the bound and load.
        let atBound = try RuneWeaverConfig(decoding: TOMLParser.parse(toml(withRuleCount: FilesWritePathRule.maxRuleCount)))
        #expect(atBound.files.writePathRules.count == FilesWritePathRule.maxRuleCount)

        // Fifty-one entries reject, naming the list rather than an entry.
        do {
            _ = try RuneWeaverConfig(decoding: TOMLParser.parse(toml(withRuleCount: FilesWritePathRule.maxRuleCount + 1)))
            Issue.record("Expected the write-path rule list bound to reject 51 entries")
        } catch let error as ConfigError {
            guard case let .validationError(field, message) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "files.write_paths")
            #expect(message == "must contain at most \(FilesWritePathRule.maxRuleCount) entries (got \(FilesWritePathRule.maxRuleCount + 1))")
        } catch {
            Issue.record("Expected ConfigError, got \(error)")
        }
    }

    @Test
    func `Write path rule path rejects beyond its length bound`() throws {
        func toml(withPath path: String) -> String {
            """
            [llm]
            default_provider = "mlx"

            [llm.providers.mlx]
            enabled = true
            model = "gemma-4-9b"
            server_url = "http://localhost:8080"

            [files]
            write_mode = "staged"

            [[files.write_paths]]
            path = \(RuneWeaverConfig.tomlQuoted(path))
            posture = "stage"
            """
        }

        // A path of exactly the bound loads.
        let atBound = try RuneWeaverConfig(decoding: TOMLParser.parse(toml(withPath: String(repeating: "d", count: FilesWritePathRule.maxPathLength))))
        #expect(atBound.files.writePathRules.count == 1)

        // One character past the bound rejects, naming the entry's path.
        let overBoundPath = String(repeating: "d", count: FilesWritePathRule.maxPathLength) + "x"
        do {
            _ = try RuneWeaverConfig(decoding: TOMLParser.parse(toml(withPath: overBoundPath)))
            Issue.record("Expected the write-path rule length bound to reject an over-long path")
        } catch let error as ConfigError {
            guard case let .validationError(field, message) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "files.write_paths.path")
            #expect(message == "must be at most \(FilesWritePathRule.maxPathLength) characters (got \(FilesWritePathRule.maxPathLength + 1))")
        } catch {
            Issue.record("Expected ConfigError, got \(error)")
        }
    }

    @Test
    func `Malformed write path rule entries fail the files load naming the entry`() throws {
        func decodeEntry(_ entryLines: [String]) throws -> RuneWeaverConfig {
            let text = ([
                "[llm]",
                "default_provider = \"mlx\"",
                "",
                "[llm.providers.mlx]",
                "enabled = true",
                "model = \"gemma-4-9b\"",
                "server_url = \"http://localhost:8080\"",
                "",
                "[files]",
                "write_mode = \"staged\"",
                "",
                "[[files.write_paths]]"
            ] + entryLines).joined(separator: "\n")
            return try RuneWeaverConfig(decoding: TOMLParser.parse(text))
        }

        func expectValidationError(_ entryLines: [String], field: String, message: String, _ context: String) throws {
            do {
                _ = try decodeEntry(entryLines)
                Issue.record("Expected \(context)")
            } catch let error as ConfigError {
                guard case let .validationError(thrownField, thrownMessage) = error else {
                    Issue.record("Expected validationError, got \(error)")
                    return
                }
                #expect(thrownField == field)
                #expect(thrownMessage == message)
            } catch {
                Issue.record("Expected ConfigError, got \(error)")
            }
        }

        try expectValidationError(
            ["posture = \"stage\""],
            field: "files.write_paths.path",
            message: "is required",
            "a missing path to reject the entry"
        )
        try expectValidationError(
            ["path = \"   \"", "posture = \"stage\""],
            field: "files.write_paths.path",
            message: "must not be empty",
            "a blank path to reject the entry"
        )
        try expectValidationError(
            ["path = 5", "posture = \"stage\""],
            field: "files.write_paths.path",
            message: "must be a string",
            "a non-string path to reject the entry"
        )
        try expectValidationError(
            ["path = \"~/Notes\""],
            field: "files.write_paths.posture",
            message: "is required",
            "a missing posture to reject the entry"
        )
        try expectValidationError(
            ["path = \"~/Notes\"", "posture = true"],
            field: "files.write_paths.posture",
            message: "must be a string",
            "a non-string posture to reject the entry"
        )
        try expectValidationError(
            ["path = \"~/Notes\"", "posture = \"sideways\""],
            field: "files.write_paths.posture",
            message: "must be one of live, stage, ask, deny (got 'sideways')",
            "an unknown posture to reject the entry"
        )
    }

    @Test
    func `Singular or scalar write_paths spelling rejects as malformed`() throws {
        let header = """
        [llm]
        default_provider = "mlx"

        [llm.providers.mlx]
        enabled = true
        model = "gemma-4-9b"
        server_url = "http://localhost:8080"

        [files]
        write_mode = "staged"

        """
        // A singular `[files.write_paths]` table is a near-miss spelling of the
        // array-of-tables shape, so it rejects instead of defaulting the list.
        let singular = header + """
        [files.write_paths]
        path = "~/Notes"
        posture = "stage"
        """
        do {
            _ = try RuneWeaverConfig(decoding: TOMLParser.parse(singular))
            Issue.record("Expected the singular table spelling to reject")
        } catch let error as ConfigError {
            guard case let .validationError(field, message) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "files.write_paths")
            #expect(message.contains("must be an array of tables"))
        } catch {
            Issue.record("Expected ConfigError, got \(error)")
        }

        // An inline scalar under the same key rejects the same way.
        let scalar = header + "write_paths = \"~/Notes\""
        do {
            _ = try RuneWeaverConfig(decoding: TOMLParser.parse(scalar))
            Issue.record("Expected the scalar spelling to reject")
        } catch let error as ConfigError {
            guard case let .validationError(field, message) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "files.write_paths")
            #expect(message.contains("must be an array of tables"))
        } catch {
            Issue.record("Expected ConfigError, got \(error)")
        }
    }

    @Test
    func `validateFilesWritePathPosture accepts the closed set and rejects unknown`() throws {
        for posture in FilesWritePathPosture.allCases {
            let parsed = try? RuneWeaverConfig.validateFilesWritePathPosture(posture.rawValue)
            #expect(parsed == posture)
        }
        #expect(try RuneWeaverConfig.validateFilesWritePathPosture(" LIVE ") == .live)
        #expect(try RuneWeaverConfig.validateFilesWritePathPosture(" ask ") == .ask)

        do {
            _ = try RuneWeaverConfig.validateFilesWritePathPosture("livewire")
            Issue.record("Expected validateFilesWritePathPosture to reject an unknown value")
        } catch let error as ConfigError {
            guard case let .validationError(field, message) = error else {
                Issue.record("Expected validationError, got \(error)")
                return
            }
            #expect(field == "files.write_paths.posture")
            #expect(message == "must be one of live, stage, ask, deny (got 'livewire')")
        } catch {
            Issue.record("Expected ConfigError, got \(error)")
        }
    }

    // MARK: - Precedence matrix

    @Test
    func `Deny patterns beat a matching write path rule`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        var config = FilesConfig(allowRoots: ["~"])
        config.denyPatterns = ["\(home.path)/Documents/Secrets/*"]
        config.writePathRules = [FilesWritePathRule(path: "\(home.path)/Documents/Secrets", posture: .live)]

        let denied = WritePathPolicy.classify(
            path: "\(home.path)/Documents/Secrets/keys.txt",
            filesConfig: config,
            homeDirectoryURL: home
        )
        #expect(denied.posture == .deny)
        #expect(denied.reason?.contains("\(home.path)/Documents/Secrets/*") == true)
        #expect(denied.reason?.contains("keys.txt") == false)
        #expect(denied.resolvedPath == home.resolvingSymlinksInPath().appendingPathComponent("Documents/Secrets/keys.txt").path)
    }

    @Test
    func `Engine deny patterns still deny when the operator list is replaced`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        // An operator list replaces the editable defaults entirely, which is
        // exactly the drift the engine-owned union exists to survive.
        let config = FilesConfig(denyPatterns: ["*.md"], allowRoots: ["~"], writePathRules: [])
        for protected in [
            ".runeweaver/memory/vectors/vec.bin",
            ".runeweaver/browser_profiles/default/Cookies",
            ".runeweaver/policy.toml",
            ".runeweaver/auth_token",
            ".runeweaver/searxng/settings.yml"
        ] {
            let decision = WritePathPolicy.classify(
                path: "\(home.path)/\(protected)",
                filesConfig: config,
                homeDirectoryURL: home
            )
            #expect(decision.posture == .deny, "Expected deny for \(protected)")
            #expect((decision.reason ?? "").isEmpty == false, "Expected a reason for \(protected)")
            #expect(decision.reason?.contains("deny pattern") == true)
        }

        // The read guard denies the same list through the same union, so a
        // replaced editable list cannot expose protected state on either path.
        let readDecision = FilesAccessGuard.evaluate(
            path: "\(home.path)/.runeweaver/memory/vectors/vec.bin",
            homeDirectoryURL: home,
            filesConfig: config
        )
        #expect(readDecision.allowed == false)
        #expect((readDecision.reason ?? "").isEmpty == false)
    }

    @Test
    func `Longest matching write path rule wins`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        var config = FilesConfig(allowRoots: ["~"], writeMode: .live)
        config.writePathRules = [
            FilesWritePathRule(path: "\(home.path)/Documents", posture: .ask),
            FilesWritePathRule(path: "\(home.path)/Documents/Secrets", posture: .deny)
        ]

        let deep = WritePathPolicy.classify(path: "\(home.path)/Documents/Secrets/keys.txt", filesConfig: config, homeDirectoryURL: home)
        #expect(deep.posture == .deny)
        #expect(deep.reason?.contains("\(home.path)/Documents/Secrets") == true)

        let shallow = WritePathPolicy.classify(path: "\(home.path)/Documents/notes/notes.txt", filesConfig: config, homeDirectoryURL: home)
        #expect(shallow.posture == .ask)
        #expect(shallow.reason?.contains("\(home.path)/Documents/Secrets") == false)
    }

    @Test
    func `A matching write path rule beats the global write mode`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        var stagedOverride = FilesConfig(allowRoots: ["~"], writeMode: .live)
        stagedOverride.writePathRules = [FilesWritePathRule(path: "\(home.path)/Documents", posture: .stage)]
        let staged = WritePathPolicy.classify(path: "\(home.path)/Documents/notes.txt", filesConfig: stagedOverride, homeDirectoryURL: home)
        #expect(staged.posture == .stage)

        var liveOverride = FilesConfig(allowRoots: ["~"], writeMode: .staged)
        liveOverride.writePathRules = [FilesWritePathRule(path: "\(home.path)/Documents", posture: .live)]
        let live = WritePathPolicy.classify(path: "\(home.path)/Documents/notes.txt", filesConfig: liveOverride, homeDirectoryURL: home)
        #expect(live.posture == .live)
    }

    @Test
    func `Out-of-root writes ask regardless of the forced mode`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        // Even a forced live posture cannot execute outside the sanctioned
        // roots: the boundary gates the mode, so the write parks an approval.
        let config = FilesConfig(allowRoots: ["\(home.path)/Documents"], writeMode: .live, writePathRules: [])
        let decision = WritePathPolicy.classify(path: "\(home.path)/Desktop/notes.txt", filesConfig: config, homeDirectoryURL: home)
        #expect(decision.posture == .ask)
        #expect(decision.reason?.contains("\(home.path)/Documents") == true)

        // No configured roots at all still asks rather than defaulting.
        let noRoots = FilesConfig(allowRoots: [], writeMode: .staged, writePathRules: [])
        let blankRoots = WritePathPolicy.classify(path: "\(home.path)/Documents/notes.txt", filesConfig: noRoots, homeDirectoryURL: home)
        #expect(blankRoots.posture == .ask)
        #expect(blankRoots.reason?.contains("No allowed roots") == true)
    }

    @Test
    func `Global write mode governs in-root writes`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        let root = "\(home.path)/Documents"
        let staged = FilesConfig(allowRoots: [root], writeMode: .staged, writePathRules: [])
        #expect(WritePathPolicy.classify(path: "\(root)/notes.txt", filesConfig: staged, homeDirectoryURL: home).posture == .stage)

        let live = FilesConfig(allowRoots: [root], writeMode: .live, writePathRules: [])
        #expect(WritePathPolicy.classify(path: "\(root)/notes.txt", filesConfig: live, homeDirectoryURL: home).posture == .live)

        // The model posture honors an explicit live request and stages an
        // omitted or non-live one.
        let model = FilesConfig(allowRoots: [root], writeMode: .model, writePathRules: [])
        let liveRequest = WritePathPolicy.classify(path: "\(root)/notes.txt", filesConfig: model, requestedMode: " LIVE ", homeDirectoryURL: home)
        #expect(liveRequest.posture == .live)
        #expect(liveRequest.reason?.contains("Requested 'live' mode") == true)

        let stagedRequest = WritePathPolicy.classify(path: "\(root)/notes.txt", filesConfig: model, requestedMode: "staged", homeDirectoryURL: home)
        #expect(stagedRequest.posture == .stage)

        let omittedRequest = WritePathPolicy.classify(path: "\(root)/notes.txt", filesConfig: model, homeDirectoryURL: home)
        #expect(omittedRequest.posture == .stage)
    }

    @Test
    func `Blank write path asks with a blank-target reason`() {
        let decision = WritePathPolicy.classify(path: "   ", filesConfig: FilesConfig())
        #expect(decision.posture == .ask)
        #expect(decision.reason?.contains("Empty path") == true)
        #expect(decision.resolvedPath.isEmpty)
    }

    // MARK: - Canonical view

    @Test
    func `Canonical path resolves symlinks and dot-dot segments`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: documents)

        let throughLink = WritePathPolicy.canonicalPath("\(link.path)/notes.txt")
        let direct = WritePathPolicy.canonicalPath("\(documents.path)/notes.txt")
        #expect(throughLink == direct)
        #expect(throughLink == home.resolvingSymlinksInPath().appendingPathComponent("Documents/notes.txt").path)

        let dotDot = WritePathPolicy.canonicalPath("\(documents.path)/../Documents/notes.txt")
        #expect(dotDot == direct)

        #expect(WritePathPolicy.canonicalPath("   ").isEmpty)
    }

    @Test
    func `Classification runs on the canonical view`() throws {
        let (base, home) = try PolicyTestSupport.makeBaseAndHome()
        defer { PolicyTestSupport.cleanup(base) }

        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: documents)

        var config = FilesConfig(allowRoots: ["~"], writeMode: .live)
        config.writePathRules = [FilesWritePathRule(path: "\(documents.path)", posture: .stage)]

        // The rule covers the real directory, so the symlinked spelling of the
        // same target classifies against the resolved path and cannot escape.
        let throughLink = WritePathPolicy.classify(path: "\(link.path)/notes.txt", filesConfig: config, homeDirectoryURL: home)
        #expect(throughLink.posture == .stage)
        #expect(throughLink.resolvedPath == documents.resolvingSymlinksInPath().appendingPathComponent("notes.txt").path)
    }

    @Test
    func `resolveAllowRoots expands tilde and drops blank entries`() {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let roots = WritePathPolicy.resolveAllowRoots(["~", "   ", "/usr/local/"])
        #expect(roots == [home.path, "/usr/local"])
        #expect(WritePathPolicy.resolveAllowRoots([]).isEmpty)
    }
}
