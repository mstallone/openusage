import Foundation
import Observation

/// A compact staleness hint for a provider's on-screen snapshot. `label` is a short, fixed word
/// ("Outdated") that stays narrow next to long plan names like "Super Grok Heavy", while the precise
/// age lives in `tooltip` ("Last updated 3h 12m ago"), revealed on hover.
struct StalenessHint: Equatable {
    let label: String
    let tooltip: String
}

@MainActor
@Observable
final class WidgetDataStore {
    private let registry: WidgetRegistry
    private let providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// Whether a provider is currently enabled. Injected so the store consults the single
    /// `ProviderEnablementStore` without owning it; defaults to "all enabled" for tests and previews.
    private let isProviderEnabled: @MainActor (String) -> Bool
    /// The user's widget order (already enablement-filtered) that drives the menu-bar value. Injected
    /// so the store reads `LayoutStore.visiblePlaced` without owning it; defaults to registry order.
    private let orderedDescriptors: @MainActor () -> [WidgetDescriptor]
    /// Clock for the failure-backoff window. Injected so tests can advance time deterministically.
    private let now: () -> Date
    /// Monotonic clock for refresh durations, kept separate from wall time so a clock adjustment cannot
    /// produce a negative or wildly inflated provider timing. Tests inject exact ticks.
    private let monotonicNow: () -> TimeInterval
    private let slowProviderRefreshThreshold: TimeInterval
    /// Hard ceiling on one provider's `refresh()`, resolved per provider
    /// (`ProviderRuntime.refreshTimeout` — a hung network call used to spin the footer's refresh
    /// indicator forever, and the in-flight guard then blocked every later attempt). This stored
    /// value is a test-only global override; `nil` in production.
    private let providerRefreshTimeoutOverride: TimeInterval?
    /// The protocol extension's default ceiling — see `ProviderRuntime.refreshTimeout` for the
    /// budget rationale and when a provider should override it.
    static let defaultProviderRefreshTimeout: TimeInterval = 150
    /// Manual hidden-account preparation gets the same hard ceiling as a normal provider refresh.
    /// A Keychain approval dialog may be ignored and Security.framework is synchronous underneath;
    /// neither is allowed to hold the footer spinner or queue duplicate readers indefinitely.
    static let defaultInteractivePreparationTimeout: TimeInterval = 150
    private let interactivePreparationTimeout: TimeInterval
    /// Providers whose timed-out refresh is still running detached (the deadline race resumed
    /// without awaiting it). Blocks new attempts for that provider so network/auth work never
    /// overlaps on one runtime — cleared ONLY when the straggler actually exits. Deliberately no
    /// time-based expiry: the periodic loop's cadence (5 min) would sail past any reasonable valve
    /// and stack overlapping attempts on a permanently wedged runtime every cycle; the timeout
    /// error card already tells the user the provider is stuck, and a straggler that never exits
    /// means retrying couldn't succeed anyway.
    private var hungRefreshProviderIDs: Set<String> = []
    /// Quota-notification preferences (three independent triggers). Injected; `nil` disables
    /// notifications entirely (tests and previews that don't wire it).
    private let notificationSettings: (@MainActor () -> NotificationSettingsStore)?
    /// Card id → the account identity currently signed in there, resolved once at launch by
    /// `ProviderAccountAssembly`. Drives the snapshot cache's account stamp: writes record the
    /// producer, and launch loads only paint an entry whose stamp matches. A card absent here has an
    /// unresolved identity this launch (or isn't account-aware) — its cache behaves as it always did.
    private let providerIdentityKeys: [String: String]
    /// Runtime cards whose current source cannot inherit a snapshot stamped by a prior account.
    /// Unlike an unresolved login, these must force a refresh before using that cached data.
    private let providersRejectingAccountStampedCache: Set<String>
    /// The live card title for a card id, `nil` for non-account providers — the account-registry
    /// name resolver, injected by `AppContainer` so notification titles carry renames. `nil`
    /// (tests, the one-shot CLI) falls back to the baked derived name.
    private let resolveDisplayName: (@MainActor (String) -> String?)?
    /// Where a fired milestone is delivered: `(idPrefix, title, subtitle, body) -> Bool`. The Bool is
    /// whether it was actually delivered (authorized + scheduled); on false the caller leaves the
    /// milestone un-marked so it retries next pass. Injected so tests can record posts without a live
    /// notification center; defaults to the shared `AppNotifications`.
    private let postNotification: @MainActor (String, String, String, String) async -> Bool

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let alwaysShowPacingKey = "alwaysShowPacing"
    /// How long a provider that just failed is skipped before the loop will probe it again. A failed
    /// refresh isn't cached, so — unlike a success, which the snapshot cache gates for an interval —
    /// nothing else stops the loop from re-probing a broken provider (logged-out Devin/Grok especially)
    /// on every wake, spawning subprocesses and network calls in a tight loop. This negative-cache caps a
    /// failing provider to one probe per window. Shorter than the refresh interval, so the normal
    /// 5-minute heartbeat always retries; it only suppresses the sub-interval re-probes a wake burst
    /// would cause. The manual `force` refresh (⌘R) always bypasses it.
    private static let failureRetryBackoff: TimeInterval = 60
    static let defaultSlowProviderRefreshThreshold: TimeInterval = 10

    /// Rendered snapshots consumed by every UI/API surface. Equal to `localSnapshots` when iCloud sync
    /// is off; machine-local history rows are rebuilt from the union while sync is on.
    var snapshots: [String: ProviderSnapshot] = [:]
    /// Last-good snapshots produced on this Mac. These alone are cached and exported to iCloud, so a
    /// peer contribution can never echo back out and multiply on the next device.
    private(set) var localSnapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// Wall-clock time the most recent full refresh pass finished. Together with the chosen refresh
    /// cadence it drives the dashboard footer's live "Next update in …" countdown, so the footer reflects
    /// the real schedule instead of a hardcoded value. `nil` until the first pass completes.
    var lastRefreshAt: Date?
    /// Latest refresh error per provider (e.g. "Not logged in. Run `codex` to authenticate."). Set when
    /// a refresh comes back as an error snapshot, cleared on the next successful one. The dashboard
    /// renders it as a warning indicator beside the provider name; the last good snapshot keeps
    /// displaying (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]
    /// The providers whose current `providerErrors` entry is the neutral connect prompt (a
    /// credential exists but hasn't been loaded this process) rather than a real failure. The
    /// dashboard renders those with the Connect affordance instead of the warning treatment.
    /// Maintained strictly alongside `providerErrors`: membership without an error entry is
    /// meaningless and never happens.
    var providerConnectPrompts: Set<String> = []

