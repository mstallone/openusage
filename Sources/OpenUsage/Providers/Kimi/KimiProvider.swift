import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi",
        icon: .providerMark("kimi"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://www.kimi.com/code/console"),
            ProviderLink(label: "Usage", url: "https://www.kimi.com/membership/subscription")
        ]
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let refreshLock: any KimiRefreshLocking
    let now: @Sendable () -> Date

    /// Coalesces an access-token rotation if a manual and scheduled refresh overlap. Kimi rotates the
    /// refresh token too, so two in-process refreshes must never spend the same token concurrently.
    private var tokenRefreshTask: Task<KimiAuth, Error>?

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        refreshLock: any KimiRefreshLocking = KimiOAuthRefreshLock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.refreshLock = refreshLock
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: "kimi.session",
                provider: provider,
                title: "Five-Hour Usage",
                metricLabel: "Five-Hour Usage",
                isSessionWindow: true
            )
            .exportingLimit("session", unit: "percent"),
            .percent(
                id: "kimi.weekly",
                provider: provider,
                title: "Weekly Usage",
                metricLabel: "Weekly Usage"
            )
            .exportingLimit("weekly", unit: "percent"),
            .values(
                id: "kimi.extraBalance",
                provider: provider,
                title: "Extra Usage Balance",
                metricLabel: "Extra Usage Balance",
                valueWord: "left"
            ),
            .boundedDollars(
                id: "kimi.extraMonthly",
                provider: provider,
                title: "Monthly Extra Usage",
                metricLabel: "Monthly Extra Usage",
                limit: 0,
                valueWord: "spent"
            )
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Exactly the same credential loader and usability checks `refresh()` starts with; no network.
        await loadOffMainActor { [authStore] in authStore.hasUsableCredentials() }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let initial = try await loadOffMainActor { [authStore] in try authStore.loadAuth() }
            let auth = try await freshAuth(initial)
            var response = try await usageClient.fetchUsage(
                accessToken: auth.token.accessToken,
                url: auth.usageURL
            )

            // Kimi Code may have rotated the file between our load and request. On 401, re-read the
            // exact source once and retry only when another process supplied a different token.
            if response.statusCode == 401 {
                let latest = try await loadOffMainActor { [authStore] in try authStore.reload(auth) }
                guard latest.token.accessToken != auth.token.accessToken else {
                    throw KimiAuthError.sessionExpired
                }
                let retryAuth = try await freshAuth(latest)
                response = try await usageClient.fetchUsage(
                    accessToken: retryAuth.token.accessToken,
                    url: retryAuth.usageURL
                )
            }

            switch response.statusCode {
            case 200..<300:
                let lines = try KimiUsageMapper.map(response.body, now: now())
                return ProviderSnapshot.make(
                    provider: provider,
                    plan: nil,
                    lines: lines,
                    refreshedAt: now()
                )
            case 401:
                throw KimiAuthError.sessionExpired
            case 404:
                throw KimiUsageError.usageUnavailable
            default:
                throw KimiUsageError.requestFailed(response.statusCode)
            }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func freshAuth(_ initial: KimiAuth) async throws -> KimiAuth {
        guard authStore.needsRefresh(initial.token) else { return initial }
        if let tokenRefreshTask {
            return try await tokenRefreshTask.value
        }

        let authStore = self.authStore
        let usageClient = self.usageClient
        let refreshLock = self.refreshLock
        let task = Task.detached(priority: .utility) {
            let lease = try await refreshLock.acquire(
                homeDirectory: initial.homeDirectory,
                credentialName: initial.credentialName
            )
            do {
                // Re-read after acquiring Kimi Code's cross-process lock. If the CLI already rotated
                // the credential, use the newer file and skip another refresh request.
                let current = try authStore.reload(initial)
                if !authStore.needsRefresh(current.token) {
                    await lease.release()
                    return current
                }
                guard !current.token.refreshToken
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw KimiAuthError.sessionExpired
                }
                let response = try await usageClient.refreshToken(
                    current.token.refreshToken,
                    url: current.refreshURL
                )
                let refreshed = current.replacing(token: authStore.refreshedToken(from: response))
                try authStore.save(refreshed)
                await lease.release()
                return refreshed
            } catch {
                await lease.release()
                throw error
            }
        }
        tokenRefreshTask = task
        defer { tokenRefreshTask = nil }
        return try await task.value
    }
}
