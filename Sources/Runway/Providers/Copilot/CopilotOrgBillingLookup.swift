import Foundation

/// The organization/enterprise billing lookup for org-managed Copilot seats: which billing entity
/// answers for the seat, how much its report can be trusted, and how evidence from several local
/// GitHub credentials is merged. `CopilotProvider.refresh()` consumes the summarized outcome.
extension CopilotProvider {
    enum OrgBillingLookup {
        case usage([MetricLine])
        /// A readable zero report. `enterpriseVerified` is true only when the owning enterprise's
        /// own usage report was read — the one zero no ownership proof can displace. An org-only
        /// zero (no enterprise visible to this credential, or associations unreadable) stays false:
        /// "no *visible* association" is viewer-relative, so another credential's positive proof of
        /// an owning enterprise outranks it. The flag only steers the multi-credential aggregation;
        /// the rendered zero is identical — real usage under the same login surfaces in the org
        /// report on the next refresh, so a month-start zero corrects itself.
        case empty([MetricLine], enterpriseVerified: Bool)
        /// `provenEnterpriseAssociation` is true when this credential *proved* an owning enterprise
        /// (whose usage it could not read). Ownership is an account-level fact — independent of
        /// which credential learned it — so the multi-credential aggregation uses the proof to
        /// invalidate another credential's unverified zero.
        case managed(provenEnterpriseAssociation: Bool)
        case temporarilyUnavailable
    }

    private enum EnterpriseBillingLookup {
        case usage([MetricLine])
        case empty([MetricLine])
        case noAssociation
        /// The token cannot see enterprise associations at all (missing scope, or the viewer simply
        /// has none). Says nothing about whether the seat org's own report is trustworthy.
        case discoveryDenied
        /// An enterprise association was *proven* but its usage is unreadable — the one case where an
        /// org-level empty report must not stand in for possibly-consolidated enterprise usage.
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
    func orgBillingLookup(
        tokens: [CopilotToken],
        seatOrgLogins: [String],
        isEnterpriseSeat: Bool
    ) async -> OrgBillingLookup {
        var sawTransientFailure = false
        var sawProvenEnterpriseAssociation = false
        var emptyCandidate: (lines: [MetricLine], enterpriseVerified: Bool)?
        for (index, token) in tokens.enumerated() {
            if index > 0 {
                AppLog.info(LogTag.plugin("copilot"), "trying another local GitHub credential for billing")
            }
            switch await orgBillingLookup(
                token: token.value,
                seatOrgLogins: seatOrgLogins,
                isEnterpriseSeat: isEnterpriseSeat
            ) {
            case .usage(let lines):
                return .usage(lines)
            case .empty(let lines, let enterpriseVerified):
                // Once any credential has proven an owning enterprise, an org-only zero is exactly
                // the claim that proof invalidates — only an enterprise-verified zero may still land.
                if !enterpriseVerified && sawProvenEnterpriseAssociation {
                    continue
                }
                // An enterprise-verified zero beats an org-only one from an earlier credential.
                if emptyCandidate == nil || (emptyCandidate?.enterpriseVerified == false && enterpriseVerified) {
                    emptyCandidate = (lines, enterpriseVerified)
                }
            case .managed(let provenEnterpriseAssociation):
                if provenEnterpriseAssociation {
                    sawProvenEnterpriseAssociation = true
                    if emptyCandidate?.enterpriseVerified == false {
                        emptyCandidate = nil
                    }
                }
                continue
            case .temporarilyUnavailable:
                sawTransientFailure = true
            }
        }
        if let emptyCandidate, !sawTransientFailure {
            return .empty(emptyCandidate.lines, enterpriseVerified: emptyCandidate.enterpriseVerified)
        }
        return sawTransientFailure
            ? .temporarilyUnavailable
            : .managed(provenEnterpriseAssociation: sawProvenEnterpriseAssociation)
    }

