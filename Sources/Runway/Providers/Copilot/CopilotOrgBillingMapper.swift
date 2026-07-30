import Foundation

/// Normalizes GitHub organization billing responses into org-level Copilot meters. The dedicated
/// AI-credit usage endpoint reports month-to-date usage per product; the Copilot items become
/// **AI Credits Used** (total credits consumed this month, with included/additional breakdown) and
/// **Additional Spend** (dollars actually billed beyond included credits). Both are organization-wide
/// totals, not the individual seat's usage —
/// GitHub doesn't expose per-seat numbers for org-managed Copilot.
enum CopilotOrgBillingMapper {
    struct UsageReport {
        let lines: [MetricLine]
        let hasUsage: Bool
    }

    struct EnterpriseTarget: Equatable, Hashable, Sendable {
        let enterprise: String
        let organization: String
    }

    struct EnterpriseOrganizationContinuation: Equatable, Sendable {
        let enterprise: String
        let cursor: String
    }

    struct EnterpriseMembershipPage: Equatable, Sendable {
        let targets: [EnterpriseTarget]
        let organizationContinuations: [EnterpriseOrganizationContinuation]
        let nextEnterpriseCursor: String?
    }

    struct EnterpriseOrganizationPage: Equatable, Sendable {
        let target: EnterpriseTarget?
        let nextCursor: String?
    }

    /// Org slugs from a `/user/orgs` response, in GitHub's order. Empty for a garbled body.
    static func orgLogins(_ response: HTTPResponse) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            (entry["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// Parses one page of the viewer's enterprises and the first matching-organization page nested
    /// under each enterprise. The returned cursors are advanced independently by the provider.
    static func enterpriseMembershipPage(
        _ response: HTTPResponse,
        organization seatOrganization: String
    ) -> EnterpriseMembershipPage? {
        guard
            let body = ProviderParse.jsonObject(response.body),
            body["errors"] == nil,
            let data = body["data"] as? [String: Any],
            let viewer = data["viewer"] as? [String: Any],
            let enterprises = viewer["enterprises"] as? [String: Any],
            let nodes = enterprises["nodes"] as? [[String: Any]],
            let nextEnterpriseCursor = nextCursor(in: enterprises)
        else {
            return nil
        }

        let seatOrgKey = seatOrganization.lowercased()
        var targets: [EnterpriseTarget] = []
        var continuations: [EnterpriseOrganizationContinuation] = []
        for node in nodes {
            guard
                let enterprise = (node["slug"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                let organizations = node["organizations"] as? [String: Any],
                let orgNodes = organizations["nodes"] as? [[String: Any]],
                let nextOrganizationCursor = nextCursor(in: organizations)
            else {
                return nil
            }

            if let organization = matchingOrganization(in: orgNodes, key: seatOrgKey) {
                targets.append(EnterpriseTarget(enterprise: enterprise, organization: organization))
            } else if let nextOrganizationCursor {
                continuations.append(.init(enterprise: enterprise, cursor: nextOrganizationCursor))
            }
        }

        return EnterpriseMembershipPage(
            targets: targets,
            organizationContinuations: continuations,
            nextEnterpriseCursor: nextEnterpriseCursor
        )
    }

    /// Parses a later organization page for a single enterprise.
    static func enterpriseOrganizationPage(
        _ response: HTTPResponse,
        enterprise: String,
        organization seatOrganization: String
    ) -> EnterpriseOrganizationPage? {
        guard
            let body = ProviderParse.jsonObject(response.body),
            body["errors"] == nil,
            let data = body["data"] as? [String: Any],
            let enterpriseBody = data["enterprise"] as? [String: Any],
            let organizations = enterpriseBody["organizations"] as? [String: Any],
            let orgNodes = organizations["nodes"] as? [[String: Any]],
            let nextCursor = nextCursor(in: organizations)
        else {
            return nil
        }

        let organization = matchingOrganization(in: orgNodes, key: seatOrganization.lowercased())
        return EnterpriseOrganizationPage(
            target: organization.map { EnterpriseTarget(enterprise: enterprise, organization: $0) },
            nextCursor: nextCursor
        )
    }

    /// Metric lines from an AI-credit usage response, or `nil` when the body is malformed or carries
    /// no AI-credit items. A report with no Copilot items maps to zero-valued Copilot lines.
    static func usageLines(_ response: HTTPResponse) -> [MetricLine]? {
        usageReport(response)?.lines
    }

    static func usageLines(body: [String: Any]) -> [MetricLine]? {
        usageReport(body: body)?.lines
    }

    /// A successfully parsed report keeps whether GitHub returned any Copilot credit items separate
    /// from its zero-valued metric lines. Discovery can therefore continue past an accessible empty
    /// org in search of actual usage without confusing that empty `200` response with a `403`.
    static func usageReport(_ response: HTTPResponse) -> UsageReport? {
        guard let body = ProviderParse.jsonObject(response.body) else { return nil }
        return usageReport(body: body)
    }

    static func usageReport(body: [String: Any]) -> UsageReport? {
        guard let items = body["usageItems"] as? [[String: Any]] else { return nil }

        let aiCreditItems = items.filter { item in
            isCreditUnit(item["unitType"])
        }
        // The endpoint can report several AI products. An empty array or credit rows for other
        // products is a valid zero-Copilot report; unrelated non-credit rows are still malformed.
        guard !aiCreditItems.isEmpty || items.isEmpty else { return nil }

        let copilotItems = aiCreditItems.filter { item in
            isCopilot(item["product"])
        }

        let credits = copilotItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["grossQuantity"]) ?? 0) }
        let included = copilotItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["discountQuantity"]) ?? 0) }
        let additional = copilotItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["netQuantity"]) ?? 0) }
        let spend = copilotItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["netAmount"]) ?? 0) }

        return UsageReport(
            lines: [
                .values(label: "Org Credits", values: [
                    MetricValue(number: credits, kind: .count, label: "credits"),
                    MetricValue(number: included, kind: .count, label: "included"),
                    MetricValue(number: additional, kind: .count, label: "additional")
                ]),
                .values(label: "Org Spend", values: [MetricValue(number: spend, kind: .dollars)])
            ],
            hasUsage: !copilotItems.isEmpty
        )
    }

    private static func isCopilot(_ value: Any?) -> Bool {
        guard let product = value as? String else { return false }
        return product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("copilot")
    }

    private static func isCreditUnit(_ value: Any?) -> Bool {
        guard let unit = value as? String else { return false }
        let normalized = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "credits" || normalized == "ai-units" || normalized == "ai-credits"
    }

    /// A valid connection with no next page returns a non-`nil` optional containing `nil`; malformed
    /// page metadata returns `nil`. The outer optional lets callers distinguish those states.
    private static func nextCursor(in connection: [String: Any]) -> String?? {
        guard
            let pageInfo = connection["pageInfo"] as? [String: Any],
            let hasNextPage = pageInfo["hasNextPage"] as? Bool
        else {
            return nil
        }
        guard hasNextPage else { return .some(nil) }
        guard
            let cursor = (pageInfo["endCursor"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }
        return .some(cursor)
    }

    private static func matchingOrganization(
        in nodes: [[String: Any]],
        key: String
    ) -> String? {
        nodes.compactMap { node in
            (node["login"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }.first { $0.lowercased() == key }
    }
}