    /// Per-provider earliest next-probe time after a failure (see `failureRetryBackoff`). Not part of
    /// observable UI state, so it's excluded from `@Observable` tracking.
    @ObservationIgnored private var failureRetryAfter: [String: Date] = [:]

    /// Owns the quota pace-notification subsystem (dedup state, fire/deliver decision, trace). This store
    /// just gathers each pass's enabled bounded metrics and delegates.
    @ObservationIgnored private let notificationEvaluator = QuotaNotificationEvaluator()

    /// Fires when this Mac's publishable sync state changes: refreshed usage history or a provider
    /// error transition (the synced snapshot carries `providerErrors`, so failures must publish
    /// too). Wired by `ICloudUsageSyncStore`; debounced there so a concurrent provider batch
    /// produces one write.
    @ObservationIgnored var onLocalStateChanged: (@MainActor () -> Void)?
    /// One-time user-attended preparation for hidden credential-backed accounts. The provider-id set
    /// makes applicability explicit: disabling that provider family must also disable its secret reads.
    @ObservationIgnored private var interactiveRefreshPreparationProviderIDs: Set<String> = []
    @ObservationIgnored private var makeInteractiveRefreshPreparationTask: (@MainActor () -> Task<Bool, Never>?)?
    @ObservationIgnored private var interactiveRefreshPrepared = false
    @ObservationIgnored private var interactivePreparationFlight: Task<Bool, Never>?
    @ObservationIgnored private var interactivePreparationGeneration = 0
    @ObservationIgnored private var interactivePreparationStragglerActive = false
    /// Included in the footer's global refresh state so a pending Keychain approval is visible and
    /// repeated clicks cannot launch another Refresh All while the bounded preparation is active.
    private(set) var isPreparingInteractiveRefresh = false
    /// Readable (not writable) so the sync tests can assert what peers actually contribute.
    @ObservationIgnored private(set) var peerHistoryDocuments: [UsageHistoryDocument] = []
    /// Non-zero while `refreshAll` is coalescing per-provider completion work into short debounced
    /// rebuilds plus one batch-end rebuild + cache persist. Plain counters — everything here is
    /// MainActor-serialized.
    @ObservationIgnored private var snapshotRebuildDeferrals = 0
    @ObservationIgnored private var pendingSnapshotRebuild = false
    /// The in-flight debounce for mid-batch publishing; see `requestSnapshotRebuild`.
    @ObservationIgnored private var coalescedRebuildTask: Task<Void, Never>?
    /// Accounts synced from other Macs that have NO card here: surfaced in Total Spend only (their
    /// synthesized snapshots carry the usual Today/Yesterday/Last 30 Days lines), never as cards.
    private(set) var remoteOnlySpend: [(provider: Provider, snapshot: ProviderSnapshot)] = []

