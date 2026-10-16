// Rune Weaver CLI Tests — Command-surface and policy-verify contract.

import ArgumentParser
import Foundation
@testable import RuneWeaverCLI
@testable import RuneWeaverCore
import Testing

/// Writes policy text to a temp file, returning the directory plus file URL so
/// the caller can clean up the whole tree.
private func makePolicyFile(_ contents: String) throws -> (directory: URL, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-cli-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("policy.toml")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return (directory, fileURL)
}

@Suite("CLI Command Surface")
struct CommandSurfaceTests {
    @Test
    func `Router exposes exactly the four ops commands`() {
        let subcommands = RuneWeaverCommand.configuration.subcommands
        #expect(subcommands.count == 4)
        #expect(subcommands.contains { $0 == AuthCommand.self })
        #expect(subcommands.contains { $0 == PolicyCommand.self })
        #expect(subcommands.contains { $0 == ServeCommand.self })
        #expect(subcommands.contains { $0 == StatusCommand.self })
    }

    @Test
    func `Policy exposes verify only`() {
        let subcommands = PolicyCommand.configuration.subcommands
        #expect(subcommands.count == 1)
        #expect(subcommands.contains { $0 == PolicyVerifyCommand.self })
        // No default subcommand: a bare `policy` prints its own help instead of
        // silently falling through to a removed display path.
        #expect(PolicyCommand.configuration.defaultSubcommand == nil)
    }

    @Test
    func `Verify accepts a sound policy file`() async throws {
        let (directory, fileURL) = try makePolicyFile(PolicyStore.serialize(.safeDefault))
        defer { try? FileManager.default.removeItem(at: directory) }
        var command = try PolicyVerifyCommand.parse(["--policy", fileURL.path])
        try await command.run()
    }

    @Test
    func `Verify checks the factory posture when no file exists`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeweaver-cli-policy-missing-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("policy.toml")
        var command = try PolicyVerifyCommand.parse(["--policy", fileURL.path])
        try await command.run()
    }

    @Test
    func `Verify refuses an unparseable policy file`() async throws {
        let (directory, fileURL) = try makePolicyFile("this is not a policy at all !!!")
        defer { try? FileManager.default.removeItem(at: directory) }
        var command = try PolicyVerifyCommand.parse(["--policy", fileURL.path])
        do {
            try await command.run()
            Issue.record("Expected verify to reject an unparseable policy file")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue != 0)
        }
    }

    @Test
    func `Verify refuses a policy that breaks credential confinement`() async throws {
        let (directory, fileURL) = try makePolicyFile(
            """
            [credentials.loopback_key]
            allowed_hosts = ["localhost"]
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        var command = try PolicyVerifyCommand.parse(["--policy", fileURL.path])
        do {
            try await command.run()
            Issue.record("Expected verify to reject a loopback-bound credential")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue != 0)
        }
    }
}
