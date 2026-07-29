import Foundation

/// Calls GitHub's public REST billing endpoints to find the organization that provides an org-managed
/// Copilot seat and read its month-to-date usage. Used only when `/copilot_internal/user` reports a
/// token-based-billing seat with no per-seat quota (Copilot Business/Enterprise managed by an org) —
/// the usage then lives in *organization* billing, which the user-scoped endpoint never carries.
///
/// Reading an org's billing requires the caller to be an org owner or billing manager; a plain member
/// gets 403. That's an expected state, handled by the provider, not an error here.
struct CopilotOrgBillingClient: Sendable {
    static let userOrgsURL = "https://api.github.com/user/orgs?per_page=100"
    static let graphqlURL = "https://api.github.com/graphql"

    static func aiCreditUsageURL(org: String) -> URL? {
        // Org slugs are alphanumeric-plus-hyphen, but encode defensively before splicing into the path.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents(
            string: "https://api.github.com/organizations/\(encoded)/settings/billing/ai_credit/usage"
        )
        components?.queryItems = [URLQueryItem(name: "product", value: "Copilot")]
        return components?.url
    }

    static func enterpriseAICreditUsageURL(enterprise: String, organization: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard
            let encodedEnterprise = enterprise.addingPercentEncoding(withAllowedCharacters: allowed),
            !encodedEnterprise.isEmpty
        else {
            return nil
        }
        var components = URLComponents(
            string: "https://api.github.com/enterprises/\(encodedEnterprise)/settings/billing/ai_credit/usage"
        )
        components?.queryItems = [
            URLQueryItem(name: "organization", value: organization),
            URLQueryItem(name: "product", value: "Copilot")
        ]
        return components?.url
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The organizations the token's user belongs to (first page, 100 max — plenty for this purpose).
    func fetchUserOrgs(token: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.userOrgsURL) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    /// Month-to-date AI-credit usage for one organization.
    func fetchAICreditUsage(org: String, token: String) async throws -> HTTPResponse {
        guard let url = Self.aiCreditUsageURL(org: org) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    /// One page of enterprises visible to the token's user, with each enterprise's organizations
    /// narrowed to the seat organization being resolved.
    func fetchEnterpriseMemberships(
        organization: String,
        after cursor: String?,
        token: String
    ) async throws -> HTTPResponse {
        let query = """
        query RunwayCopilotBillingEnterprises($enterpriseCursor: String, $organization: String!) {
          viewer {
            enterprises(first: 100, after: $enterpriseCursor) {
              nodes {
                slug
                organizations(first: 100, query: $organization) {
                  nodes { login }
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
        """
        var variables: [String: Any] = ["organization": organization]
        if let cursor {
            variables["enterpriseCursor"] = cursor
        }
        return try await sendGraphQL(query: query, variables: variables, token: token)
    }

    /// A later organization page for one enterprise. GitHub exposes organizations as a separate
    /// cursor connection inside each enterprise, so it must be advanced independently.
    func fetchEnterpriseOrganizations(
        enterprise: String,
        organization: String,
        after cursor: String,
        token: String
    ) async throws -> HTTPResponse {
        let query = """
        query RunwayCopilotBillingOrganizations(
          $enterprise: String!,
          $organization: String!,
          $organizationCursor: String
        ) {
          enterprise(slug: $enterprise) {
            organizations(first: 100, after: $organizationCursor, query: $organization) {
              nodes { login }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
        """
        return try await sendGraphQL(
            query: query,
            variables: [
                "enterprise": enterprise,
                "organization": organization,
                "organizationCursor": cursor
            ],
            token: token
        )
    }

    /// Month-to-date Copilot AI-credit usage billed through an enterprise, filtered to one seat org.
    func fetchAICreditUsage(enterprise: String, organization: String, token: String) async throws -> HTTPResponse {
        guard let url = Self.enterpriseAICreditUsageURL(
            enterprise: enterprise,
            organization: organization
        ) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    private func sendGraphQL(
        query: String,
        variables: [String: Any],
        token: String
    ) async throws -> HTTPResponse {
        guard let url = URL(string: Self.graphqlURL) else {
            throw CopilotUsageError.invalidResponse
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables
        ])
        return try await send(
            url: url,
            token: token,
            method: "POST",
            body: body,
            additionalHeaders: ["Content-Type": "application/json"]
        )
    }

    private func send(
        url: URL,
        token: String,
        method: String = "GET",
        body: Data? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "token \(token)",
            "Accept": "application/vnd.github+json",
            "User-Agent": "Runway",
            "X-GitHub-Api-Version": "2026-03-10"
        ]
        headers.merge(additionalHeaders) { _, additional in additional }
        return try await http.send(HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: 15
        ))
    }
}

extension HTTPResponse {
    var isGitHubRateLimited: Bool {
        statusCode == 429
            || header("retry-after") != nil
            || header("x-ratelimit-remaining")?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }
}
