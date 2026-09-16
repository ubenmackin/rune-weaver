// Rune Weaver Tools Tests — File tools (files.read, files.grep, files.glob), shared guard, and Seatbelt staging.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

/// Isolated filesystem helpers for the files suites.
private enum FilesTestSupport {
    /// Creates a fresh temp base with an isolated fake home.
    /// - Returns: Base directory plus the fake home boundary.
    /// - Throws: When directories cannot be created.
    static func makeBaseAndHome() throws -> (base: URL, home: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (base, home)
    }

    /// Removes a temp base best-effort.
    /// - Parameter base: Directory created by `makeBaseAndHome()`.
    static func cleanup(_ base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    /// Writes UTF-8 text, creating parents.
    static func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Decoded shape of the denied failure document.
    struct Denied: Decodable {
        /// Human-readable denial.
        let error: String
        /// Canonical denied path.
        let path: String
        /// Escalation hint.
        let approvalRequired: Bool
        /// Policy reason.
        let reason: String?
    }

    /// Decoded shape of the read success document.
    struct Read: Decodable {
        /// Canonical path read.
        let path: String
        /// On-disk size.
        let sizeBytes: Int
        /// Whether the view was cut short.
        let truncated: Bool
        /// Selected text.
        let content: String
    }

    /// Decoded shape of one grep hit.
    struct GrepHit: Decodable {
        /// Canonical file holding the match.
        let path: String
        /// 1-indexed line number.
        let line: Int
        /// Bounded line preview.
        let preview: String
    }

    /// Decoded shape of the grep success document.
    struct Grep: Decodable {
        /// Returned matches.
        let matches: [GrepHit]
        /// Whether further matches existed past the cap.
        let truncated: Bool
    }

    /// Decoded shape of the glob success document.
    struct Glob: Decodable {
        /// Sorted canonical paths.
        let paths: [String]
        /// Whether further paths existed past the cap.
        let truncated: Bool
    }
}

@Suite("Files Tools")
struct FilesToolsTests {
    @Test
    func `Read args default and clamp offset and limit`() throws {
        let omitted = try JSONDecoder().decode(FilesReadArgs.self, from: Data(#"{"path":"notes.txt"}"#.utf8))
        #expect(omitted.offset == FilesReadArgs.defaultOffset)
        #expect(omitted.limit == FilesReadArgs.defaultLimit)
        #expect(FilesReadArgs.defaultLimit == 2000)
        #expect(FilesReadArgs.maxLimit == 5000)
        let clamped = try JSONDecoder().decode(FilesReadArgs.self, from: Data(#"{"path":"notes.txt","offset":0,"limit":99999}"#.utf8))
        #expect(clamped.offset == 1)
        #expect(clamped.limit == FilesReadArgs.maxLimit)
        let low = try JSONDecoder().decode(FilesReadArgs.self, from: Data(#"{"path":"notes.txt","offset":-4,"limit":0}"#.utf8))
        #expect(low.offset == 1)
        #expect(low.limit == 1)
    }

    @Test
    func `Tool is readOnly and registered by name`() async throws {
        let (_, home) = try FilesTestSupport.makeBaseAndHome()
        // Base is only needed for the home boundary; remove via home's parent.
        defer { FilesTestSupport.cleanup(home.deletingLastPathComponent()) }
        let tools = FilesTools.makeTools(homeDirectoryURL: home)
        #expect(tools.count == 3)
        #expect(tools.map(\.name) == ["files.read", "files.grep", "files.glob"])
        for tool in tools {
            #expect(tool.permissionLevel == .readOnly)
        }
        #expect(FilesTools.toolNames == ["files.read", "files.grep", "files.glob"])
        let bus = ToolBus()
        await FilesTools.register(on: bus, homeDirectoryURL: home)
        let names = await bus.toolNames()
        #expect(names.contains("files.read"))
        #expect(names.contains("files.grep"))
        #expect(names.contains("files.glob"))
    }

    @Test
    func `Guard denies sensitive patterns with approval hint`() throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // Path-pattern denials hold even when the file was never created,
        // proving the guard is content-blind and needs no disk read.
        let sensitive = [
            ".env",
            ".env.local",
            ".env.production",
            ".netrc",
            "secrets.json",
            "config.toml",
            "id_rsa.pem",
            "server.key",
            "login.keychain-db",
            ".ssh/id_rsa",
            "sub/.ssh/config",
            ".aws/credentials",
            "sub/.aws/config",
            ".runeweaver/memory/vectors/chunk.json"
        ]
        for relative in sensitive {
            let candidate = home.appendingPathComponent(relative).path
            let decision = FilesAccessGuard.evaluate(path: candidate, homeDirectoryURL: home)
            #expect(decision.allowed == false, "Expected deny for \(relative)")
            #expect(decision.requiresApproval == true, "Expected approval hint for \(relative)")
            #expect((decision.reason ?? "").isEmpty == false, "Expected reason for \(relative)")
        }
        let benign = home.appendingPathComponent("notes.txt").path
        let allowed = FilesAccessGuard.evaluate(path: benign, homeDirectoryURL: home)
        #expect(allowed.allowed == true)
        #expect(allowed.requiresApproval == false)
    }

    @Test
    func `Guard flags outside-home paths for approval`() throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // Sibling of the fake home: benign name, but outside the boundary.
        let outside = base.appendingPathComponent("outside.txt")
        try FilesTestSupport.write("hello", at: outside)
        let decision = FilesAccessGuard.evaluate(path: outside.path, homeDirectoryURL: home)
        #expect(decision.allowed == false)
        #expect(decision.requiresApproval == true)
        #expect((decision.reason ?? "").contains("home"))
    }

    @Test
    func `Guard resolves dot segments and symlink escapes`() throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // Dot-segment normalisation: `subdir/../.ssh/id_rsa` is the same
        // sensitive path as `.ssh/id_rsa` once standardised.
        let dotted = home
            .appendingPathComponent("subdir", isDirectory: true)
            .appendingPathComponent("../.ssh/id_rsa").path
        let dottedDecision = FilesAccessGuard.evaluate(path: dotted, homeDirectoryURL: home)
        #expect(dottedDecision.allowed == false)
        #expect(dottedDecision.requiresApproval == true)

        // Symlink to a sensitive filename: the link name itself looks
        // benign, so only symlink resolution catches the escape.
        let secretDir = base.appendingPathComponent("secret-store", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secretFile = secretDir.appendingPathComponent(".env")
        try FilesTestSupport.write("SUPERSECRET=abc123", at: secretFile)
        let sensitiveLink = home.appendingPathComponent("link-to-env")
        try FileManager.default.createSymbolicLink(atPath: sensitiveLink.path, withDestinationPath: secretFile.path)
        let sensitiveDecision = FilesAccessGuard.evaluate(path: sensitiveLink.path, homeDirectoryURL: home)
        #expect(sensitiveDecision.allowed == false)
        #expect(sensitiveDecision.requiresApproval == true)

        // Symlink to a benign file outside home: no sensitive pattern, but
        // the resolved target sits outside the boundary and must escalate.
        let outsideDir = base.appendingPathComponent("outside-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outsideFile = outsideDir.appendingPathComponent("notes.txt")
        try FilesTestSupport.write("outside content", at: outsideFile)
        let outsideLink = home.appendingPathComponent("link-outside")
        try FileManager.default.createSymbolicLink(atPath: outsideLink.path, withDestinationPath: outsideFile.path)
        let outsideDecision = FilesAccessGuard.evaluate(path: outsideLink.path, homeDirectoryURL: home)
        #expect(outsideDecision.allowed == false)
        #expect(outsideDecision.requiresApproval == true)
    }

    @Test
    func `Read denies sensitive path without leaking bytes`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let secret = home.appendingPathComponent(".env")
        try FilesTestSupport.write("SUPERSECRET=abc123", at: secret)
        let tool = FilesReadTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"\#(secret.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(!output.content.contains("SUPERSECRET"))
        #expect(output.content.contains("approvalRequired"))
        let denied = try JSONDecoder().decode(FilesTestSupport.Denied.self, from: Data(output.content.utf8))
        #expect(denied.approvalRequired == true)
        #expect((denied.reason ?? "").isEmpty == false)
    }

    @Test
    func `Read flags outside-home files without leaking bytes`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let outside = base.appendingPathComponent("outside.txt")
        try FilesTestSupport.write("outside secret bytes", at: outside)
        let tool = FilesReadTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"\#(outside.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(!output.content.contains("outside secret bytes"))
        #expect(output.content.contains("approvalRequired"))
    }

    @Test
    func `Read returns line window with truncation flag`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let file = home.appendingPathComponent("notes.txt")
        let lines = (1 ... 10).map { "line\($0)" }
        try FilesTestSupport.write(lines.joined(separator: "\n") + "\n", at: file)
        let tool = FilesReadTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.read",
                argumentsJSON: #"{"path":"\#(file.path)","offset":2,"limit":3}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Read.self, from: Data(output.content.utf8))
        #expect(decoded.content == "line2\nline3\nline4")
        #expect(decoded.truncated == true)
        #expect(decoded.sizeBytes > 0)
        #expect(decoded.path == FilesAccessGuard.resolvedURL(for: file.path).path)

        // Offset past end-of-file yields an empty (not failed) view.
        let pastEnd = try await tool.execute(
            input: ToolInput(
                toolName: "files.read",
                argumentsJSON: #"{"path":"\#(file.path)","offset":99,"limit":10}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(pastEnd.isError == false)
        let empty = try JSONDecoder().decode(FilesTestSupport.Read.self, from: Data(pastEnd.content.utf8))
        #expect(empty.content == "")
        #expect(empty.truncated == false)
    }

    @Test
    func `Read enforces byte cap on oversized files`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // One huge line pushes the file past the 1 MB ceiling while keeping
        // the line window (max 5000) wide open, isolating the byte cap.
        let file = home.appendingPathComponent("big.txt")
        let huge = String(repeating: "a", count: FilesReadTool.maxFileBytes + 10000)
        try FilesTestSupport.write(huge, at: file)
        let tool = FilesReadTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(
                toolName: "files.read",
                argumentsJSON: #"{"path":"\#(file.path)","offset":1,"limit":5000}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Read.self, from: Data(output.content.utf8))
        #expect(decoded.truncated == true)
        #expect(decoded.sizeBytes > FilesReadTool.maxFileBytes)
        #expect(Data(decoded.content.utf8).count <= FilesReadTool.maxFileBytes)
    }

    @Test
    func `Read refuses binary files with a note`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let file = home.appendingPathComponent("image.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // NUL byte marks binary; the sniff must refuse before decoding.
        try Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64]).write(to: file, options: .atomic)
        let tool = FilesReadTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"\#(file.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(output.content.lowercased().contains("binary"))
    }

    @Test
    func `Read validates arguments and missing paths`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let tool = FilesReadTool(homeDirectoryURL: home)
        let malformed = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: "not-json"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(malformed.isError == true)
        let empty = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"   "}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(empty.isError == true)
        let missing = try await tool.execute(
            input: ToolInput(
                toolName: "files.read",
                argumentsJSON: #"{"path":"\#(home.appendingPathComponent("missing.txt").path)"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(missing.isError == true)
        #expect(missing.content.lowercased().contains("not found"))
        let directory = try await tool.execute(
            input: ToolInput(toolName: "files.read", argumentsJSON: #"{"path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(directory.isError == true)
        let badEncoding = try await tool.execute(
            input: ToolInput(
                toolName: "files.read",
                argumentsJSON: #"{"path":"\#(home.appendingPathComponent("notes.txt").path)","encoding":"utf-16"}"#
            ),
            context: ToolContext(conversationID: UUID())
        )
        #expect(badEncoding.isError == true)
        #expect(badEncoding.content.lowercased().contains("encoding"))
    }

    @Test
    func `Grep args default and clamp maxResults`() throws {
        let omitted = try JSONDecoder().decode(FilesGrepArgs.self, from: Data(#"{"pattern":"hi","path":"x"}"#.utf8))
        #expect(omitted.maxResults == FilesGrepArgs.defaultMaxResults)
        #expect(FilesGrepArgs.defaultMaxResults == 50)
        #expect(FilesGrepArgs.maxMaxResults == 200)
        #expect(FilesGrepArgs.maxPatternChars == 500)
        let clamped = try JSONDecoder().decode(FilesGrepArgs.self, from: Data(#"{"pattern":"hi","path":"x","maxResults":99999}"#.utf8))
        #expect(clamped.maxResults == FilesGrepArgs.maxMaxResults)
        let low = try JSONDecoder().decode(FilesGrepArgs.self, from: Data(#"{"pattern":"hi","path":"x","maxResults":0}"#.utf8))
        #expect(low.maxResults == 1)
    }

    @Test
    func `Grep rejects invalid and RE2-unsafe patterns`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let tool = FilesGrepTool(homeDirectoryURL: home)
        // Unclosed class never reaches the walker; the failure names the
        // regex instead of crashing the turn.
        let invalid = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"[unclosed","path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(invalid.isError == true)
        #expect(invalid.content.lowercased().contains("regex"))
        // Lookahead is valid ICU but outside the RE2 subset, so it fails
        // as unsupported rather than running with different semantics.
        let lookahead = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"(?=secret)secret","path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(lookahead.isError == true)
        #expect(lookahead.content.lowercased().contains("lookahead"))
        // Backreferences would let a crafted pattern exfiltrate group
        // captures; RE2 omits them, so they fail closed.
        let backref = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"(a)\\1","path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(backref.isError == true)
        // Overlong patterns fail before compiling, bounding engine work.
        let long = String(repeating: "a", count: FilesGrepArgs.maxPatternChars + 1)
        let escaped = long.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let overlong = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: "{\"pattern\":\"\(escaped)\",\"path\":\"\(home.path)\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(overlong.isError == true)
        #expect(overlong.content.contains("500"))
    }

    @Test
    func `Grep denies sensitive root without leaking bytes`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let secret = home.appendingPathComponent(".env")
        try FilesTestSupport.write("SUPERSECRET=abc123", at: secret)
        let tool = FilesGrepTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"SUPERSECRET","path":"\#(secret.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == true)
        #expect(!output.content.contains("SUPERSECRET"))
        #expect(output.content.contains("approvalRequired"))
    }

    @Test
    func `Grep prunes denied files while returning allowed matches`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // Same marker in both files proves pruning: the allowed hit
        // returns while the denied twin contributes no bytes.
        let allowed = home.appendingPathComponent("notes.txt")
        try FilesTestSupport.write("hello world\nsecond line\n", at: allowed)
        let denied = home.appendingPathComponent(".env")
        try FilesTestSupport.write("hello SUPERSECRET=abc123\n", at: denied)
        let tool = FilesGrepTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"hello","path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Grep.self, from: Data(output.content.utf8))
        #expect(decoded.matches.count == 1)
        #expect(decoded.matches[0].path == FilesAccessGuard.resolvedURL(for: allowed.path).path)
        #expect(decoded.matches[0].line == 1)
        #expect(!output.content.contains("SUPERSECRET"))
        // Dry runs stay read-only-trivial: the same search succeeds
        // without any write side effect to gate.
        let dry = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"hello","path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(dry.isError == false)
    }

    @Test
    func `Grep skips binaries and oversized files`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // Binary twin holds the marker past a NUL so the skip is what
        // hides it, not the pattern.
        let binary = home.appendingPathComponent("image.bin")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        var blob = Data("marker hello".utf8)
        blob.append(0x00)
        blob.append(contentsOf: Data("world".utf8))
        try blob.write(to: binary, options: .atomic)
        let allowed = home.appendingPathComponent("notes.txt")
        try FilesTestSupport.write("hello there\n", at: allowed)
        let tool = FilesGrepTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"hello","path":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Grep.self, from: Data(output.content.utf8))
        #expect(decoded.matches.count == 1)
        #expect(decoded.matches[0].path.hasSuffix("notes.txt"))
        // A file past the 2 MB ceiling is skipped even though it holds
        // the marker; the search still succeeds on the small twin.
        let big = home.appendingPathComponent("big.txt")
        let prefix = String(repeating: "x", count: FilesGrepTool.maxFileBytes + 100)
        try FilesTestSupport.write(prefix + "hello", at: big)
        let capped = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"hello","path":"\#(big.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(capped.isError == false)
        let empty = try JSONDecoder().decode(FilesTestSupport.Grep.self, from: Data(capped.content.utf8))
        #expect(empty.matches.isEmpty)
        #expect(empty.truncated == false)
    }

    @Test
    func `Grep caps results with truncated flag and bounded previews`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let file = home.appendingPathComponent("log.txt")
        let lines = (1 ... 10).map { "match line \($0)" }
        try FilesTestSupport.write(lines.joined(separator: "\n") + "\n", at: file)
        let tool = FilesGrepTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"match","path":"\#(home.path)","maxResults":3}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Grep.self, from: Data(output.content.utf8))
        #expect(decoded.matches.count == 3)
        #expect(decoded.truncated == true)
        // Long lines truncate to the 200-char preview ceiling so one
        // pathological line cannot flood context.
        let long = home.appendingPathComponent("long.txt")
        try FilesTestSupport.write(String(repeating: "y", count: 500) + "\n", at: long)
        let previewed = try await tool.execute(
            input: ToolInput(toolName: "files.grep", argumentsJSON: #"{"pattern":"y+","path":"\#(long.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(previewed.isError == false)
        let one = try JSONDecoder().decode(FilesTestSupport.Grep.self, from: Data(previewed.content.utf8))
        #expect(one.matches.count == 1)
        #expect(one.matches[0].preview.count == FilesGrepTool.maxPreviewChars)
        #expect(one.truncated == false)
    }

    @Test
    func `Glob args default and clamp maxResults`() throws {
        let omitted = try JSONDecoder().decode(FilesGlobArgs.self, from: Data(#"{"pattern":"*.txt"}"#.utf8))
        #expect(omitted.maxResults == FilesGlobArgs.defaultMaxResults)
        #expect(FilesGlobArgs.defaultMaxResults == 100)
        #expect(FilesGlobArgs.maxMaxResults == 500)
        let clamped = try JSONDecoder().decode(FilesGlobArgs.self, from: Data(#"{"pattern":"*.txt","maxResults":99999}"#.utf8))
        #expect(clamped.maxResults == FilesGlobArgs.maxMaxResults)
    }

    @Test
    func `Glob rejects dot-dot and absolute escapes`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let tool = FilesGlobTool(homeDirectoryURL: home)
        // Each `..` shape fails as invalid input (not an approval hint)
        // so escape probes cannot double as policy oracles.
        for pattern in ["../*.txt", "a/../../b", "..", "sub/../.."] {
            let output = try await tool.execute(
                input: ToolInput(toolName: "files.glob", argumentsJSON: "{\"pattern\":\"\(pattern)\",\"baseDir\":\"\(home.path)\"}"),
                context: ToolContext(conversationID: UUID())
            )
            #expect(output.isError == true, "Expected rejection for \(pattern)")
            #expect(output.content.contains(".."), "Expected '..' hint for \(pattern)")
        }
        let absolute = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: #"{"pattern":"/etc/*.txt"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(absolute.isError == true)
        #expect(absolute.content.lowercased().contains("relative"))
        let long = String(repeating: "a", count: FilesGlobArgs.maxPatternChars + 1)
        let escaped = long.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let overlong = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: "{\"pattern\":\"\(escaped)\"}"),
            context: ToolContext(conversationID: UUID())
        )
        #expect(overlong.isError == true)
        #expect(overlong.content.contains("500"))
    }

    @Test
    func `Glob prunes denied paths and denies outside bases`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let visible = home.appendingPathComponent("notes.txt")
        try FilesTestSupport.write("hello", at: visible)
        let denied = home.appendingPathComponent(".env")
        try FilesTestSupport.write("SUPERSECRET=abc123", at: denied)
        let tool = FilesGlobTool(homeDirectoryURL: home)
        // Wildcard listing omits the denied filename and leaks no bytes.
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: #"{"pattern":"**/*","baseDir":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Glob.self, from: Data(output.content.utf8))
        #expect(decoded.paths.contains(FilesAccessGuard.resolvedURL(for: visible.path).path))
        #expect(!decoded.paths.contains(where: { $0.hasSuffix(".env") }))
        #expect(!output.content.contains("SUPERSECRET"))
        // A base outside the boundary escalates with an approval hint
        // instead of listing foreign bytes.
        let outside = base.appendingPathComponent("outside.txt")
        try FilesTestSupport.write("outside bytes", at: outside)
        let deniedBase = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: #"{"pattern":"*","baseDir":"\#(outside.path)"}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(deniedBase.isError == true)
        #expect(deniedBase.content.contains("approvalRequired"))
        // Dry runs list identically; there is nothing to stage.
        let dry = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: #"{"pattern":"*.txt","baseDir":"\#(home.path)"}"#),
            context: ToolContext(conversationID: UUID(), dryRun: true)
        )
        #expect(dry.isError == false)
    }

    @Test
    func `Glob caps sorted results with truncated flag`() async throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        for name in ["c.txt", "a.txt", "e.txt", "b.txt", "d.txt"] {
            try FilesTestSupport.write("x", at: home.appendingPathComponent(name))
        }
        let tool = FilesGlobTool(homeDirectoryURL: home)
        let output = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: #"{"pattern":"*.txt","baseDir":"\#(home.path)","maxResults":2}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(output.isError == false)
        let decoded = try JSONDecoder().decode(FilesTestSupport.Glob.self, from: Data(output.content.utf8))
        #expect(decoded.paths.count == 2)
        #expect(decoded.truncated == true)
        #expect(decoded.paths == decoded.paths.sorted())
        // Full listing is sorted and untruncated once the cap lifts.
        let full = try await tool.execute(
            input: ToolInput(toolName: "files.glob", argumentsJSON: #"{"pattern":"*.txt","baseDir":"\#(home.path)","maxResults":10}"#),
            context: ToolContext(conversationID: UUID())
        )
        #expect(full.isError == false)
        let all = try JSONDecoder().decode(FilesTestSupport.Glob.self, from: Data(full.content.utf8))
        #expect(all.paths.count == 5)
        #expect(all.truncated == false)
        #expect(all.paths == all.paths.sorted())
    }
}

@Suite("Seatbelt Temp Staging")
struct SeatbeltTempStagingTests {
    @Test
    func `Stage then atomic move commits on approval`() throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        // Temp lives outside the home boundary under the system temp, proving
        // staging needs no host sandbox folder; the move lands inside home.
        let tempDir = try SeatbeltTempStaging.makeTempDirectory()
        defer { SeatbeltTempStaging.discardTemp(at: tempDir) }
        let staged = try SeatbeltTempStaging.stageBytes(Data("hello".utf8), filename: "notes.txt", in: tempDir)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        let destination = home.appendingPathComponent("notes.txt").path
        let committed = try SeatbeltTempStaging.atomicMoveTempFile(at: staged, to: destination, homeDirectoryURL: home)
        #expect(committed == FilesAccessGuard.resolvedURL(for: destination).path)
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
        #expect(try String(data: Data(contentsOf: URL(fileURLWithPath: committed)), encoding: .utf8) == "hello")
    }

    @Test
    func `Deny discards temp without writing`() throws {
        let (base, home) = try FilesTestSupport.makeBaseAndHome()
        defer { FilesTestSupport.cleanup(base) }
        let tempDir = try SeatbeltTempStaging.makeTempDirectory()
        defer { SeatbeltTempStaging.discardTemp(at: tempDir) }
        let staged = try SeatbeltTempStaging.stageBytes(Data("secret".utf8), filename: "payload.txt", in: tempDir)
        // Sensitive destinations fail closed at approval time via the guard,
        // and the staged temp is removed so bytes never accumulate.
        let denied = home.appendingPathComponent(".env").path
        do {
            try SeatbeltTempStaging.atomicMoveTempFile(at: staged, to: denied, homeDirectoryURL: home)
            Issue.record("Expected guard denial for sensitive destination")
        } catch {
            // Deny path must discard the staged temp.
            #expect(FileManager.default.fileExists(atPath: staged.path) == false)
            #expect(FileManager.default.fileExists(atPath: FilesAccessGuard.resolvedURL(for: denied).path) == false)
        }
    }

    @Test
    func `Temp directory is owner-only`() throws {
        let tempDir = try SeatbeltTempStaging.makeTempDirectory()
        defer { SeatbeltTempStaging.discardTemp(at: tempDir) }
        let attributes = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let rawPermissions = attributes[.posixPermissions]
        let permissions = (rawPermissions as? NSNumber)?.intValue ?? (rawPermissions as? Int) ?? 0
        #expect(permissions & 0o777 == 0o700)
    }
}
