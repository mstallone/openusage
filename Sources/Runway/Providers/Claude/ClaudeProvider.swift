import CryptoKit
import Foundation

@MainActor
final class ClaudeProvider: ProviderRuntime {
    /// The default card's identity. Extra account cards inject their own `Provider` with an
    /// `@`-suffixed id and an account-derived display name; everything else about the runtime is
    /// identical.
    static func makeProvider(id: String = "claude", displayName: String = "Claude") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    let provider: Provider

    let authStore: ClaudeAuthStore
    let usageClient: ClaudeUsageClient
    let logUsageScanner: ClaudeLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// Last successful live-usage result and a rate-limit cooldown, carried across refreshes (the provider
    /// is a long-lived singleton). `/api/oauth/usage` rate-limits aggressively, so on a 429 we serve the
    /// last-good bars with a staleness note instead of blanking the dashboard, and skip the live call
    /// entirely until the cooldown expires so we don't keep hammering an endpoint that's already limiting
    /// us.
    private var cachedCredentialFingerprint: Data?
    private var lastGoodUsage: ClaudeMappedUsage?
    private var rateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    init(
        provider: Provider = ClaudeProvider.makeProvider(),
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        logUsageScanner: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = ModelPricingStore.livePricing
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent"),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Claude usage history (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Detection validates local files, environment, Keychain attributes, and Desktop material with
        // Keychain interaction forbidden. It can never raise a launch-time password dialog.
        await loadOffMainActor { [authStore] in authStore.hasCredentialFootprint() }
    }

    func refresh() async -> ProviderSnapshot {
        await refresh(forceDesktopFallback: false, previousFallbackError: nil)
    }

