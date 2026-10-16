// Rune Weaver App — Permissions window view model over live probes.

import AppKit
import Observation

/// Live permission rows for the Permissions window. Prompts originate only from explicit button
/// presses routed through `request(_:)` or `perform(_:for:)` with `.enable`; silent paths never
/// initiate consent.
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
    public private(set) var didLoad = false

    /// Waiters parked behind the in-flight refresh.
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    public init(probes: any PermissionProbing, actions: any PermissionSystemActing) {
        self.probes = probes
        self.actions = actions
    }

    /// Row order for the window; declaration order is presentation order.
    public var orderedKinds: [PermissionKind] {
        PermissionKind.allCases
    }

    /// Live status for one row, falling back to unavailable before the first refresh so an unread
    /// row never claims a grant it has not verified.
    public func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .unavailable
    }

    /// Re-reads every row silently without ever prompting. Never calls `probes.request`, so
    /// background triggers cannot steal focus with a consent dialog.
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
