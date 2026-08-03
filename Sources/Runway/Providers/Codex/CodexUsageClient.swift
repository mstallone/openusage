import Foundation

struct CodexUsageClient: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let consumeResetCreditURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "Runway"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: headers,
            timeout: 10
        ))
    }

    /// On-demand rate-limit reset credits, including each credit's expiry — a separate endpoint from
    /// `usage` (the usage body's `rate_limit_reset_credits` carries only the count, no expiry list). The
    /// extra headers mirror the Codex desktop client, which the endpoint expects. Best-effort: the
    /// provider tolerates a failure here and falls back to the usage body's count.
    func fetchResetCredits(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "Runway",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.resetCreditsURL,
            headers: headers,
            timeout: 10
        ))
    }

    /// Consumes (claims) one rate-limit reset credit — the protocol the Codex CLI uses, verified live
    /// and documented in docs/research/codex-reset-credit-claim.md. `redeemRequestID` is the caller's
    /// idempotency key (a UUID minted once per credit and reused on retry, so a retried claim can never
    /// burn a second credit — the server answers `already_redeemed`); `creditID` targets exactly one
    /// credit, never letting the server pick. The outcome rides in the 200 body's `code`
    /// (reset / already_redeemed / nothing_to_reset / no_credit) — see
    /// `CodexResetClaimService.outcome(fromConsume:)`.
    func consumeResetCredit(
        accessToken: String,
        accountID: String?,
        creditID: String,
        redeemRequestID: String
    ) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Runway",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let payload = ["redeem_request_id": redeemRequestID, "credit_id": creditID]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.consumeResetCreditURL,
            headers: headers,
            body: body,
            timeout: 15
        ))
    }

}

