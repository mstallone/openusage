import Foundation

/// Resolves the enterprises that own Copilot seat organizations. GitHub exposes both the viewer's
/// enterprises and each enterprise's organizations as independent cursor connections.
struct CopilotEnterpriseDiscovery: Sendable {
    enum Result: Sendable {
        case targets([CopilotOrgBillingMapper.EnterpriseTarget])
        case noAssociation
        case managed
        case temporarilyUnavailable
    }

    private enum MembershipPageLookup: Sendable {
        case page(CopilotOrgBillingMapper.EnterpriseMembershipPage)
        case managed
        case temporarilyUnavailable
    }

    private enum OrganizationPageLookup: Sendable {
        case page(CopilotOrgBillingMapper.EnterpriseOrganizationPage)
        case managed
        case temporarilyUnavailable
    }

    let client: CopilotOrgBillingClient

    func lookup(token: String, seatOrgLogins: [String]) async -> Result {
        var seenOrganizationKeys: Set<String> = []
        let organizations = seatOrgLogins.compactMap { organization -> String? in
            guard let trimmed = organization
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else {
                return nil
            }
            return seenOrganizationKeys.insert(trimmed.lowercased()).inserted ? trimmed : nil
        }

        var targets: [CopilotOrgBillingMapper.EnterpriseTarget] = []
        var targetKeys: Set<String> = []
        for organization in organizations {
            var enterpriseCursor: String?
            var seenEnterpriseCursors: Set<String> = []
            while true {
                if let enterpriseCursor,
                   !seenEnterpriseCursors.insert(enterpriseCursor).inserted
                {
                    AppLog.warn(LogTag.plugin("copilot"), "enterprise discovery repeated an enterprise cursor")
                    return .temporarilyUnavailable
                }

                let membershipPage: CopilotOrgBillingMapper.EnterpriseMembershipPage
                switch await self.membershipPage(
                    organization: organization,
                    after: enterpriseCursor,
                    token: token
                ) {
                case .page(let page):
                    membershipPage = page
                case .managed:
                    return .managed
                case .temporarilyUnavailable:
                    return .temporarilyUnavailable
                }

                appendTargets(membershipPage.targets, to: &targets, seenKeys: &targetKeys)

                for continuation in membershipPage.organizationContinuations {
                    let expectedKey = targetKey(
                        enterprise: continuation.enterprise,
                        organization: organization
                    )
                    if targetKeys.contains(expectedKey) {
                        continue
                    }

                    var organizationCursor: String? = continuation.cursor
                    var seenOrganizationCursors: Set<String> = []
                    while let cursor = organizationCursor {
                        guard seenOrganizationCursors.insert(cursor).inserted else {
                            AppLog.warn(
                                LogTag.plugin("copilot"),
                                "enterprise discovery repeated an organization cursor"
                            )
                            return .temporarilyUnavailable
                        }

                        let organizationPage: CopilotOrgBillingMapper.EnterpriseOrganizationPage
                        switch await self.organizationPage(
                            enterprise: continuation.enterprise,
                            organization: organization,
                            after: cursor,
                            token: token
                        ) {
                        case .page(let page):
                            organizationPage = page
                        case .managed:
                            return .managed
                        case .temporarilyUnavailable:
                            return .temporarilyUnavailable
                        }

                        if let target = organizationPage.target {
                            appendTargets([target], to: &targets, seenKeys: &targetKeys)
                            break
                        }
                        organizationCursor = organizationPage.nextCursor
                    }
                }

                guard let nextCursor = membershipPage.nextEnterpriseCursor else {
                    break
                }
                enterpriseCursor = nextCursor
            }
        }
        return targets.isEmpty ? .noAssociation : .targets(targets)
    }

    private func membershipPage(
        organization: String,
        after cursor: String?,
        token: String
    ) async -> MembershipPageLookup {
        let response: HTTPResponse
        do {
            response = try await client.fetchEnterpriseMemberships(
                organization: organization,
                after: cursor,
                token: token
            )
        } catch {
            AppLog.warn(LogTag.plugin("copilot"), "enterprise discovery failed: \(error.localizedDescription)")
            return .temporarilyUnavailable
        }
        guard response.statusCode == 200 else {
            AppLog.info(
                LogTag.plugin("copilot"),
                "enterprise discovery HTTP \(response.statusCode); skipping enterprise billing lookup"
            )
            if response.isGitHubRateLimited || response.statusCode >= 500 {
                return .temporarilyUnavailable
            }
            return .managed
        }
        if let failure = graphQLFailure(in: response) {
            return failure == .accessDenied ? .managed : .temporarilyUnavailable
        }
        guard let page = CopilotOrgBillingMapper.enterpriseMembershipPage(
            response,
            organization: organization
        ) else {
            AppLog.warn(
                LogTag.plugin("copilot"),
                "enterprise discovery returned a malformed success response"
            )
            return .temporarilyUnavailable
        }
        return .page(page)
    }