    private func refresh(
        forceDesktopFallback: Bool,
        previousFallbackError: ClaudeAuthError?
    ) async -> ProviderSnapshot {
        let allowInteraction = ProviderRefreshContext.isManual
        let credentialLoad = await loadOffMainActor { [authStore] in
            authStore.loadCredentialSet(
                allowKeychainInteraction: allowInteraction,
                allowDesktopInteraction: allowInteraction,
                forceDesktopFallback: forceDesktopFallback
            )
        }
        let storedCandidates = credentialLoad.candidates
        let candidates = storedCandidates.filter {
            $0.hasUsableAccessToken && (!forceDesktopFallback || $0.source == .desktop)
        }
        // Keychain is Claude Code's source of truth on macOS. If its item cannot be read — or its
        // existence cannot be determined — never publish a lower-priority file/Desktop/environment
        // login that may be stale or belong to another account. Automatic refresh remains
        // non-interactive; a manual refresh performs the explicit in-process approval read.
        switch credentialLoad.keychainAccessStatus {
        case .permissionRequired:
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.codePermissionRequired)
        case .unavailable:
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.codeCredentialsUnavailable)
        case .resolved:
            break
        }
        if forceDesktopFallback {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale, .invalid, .notFound:
                if let previousFallbackError {
                    return await failureSnapshot(
                        previousFallbackError,
                        renewalState: storedCandidates.first(where: \.hasUsableAccessToken)
                    )
                }
            case .notChecked, .available:
                break
            }
        }
        let hasLiveUsageCandidate = candidates.contains {
            authStore.liveUsageAvailability($0) == .available
        }
        let desktopFallbackWarning: String? = if !hasLiveUsageCandidate {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                ClaudeAuthError.desktopPermissionRequired.localizedDescription
            case .stale:
                ClaudeAuthError.desktopTokenExpired.localizedDescription
            case .invalid:
                ClaudeAuthError.desktopCredentialsUnavailable.localizedDescription
            case .notChecked, .notFound, .available:
                nil
            }
        } else {
            nil
        }
        guard !candidates.isEmpty else {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale:
                // A Desktop-only login whose cached token lapsed: same renewal treatment as a lapsed
                // CLI login (Desktop's loader returns no credential state for a stale entry).
                return await failureSnapshot(.desktopTokenExpired, renewalState: nil)
            case .invalid:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopCredentialsUnavailable)
            case .notChecked, .notFound, .available:
                break
            }
            AppLog.info(LogTag.auth("claude"), "no access token, not logged in")
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.notLoggedIn)
        }

        // Per-source diagnostics at info level (token-free: source kind + expired boolean) so a
        // "token expired" report is diagnosable from a default log without a debug build.
        let sources = candidates.map { $0.diagnosticsLabel(now: now()) }.joined(separator: ", ")
        AppLog.info(LogTag.plugin("claude"), "refresh start (\(candidates.count) source\(candidates.count == 1 ? "" : "s"): \(sources))")
        let start = Date()
        // Probe each credential source in keychain-before-file order. An auth-expiry failure on one source (a
        // stale/locked-out token that an external `claude` re-login replaced in another source) falls
        // through to the next rather than failing the whole refresh; any non-auth error (rate limit,
        // request/transport failure) surfaces immediately so a real outage is never masked as a retry.
        var lastFallbackError: ClaudeAuthError?
        for state in candidates {
            // The environment token cannot read subscription usage. If a CLI login was rejected, try
            // Desktop before this spend-only fallback can turn the refresh into a false success.
            if !forceDesktopFallback,
               lastFallbackError != nil,
               credentialLoad.desktopStatus == .notChecked,
               authStore.liveUsageAvailability(state) == .inferenceOnlyToken
            {
                return await refresh(forceDesktopFallback: true, previousFallbackError: lastFallbackError)
            }
            do {
                let snapshot = try await probe(state: state, fallbackWarning: desktopFallbackWarning)
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                AppLog.warn(LogTag.auth("claude"), "\(state.source.label) failed (\(error)); falling back to next source if any")
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        if !forceDesktopFallback,
           lastFallbackError != nil,
           credentialLoad.desktopStatus == .notChecked
        {
            AppLog.info(LogTag.auth("claude"), "stored Claude login failed; trying Claude Desktop")
            return await refresh(forceDesktopFallback: true, previousFallbackError: lastFallbackError)
        }
        return await failureSnapshot(
            lastFallbackError ?? ClaudeAuthError.notLoggedIn,
            renewalState: candidates.first
        )
    }

    /// Terminal failure handling: a lapsed login (`isLoginRenewal`) degrades to the local spend tiles
    /// under a renewal notice — the data is still trustworthy and the fix belongs to the owning Claude
    /// app — while every other failure stays a hard error card. `renewalState` only feeds the plan
    /// badge; a stale Desktop-only login has none and still degrades.
    private func failureSnapshot(
        _ error: ClaudeAuthError,
        renewalState: ClaudeCredentialState?
    ) async -> ProviderSnapshot {
        guard error.isLoginRenewal else {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        AppLog.info(LogTag.auth("claude"), "login needs renewal; serving local usage with a renewal notice")
        let mapped = ClaudeMappedUsage(
            plan: renewalState.flatMap {
                ClaudeUsageMapper.formatPlan(
                    subscriptionType: $0.displayOAuth.subscriptionType,
                    rateLimitTier: $0.displayOAuth.rateLimitTier
                )
            },
            lines: []
        )
        return await localUsageSnapshot(mapped: mapped, warning: error.localizedDescription)
    }

    private func probe(
        state: ClaudeCredentialState,
        fallbackWarning: String?
    ) async throws -> ProviderSnapshot {
        var mapped = ClaudeMappedUsage(
            plan: ClaudeUsageMapper.formatPlan(
                subscriptionType: state.displayOAuth.subscriptionType,
                rateLimitTier: state.displayOAuth.rateLimitTier
            ),
            lines: []
        )

        var warning: String?
        // Everything below is a "fix this, then refresh" notice; only the rate-limited fetch overrides it.
        var warningAction = ProviderSnapshot.WarningAction.refresh
        switch authStore.liveUsageAvailability(state) {
        case .available:
            mapped = try await fetchLiveUsage(state: state)
            // A rate-limited fetch rides its "Updates blocked by Anthropic" notice on the mapped usage so
            // it reaches the header triangle even when the badge/note lines aren't in the user's layout.
            warning = mapped.warning
            warningAction = mapped.warningAction
        case .missingProfileScope:
            // The login authenticates for inference but lacks the `user:profile` scope the usage endpoint
            // needs (typically a `claude setup-token` token). Don't leave the session/weekly bars silently
            // blank — log it for diagnosis and surface a provider header warning (the amber triangle, like
            // Z.ai's "no coding plan" notice) telling the user a re-login restores them. The local-log
            // spend tiles below are unaffected and still load.
            AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: credential lacks the user:profile scope (inference-only token); re-login with `claude` to restore session/weekly limits")
            warning = ClaudeUsageMapper.missingProfileScopeWarning
        case .inferenceOnlyToken:
            // An explicit CLAUDE_CODE_OAUTH_TOKEN is inference-only by design; nothing to fetch and nothing
            // to nag about — the spend tiles still load below.
            break
        }
        if let fallbackWarning {
            // The Desktop-login notice: the user renews it, then refreshes — actionable.
            warning = fallbackWarning
            warningAction = .refresh
        }
        return await localUsageSnapshot(mapped: mapped, warning: warning, warningAction: warningAction)
    }

    /// Assembles the published snapshot from whatever live usage is available plus the always-local
    /// spend tiles and trend.
    private func localUsageSnapshot(
        mapped initialMapped: ClaudeMappedUsage,
        warning: String?,
        warningAction: ProviderSnapshot.WarningAction = .refresh
    ) async -> ProviderSnapshot {
        var mapped = initialMapped
        // Local spend tiles, scanned natively from Claude Code's session logs and priced through the
        // shared pricing store, merged with Claude usage that happened inside pi (attributed back here).
        // Both scans run on their scanner actors, off the main actor.
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan = await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
        var usageHistory: ProviderUsageHistory?
        // Cancellation can land between the native and pi scans. Treat the pair as one unit so a
        // partial result cannot replace the last-good combined history in WidgetDataStore.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Claude usage history (estimated)"
                : "From your Claude usage history and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning,
            warningAction: warningAction
        )
    }

    /// Fetch live usage with the token exactly as Claude stored it. Runway is a read-only consumer of
    /// Claude's credentials: it never calls the OAuth token endpoint and never writes a credential
    /// store. A second process rotating Claude's refresh token can trip the server's reuse detection
    /// and revoke the user's whole session — so a lapsed token is Claude Code's to renew, and Runway
    /// only reports that renewal is needed.
    private func fetchLiveUsage(state: ClaudeCredentialState) async throws -> ClaudeMappedUsage {
        activateLiveUsageCache(for: state.oauth)

        // Inside an active rate-limit cooldown, skip the live call and serve the last-good usage so a
        // constantly-limited endpoint doesn't blank the dashboard (and we don't pile on more 429s).
        if let until = rateLimitedUntil, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: state.displayOAuth, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        // An expired stamp means the call below is doomed; skip the network round trip.
        guard !authStore.isExpired(state.oauth) else {
            AppLog.info(LogTag.auth("claude"), "\(state.source.label) token expired; renewal belongs to Claude")
            throw renewalError(for: state)
        }

        let usageURL = try authStore.usageEndpoint()
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(
                accessToken: state.oauth.accessToken ?? "",
                usageURL: usageURL
            )
        } catch {
            throw ClaudeUsageError.connectionFailed
        }

        if ProviderAuthRetry.isAuthFailure(response) {
            AppLog.warn(LogTag.auth("claude"), "\(state.source.label) unauthorized (\(response.statusCode)); renewal belongs to Claude")
            throw renewalError(for: state)
        }

        // On a 429, start a cooldown (respecting Retry-After) and serve the last-good usage rather
        // than a bare badge.
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown)))
            AppLog.info(LogTag.plugin("claude"), "rate-limited (serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: state.displayOAuth, retryAfterSeconds: retryAfterSeconds)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: state.displayOAuth, now: now())
        lastGoodUsage = mapped
        rateLimitedUntil = nil
        return mapped
    }

    /// The renewal error for a lapsed credential, named after the app that owns it.
    private func renewalError(for state: ClaudeCredentialState) -> ClaudeAuthError {
        state.source == .desktop ? .desktopTokenExpired : .loginRenewalRequired
    }

    /// Last-good usage with an appended staleness note when we have it; otherwise the plain rate-limited
    /// badge (no successful fetch yet this run). `lastGoodUsage` only ever holds a clean `mapUsageResponse`
    /// result (never a rate-limited snapshot), so the note is never duplicated and no stale spend tiles
    /// ride along — `probe` appends those fresh after this returns.
    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        // The cached mapping's plan is from fetch time; the tier can change during a long cooldown,
        // so re-derive it from the credentials the caller just loaded.
        mapped.plan = ClaudeUsageMapper.formatPlan(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier
        )
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        // Last-good usage is a clean fetch, so its action is `.refresh`; the rate-limit notice replacing
        // its warning must carry `.wait` with it or the triangle stays clickable on stale bars.
        mapped.warningAction = .wait
        return mapped
    }

    /// Cache state belongs to the complete access + refresh credential pair. A login change therefore
    /// clears both last-good usage and cooldown, even when the two accounts share an access token.
    private func activateLiveUsageCache(for credentials: ClaudeOAuth) {
        let fingerprint = Self.credentialFingerprint(credentials)
        guard cachedCredentialFingerprint != fingerprint else { return }
        cachedCredentialFingerprint = fingerprint
        lastGoodUsage = nil
        rateLimitedUntil = nil
    }

    private static func credentialFingerprint(_ credentials: ClaudeOAuth) -> Data {
        let access = Data((credentials.accessToken ?? "").utf8)
        let refresh = Data((credentials.refreshToken ?? "").utf8)
        var pair = Data(SHA256.hash(data: access))
        pair.append(contentsOf: SHA256.hash(data: refresh))
        return Data(SHA256.hash(data: pair))
    }

}
