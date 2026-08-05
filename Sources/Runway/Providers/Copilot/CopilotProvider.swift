import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// `UserDefaults` key caching the slug of the org whose billing carried Copilot credit usage, so
    /// steady-state refreshes make one billing call instead of re-probing every org.
    static let billingOrgDefaultsKey = "copilot.billingOrg"

    /// Above the store default: an org-managed account's billing fallback sequentially probes every
    /// seat org (up to 15s each), may repeat the list for a second local credential, and can finish
    /// with paginated enterprise discovery — ~90s per credential is a legitimate worst case, and the
    /// global default would cut off a usable second-credential result mid-probe.
    var refreshTimeout: TimeInterval { 360 }

    let provider = Provider(
        id: "copilot",
        displayName: "Copilot",
        icon: .providerMark("copilot"),
        links: [
            .init(label: "Status", url: "https://www.githubstatus.com/"),
            .init(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    let authStore: CopilotAuthStore
    let usageClient: CopilotUsageClient
    let orgBillingClient: CopilotOrgBillingClient
    let defaults: UserDefaults
    let now: @Sendable () -> Date

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        orgBillingClient: CopilotOrgBillingClient = CopilotOrgBillingClient(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.orgBillingClient = orgBillingClient
        self.defaults = defaults
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "copilot.premium", provider: provider, title: "Credits")
                .exportingLimit("premiumCredits", unit: "percent"),
            .values(id: "copilot.extra", provider: provider, title: "Extra Usage", selection: .kind(.count))
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(
                id: "copilot.orgCredits",
                provider: provider,
                title: "AI Credits Used",
                metricLabel: "Org Credits",
                selection: .labeled(.count, "credits"),
                subtitleValueLabels: ["included", "additional"]
            )
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits")),
            .values(
                id: "copilot.orgSpend",
                provider: provider,
                title: "Additional Spend",
                metricLabel: "Org Spend",
                selection: .kind(.dollars),
                valueWord: "spent"
            )
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars)),
            .badge(
                id: "copilot.orgManaged",
                provider: provider,
                title: "Organization Usage",
                pinnable: false
            ),
            .percent(id: "copilot.chat", provider: provider, title: "Chat")
                .exportingLimit("chat", unit: "percent"),
            .percent(id: "copilot.completions", provider: provider, title: "Completions")
                .exportingLimit("completions", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: editor config, gh config, or the gh keychain entry. A
        // protected keychain item counts — it is a real login even though only a manual refresh may
        // ask the user to approve reading it.
        await loadOffMainActor { [authStore] in authStore.loadCredentials() } != .none
    }

    func refresh() async -> ProviderSnapshot {
        // A manual refresh may raise the Keychain approval prompt (once, for Runway itself);
        // automatic refreshes stay prompt-free.
        let allowInteraction = ProviderRefreshContext.isManual
        let load = await loadOffMainActor { [authStore] in
            authStore.loadCredentials(allowKeychainInteraction: allowInteraction)
        }
        let token: CopilotToken
        switch load {
        case .token(let loaded):
            token = loaded
        case .connectRequired:
            // The login exists but hasn't been loaded this process — the neutral Connect
            // affordance, not a warning.
            return ProviderSnapshot.connectPrompt(provider: provider, error: CopilotAuthError.keychainConnectRequired)
        case .keychainPermissionRequired:
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.keychainPermissionRequired)
        case .unreadable:
            // Approval cannot fix a locked keychain or a failing securityd, so don't ask for it.
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.credentialStoreUnreadable)
        case .none:
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchUsage(token: token.value)

            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.tokenInvalid)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.requestFailed(response.statusCode))
            }

            let mapped = try CopilotUsageMapper.map(response)

            // An org-managed (token-based-billing) seat has no per-seat quota, so the real usage lives
            // in the org's billing. Look it up there — best-effort: an org admin sees organization-wide
            // credits and spend, while everyone else gets an explicit managed-account state. Gated on
            // the mapper's explicit flag, never on `lines` being empty (issue #839).
            var lines = mapped.lines
            if mapped.isOrgManagedSeat {
                // A second local token may belong to another GitHub account. It is safe for billing
                // only when Copilot named the seat org; otherwise `/user/orgs` must stay tied to the
                // same credential that produced this Copilot card.
                let billingTokens: [CopilotToken]
                // Set when the preferred GitHub CLI credential exists but needs a manual load, so a
                // failed billing lookup can name the real fix instead of blaming billing access.
                var billingKeychainError: CopilotAuthError?
                if mapped.organizationLogins.isEmpty {
                    billingTokens = [token]
                } else {
                    let candidates = await loadOffMainActor { [authStore] in
                        authStore.loadBillingTokenCandidates(
                            usageToken: token,
                            allowKeychainInteraction: allowInteraction
                        )
                    }
                    billingTokens = candidates.tokens
                    billingKeychainError = candidates.keychainError
                }
                switch await orgBillingLookup(
                    tokens: billingTokens,
                    seatOrgLogins: mapped.organizationLogins,
                    isEnterpriseSeat: mapped.isEnterpriseSeat
                ) {
                case .usage(let usageLines):
                    lines = usageLines
                case .empty(let usageLines, _):
                    // A month-start zero is self-correcting — any real usage under this login shows
                    // up in the org report on the next refresh — so an unverified zero renders
                    // without a warning; `enterpriseUnverified` still steers the credential
                    // aggregation above.
                    lines = usageLines
                case .managed:
                    // An unusable GitHub CLI credential is the likely reason billing could not
                    // be read; telling the user to obtain billing access would send them down the
                    // wrong path. Report which Keychain problem it actually was — a deferred read
                    // stays the neutral connect prompt.
                    if let billingKeychainError {
                        return billingKeychainError == .keychainConnectRequired
                            ? ProviderSnapshot.connectPrompt(provider: provider, error: billingKeychainError)
                            : ProviderSnapshot.error(provider: provider, error: billingKeychainError)
                    }
                    lines = [
                        .badge(
                            label: "Organization Usage",
                            text: "Managed by Your Organization",
                            subtitle: "You need organization billing access to view totals."
                        )
                    ]
                case .temporarilyUnavailable:
                    // A transient billing outage (rate limit, 5xx) must not overwrite good org
                    // numbers with an "unavailable" placeholder: failing the refresh keeps the
                    // previous snapshot on screen with the standard staleness/warning treatment.
                    return ProviderSnapshot.error(
                        provider: provider,
                        error: CopilotUsageError.orgBillingUnavailable
                    )
                }
            }

            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: lines,
                refreshedAt: now(),
                applicableMetricIDs: applicableMetricIDs(
                    for: lines,
                    isOrgManagedSeat: mapped.isOrgManagedSeat,
                    usesFreeTierQuotas: mapped.usesFreeTierQuotas
                )
            )
        } catch let error as CopilotUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.connectionFailed)
        }
    }

    private func applicableMetricIDs(
        for lines: [MetricLine],
        isOrgManagedSeat: Bool,
        usesFreeTierQuotas: Bool
    ) -> Set<String> {
        if isOrgManagedSeat {
            if lines.contains(where: { $0.label == "Organization Usage" }) {
                return ["copilot.orgManaged"]
            }
            return Set(lines.compactMap { line in
                switch line.label {
                case "Org Credits": "copilot.orgCredits"
                case "Org Spend": "copilot.orgSpend"
                default: nil
                }
            })
        }

        var metricIDs = Set(lines.compactMap { line in
            switch line.label {
            case "Credits": "copilot.premium"
            case "Extra Usage": "copilot.extra"
            case "Chat": "copilot.chat"
            case "Completions": "copilot.completions"
            default: nil
            }
        })
        if usesFreeTierQuotas {
            metricIDs.formUnion(["copilot.chat", "copilot.completions"])
        }
        return metricIDs
    }
}