    private func organizationPage(
        enterprise: String,
        organization: String,
        after cursor: String,
        token: String
    ) async -> OrganizationPageLookup {
        let response: HTTPResponse
        do {
            response = try await client.fetchEnterpriseOrganizations(
                enterprise: enterprise,
                organization: organization,
                after: cursor,
                token: token
            )
        } catch {
            AppLog.warn(
                LogTag.plugin("copilot"),
                "enterprise organization discovery failed: \(error.localizedDescription)"
            )
            return .temporarilyUnavailable
        }
        guard response.statusCode == 200 else {
            AppLog.info(
                LogTag.plugin("copilot"),
                "enterprise organization discovery HTTP \(response.statusCode); skipping enterprise billing lookup"
            )
            if response.isGitHubRateLimited || response.statusCode >= 500 {
                return .temporarilyUnavailable
            }
            return .managed
        }
        if let failure = graphQLFailure(in: response) {
            return failure == .accessDenied ? .managed : .temporarilyUnavailable
        }
        guard let page = CopilotOrgBillingMapper.enterpriseOrganizationPage(
            response,
            enterprise: enterprise,
            organization: organization
        ) else {
            AppLog.warn(
                LogTag.plugin("copilot"),
                "enterprise organization discovery returned a malformed success response"
            )
            return .temporarilyUnavailable
        }
        return .page(page)
    }

    private enum GraphQLFailure: Equatable {
        case accessDenied
        case temporarilyUnavailable
    }

    /// GitHub can return HTTP 200 for both authorization and retryable GraphQL failures. Only explicit
    /// authorization errors become the managed-account state; rate limits, internal errors, and unknown
    /// failures stay retryable so the UI does not claim that billing access is missing.
    private func graphQLFailure(in response: HTTPResponse) -> GraphQLFailure? {
        guard
            let body = ProviderParse.jsonObject(response.body),
            let errors = body["errors"] as? [[String: Any]],
            !errors.isEmpty
        else {
            return nil
        }

        if response.isGitHubRateLimited {
            AppLog.warn(LogTag.plugin("copilot"), "enterprise discovery was rate limited")
            return .temporarilyUnavailable
        }

        let accessDenied = errors.allSatisfy { error in
            let extensions = error["extensions"] as? [String: Any]
            let rawType = (error["type"] as? String)
                ?? (extensions?["type"] as? String)
                ?? (extensions?["code"] as? String)
            let type = rawType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let type, ["FORBIDDEN", "UNAUTHORIZED", "INSUFFICIENT_SCOPES", "NOT_FOUND"].contains(type) {
                return true
            }

            let message = (error["message"] as? String)?.lowercased() ?? ""
            return message.contains("resource not accessible")
                || message.contains("not authorized")
                || message.contains("does not have access")
                || message.contains("insufficient scope")
        }

        if accessDenied {
            AppLog.info(LogTag.plugin("copilot"), "enterprise discovery access is unavailable")
            return .accessDenied
        }

        AppLog.warn(LogTag.plugin("copilot"), "enterprise discovery returned a retryable GraphQL error")
        return .temporarilyUnavailable
    }

    private func appendTargets(
        _ newTargets: [CopilotOrgBillingMapper.EnterpriseTarget],
        to targets: inout [CopilotOrgBillingMapper.EnterpriseTarget],
        seenKeys: inout Set<String>
    ) {
        for target in newTargets {
            let key = targetKey(
                enterprise: target.enterprise,
                organization: target.organization
            )
            if seenKeys.insert(key).inserted {
                targets.append(target)
            }
        }
    }

    private func targetKey(enterprise: String, organization: String) -> String {
        "\(enterprise.lowercased())\u{0}\(organization.lowercased())"
    }
}
