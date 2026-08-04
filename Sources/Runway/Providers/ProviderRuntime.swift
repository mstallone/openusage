import Foundation

/// What kind of refresh a provider is running inside. The two flags are deliberately separate:
/// `runway --force` and automated retries bypass caches with nobody watching, so they must never
/// unlock credential UI (a prompt from the separately signed CLI would also authorize the wrong
/// binary), while a GUI refresh is user-attended and may ask once.
enum ProviderRefreshContext {
    /// A user-attended refresh from the app: the only REFRESH that may raise a Keychain approval
    /// dialog. It is not the only user action that can — `CodexResetClaimService` asks for approval
    /// when a reset credit is claimed and every readable credential was rejected — but any prompt
    /// must, like these two, follow directly from something the user just clicked.
    @TaskLocal static var isManual = false
    /// The caller bypassed the snapshot cache — ⌘R, `runway --force`, or an automated retry. Use
    /// this for non-UI "the user asked for fresh data" behavior such as skipping a negative cache.
    @TaskLocal static var isForced = false
}

/// One AI provider Runway can track. A conformer reads credentials already on the machine, calls the
/// provider's API, and normalizes the result into a `ProviderSnapshot` of `MetricLine` values that the UI
/// renders. See `docs/adding-a-provider.md` for the full walkthrough.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.values` — one or more typed, unbounded numbers. Use for spend, balances, token counts, and other
///   limitless numeric rows; formatting stays at the display edge.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
/// - `.chart` — dated numeric points rendered as a compact usage trend.
/// - `.text` — a string-valued provider notice preserved for the local API. Dashboard widgets do not
///   parse display text; use a typed line above for every widget descriptor.
///
/// On failure, return `ProviderSnapshot.error(provider:error:)` with a typed provider error so its
/// user-facing description surfaces loudly in the UI. Use the message-only factory only when no typed
/// error exists.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot

    /// Whether credentials for this provider already exist on this machine — a cheap, local-only probe
    /// (files, keychain, SQLite; never the network). Used once, on a fresh install's first launch, by
    /// `FirstRunSeeder` to enable exactly the providers the user actually has. Mirror the credential
    /// sources `refresh()` reads, and run blocking loads via `loadOffMainActor`.
    func hasLocalCredentials() async -> Bool

    /// Hard ceiling on one `refresh()` before `WidgetDataStore` cuts it off as hung (error card +
    /// backoff; the last-good snapshot stays on screen). The default covers the common providers'
    /// complete built-in request budgets with margin — override it when a provider's own sequential
    /// budgets can legitimately exceed it (Copilot's multi-org billing probe does), so the ceiling
    /// stays what it's for: killing genuinely dead work, not policing slow-but-valid paths.
    var refreshTimeout: TimeInterval { get }
}

extension ProviderRuntime {
    /// 150s default: above Kimi's full OAuth retry budget (~93s plus loading and the usage
    /// request), Cursor's sequential probe (~70s), and Codex's claim probe (~45s).
    var refreshTimeout: TimeInterval { WidgetDataStore.defaultProviderRefreshTimeout }
}

/// Run a blocking, `Sendable` credential load off the MainActor.
///
/// Auth stores read credentials through in-process Keychain calls, files, and in some cases the
/// `sqlite3` CLI. Those blocking loads run at the top of a provider's
/// `@MainActor refresh()`, so calling them inline freezes the popover and the periodic-refresh loop for
/// the whole operation (a provider can issue several reads per refresh). Offloading to a
/// detached task moves the wait onto a background executor; the `Sendable` result crosses back cleanly.
/// It is awaited immediately, so it reads like a normal call while no longer blocking the actor.
/// Cancellation is forwarded to the detached task so a provider watchdog can remove a queued
/// interactive Keychain read instead of leaving a stale approval request behind the active dialog.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(priority: .utility, operation: load)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Throwing counterpart for blocking credential reads that distinguish absence from access failure.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .utility, operation: load)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
