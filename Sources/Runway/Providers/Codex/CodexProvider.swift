import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    /// The default card and every extra account card use identical machinery; only their stable id,
    /// derived display name, credential scope, and log roots differ.
    static func makeProvider(id: String = "codex", displayName: String = "Codex") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("codex"),
            links: [
                .init(label: "Status", url: "https://status.openai.com/"),
                .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
            ]
        )
    }

    let provider: Provider

    let authStore: CodexAuthStore
    let usageClient: CodexUsageClient
    let logUsageScanner: CodexLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    /// Pi names only the provider family in its logs. `nil` keeps those account-ambiguous entries
    /// off this card; the current default-source holder receives the family slice under `codex`.
    let piUsageCardID: String?

    init(
        provider: Provider = CodexProvider.makeProvider(),
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        logUsageScanner: CodexLogUsageScanner = CodexLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = ModelPricingStore.livePricing,
        piUsageCardID: String? = "codex"
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
        self.piUsageCardID = piUsageCardID
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            // Model-specific Spark limits (GPT-5.3-Codex-Spark), parsed from `additional_rate_limits`.
            // Declared right after Weekly so they group with the core rate-limit meters; seeded On
            // Demand (below the caret) and unpinned in `DefaultLayout`.
            .percent(id: "\(provider.id).spark", provider: provider, title: "Spark")
                .exportingLimit("spark", unit: "percent"),
            .percent(id: "\(provider.id).sparkWeekly", provider: provider, title: "Spark Weekly")
                .exportingLimit("sparkWeekly", unit: "percent"),
            .combined(id: "\(provider.id).credits", provider: provider, title: "Extra Usage", metricLabel: "Credits")
                .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
                .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "\(provider.id).rateLimitResets", provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets", traySuffix: "resets", showsResetExpiries: true)
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available")),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: auth.json candidates first, keychain as the fallback. Only a
        // usable access token counts (see `hasUsableAccessToken`) — an API-key-only auth.json can't
        // serve the usage API, so seeding it on would just show an error row. A protected keyring
        // item counts too: it is a real login even though only a manual refresh may ask the user to
        // approve reading it.
        let fileCandidates = authStore.loadAuthCandidates()
        if fileCandidates.contains(where: \.hasUsableAccessToken) {
            return true
        }
        switch await loadOffMainActor({ [authStore] in authStore.loadKeychainCredentials() }) {
        case .state(let state):
            return state.hasUsableAccessToken
        case .connectRequired, .permissionRequired, .unreadable:
            // Both mean an item may well be there and Runway simply could not read it. Reporting
            // "no credential" would hide the provider on first run over an access problem.
            return true
        case .none:
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        let fileCandidates = authStore.loadAuthCandidates()
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            do {
                return try await probe(authState: candidate)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        // A manual refresh may raise the Keychain approval prompt (once, for Runway itself);
        // automatic refreshes stay prompt-free.
        let allowInteraction = ProviderRefreshContext.isManual
        switch await loadOffMainActor({ [authStore] in
            authStore.loadKeychainCredentials(allowKeychainInteraction: allowInteraction)
        }) {
        case .state(let keychainCandidate):
            do {
                return try await probe(authState: keychainCandidate)
            } catch let error as CodexAuthError where error == .loginRenewalRequired {
                // Keyring logins degrade exactly like file logins: local tiles under the notice.
                AppLog.info(LogTag.auth("codex"), "login needs renewal; serving local usage with a renewal notice")
                return await localUsageSnapshot(
                    mapped: CodexMappedUsage(plan: nil, lines: []),
                    warning: error.localizedDescription
                )
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .connectRequired:
            // The keyring likely holds the freshest rotated credential (it is Codex CLI's source of
            // truth in keyring mode), so loading it is the actionable step — surface it over a
            // stale file candidate's token error. The local spend tiles are still trustworthy, so
            // this rides as a header notice; connect-flavored, because nothing was denied.
            AppLog.info(LogTag.auth("codex"), "keyring secret not loaded this process; serving local usage with a connect prompt")
            return await localUsageSnapshot(
                mapped: CodexMappedUsage(plan: nil, lines: []),
                warning: CodexAuthError.keychainConnectRequired.localizedDescription,
                warningIsConnectPrompt: true
            )
        case .permissionRequired:
            // A real denial from an attempted manual read: approving it is the actionable fix.
            AppLog.info(LogTag.auth("codex"), "keyring approval was declined; serving local usage with a permission notice")
            return await localUsageSnapshot(
                mapped: CodexMappedUsage(plan: nil, lines: []),
                warning: CodexAuthError.keychainPermissionRequired.localizedDescription
            )
        case .unreadable:
            // Approval cannot fix a locked keychain or a failing securityd, so don't ask for it.
            // The local tiles survive the same way they do for a pending approval.
            AppLog.error(LogTag.auth("codex"), "keyring item could not be read; serving local usage with an unreadable-keychain notice")
            return await localUsageSnapshot(
                mapped: CodexMappedUsage(plan: nil, lines: []),
                warning: CodexAuthError.credentialStoreUnreadable.localizedDescription
            )
        case .none:
            break
        }

        if let lastFallbackError {
            // A lapsed login degrades to the local spend tiles under a renewal notice — the data is
            // still trustworthy and the fix belongs to the `codex` CLI — while other failures stay
            // hard error cards.
            if let authError = lastFallbackError as? CodexAuthError, authError == .loginRenewalRequired {
                AppLog.info(LogTag.auth("codex"), "login needs renewal; serving local usage with a renewal notice")
                return await localUsageSnapshot(
                    mapped: CodexMappedUsage(plan: nil, lines: []),
                    warning: authError.localizedDescription
                )
            }
            return ProviderSnapshot.error(provider: provider, error: lastFallbackError)
        }
        return ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
    }

    private func probe(authState initialState: CodexAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth) {
            // The `codex` CLI may have rotated the token on disk since we loaded it. Re-read the live
            // credential and adopt its (newer) access token. Runway itself never refreshes: the CLI
            // owns rotation, and a second rotator trips OpenAI's `refresh_token_reused` reuse
            // detection (issue #516) — the same failure class the Claude read-only change closed.
            if let live = authStore.reload(authState),
               let liveToken = live.auth.tokens?.accessToken, !liveToken.isEmpty {
                authState = live
                accessToken = liveToken
            }
        }

        // An expired stamp means the call below is doomed; skip the network round trip. Renewal
        // belongs to the `codex` CLI.
        if authStore.isExpired(authState.auth) {
            AppLog.info(LogTag.auth("codex"), "access token expired; renewal belongs to Codex")
            throw CodexAuthError.loginRenewalRequired
        }

        let response = try await fetchUsage(accessToken: accessToken, accountID: authState.auth.tokens?.accountID)
        // A successful exact keyring candidate can now safely bind its home for the next launch's
        // attributes-only discovery pass.
        _ = authStore.recordSelectedIdentity(authState)
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let resetCredits = await fetchResetCreditsBestEffort(
            accessToken: currentToken,
            accountID: authState.auth.tokens?.accountID
        )
        let mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())
        return await localUsageSnapshot(mapped: mapped, warning: nil)
    }

    /// Assembles the published snapshot from whatever live usage is available plus the always-local
    /// spend tiles and trend (scanned from the Codex CLI's session rollouts and pi's logs).
    private func localUsageSnapshot(
        mapped initialMapped: CodexMappedUsage,
        warning: String?,
        warningIsConnectPrompt: Bool = false
    ) async -> ProviderSnapshot {
        var mapped = initialMapped
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan: LogUsageScan?
        if let piUsageCardID {
            piScan = await PiUsageScanner.shared.scan(
                cardID: piUsageCardID,
                now: now(),
                pricing: pricing
            )
        } else {
            piScan = nil
        }
        var usageHistory: ProviderUsageHistory?
        // Cancellation can land between the native and pi scans. Treat the pair as one unit so a
        // partial result cannot replace the last-good combined history in WidgetDataStore.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Codex logs (estimated)"
                : "From your Codex logs and pi (estimated)"
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
            warningIsConnectPrompt: warningIsConnectPrompt
        )
    }

    /// Fetches the on-demand reset-credit balance (and per-credit expiry) without ever failing the
    /// refresh: this is supplementary to the usage metrics, so a network error, timeout, or non-2xx just
    /// yields `nil` and the mapper falls back to the count embedded in the usage body. Logged, not thrown —
    /// the user still gets Session/Weekly/Credits even if this endpoint is down.
    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch usage with the token exactly as Codex stored it. Runway is a read-only consumer of
    /// Codex's credentials: it never calls the OAuth token endpoint and never writes `auth.json` or
    /// the keyring item — so a 401/403 means the login lapsed and only the `codex` CLI can renew it.
    private func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(accessToken: accessToken, accountID: accountID)
        } catch {
            throw CodexUsageError.connectionFailed
        }
        if ProviderAuthRetry.isAuthFailure(response) {
            AppLog.warn(LogTag.auth("codex"), "unauthorized (\(response.statusCode)); renewal belongs to Codex")
            throw CodexAuthError.loginRenewalRequired
        }
        return response
    }
}