    /// Global meter style: whether every bounded tile (and the menu-bar value) renders as "used" or
    /// "left/remaining". Persisted so the choice survives relaunch; defaults to `.remaining`.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// Global reset-countdown format: relative ("Resets in 4d 17h") or absolute ("Resets tomorrow at
    /// 9:00 AM"). Persisted across relaunch; defaults to `.relative`. Toggled by clicking a reset label.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    /// Global "always show pacing" opt-in: when on, on-track rows surface their pace projection (the
    /// blue/healthy row gains its "~N% left at reset" copy + an even-pace tick, the amber tick switches
    /// to the same even-pace line). Persisted across relaunch; defaults to `false` (every row unchanged).
    var alwaysShowPacing: Bool {
        didSet { defaults.set(alwaysShowPacing, forKey: Self.alwaysShowPacingKey) }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        slowProviderRefreshThreshold: TimeInterval = WidgetDataStore.defaultSlowProviderRefreshThreshold,
        providerRefreshTimeout: TimeInterval? = nil,
        interactivePreparationTimeout: TimeInterval = WidgetDataStore.defaultInteractivePreparationTimeout,
        notificationSettings: (@MainActor () -> NotificationSettingsStore)? = nil,
        postNotification: (@MainActor (String, String, String, String) async -> Bool)? = nil,
        providerIdentityKeys: [String: String] = [:],
        providersRejectingAccountStampedCache: Set<String> = [],
        resolveDisplayName: (@MainActor (String) -> String?)? = nil
    ) {
        precondition(slowProviderRefreshThreshold >= 0)
        if let providerRefreshTimeout { precondition(providerRefreshTimeout > 0) }
        precondition(interactivePreparationTimeout > 0)
        self.providerRefreshTimeoutOverride = providerRefreshTimeout
        self.interactivePreparationTimeout = interactivePreparationTimeout
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.now = now
        self.monotonicNow = monotonicNow
        self.slowProviderRefreshThreshold = slowProviderRefreshThreshold
        self.notificationSettings = notificationSettings
        self.postNotification = postNotification
            ?? { idPrefix, title, subtitle, body in
                await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
            }
        self.providerIdentityKeys = providerIdentityKeys
        self.providersRejectingAccountStampedCache = providersRejectingAccountStampedCache
        self.resolveDisplayName = resolveDisplayName
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .remaining)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .relative)
        self.alwaysShowPacing = defaults.bool(forKey: Self.alwaysShowPacingKey)
        // Stale-while-revalidate: load whatever was cached (expired included) so the menu bar and
        // dashboard show last-known values immediately at launch instead of "—"; the refresh loop
        // replaces them as soon as fresh data lands.
        //
        // Account swap guard: when a claude/codex card's CURRENT account identity is known, a cached
        // entry only paints if the account that produced it matches. After a swap at the same home the
        // card id still matches, so without this check the previous account's limits and plan would
        // paint under the new account until the first successful refresh. A card whose current
        // identity is unresolved (logged out, keyring-mode Codex) can't be verified either way — it
        // keeps its cache, exactly as before the guard existed. Non-account providers are unaffected.
        let loaded = cache.loadSnapshots(providerIDs: registry.providers.map(\.id))
            .filter { cardID, _ in
                guard cache.hasStaleAccountStamp(
                    providerID: cardID,
                    currentIdentityKey: providerIdentityKeys[cardID],
                    rejectsAccountStampedCache: providersRejectingAccountStampedCache.contains(cardID)
                ) else {
                    return true
                }
                AppLog.info(.cache, "stale account cache discarded for \(cardID)")
                return false
            }
        self.localSnapshots = loaded
        self.snapshots = loaded
    }

    /// Refresh every enabled provider, concurrently — one slow provider never delays the rest.
    /// Everything stays MainActor-isolated; the overlap happens at the network awaits inside each
    /// provider, and the per-provider in-flight guard in `refresh` still prevents duplicate fetches.
    /// `force` bypasses the snapshot cache; `interactive` marks a user-attended GUI action, the only
    /// context in which a provider may raise a Keychain approval prompt. The two are deliberately
    /// separate: the CLI and automated retries force past caches without a user present, so they
    /// must never unlock credential UI (a prompt from the CLI helper would also authorize the wrong
    /// binary).
    func refreshAll(force: Bool = false, interactive: Bool = false) async {
        let providerIDs = registry.providers.map(\.id).filter { isProviderEnabled($0) }
        if interactive {
            await prepareInteractiveRefreshIfNeeded(enabledProviderIDs: Set(providerIDs))
        }
        // `Task {}` from MainActor context inherits the isolation (a task-group child can't capture
        // the non-Sendable store), so: fire one task per provider, then await them all.
        let start = monotonicNow()
        AppLog.info(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        // Coalesce per-provider completion work: with N providers finishing in one pass, rebuilding
        // the rendered union and re-encoding the snapshot blob once per provider is O(N²) — defer
        // both to a single batch-end rebuild + persist.
        snapshotRebuildDeferrals += 1
        let tasks = providerIDs.map { providerID in
            Task { await self.refresh(providerID: providerID, force: force, interactive: interactive, notifyStateChange: false) }
        }
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            outcomes.append(await task.value)
        }
        snapshotRebuildDeferrals -= 1
        if snapshotRebuildDeferrals == 0 {
            coalescedRebuildTask?.cancel()
            coalescedRebuildTask = nil
            flushPendingSnapshotWork()
        }
        // Stamp the end of the pass so the footer countdown targets the next scheduled refresh
        // (this time + one refresh interval), mirroring the periodic loop that sleeps one interval
        // after each pass.
        lastRefreshAt = Date()
        let durationMs = durationMilliseconds(since: start)
        // Count THIS batch's actual outcomes, not the long-lived `providerErrors` map (which persists
        // across passes, so reading it would miscount cache hits and stale earlier failures).
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        // Failures publish too: the synced snapshot's error map must not stay frozen on a Mac whose
        // every provider is failing. Cached/backed-off outcomes changed nothing, so they don't.
        if refreshed > 0 || failed > 0 { onLocalStateChanged?() }
        AppLog.info(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off)")
    }

    /// Installs a prompt-capable preparation for the listed provider cards. The operation returns its
    /// actual task so the store can cancel it at the deadline; `nil` means there is nothing to prepare.
    func configureInteractiveRefreshPreparation(
        for providerIDs: Set<String>,
        makeTask: @escaping @MainActor () -> Task<Bool, Never>?
    ) {
        interactiveRefreshPreparationProviderIDs = providerIDs
        makeInteractiveRefreshPreparationTask = makeTask
    }

    private func prepareInteractiveRefreshIfNeeded(enabledProviderIDs: Set<String>) async {
        guard !interactiveRefreshPrepared,
              !interactiveRefreshPreparationProviderIDs.isDisjoint(with: enabledProviderIDs),
              let makeTask = makeInteractiveRefreshPreparationTask
        else {
            return
        }

        // Every caller joins the same bounded flight. This matters even though the footer disables its
        // button: keyboard commands and programmatic refreshes can still overlap while an approval
        // dialog is open.
        if let flight = interactivePreparationFlight {
            if await flight.value { interactiveRefreshPrepared = true }
            return
        }
        // A deadline cannot force a synchronous Security.framework call to unwind. Keep the overlap
        // valve closed until that sacrificial task really exits, but let provider refreshes proceed.
        guard !interactivePreparationStragglerActive else {
            AppLog.warn(.keychain, "hidden-account preparation is still exiting after its deadline; skipping duplicate read")
            return
        }

        interactivePreparationGeneration += 1
        let generation = interactivePreparationGeneration
        let flight = Task { [interactivePreparationTimeout] in
            await self.runInteractivePreparation(makeTask: makeTask, timeout: interactivePreparationTimeout)
        }
        interactivePreparationFlight = flight
        let succeeded = await flight.value
        if generation == interactivePreparationGeneration {
            interactivePreparationFlight = nil
        }
        if succeeded { interactiveRefreshPrepared = true }
    }

    /// A true deadline race: the watchdog resumes Refresh All without awaiting a wedged reader. The
    /// losing work task remains tracked as a straggler, preventing another prompt/read until it exits.
    private func runInteractivePreparation(
        makeTask: @MainActor () -> Task<Bool, Never>?,
        timeout: TimeInterval
    ) async -> Bool {
        guard let work = makeTask() else { return true }
        isPreparingInteractiveRefresh = true
        defer { isPreparingInteractiveRefresh = false }

        return await withCheckedContinuation { continuation in
            final class RaceState {
                var resumed = false
                var watchdog: Task<Void, Never>?
            }
            let state = RaceState()
            Task {
                let succeeded = await work.value
                guard !state.resumed else {
                    self.interactivePreparationStragglerActive = false
                    // The binding writes its durable identity before returning. If it completed after
                    // the UI deadline, remember that success instead of prompting again next click.
                    if succeeded { self.interactiveRefreshPrepared = true }
                    return
                }
                state.resumed = true
                state.watchdog?.cancel()
                continuation.resume(returning: succeeded)
            }
            state.watchdog = Task { [timeout] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !state.resumed, !Task.isCancelled else { return }
                state.resumed = true
                self.interactivePreparationStragglerActive = true
                work.cancel()
                AppLog.warn(.keychain, "hidden-account preparation timed out after \(Int(timeout))s; provider refresh will continue")
                continuation.resume(returning: false)
            }
        }
    }

    /// Evaluate every visible, enabled metric for a quota pace milestone and post a notification for any
    /// that just crossed one. Driven from the periodic loop *after* `refreshAll`, so it catches pace
    /// worsening from time passing (not only from a fresh fetch). Deduped per metric per reset window by
    /// the evaluator's per-key state. No-data metrics never fire; bounded level-only metrics can fire
    /// Almost Out, but not pace-based milestones. A no-op when notifications are unconfigured
    /// (tests/previews) or all triggers are off.
    ///
    /// State for metrics not visited this pass (e.g. a provider the user just disabled, or a metric
    /// removed from the layout) is pruned, so re-enabling/re-adding starts fresh rather than carrying a
    /// stale "already fired" flag.
    func evaluateNotifications(now: Date = Date()) async {
        guard let settingsProvider = notificationSettings else { return }
        let toggles = settingsProvider().toggles
        // All triggers off (the default): nothing can fire, so skip resolving and formatting every
        // visible metric. Present metrics keep their evaluator state UNTOUCHED — the pace logic
        // deliberately keeps `previousBucket` behind while a trigger is off so an unconsumed
        // worsening fires when the trigger comes back on (see `testOffToggleDoesNotConsumeTheEdge`).
        // Metrics no longer in the layout still prune (cheap — descriptor keys only, no data
        // resolution), so re-adding one starts fresh instead of firing on stale state.
        guard toggles.underTenPercent || toggles.healthyToClose || toggles.closeToRunningOut else {
            let presentKeys = Set(
                orderedDescriptors()
                    .filter { isProviderEnabled($0.providerID) }
                    .map { "\($0.providerID).\($0.id)" }
            )
            notificationEvaluator.prune(keeping: presentKeys)
            return
        }
        // Gather this pass's enabled, bounded, visible metrics — unbounded rows and charts have no pace
        // story (their meterState never fires), so they're skipped here rather than occupying state.
        // Order is the layout order; the evaluator prunes state for anything not passed this pass.
        // Deliberate delta from the pre-extraction loop: the pass decides from this snapshot, taken
        // before the first delivery `await`, where the old inline loop re-read `data(for:)` between
        // deliveries — a mid-pass refresh no longer changes later metrics' inputs within one pass.
        let metrics = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
            .compactMap { descriptor -> QuotaNotificationEvaluator.Metric? in
                let data = data(for: descriptor)
                guard data.isBounded else { return nil }
                return QuotaNotificationEvaluator.Metric(
                    key: "\(descriptor.providerID).\(descriptor.id)",
                    providerID: descriptor.providerID,
                    data: data
                )
            }
        await notificationEvaluator.evaluate(
            metrics: metrics,
            toggles: toggles,
            now: now,
            providerName: { [providersByID, resolveDisplayName] id in
                resolveDisplayName?(id) ?? providersByID[id]?.provider.displayName ?? id
            },
            post: postNotification
        )
    }

    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the provider failed within the last `failureRetryBackoff` — distinct from `.skipped`
    /// (disabled / unknown / already in flight) so a wake-burst's suppression is visible in the logs.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    @discardableResult
    func refresh(
        providerID: String,
        force: Bool = false,
        interactive: Bool = false,
        notifyStateChange: Bool = true
    ) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        // A TTL-fresh entry that provably belongs to another account (swap since it was written) must
        // not short-circuit the refresh — under persisted freshness (the one-shot CLI) it would copy
        // the previous account's snapshot back in. Treat it as a miss so the fetch overwrites it.
        let staleAccountStamp = cache.hasStaleAccountStamp(
            providerID: providerID,
            currentIdentityKey: providerIdentityKeys[providerID],
            rejectsAccountStampedCache: providersRejectingAccountStampedCache.contains(providerID)
        )
        if !force, !staleAccountStamp, let cached = cache.snapshot(providerID: providerID) {
            // Skip the no-op write: `@Observable` doesn't compare values, so unconditionally
            // re-assigning an unchanged snapshot would re-render the menu-bar label every pass.
            AppLog.debug(.refresh, "cache hit \(providerID)")
            if localSnapshots[providerID] != cached {
                localSnapshots[providerID] = cached
                requestSnapshotRebuild()
            }
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(providerID)") }

        // A provider that just failed isn't cached, so nothing else stops the loop from re-probing it on
        // every wake. Hold off until its backoff expires; the manual `force` refresh ignores the backoff.
        if !force, let retryAfter = failureRetryAfter[providerID], now() < retryAfter {
            AppLog.debug(.refresh, "backoff skip \(providerID) (failed <\(Int(Self.failureRetryBackoff))s ago)")
            return .backedOff
        }

        guard let provider = providersByID[providerID] else { return .skipped }
        // Skip if an in-flight refresh already owns this provider (e.g. the background timer racing the
        // first popover open), so we never fire duplicate network calls for the same provider.
        guard !refreshingProviderIDs.contains(providerID) else {
            AppLog.debug(.refresh, "cache skip \(providerID) (already in flight)")
            return .skipped
        }
        // A timed-out attempt's straggler may still be running detached; don't stack a second
        // network/auth pass on the same runtime while it lives (see `hungRefreshProviderIDs`).
        guard !hungRefreshProviderIDs.contains(providerID) else {
            AppLog.debug(.refresh, "hung-refresh skip \(providerID) (straggler still running)")
            return .skipped
        }
        refreshingProviderIDs.insert(providerID)
        defer { refreshingProviderIDs.remove(providerID) }
        let start = monotonicNow()
        // Each provider owns its ceiling (`ProviderRuntime.refreshTimeout`); the injected override
        // exists for tests.
        let refreshTimeout = providerRefreshTimeoutOverride ?? provider.refreshTimeout
        // Bound the refresh with a true deadline race. `provider` is not Sendable, so both racers
        // are isolation-inheriting `Task`s (not a task group) and the continuation is resumed by
        // whichever finishes first — the deadline never `await`s the provider, so even a provider
        // suspended in a non-cancellable operation cannot hold the spinner and in-flight guard
        // hostage (merely cancelling and then awaiting would). The loser's result is discarded via
        // the MainActor-confined `resumed` flag; a cancelled provider (URLSession-backed work exits
        // promptly on cancellation) finishes into the void and is never published.
        let timedOutSnapshot: ProviderSnapshot? = await withCheckedContinuation { continuation in
            final class RaceState { var resumed = false; var watchdog: Task<Void, Never>? }
            let state = RaceState()
            let refreshTask = Task { [force, interactive] in
                let snapshot = await ProviderRefreshContext.$isForced.withValue(force) {
                    await ProviderRefreshContext.$isManual.withValue(interactive) {
                        await provider.refresh()
                    }
                }
                guard !state.resumed else {
                    // Lost the race: this straggler just exited, so the runtime is idle again —
                    // lift the overlap guard.
                    self.hungRefreshProviderIDs.remove(providerID)
                    return
                }
                state.resumed = true
                state.watchdog?.cancel()
                continuation.resume(returning: snapshot)
            }
            state.watchdog = Task { [refreshTimeout] in
                try? await Task.sleep(for: .seconds(refreshTimeout))
                guard !state.resumed, !Task.isCancelled else { return }
                state.resumed = true
                refreshTask.cancel()
                // The provider's work may still be running detached (cancellation is cooperative,
                // and e.g. Kimi's token refresh awaits a detached task that ignores it). The outer
                // `defer` is about to release `refreshingProviderIDs`, so hold a separate overlap
                // guard until the straggler exits — overlapping auth/network attempts on one
                // runtime is worse than waiting.
                self.hungRefreshProviderIDs.insert(providerID)
                continuation.resume(returning: nil)
            }
        }
        // Timed out: the deadline won the race. Surface it like any failed refresh — error card +
        // backoff — and keep the last-good snapshot on screen.
        guard var snapshot = timedOutSnapshot else {
            let message = "Refresh timed out after \(Int(refreshTimeout))s"
            providerErrors[providerID] = message
            providerConnectPrompts.remove(providerID)
            failureRetryAfter[providerID] = now().addingTimeInterval(Self.failureRetryBackoff)
            AppLog.warn(.refresh, "\(providerID) timed out after \(Int(refreshTimeout * 1000))ms; keeping last-good snapshot")
            if notifyStateChange { onLocalStateChanged?() }
            return .failed
        }
        // A canceled refresh may still return if a provider's underlying work is non-throwing. Never
        // publish that potentially partial snapshot; keep the last-good state exactly as it was.
        guard !Task.isCancelled else {
            AppLog.debug(.refresh, "cancelled \(providerID) refresh; keeping last-good snapshot")
            return .skipped
        }
        let durationMs = durationMilliseconds(since: start)
        if TimeInterval(durationMs) >= slowProviderRefreshThreshold * 1000 {
            AppLog.warn(
                .refresh,
                "\(providerID) slow refresh (\(durationMs)ms, threshold=\(Int(slowProviderRefreshThreshold * 1000))ms)"
            )
        }
        if let message = Self.errorMessage(in: snapshot) {
            // Failed refresh: surface the error but keep the last good snapshot on screen rather than
            // collapsing every row to "No data". The provider error string is already user-safe.
            providerErrors[providerID] = message
            // A connect prompt travels this same path but renders neutrally — remember which it is.
            if snapshot.lines.first?.isConnectPrompt == true {
                providerConnectPrompts.insert(providerID)
            } else {
                providerConnectPrompts.remove(providerID)
            }
            // Negative-cache the failure so a wake burst can't re-probe this provider in a tight loop.
            failureRetryAfter[providerID] = now().addingTimeInterval(Self.failureRetryBackoff)
            AppLog.warn(.refresh, "\(providerID) failed: \(message)")
            if notifyStateChange { onLocalStateChanged?() }
            return .failed
        }
        if providerErrors[providerID] != nil {
            providerErrors[providerID] = nil
        }
        providerConnectPrompts.remove(providerID)
        // Recovered: drop any backoff so the provider resumes the normal cadence immediately.
        failureRetryAfter[providerID] = nil
        // A provider can refresh its live limits successfully while its optional local log/CSV scan
        // produces no result. Keep only the last-good normalized history in that case; the new plan,
        // limits, warnings, and timestamp still win. A non-nil empty history remains authoritative and
        // clears the old rows, because it proves the scan completed and found no usage.
        if snapshot.usageHistory == nil,
           let history = localSnapshots[providerID]?.usageHistory,
           let descriptor = registry.historyDescriptorsByProvider[providerID]
        {
            snapshot.usageHistory = history
            snapshot = UsageHistorySnapshotRenderer.render(
                local: snapshot,
                history: history,
                descriptor: descriptor,
                now: now(),
                combined: false
            )
            AppLog.debug(.refresh, "preserved last-good history for \(providerID) after scan miss")
        }
        localSnapshots[providerID] = snapshot
        // Stamp the write with the card's launch-resolved account identity; nil (no stamp) for
        // non-account providers and for cards whose identity didn't resolve this launch.
        cache.store(
            snapshot,
            producedByIdentityKey: providerIdentityKeys[providerID],
            persist: snapshotRebuildDeferrals == 0
        )
        requestSnapshotRebuild()
        if notifyStateChange { onLocalStateChanged?() }
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        return .refreshed
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((monotonicNow() - start) * 1000))
    }

    /// Clears a provider's failure backoff so the next pass probes it immediately. Called when the user
    /// re-enables a provider: the enablement wake exists to fetch promptly, so a stale backoff from a
    /// failure just before it was turned off must not suppress that fetch (the loop wouldn't otherwise
    /// retry until the 5-minute heartbeat). The periodic loop never calls this — only the user action does.
    func clearFailureBackoff(for providerID: String) {
        failureRetryAfter[providerID] = nil
    }

    /// Rebuild the in-memory union immediately after a provider toggle. Local cached data remains
    /// available to direct API reads, but disabled providers stop receiving peer contributions.
    func providerEnablementDidChange() {
        rebuildRenderedSnapshots()
    }

    /// Replaces the downloaded peer set. A duplicate device document resolves to the newest valid
    /// one, and this Mac's own downloaded copy is excluded in favor of current memory.
    func setPeerHistoryDocuments(_ documents: [UsageHistoryDocument], ownDeviceID: String) {
        peerHistoryDocuments = UsageHistoryDocument.newestByDevice(documents)
            .filter { $0.deviceID != ownDeviceID }
        rebuildRenderedSnapshots()
    }

    func clearPeerHistoryDocuments() {
        guard !peerHistoryDocuments.isEmpty else { return }
        peerHistoryDocuments = []
        rebuildRenderedSnapshots()
    }

    func localHistoryDocument(deviceID: String, deviceName: String, updatedAt: Date = Date()) -> UsageHistoryDocument {
        var providers: [String: ProviderUsageHistory] = [:]
        var identities: [String: String] = [:]
        // Every machine-local card syncs — account cards included. Their ids are identity-derived,
        // so they mean the same account on every Mac; the identities map additionally lets peers
        // match a default card's history to whatever card that account is over there (see
        // `PeerHistoryRemapper`).
        for (providerID, descriptor) in registry.historyDescriptorsByProvider
        where descriptor.scope == .machineLocal && isProviderEnabled(providerID) {
            if let history = localSnapshots[providerID]?.usageHistory {
                providers[providerID] = history
                if let identity = providerIdentityKeys[providerID] {
                    identities[providerID] = identity
                }
            }
        }
        return UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
            providers: providers,
            identities: identities.isEmpty ? nil : identities
        )
    }

    /// The companion payload to `localHistoryDocument`: this Mac's rendered live state for every
    /// enabled provider, written for the iOS app. Built from `localSnapshots` only — peer
    /// contributions never republish — and unlike history it includes account-wide providers such
    /// as Cursor, because a live snapshot is per-device display state, not additive history.
    func localSnapshotDocument(deviceID: String, deviceName: String, updatedAt: Date = Date()) -> DeviceSnapshotDocument {
        var snapshots = localSnapshots.filter { isProviderEnabled($0.key) }
        for (id, var snapshot) in snapshots {
            // Strip the raw daily series: the rendered lines already carry every display value, and
            // the machine-local series ships in the record's history payload. Not duplicating it
            // keeps the per-device record far from CloudKit's 1 MB record limit.
            snapshot.usageHistory = nil
            // The publish boundary is a display boundary, like the CLI/API: renames live only in
            // the account registry (never baked into cached snapshots), so resolve them here or
            // companion apps would show the derived name instead of the user's chosen one.
            if let resolved = resolveDisplayName?(id) {
                snapshot.displayName = resolved
            }
            snapshots[id] = snapshot
        }
        let errors = providerErrors.filter { isProviderEnabled($0.key) }
        // Error-only providers (no last-good snapshot) carry no display name anywhere else in the
        // record, so resolve theirs here — same boundary rule as the card titles above.
        var names: [String: String] = [:]
        for id in errors.keys where snapshots[id] == nil {
            names[id] = resolveDisplayName?(id) ?? registry.provider(id: id)?.displayName ?? id
        }
        // The connect-prompt flavor travels with the errors it describes, so a companion app can
        // render those entries neutrally instead of as warnings.
        let connectPrompts = providerConnectPrompts.filter { errors.keys.contains($0) }
        return DeviceSnapshotDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
            snapshots: snapshots,
            providerErrors: errors,
            providerNames: names.isEmpty ? nil : names,
            providerConnectPrompts: connectPrompts.isEmpty ? nil : connectPrompts
        )
    }

    /// Rebuild now, unless a batch pass is in flight — then via a short debounce so a burst of
    /// provider completions costs one rebuild while a fast provider still publishes promptly
    /// instead of waiting out the batch's slowest card. Only the refresh paths route through this;
    /// user-driven changes (enablement, peer documents) rebuild immediately.
    private func requestSnapshotRebuild() {
        guard snapshotRebuildDeferrals > 0 else {
            rebuildRenderedSnapshots()
            return
        }
        pendingSnapshotRebuild = true
        guard coalescedRebuildTask == nil else { return }
        coalescedRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.coalescedRebuildTask = nil
            self.flushPendingSnapshotWork()
        }
    }

    /// Publish pending refresh results now: one rendered rebuild plus one cache persist. Runs from
    /// the mid-batch debounce, the batch end, and app termination — a quit mid-batch must not drop
    /// completed providers' snapshots on the floor.
    func flushPendingSnapshotWork() {
        if pendingSnapshotRebuild {
            pendingSnapshotRebuild = false
            rebuildRenderedSnapshots()
        }
        cache.persistPending()
    }

    private func rebuildRenderedSnapshots() {
        guard !peerHistoryDocuments.isEmpty else {
            snapshots = localSnapshots
            remoteOnlySpend = []
            return
        }
        let renderDate = now()
        let enabledDescriptors = registry.historyDescriptorsByProvider.reduce(
            into: [String: UsageHistoryDescriptor]()
        ) { result, entry in
            if isProviderEnabled(entry.key) { result[entry.key] = entry.value }
        }
        // Match peers by account identity, not card id — the same account can be the default card
        // on one Mac and an extra account card on another. Whatever matches no local card at all
        // becomes a Total Spend-only remote entry below.
        let remapped = PeerHistoryRemapper.remap(
            documents: peerHistoryDocuments,
            localCardIDs: Set(registry.providers.map(\.id)),
            localIdentityByCardID: providerIdentityKeys
        )
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: localSnapshots,
            peerHistories: remapped.histories,
            descriptors: enabledDescriptors,
            now: renderDate
        )
        remoteOnlySpend = Self.renderRemoteOnlySpend(
            remapped.remoteOnly,
            registry: registry,
            enabledDescriptors: enabledDescriptors,
            now: renderDate
        )
        var rendered = localSnapshots
        for (providerID, history) in merged {
            guard let descriptor = registry.historyDescriptorsByProvider[providerID],
                  let provider = registry.provider(id: providerID)
            else { continue }
            let local = localSnapshots[providerID] ?? ProviderSnapshot(
                providerID: providerID,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: peerHistoryDocuments.map(\.updatedAt).max() ?? renderDate
            )
            rendered[providerID] = UsageHistorySnapshotRenderer.render(
                local: local,
                history: history,
                descriptor: descriptor,
                now: renderDate
            )
        }
        snapshots = rendered
    }

    /// Synthesize Total Spend entries for accounts that exist only on other Macs: a pseudo provider
    /// (family icon, "Claude · Mac mini" name) plus a snapshot carrying the standard spend-tile
    /// lines, rendered from the merged remote history by the same renderer real cards use.
    private static func renderRemoteOnlySpend(
        _ remoteOnly: [PeerHistoryRemapper.RemoteOnlyHistory],
        registry: WidgetRegistry,
        enabledDescriptors: [String: UsageHistoryDescriptor],
        now: Date
    ) -> [(provider: Provider, snapshot: ProviderSnapshot)] {
        remoteOnly.compactMap { entry in
            // Scoped account cards are the complete local family when no default-home login exists,
            // so the bare provider may be absent. Any ENABLED sibling carries the same icon and
            // history rendering metadata needed for a remote-only Total Spend slice. If the whole
            // family is disabled, its peer-only spend stays out of Total Spend too.
            guard let familyProvider = registry.providers.first(where: {
                let isFamily = ProviderAccountID.family(of: $0.id) == entry.family
                return isFamily && enabledDescriptors[$0.id] != nil
            }),
                  let descriptor = enabledDescriptors[familyProvider.id]
            else { return nil }
            let history = UsageHistoryAggregator.mergeHistories(entry.histories, now: now)
            guard !history.series.daily.isEmpty else { return nil }

            // The slice is named by the account's identity-derived card id ("claude@ab12cd34") —
            // unique per account, and the exact id the account's card gets the day it's signed in
            // here (and the id the CLI/API answer to on the Mac that has it). Which Mac the spend
            // came from is irrelevant to the total, so it's not part of the name. The pseudo
            // provider id stays distinct from real card ids so a slice can never collide with a
            // live card.
            let provider = Provider(
                id: "\(entry.family)@peer-\(ProviderAccountID.hash8(entry.identityKey))",
                displayName: entry.cardID,
                icon: familyProvider.icon
            )
            let empty = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: now
            )
            let snapshot = UsageHistorySnapshotRenderer.render(
                local: empty,
                history: history,
                descriptor: descriptor,
                now: now
            )
            return (provider, snapshot)
        }
    }

    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }

    /// The provider's current refresh error when NONE of the card's placed rows can show last-good
    /// data — a provider that has never refreshed successfully (a login awaiting Keychain approval,
    /// a fresh install that isn't signed in). The dashboard then replaces the card's empty "No data"
    /// rows with the error prompt itself. While any placed row still shows stale data this stays
    /// `nil`: the rows keep it on screen and the header triangle carries the error instead.
    ///
    /// `placedDescriptors` is the card's own row list (placed and applicable) — the check must
    /// mirror exactly what the card renders. Judging by the whole registry instead would let a line
    /// belonging only to a HIDDEN metric (a cached spend line while just Session is enabled) keep a
    /// visible wall of "No data" rows under an unexplained triangle — exactly the state this
    /// accessor exists to replace. Error badges and row-less status/note lines resolve to no placed
    /// row, so they never count as data.
    func emptyStateError(for providerID: String, placedDescriptors: [WidgetDescriptor]) -> String? {
        guard let message = providerErrors[providerID] else { return nil }
        let hasVisibleData = placedDescriptors.contains { descriptor in
            descriptor.providerID == providerID && data(for: descriptor).hasData
        }
        return hasVisibleData ? nil : message
    }

    /// A soft, non-blocking notice from the provider's latest *successful* snapshot (e.g. Claude's
    /// "Re-login for live usage" when the login lacks the `user:profile` scope). `nil` when there's no
    /// warning. After a *failed* refresh the store keeps the last good snapshot (so this warning can
    /// linger) while setting `providerErrors` — use `headerNotice(for:)` for the rendered triangle so a
    /// current hard error isn't masked by a stale soft warning.
    func warningMessage(for providerID: String) -> String? {
        snapshots[providerID]?.warning
    }

    /// The provider header's amber-triangle notice: a hard refresh error takes precedence over a stale
    /// soft warning from the last successful snapshot. After a failed refresh the store keeps the last
    /// good snapshot (so `warningMessage` still returns its warning) while `errorMessage` holds the
    /// current failure — the error must win, or a stale "Re-login for live usage" warning would hide a
    /// real "Token expired" failure. When there's no error, the soft warning (if any) shows.
    func headerNotice(for providerID: String) -> String? {
        errorMessage(for: providerID) ?? warningMessage(for: providerID)
    }

    /// What the user can do about `headerNotice(for:)`, which decides whether the header's triangle is a
    /// refresh button. Follows the same precedence: a hard refresh error is always something a manual
    /// retry can move (that retry is the one gesture allowed to raise a Keychain prompt), so it reports
    /// `.refresh` even when the last successful snapshot's soft warning said `.wait`. Otherwise the
    /// warning speaks for itself — Claude's rate-limit notice says manual refreshes make it worse, and
    /// must not be handed a refresh button.
    func headerNoticeAction(for providerID: String) -> ProviderSnapshot.WarningAction {
        if errorMessage(for: providerID) != nil { return .refresh }
        return snapshots[providerID]?.resolvedWarningAction ?? .refresh
    }

    /// Whether the notice `headerNotice(for:)` (or `emptyStateError(for:)`) returns is the neutral
    /// connect prompt: a credential exists on the machine but hasn't been loaded into this process.
    /// The dashboard then shows a Connect affordance — nothing is broken, so no amber triangle.
    /// Follows `headerNotice`'s precedence: with a current refresh error the error's flavor speaks;
    /// otherwise the last successful snapshot's soft warning does.
    func noticeIsConnectPrompt(for providerID: String) -> Bool {
        if errorMessage(for: providerID) != nil {
            return providerConnectPrompts.contains(providerID)
        }
        return snapshots[providerID]?.warningIsConnectPrompt ?? false
    }

    /// A snapshot that carries only error lines is a failed refresh; its message comes from the badge.
    private static func errorMessage(in snapshot: ProviderSnapshot) -> String? {
        guard !snapshot.lines.isEmpty, snapshot.lines.allSatisfy(\.isError) else { return nil }
        if case .badge(_, let text, _, _) = snapshot.lines[0] { return text }
        return "Refresh failed"
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // No real metric line backs this placed tile, so the sample's numbers are placeholders.
            // Flag it as no-data; the tile renders "No data" instead of inventing usage.
            result = descriptor.sample
            result.hasData = false
        }

        // Single global choke point: dashboard/share rows and menu-bar values all funnel through here,
        // so stamping the mode once makes them follow the global setting. Inert for unbounded rows
        // (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = alwaysShowPacing
        return result
    }

    /// Whether a descriptor represents a real capability for the provider's current account type.
    /// Providers that do not publish account-aware applicability keep the legacy all-applicable
    /// behavior. This is intentionally separate from `data(for:)`: an applicable metric can still
    /// have no data after a partial response, and should continue to render that honest state.
    func isMetricApplicable(_ descriptor: WidgetDescriptor) -> Bool {
        snapshots[descriptor.providerID]?.applicableMetricIDs?.contains(descriptor.id) ?? true
    }

    /// The plan label for a provider's latest snapshot. `nil` until a snapshot exists or when the
    /// provider doesn't expose a plan. Provider section headers render this beside the provider name.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// How long a displayed snapshot may age before the header calls it out. A healthy provider's
    /// snapshot resets to ~0 on every successful pass and only brushes one interval just before the next
    /// one, so the threshold sits at two intervals: it fires only when a refresh has actually been missed
    /// — a refresh loop that keeps failing, or a long-suspended background timer — never on the normal
    /// per-cycle aging, which would flicker a hint on healthy providers.
    static let stalenessThreshold = RefreshSetting.interval * 2

    /// A compact "Outdated" hint for the provider's on-screen snapshot, surfaced only once that snapshot
    /// has aged past `stalenessThreshold`; `nil` while the data is still current (the common case), so the
    /// header stays clean until staleness is real. The label is short on purpose — a long plan name plus a
    /// full "Updated 3h ago" string would overflow the header — so the precise age rides in the tooltip.
    /// This is the visible counterpart to the silent fossilized-cache problem (#582): a failing-refresh
    /// loop keeps the last good plan/limits on screen, and without this nothing told the user that data was
    /// stale. Reads the store's injected clock, which tests pin to a fixed value.
    func stalenessHint(for providerID: String) -> StalenessHint? {
        guard let refreshedAt = snapshots[providerID]?.refreshedAt else { return nil }
        let age = now().timeIntervalSince(refreshedAt)
        guard age >= Self.stalenessThreshold, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return StalenessHint(label: "Outdated", tooltip: "Last updated \(duration) ago")
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _):
            // A percent meter is a bounded 0...100 domain; sanitize an out-of-range sample (a provider
            // reporting a negative or >100 utilization) here, at the single construction choke point
            // every provider funnels through, so no surface — headline, flip tooltip, menu bar — can
            // render "-5%" or "105%". For percent the limit is always 100, so clamping `used` also
            // keeps the meter's spent verdict intact (>=100 still reads "Limit reached"). Non-percent
            // meters keep their raw `used`: a dollar/count overage (used > limit) is real and is
            // conveyed by the meter's spent state rather than hidden.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
            // Descriptor opt-in (session-window meters read "Not started" when unused); the fresh
            // `.progress` result doesn't start from the sample, so carry the flag explicitly.
            result.isSessionWindow = descriptor.sample.isSessionWindow
            return result
        case .text:
            // Text lines carry provider notices for the local API; no dashboard descriptor consumes
            // them. Numeric widgets use typed progress/values lines and must never parse display text.
            return nil
        case .values(_, let values, _, let expiriesAt, let unknownModels, let modelBreakdown):
            // The number is carried raw — no regex re-parse. Presentation (title, icon, selection,
            // trailing word) comes from the descriptor's sample; the live numbers come from the line.
            var data = descriptor.sample
            data.values = values
            // A `.values` line is unbounded by definition (see `MetricLine`), so it never renders as a
            // meter even when the descriptor template carries a placeholder limit — e.g. Claude's
            // `claude.extra` is `boundedDollars` for its capped `.progress` case but feeds an uncapped
            // `.values` row when there's no monthly cap.
            data.limit = nil
            // Optional expiry instants (Codex rate-limit-reset credits): surfaced in the row's hover
            // tooltip (see `expiryTooltip`), with the row re-rendering on the clock tick so they stay live.
            data.expiriesAt = expiriesAt
            // Unknown-model names (Cursor spend tiles): drive the label warning triangle whose hover lists
            // the models this period used that the pricing manifest can't price, so the cost is incomplete.
            data.unknownModels = unknownModels
            data.modelBreakdown = modelBreakdown
            // A tile whose selection finds no value (e.g. a cost-only tile on a day the scanner couldn't
            // price) has nothing real to show — render "No data" rather than a misleading $0.00 / 0.
            data.hasData = !data.selectedValues.isEmpty
            // The ⓘ is data-driven: it shows when a *shown* value is locally estimated (a spend row's
            // dollars) and stays off for a measured one (its tokens), so the tokens-only tile reads clean.
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.localEstimateNote
                : descriptor.sample.infoNote
            return data
        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data
        case .chart(_, let points, let note):
            // Presentation (title, icon) from the sample; the live per-day points from the line. No
            // points means the source was read but had no usable day — render "No data", not an empty
            // axis (and so descriptor template data never leaks onto the dashboard).
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

}
