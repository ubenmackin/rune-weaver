// Rune Weaver Tools — Shared supervised browser gateway resolution.

import Foundation
import RuneWeaverCore

/// Single owner for supervised gateway reuse across plugin and boot paths.
/// Preserves bridge budgets while keeping one shared instance per supervisor.
/// Callers supply the live supervisor so results never stay unsupervised.
public enum SupervisedBrowserGateway {
    /// Merges config origins with owner grants for one supervised gateway.
    /// - Parameter extraAllowlistedOrigins: Owner grants unioned with auto origins.
    /// - Returns: Effective origins for the supervised gateway and guards.
    public static func mergedOrigins(
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        extraAllowlistedOrigins: Set<String> = []
    ) -> Set<String> {
        ApiSSRFGuard.allowlistedOrigins(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs
        ).union(extraAllowlistedOrigins)
    }

    /// Resolves the supervised gateway, rebuilding only managed mismatches.
    /// Saved timeout applies live; non-subprocess doubles pass through unchanged.
    /// Nil builds a fresh supervised subprocess gateway with merged origins.
    public static func resolve(
        injected: any BrowserPlaywrightGateway?,
        browserConfig: BrowserConfig,
        mediaConfig: MediaConfig? = nil,
        llmServerURLs: [String] = [],
        mergedOrigins: Set<String> = [],
        supervisor: OutboundEgressSupervisor
    ) -> any BrowserPlaywrightGateway {
        if let managed = injected as? SubprocessPlaywrightGateway,
           managed.egressSupervisor === supervisor,
           managed.allowlistedOrigins == mergedOrigins,
           managed.llmServerURLs == llmServerURLs,
           managed.timeoutSeconds == TimeInterval(browserConfig.timeoutSeconds)
        {
            return managed
        }
        if let managed = injected as? SubprocessPlaywrightGateway {
            return SubprocessPlaywrightGateway(
                pythonExecutable: managed.pythonExecutable,
                timeoutSeconds: TimeInterval(browserConfig.timeoutSeconds),
                maxOutputBytes: managed.maxOutputBytes,
                browserConfig: browserConfig,
                mediaConfig: mediaConfig,
                llmServerURLs: llmServerURLs,
                allowlistedOrigins: mergedOrigins,
                egressSupervisor: supervisor
            )
        }
        if let injected {
            return injected
        }
        return SubprocessPlaywrightGateway(
            browserConfig: browserConfig,
            mediaConfig: mediaConfig,
            llmServerURLs: llmServerURLs,
            allowlistedOrigins: mergedOrigins,
            egressSupervisor: supervisor
        )
    }
}
