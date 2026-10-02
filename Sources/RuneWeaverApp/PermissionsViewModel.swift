// Rune Weaver App — Permissions window view model over live probes.
//
// Presents one live row per capability, refreshing silently on appear and on
// activation and prompting only from an explicit Enable press. A single-flight
// refresh keeps concurrent appear and activation triggers from interleaving
// reads, while request-then-refresh reconciliation keeps the row honest when
// the system settles to a different value than the prompt returned. The app is
// brought frontmost before any prompt so the system dialog never hides behind
// other windows.
//
// Scope: row state plus Enable versus Settings routing plus relaunch. No TCC
// calls, no Settings URLs, no persistence — the probing and system-action seams
// own those so tests drive every path without touching real consent.
// Architectural role: the single MainActor owner of Permissions window state,
// keeping prompting behind explicit user intent while background refreshes stay
// silent.

import AppKit
import Observation

/// Live permission rows for the Permissions window.
///
/// Statuses are live reads with no caching: callers refresh on window appear,
/// on activation, and after every request. Prompts originate only from explicit
/// button presses routed through `request(_:)` or `perform(_:for:)` with
/// `.enable`; silent paths never initiate consent.
@Observable
@MainActor
public final class PermissionsViewModel {
    private let probes: any PermissionProbing
    private let actions: any PermissionSystemActing

    /// Latest live read per kind, empty until the first refresh completes.
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    /// Whether a refresh is currently reading every row.
    public private(set) var isRefreshing = false

    /// Whether the first refresh pass has completed.
    ///
    /// Stays false through the initial silent read so the window can render
    /// a loading affordance instead of the unavailable fallback, which would
    /// otherwise flash Open System Settings before any live read lands.
    public private(set) var didLoad = false

    /// Waiters parked behind the in-flight refresh.
    ///
    /// A reconciling `force` pass appends its continuation here instead of
    /// spin-waiting, so concurrent appear and activation triggers serialize
    /// without wasting CPU and without a timeout.
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    public init(probes: any PermissionProbing, actions: any PermissionSystemActing) {
        self.probes = probes
        self.actions = actions
    }

    /// Row order for the window; declaration order is presentation order.
    public var orderedKinds: [PermissionKind] {
        PermissionKind.allCases
    }

    /// Live status for one row, falling back to unavailable before the first
    /// refresh so an unread row never claims a grant it has not verified.
    /// The window gates affordances on `didLoad` so this fallback never
    /// flashes an Open Settings button before the first live read lands.
    public func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .unavailable
    }

    /// Re-reads every row silently without ever prompting.
    ///
    /// Single-flight: a concurrent appear plus activation pair collapses into
    /// one pass instead of interleaving writes. A reconciling refresh passes
    /// `force: true` so a request-then-refresh pass parks behind the in-flight
    /// read via continuations and re-reads every row instead of being dropped
    /// while stale. Never calls `probes.request`, so background triggers
    /// cannot steal focus with a consent dialog.
    public func refresh(force: Bool = false) async {
        if isRefreshing {
            // Background triggers collapse; the reconciling pass serializes
            // behind the in-flight read so no row stays stale after a grant.
            guard force else { return }
            // Park behind the in-flight pass instead of yielding in a loop,
            // so waiting costs no CPU and cancellation stays cooperative.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                refreshWaiters.append(continuation)
            }
            if Task.isCancelled {
                return
            }
            // A fellow reconciling pass may have claimed the follow-up while
            // this waiter was parked; join it instead of starting parallel
            // work so concurrent grants collapse to one re-read.
            if isRefreshing {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    refreshWaiters.append(continuation)
                }
                return
            }
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            let pending = refreshWaiters
            refreshWaiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }
        for kind in PermissionKind.allCases {
            if Task.isCancelled {
                break
            }
            let next = await probes.status(kind)
            statuses[kind] = next
        }
        // Mark the first pass complete only after attempting every row, so
        // the window can gate its affordances on live reads rather than the
        // pre-first-read fallback.
        if !Task.isCancelled {
            didLoad = true
        }
    }

    /// Prompts for one capability, then reconciles every row.
    ///
    /// The prompt result is stored immediately so the pressed row responds at
    /// once, and the trailing refresh re-reads all rows because the system can
    /// settle related rows as a side effect of one grant.
    public func request(_ kind: PermissionKind) async {
        // Frontmost first: the single activation for the prompting path lives
        // here so the system dialog appears above other windows when the
        // owner just pressed Enable.
        NSApp?.activate()
        let result = await probes.request(kind)
        statuses[kind] = result
        await refresh(force: true)
    }

    /// Routes a row affordance to its backing behavior.
    ///
    /// `.none` is a deliberate no-op for rows that need no action; `.enable`
    /// runs the prompting path; `.openSettings` deep-links the capability's
    /// privacy pane without prompting anything.
    public func perform(_ action: PermissionAction, for kind: PermissionKind) async {
        switch action {
        case .none:
            return
        case .enable:
            // Activation lives in `request(_:)` alone so the prompting path
            // fronts exactly once before the consent dialog.
            await request(kind)
        case .openSettings:
            actions.open(kind.pane)
        }
    }

    /// Relaunches the app so newly granted capture, control, or history grants take effect.
    public func relaunchApp() {
        actions.relaunchApp()
    }
}
