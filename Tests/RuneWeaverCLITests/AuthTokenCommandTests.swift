// Rune Weaver CLI Tests — Owner-token command surface.
//
// Rune Weaver is single-owner by design, so the `auth token` commands must
// never silently overwrite an existing credential and `status` must report the
// configuration state without ever rendering the secret. These tests drive the
// real command structs with an explicit temp config that resolves the token
// from a throwaway environment variable, so no test touches the operator's
// Keychain or token file.

import ArgumentParser
import Foundation
@testable import RuneWeaverCLI
import RuneWeaverServer
import Testing

/// Writes a minimal config naming one environment-variable token source and
/// returns its URL plus the surrounding temp directory for cleanup.
private func makeAuthConfigFile(tokenEnv: String) throws -> (directory: URL, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("runeweaver-cli-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("config.toml")
    let contents = """
    [auth]
    token_env = "\(tokenEnv)"
    """
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return (directory, fileURL)
}

@Suite("Auth Token Commands", .serialized)
struct AuthTokenCommandTests {
    @Test
    func `Generate refuses when a token source already resolves`() async throws {
        // A second generate must not clobber a live credential: resolving from
        // the environment proves a token is already configured, so the command
        // exits with a failure instead of minting and persisting a replacement.
        let envName = "RUNEWEAVER_AUTH_CLI_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let token = "cli-existing-token-\(UUID().uuidString)"
        _ = setenv(envName, token, 1)
        defer { _ = unsetenv(envName) }
        let (directory, fileURL) = try makeAuthConfigFile(tokenEnv: envName)
        defer { try? FileManager.default.removeItem(at: directory) }

        var command = try AuthTokenGenerateCommand.parse(["--config", fileURL.path])
        do {
            try await command.run()
            Issue.record("Expected the generate command to refuse an already-configured token")
        } catch let exitCode as ExitCode {
            // Expected: refusal is a nonzero exit, never a silent overwrite.
            #expect(exitCode.rawValue != 0)
        }
    }

    @Test
    func `Status reports source and fingerprint without the secret`() async throws {
        // `status` is the operator's only way to inspect a configured token, so
        // it must name the source and a non-secret fingerprint while never
        // echoing the credential. `print` targets the process-wide stdout, so
        // the descriptor is redirected for the duration and the suite stays
        // serialized so no two captures can interleave.
        let envName = "RUNEWEAVER_AUTH_CLI_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let token = "cli-secret-token-\(UUID().uuidString)"
        _ = setenv(envName, token, 1)
        defer { _ = unsetenv(envName) }
        let (directory, fileURL) = try makeAuthConfigFile(tokenEnv: envName)
        defer { try? FileManager.default.removeItem(at: directory) }

        var command = try AuthTokenStatusCommand.parse(["--config", fileURL.path])
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var captured: Error?
        do {
            try await command.run()
        } catch {
            captured = error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let captured {
            throw captured
        }
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(output.contains("Owner auth: configured"))
        #expect(output.contains("source: environment (\(envName))"))
        // The fingerprint is the only credential identifier allowed on screen.
        #expect(output.contains(ServerAuth.fingerprint(token)))
        #expect(output.contains(token) == false)
    }
}
