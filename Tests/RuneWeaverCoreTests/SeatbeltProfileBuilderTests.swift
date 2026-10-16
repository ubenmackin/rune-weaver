// Rune Weaver Core Tests — Seatbelt profile generator tests.

import Foundation
@testable import RuneWeaverCore
import Testing

@Suite("Seatbelt Profile Builder")
struct SeatbeltProfileBuilderTests {
    @Test
    func `Builds default profile with network denied and sensitive paths blocked`() {
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/workspace"],
            allowedWritePaths: ["/Users/test/workspace"],
            allowNetwork: false
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("(version 1)"))
        #expect(profile.contains("(deny default)"))
        #expect(!profile.contains("(allow default)"))
        #expect(profile.contains("(deny network*)"))
        #expect(profile.contains("(deny file-write* (subpath \"/\"))"))
        #expect(profile.contains("(allow file-write*"))
        #expect(profile.contains("(allow file-read*"))
        #expect(profile.contains("/Users/test/workspace"))
        // System roots stay readable so dyld and standard runtimes launch.
        #expect(profile.contains("/System"))
        #expect(profile.contains(".ssh"))
        #expect(profile.contains(".aws"))
        #expect(profile.contains("Keychains"))
        // Filename-level secrets must hold even inside the allowed workspace.
        #expect(profile.contains(".env"))
        #expect(profile.contains("secrets\\.json"))
        #expect(profile.contains("config\\.toml"))
        #expect(profile.contains(".pem"))
        #expect(profile.contains("keychain"))
    }

    @Test
    func `Denies browser profile reads inside the sandbox`() {
        // The persistent browser profile lives under the home directory, which the sandbox
        // otherwise reopens as an allowed read root, so the generated profile must deny the whole
        // profile tree both as an explicit subpath and as a filename-level regex.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/workspace"],
            allowedWritePaths: ["/Users/test/workspace"]
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("(deny file-read* file-write* file-map-executable file-test-existence"))
        #expect(profile.contains("/.runeweaver/browser_profiles"))
        #expect(profile.contains(#"/\.runeweaver/browser_profiles/"#))
    }

    @Test
    func `Denies engine token and SearXNG secrets inside the sandbox`() {
        // The owner bearer token and the per-install SearXNG settings live under the home
        // directory, which the sandbox otherwise reopens as an allowed read root, so the generated
        // profile must deny both as explicit subpaths plus filename-level regexes.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/workspace"],
            allowedWritePaths: ["/Users/test/workspace"]
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("/.runeweaver/auth_token"))
        #expect(profile.contains("/.runeweaver/searxng"))
        #expect(profile.contains(#"/[^/]*auth_token$"#))
        #expect(profile.contains(#"/\.runeweaver/searxng/"#))
    }

    @Test
    func `Enables network when requested`() {
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/app"],
            allowedWritePaths: ["/tmp/app"],
            allowNetwork: true
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(deny network*)"))
        #expect(profile.contains("(deny default)"))
        #expect(!profile.contains("(allow default)"))
        #expect(profile.contains("(allow file-read*"))
        #expect(profile.contains("(allow file-write*"))
    }

    @Test
    func `Restricts writes to workspace and temporary paths while blocking credentials`() {
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/workspace"],
            allowedWritePaths: ["/Users/test/workspace"],
            allowNetwork: false
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("(allow file-write*"))
        #expect(profile.contains("(allow file-read*"))
        #expect(profile.contains("/Users/test/workspace"))
        #expect(profile.contains("/private/tmp"))
        #expect(profile.contains("/tmp"))
        #expect(profile.contains(".ssh"))
        #expect(profile.contains(".aws"))
    }

    @Test
    func `Emits read-only workspace roots in file-read allows`() {
        // Read-only caller roots must take effect in the profile: a path
        // passed only via allowedReadPaths stays readable without gaining
        // write rights, so plugin working directories stay confined.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/read-only"],
            allowedWritePaths: ["/Users/test/workspace"],
            allowNetwork: false
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("(deny default)"))
        #expect(profile.contains("(allow file-read*"))
        #expect(profile.contains("/Users/test/read-only"))
        #expect(profile.contains("/Users/test/workspace"))
        // System read roots keep dyld launchable under deny-default.
        #expect(profile.contains("/System"))
        #expect(profile.contains("/usr"))
        // The read-only root must sit inside the file-read allow block,
        // proving allowedReadPaths is wired rather than silently ignored.
        let readSection = profile.components(separatedBy: "(allow file-read*").dropFirst().joined(separator: "(allow file-read*")
        #expect(readSection.contains("/Users/test/read-only"))
    }

    @Test
    func `Rejects filesystem-root allowlist bypass`() {
        // Allowing `/` would silently reopen root-wide writes,
        // so root entries are dropped while the deny file-write* guard remains.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/"],
            allowedWritePaths: ["/"],
            allowNetwork: false
        )
        let profile = builder.buildProfile()
        let rootGuardCount = profile.components(separatedBy: "(subpath \"/\")").count - 1
        #expect(rootGuardCount == 1)
    }

    @Test
    func `Neutralizes SBPL injection in marketplace-controlled paths`() {
        // A crafted plugin directory name must not break out of its quoted
        // string and smuggle an allow-all rule into the profile.
        let malicious = "x\") (allow file-write* (subpath \"/\")) (deny file-read* (subpath \"y"
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/tmp/\(malicious)"],
            allowedWritePaths: ["/tmp/\(malicious)"],
            allowNetwork: false
        )
        let profile = builder.buildProfile()

        // The raw breakout sequence must never appear unescaped.
        #expect(!profile.contains(#"") (allow"#))
        // Metacharacters are escaped so the payload stays inert string content.
        #expect(profile.contains("\\\""))
        #expect(profile.contains("\\("))
        #expect(profile.contains("\\)"))
        // No allow-all is smuggled: only the deny-all write guard uses root.
        let rootGuardCount = profile.components(separatedBy: "(subpath \"/\")").count - 1
        #expect(rootGuardCount == 1)
    }

    @Test
    func `Neutralizes newline and comment injection in paths`() {
        // Line breaks and comment markers could otherwise split the profile
        // or truncate the closing quote, so they must not survive raw.
        let sneakyWrite = "/tmp/evil\n(allow file-write* (subpath \"/\"))"
        let sneakyComment = "/tmp/sneaky; (deny file-write* (subpath \"/\"))"
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: [],
            allowedWritePaths: [sneakyWrite, sneakyComment],
            allowNetwork: false
        )
        let profile = builder.buildProfile()

        // Newline payloads are dropped fail-closed, keeping guards intact.
        #expect(!profile.contains(sneakyWrite))
        // Semicolons stay escaped inside the string, never as comments.
        #expect(profile.contains("\\;"))
        let rootGuardCount = profile.components(separatedBy: "(subpath \"/\")").count - 1
        #expect(rootGuardCount == 1)
    }

    @Test
    func `Temp staging is writable and readable but never executable`() {
        // Staged document bytes must land in temp without gaining code
        // execution: temp joins the read/write allows but is excluded from the
        // executable mapping and carries an explicit exec deny.
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/workspace"],
            allowedWritePaths: ["/Users/test/workspace"],
            allowedTempPaths: ["/tmp/runeweaver-doc-123"],
            allowNetwork: false
        )
        let profile = builder.buildProfile()

        #expect(profile.contains("/tmp/runeweaver-doc-123"))
        #expect(profile.contains("(allow file-write*"))
        #expect(profile.contains("(allow file-read*"))
        // The temp path must appear in the exec deny block, proving staged
        // bytes cannot map as code even when the write allow covers them.
        let denyExecSection = profile.components(separatedBy: "(deny file-map-executable").dropFirst().joined(separator: "(deny file-map-executable")
        #expect(denyExecSection.contains("/tmp/runeweaver-doc-123"))
        // And it must not appear in the exec allow block.
        let allowExecPrefix = profile.components(separatedBy: "(allow file-map-executable").dropFirst().first ?? ""
        let allowExecBlock = allowExecPrefix.components(separatedBy: "(deny").first ?? allowExecPrefix
        #expect(!allowExecBlock.contains("/tmp/runeweaver-doc-123"))
    }

    @Test
    func `Confined temp directory is owner-only`() throws {
        // Temp staging must not leak across local users while awaiting the
        // approval-gated atomic move; mode 0700 is the filesystem half of the
        // never-execute guarantee.
        let url = try SeatbeltProfileBuilder.makeConfinedTempDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let rawPermissions = attributes[.posixPermissions]
        let permissions = (rawPermissions as? NSNumber)?.intValue ?? (rawPermissions as? Int) ?? 0
        #expect(permissions & 0o777 == 0o700)
    }

    @Test
    func `Executes under sandbox-exec on macOS`() throws {
        let sandboxExecURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard FileManager.default.isExecutableFile(atPath: sandboxExecURL.path) else {
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-seatbelt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("sample.txt")
        try Data("sandbox test content".utf8).write(to: testFile)

        let profile = SeatbeltProfileBuilder(
            allowedReadPaths: [tempDir.path],
            allowedWritePaths: [tempDir.path],
            allowNetwork: false
        ).buildProfile()

        // Run /bin/cat under sandbox-exec to read allowed file
        let process = Process()
        process.executableURL = sandboxExecURL
        process.arguments = ["-p", profile, "/bin/cat", testFile.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            print("SANDBOX-EXEC STDERR: \(errText)")
        }

        #expect(process.terminationStatus == 0)
        #expect(outputText.contains("sandbox test content"))
    }

    @Test
    func `Denies shell startup files and launch agents inside the sandbox`() {
        let builder = SeatbeltProfileBuilder(
            allowedReadPaths: ["/Users/test/workspace"],
            allowedWritePaths: ["/Users/test/workspace"]
        )
        let profile = builder.buildProfile()

        #expect(profile.contains(".zshrc"))
        #expect(profile.contains(".bashrc"))
        #expect(profile.contains(".profile"))
        #expect(profile.contains("LaunchAgents"))
        #expect(profile.contains(#"/\.zshrc$"#))
        #expect(profile.contains(#"/\.bashrc$"#))
        #expect(profile.contains(#"/Library/LaunchAgents/"#))
    }
}