    private func orgBillingLookup(
        token: String,
        seatOrgLogins: [String],
        isEnterpriseSeat: Bool
    ) async -> OrgBillingLookup {
        let associatedOrgKeys = Set(seatOrgLogins.map { $0.lowercased() })
        var shouldTryEnterprise = false
        var attemptedOrgKeys: Set<String> = []
        var unresolvedAssociatedOrgKeys: Set<String> = []
        // Set when GraphQL proved an enterprise owns the seat org (usage unreadable) — carried out
        // so the aggregation across credentials can overrule another credential's unverified zero.
        var provenEnterpriseAssociation = false
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
                    return .managed(provenEnterpriseAssociation: false)
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
                // The enterprise itself answered with a zero report — a verified zero.
                return .empty(lines, enterpriseVerified: true)
            case .noAssociation:
                // Discovery answered and no visible enterprise claims the seat org: the org's own
                // readable report (including a month-start empty one) is the best available truth.
                break
            case .discoveryDenied:
                // The token can't see enterprise associations at all. What an empty org report can
                // still prove depends on the seat: a Copilot Enterprise seat guarantees an owning
                // enterprise exists, so possibly-consolidated usage stays unverifiable — keep the
                // managed state. A Business seat's org normally bills itself, so its readable empty
                // report stands: every business org reads as zero credits at the start of a billing
                // month, not as "managed", and any real usage under this login surfaces in the org
                // report on a later refresh.
                if isEnterpriseSeat, emptyCandidate != nil, !sawTransientFailure {
                    return .managed(provenEnterpriseAssociation: false)
                }
            case .managed:
                // A proven enterprise association with unreadable usage: an empty org report cannot
                // prove that consolidated usage is zero. Keep the honest managed state instead of
                // publishing false totals.
                provenEnterpriseAssociation = true
                if emptyCandidate != nil && !sawTransientFailure {
                    return .managed(provenEnterpriseAssociation: true)
                }
            case .temporarilyUnavailable:
                sawTransientFailure = true
            }
        }

        if let emptyCandidate,
           !sawTransientFailure,
           unresolvedAssociatedOrgKeys.isEmpty
        {
            // Whether discovery answered "no visible enterprise" or couldn't be read at all, this
            // zero rests on the org's own report — org-only, so a later credential's ownership
            // proof may displace it in the aggregation above.
            return .empty(emptyCandidate.lines, enterpriseVerified: false)
        }
        return sawTransientFailure
            ? .temporarilyUnavailable
            : .managed(provenEnterpriseAssociation: provenEnterpriseAssociation)
    }

    private func enterpriseBillingLookup(
        token: String,
        seatOrgLogins: [String],
        unresolvedOrgKeys: Set<String>
    ) async -> EnterpriseBillingLookup {
        let targets: [CopilotOrgBillingMapper.EnterpriseTarget]
        let discoveryComplete: Bool
        switch await CopilotEnterpriseDiscovery(client: orgBillingClient).lookup(
            token: token,
            seatOrgLogins: seatOrgLogins
        ) {
        case .targets(let discoveredTargets, let complete):
            targets = discoveredTargets
            discoveryComplete = complete
        case .noAssociation:
            return .noAssociation
        case .managed:
            // Discovery-level denial: the token can't list enterprises, so nothing was proven about
            // the seat org's billing home. The caller decides what its org-level evidence is worth.
            return .discoveryDenied
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        }

        let targetOrgKeys = Set(targets.map { $0.organization.lowercased() })
        let seatOrgKeys = Set(seatOrgLogins.map { $0.lowercased() })
        // Unresolved when an org-endpoint failure isn't covered by a proven target, or when a
        // partial discovery denial left some seat org without a proven billing home. A seat org
        // *with* a proven target is fully resolved by it regardless of how discovery ended — an
        // organization has one owning enterprise — so a truncated discovery only taints the orgs
        // that never got one.
        var sawUnresolvedTarget = !unresolvedOrgKeys.isSubset(of: targetOrgKeys)
            || (!discoveryComplete && !seatOrgKeys.isSubset(of: targetOrgKeys))
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
}
