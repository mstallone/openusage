import Foundation

@MainActor
final class SakanaProvider: ProviderRuntime {
    let provider = Provider(
        id: "sakana",
        displayName: "Sakana Fugu",
        icon: .providerMark("sakana"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://console.sakana.ai/overview"),
            ProviderLink(label: "Usage", url: "https://console.sakana.ai/billing")
        ]
    )

    let authStore: SakanaAuthStore
    let usageClient: SakanaUsageClient
    let logUsageScanner: SakanaLogUsageScanner
    let now: @Sendable () -> Date
    private let localSourceNote =
        "From your Fugu Codex logs; estimated API-rate value, not billed spend (orchestration may be omitted)"

    init(
        authStore: SakanaAuthStore = SakanaAuthStore(),
        usageClient: SakanaUsageClient = SakanaUsageClient(),
        logUsageScanner: SakanaLogUsageScanner = SakanaLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: "sakana.session",
                provider: provider,
                title: "Five-Hour Usage",
                metricLabel: "Five-Hour Usage",
                isSessionWindow: true
            )
            .exportingLimit("session", unit: "percent"),
            .percent(
                id: "sakana.weekly",
                provider: provider,
                title: "Weekly Usage",
                metricLabel: "Weekly Usage"
            )
            .exportingLimit("weekly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: localSourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore, logUsageScanner] in
            authStore.hasBrowserSessionFootprint() || logUsageScanner.hasSakanaFootprint()
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        async let localScanTask = logUsageScanner.scan(now: refreshedAt)
        var mapped = SakanaMappedUsage(plan: nil, lines: [])
        var subscriptionError: Error?

        do {
            let allowInteraction = ProviderRefreshContext.isManual
            let session = try await loadOffMainActor { [authStore] in
                try authStore.loadSession(allowInteraction: allowInteraction)
            }
            let sessionResponse = try await usageClient.fetchSession(token: session.token)
            try SakanaUsageMapper.validateSession(sessionResponse, now: refreshedAt)
            let billingResponse = try await usageClient.fetchBilling(token: session.token)
            mapped = try SakanaUsageMapper.mapBilling(billingResponse)
        } catch {
            subscriptionError = error
        }

        var usageHistory: ProviderUsageHistory?
        if !Task.isCancelled, let scan = await localScanTask {
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series,
                to: &mapped.lines,
                now: refreshedAt,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: localSourceNote
            )
            SpendTileMapper.appendUsageTrend(
                scan.series,
                to: &mapped.lines,
                now: refreshedAt,
                note: localSourceNote
            )
        }

        // A deferred Safe Storage read is the neutral connect prompt, never a "meters unavailable"
        // warning: nothing is broken, the key just hasn't been loaded this process.
        let isConnectPrompt = subscriptionError as? SakanaAuthError == .connectRequired
        if let subscriptionError {
            guard !mapped.lines.isEmpty else {
                return isConnectPrompt
                    ? ProviderSnapshot.connectPrompt(provider: provider, error: subscriptionError)
                    : ProviderSnapshot.error(provider: provider, error: subscriptionError)
            }
            AppLog.warn(
                LogTag.plugin("sakana"),
                "subscription meters unavailable; showing local Fugu history: \(subscriptionError.localizedDescription)"
            )
        }
        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: subscriptionError.map {
                isConnectPrompt
                    ? $0.localizedDescription
                    : "Subscription meters unavailable: \($0.localizedDescription)"
            },
            warningIsConnectPrompt: isConnectPrompt
        )
    }
}
