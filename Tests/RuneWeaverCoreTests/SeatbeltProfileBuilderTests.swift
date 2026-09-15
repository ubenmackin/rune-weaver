// Rune Weaver Core Tests — Seatbelt profile generator tests.
//
// Covers the deny-default SBPL baseline: every profile must block by default,
// reopen only minimal system plus explicit workspace roots for reads and
// writes, retain macOS dyld launch compat, and keep credential denies
// overriding workspace allows.

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
}
