// Rune Weaver Core Tests — Shared bash fixtures for permission gate suites.

import Foundation
@testable import RuneWeaverCore

/// Namespace for shared bash policy fixtures used by gate suites.
enum BashGateTestSupport {
    /// Smoke-test shell policy for the gate suite.
    /// Default deny with `*` ask, `echo` allow, and `rm` deny in rule order.
    static func smokeBashConfig() -> BashConfig {
        BashConfig(
            defaultAction: .deny,
            rules: [
                BashRule(pattern: "*", action: .ask),
                BashRule(pattern: "echo", action: .allow),
                BashRule(pattern: "rm", action: .deny)
            ]
        )
    }
}
