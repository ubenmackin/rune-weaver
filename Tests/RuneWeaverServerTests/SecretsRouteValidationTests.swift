// Rune Weaver Tests — Secrets route key validation refusing reserved sovereign accounts.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import Testing
import Vapor

@Suite("Secrets Route Key Validation")
struct SecretsRouteKeyValidationTests {
    @Test
    func `Reserved sovereign prefix is refused on the secrets routes`() {
        // Store, status, and delete share this one validator, so a single
        // refusal pins all three against sovereign account collisions.
        for reserved in ["sovereign.signing.key", "sovereign.anchor", "sovereign.anything"] {
            do {
                _ = try validateSecretKey(reserved)
                Issue.record("Expected the reserved prefix to refuse \(reserved)")
            } catch let abort as AbortError {
                #expect(abort.status == .badRequest)
                #expect(abort.reason.contains(SecretsManager.reservedAccountPrefix))
            } catch {
                Issue.record("Expected Abort.badRequest, got \(error)")
            }
        }
    }

    @Test
    func `Ordinary operator keys still validate`() throws {
        #expect(try validateSecretKey("EMAIL_WORK_PASSWORD") == "EMAIL_WORK_PASSWORD")
        #expect(try validateSecretKey("  MY_API_KEY  ") == "MY_API_KEY")
    }
}
