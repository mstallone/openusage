import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// `UserDefaults` key caching the slug of the org whose billing carried Copilot credit usage, so
    /// steady-state refreshes make one billing call instead of re-probing every org.
    static let billingOrgDefaultsKey = "copilot.billingOrg"

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
        // Same source as `refresh()`: editor config, gh config, or the gh keychain entry.
        await loadOffMainActor { [authStore] in authStore.loadToken() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        let token = await loadOffMainActor { [authStore] in authStore.loadToken() }
        guard let token else {
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
                if mapped.organizationLogins.isEmpty {
                    billingTokens = [token]
                } else {
                    billingTokens = await loadOffMainActor { [authStore] in
                        authStore.loadBillingTokenCandidates(usageToken: token)
                    }
                }
                switch await orgBillingLookup(
                    tokens: billingTokens,
                    seatOrgLogins: mapped.organizationLogins
                ) {
                case .usage(let usageLines), .empty(let usageLines):
                    lines = usageLines
                case .managed:
                    lines = [
                        .badge(
                            label: "Organization Usage",
                            text: "Managed by Your Organization",
                            subtitle: "Organization billing access is required to view totals."
                        )
                    ]
                case .temporarilyUnavailable:
                    lines = [
                        .badge(
                            label: "Organization Usage",
                            text: "Organization Usage Unavailable",
                            subtitle: "GitHub billing could not be reached. Try again later."
                        )
                    ]
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

    // MARK: - Org billing lookup

    private enum OrgBillingLookup {
        case usage([MetricLine])
        case empty([MetricLine])
        case managed
        case temporarilyUnavailable
    }

    private enum EnterpriseBillingLookup {
        case usage([MetricLine])
        case empty([MetricLine])
        case noAssociation
        case managed
        case temporarilyUnavailable
    }

    private enum OrgUsageLookup {
        case usage([MetricLine])
        case empty([MetricLine])
        case forbidden
        case inaccessible
        case notFound
    }

    /// Copilot billing lines for an org-managed seat. Organization billing is preferred; a 403 can
    /// mean the caller is an enterprise billing manager but not an org administrator, while a 404 can
    /// mean billing is consolidated. In either case GraphQL verifies the enterprise-to-seat-org
    /// association before the enterprise endpoint is queried.
    private func orgBillingLookup(
        tokens: [CopilotToken],
        seatOrgLogins: [String]
    ) async -> OrgBillingLookup {
        var sawTransientFailure = false
        var emptyCandidate: [MetricLine]?
        for (index, token) in tokens.enumerated() {
            if index > 0 {
                AppLog.info(LogTag.plugin("copilot"), "trying another local GitHub credential for billing")
            }
            switch await orgBillingLookup(token: token.value, seatOrgLogins: seatOrgLogins) {
            case .usage(let lines):
                return .usage(lines)
            case .empty(let lines):
                emptyCandidate = emptyCandidate ?? lines
            case .managed:
                continue
            case .temporarilyUnavailable:
                sawTransientFailure = true
            }
        }
        if let emptyCandidate, !sawTransientFailure {
            return .usage(emptyCandidate)
        }
        return sawTransientFailure ? .temporarilyUnavailable : .managed
    }

    private func orgBillingLookup(token: String, seatOrgLogins: [String]) async -> OrgBillingLookup {
        let associatedOrgKeys = Set(seatOrgLogins.map { $0.lowercased() })
        var shouldTryEnterprise = false
        var attemptedOrgKeys: Set<String> = []
        var unresolvedAssociatedOrgKeys: Set<String> = []
        var rememberedEmpty: (org: String, lines: [MetricLine])?
        if let cached = defaults.string(forKey: Self.billingOrgDefaultsKey) {
            let cachedKey = cached.lowercased()
            if !associatedOrgKeys.isEmpty && !associatedOrgKeys.contains(cachedKey) {
                // The Copilot account no longer associates this cached org with the seat.
                defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
            } else {
                do {
                    attemptedOrgKeys.insert(cachedKey)
                    switch try await orgUsageLookup(org: cached, token: token) {
                    case .usage(let lines):
                        return .usage(lines)
                    case .empty(let lines):
                        // Only observed Copilot usage makes an org definitive. Re-discover when that org
                        // is empty so another associated org or its consolidated enterprise can take over.
                        // Without a current seat association, the cache may belong to a previous account.
                        defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
                        if associatedOrgKeys.contains(cachedKey) {
                            rememberedEmpty = (cached, lines)
                            shouldTryEnterprise = true
                        }
                    case .forbidden:
                        // Enterprise billing managers do not necessarily administer the seat org, so
                        // org-level 403 does not rule out access through the enterprise endpoint.
                        defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
                        if associatedOrgKeys.contains(cachedKey) {
                            unresolvedAssociatedOrgKeys.insert(cachedKey)
                        }
                        shouldTryEnterprise = true
                    case .inaccessible:
                        // The remembered org no longer answers for this token (left the org or lost the
                        // billing role), so forget it and re-probe from scratch.
                        defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
                        if associatedOrgKeys.contains(cachedKey) {
                            unresolvedAssociatedOrgKeys.insert(cachedKey)
                        }
                    case .notFound:
                        // Consolidated enterprise billing can make the org endpoint unavailable.
                        defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
                        if associatedOrgKeys.contains(cachedKey) {
                            unresolvedAssociatedOrgKeys.insert(cachedKey)
                        }
                        shouldTryEnterprise = true
                    }
                } catch {
                    // Transient failure: log it and keep the cached org for the next refresh.
                    AppLog.warn(LogTag.plugin("copilot"), "org AI credit lookup failed for the remembered org: \(error.localizedDescription)")
                    return .temporarilyUnavailable
                }
            }
        }

        let orgs: [String]
        let emptyReportsAreAuthoritative: Bool
        if !seatOrgLogins.isEmpty {
            orgs = seatOrgLogins
            emptyReportsAreAuthoritative = true
        } else {
            do {
                let response = try await orgBillingClient.fetchUserOrgs(token: token)
                guard response.statusCode == 200 else {
                    // 403 here means the token lacks `read:org` (editor-plugin tokens can) — expected,
                    // not an error. Anything else is still worth a diagnostic, never a failed card.
                    AppLog.info(LogTag.plugin("copilot"), "org list HTTP \(response.statusCode); skipping org billing lookup")
                    if response.isGitHubRateLimited || response.statusCode >= 500 {
                        return .temporarilyUnavailable
                    }
                    return .managed
                }
                orgs = CopilotOrgBillingMapper.orgLogins(response)
                emptyReportsAreAuthoritative = false
            } catch {
                AppLog.warn(LogTag.plugin("copilot"), "org list fetch failed: \(error.localizedDescription)")
                return .temporarilyUnavailable
            }
        }

        var sawTransientFailure = false
        var emptyCandidate = rememberedEmpty
        for org in orgs {
            // A cached org was already fetched above, regardless of its response.
            if !attemptedOrgKeys.insert(org.lowercased()).inserted {
                continue
            }
            do {
                switch try await orgUsageLookup(org: org, token: token) {
                case .usage(let lines):
                    defaults.set(org, forKey: Self.billingOrgDefaultsKey)
                    return .usage(lines)
                case .empty(let lines):
                    // An associated org's empty report is only provisional: usage may be billed to its
                    // enterprise instead. A random billing-accessible membership is never authoritative.
                    if emptyReportsAreAuthoritative && emptyCandidate == nil {
                        emptyCandidate = (org, lines)
                        shouldTryEnterprise = true
                    }
                case .forbidden:
                    if emptyReportsAreAuthoritative {
                        unresolvedAssociatedOrgKeys.insert(org.lowercased())
                    }
                    shouldTryEnterprise = true
                case .inaccessible:
                    if emptyReportsAreAuthoritative {
                        unresolvedAssociatedOrgKeys.insert(org.lowercased())
                    }
                    continue
                case .notFound:
                    if emptyReportsAreAuthoritative {
                        unresolvedAssociatedOrgKeys.insert(org.lowercased())
                    }
                    shouldTryEnterprise = true
                }
            } catch {
                // One org's billing having an outage must not hide another org's usage — keep probing.
                sawTransientFailure = true
                AppLog.warn(LogTag.plugin("copilot"), "org AI credit usage failed for one org; trying the next: \(error.localizedDescription)")
            }
        }

        if shouldTryEnterprise, !seatOrgLogins.isEmpty {
            switch await enterpriseBillingLookup(
                token: token,
                seatOrgLogins: seatOrgLogins,
                unresolvedOrgKeys: unresolvedAssociatedOrgKeys
            ) {
            case .usage(let lines):
                return .usage(lines)
            case .empty(let lines):
                return .empty(lines)
            case .noAssociation:
                break
            case .managed:
                // Without enterprise visibility, an empty org report cannot prove that consolidated
                // usage is zero. Keep the honest managed state instead of publishing false totals.
                if emptyCandidate != nil && !sawTransientFailure {
                    return .managed
                }
            case .temporarilyUnavailable:
                sawTransientFailure = true
            }
        }

        if let emptyCandidate,
           !sawTransientFailure,
           unresolvedAssociatedOrgKeys.isEmpty
        {
            return .empty(emptyCandidate.lines)
        }
        return sawTransientFailure ? .temporarilyUnavailable : .managed
    }

    private func enterpriseBillingLookup(
        token: String,
        seatOrgLogins: [String],
        unresolvedOrgKeys: Set<String>
    ) async -> EnterpriseBillingLookup {
        let targets: [CopilotOrgBillingMapper.EnterpriseTarget]
        switch await CopilotEnterpriseDiscovery(client: orgBillingClient).lookup(
            token: token,
            seatOrgLogins: seatOrgLogins
        ) {
        case .targets(let discoveredTargets):
            targets = discoveredTargets
        case .noAssociation:
            return .noAssociation
        case .managed:
            return .managed
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        }

        let targetOrgKeys = Set(targets.map { $0.organization.lowercased() })
        var sawUnresolvedTarget = !unresolvedOrgKeys.isSubset(of: targetOrgKeys)
        var sawTransientFailure = false
        var emptyCandidate: [MetricLine]?
        for target in targets {
            do {
                switch try await enterpriseUsageLookup(target: target, token: token) {
                case .usage(let lines):
                    return .usage(lines)
                case .empty(let lines):
                    // GraphQL proved this enterprise owns the Copilot seat org. Keep the empty report
                    // provisional until every associated enterprise target is readable.
                    emptyCandidate = emptyCandidate ?? lines
                case .forbidden, .inaccessible, .notFound:
                    sawUnresolvedTarget = true
                }
            } catch {
                sawTransientFailure = true
                AppLog.warn(
                    LogTag.plugin("copilot"),
                    "enterprise AI credit usage failed for one enterprise; trying the next: \(error.localizedDescription)"
                )
            }
        }

        if let emptyCandidate,
           !sawTransientFailure,
           !sawUnresolvedTarget
        {
            return .empty(emptyCandidate)
        }
        return sawTransientFailure ? .temporarilyUnavailable : .managed
    }

    /// Distinguishes a valid zero report from inaccessible billing. Throws for transient failures
    /// (transport errors, 429, 5xx) and malformed `200` responses so callers do not mistake either for
    /// missing billing access.
    private func orgUsageLookup(org: String, token: String) async throws -> OrgUsageLookup {
        let response = try await orgBillingClient.fetchAICreditUsage(org: org, token: token)
        return try billingUsageLookup(response, scope: "org")
    }

    private func enterpriseUsageLookup(
        target: CopilotOrgBillingMapper.EnterpriseTarget,
        token: String
    ) async throws -> OrgUsageLookup {
        let response = try await orgBillingClient.fetchAICreditUsage(
            enterprise: target.enterprise,
            organization: target.organization,
            token: token
        )
        return try billingUsageLookup(response, scope: "enterprise")
    }

    private func billingUsageLookup(_ response: HTTPResponse, scope: String) throws -> OrgUsageLookup {
        guard response.statusCode == 200 else {
            AppLog.debug(
                LogTag.plugin("copilot"),
                "\(scope) AI credit usage for one billing entity: HTTP \(response.statusCode)"
            )
            if response.isGitHubRateLimited || response.statusCode >= 500 {
                throw CopilotUsageError.requestFailed(response.statusCode)
            }
            if response.statusCode == 404 {
                return .notFound
            }
            if response.statusCode == 403 {
                return .forbidden
            }
            return .inaccessible
        }
        guard let report = CopilotOrgBillingMapper.usageReport(response) else {
            throw CopilotUsageError.invalidResponse
        }
        return report.hasUsage ? .usage(report.lines) : .empty(report.lines)
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
