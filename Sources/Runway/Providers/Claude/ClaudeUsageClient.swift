import Foundation

enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        }
    }
}

/// Read-only client for Claude's usage endpoint. Runway never calls the OAuth token endpoint:
/// Claude Code owns its credentials and their rotation, and a second process refreshing the same
/// refresh token can trip the server's reuse detection and revoke the user's session.
struct ClaudeUsageClient: Sendable {
    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchUsage(accessToken: String, usageURL: URL) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: usageURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69"
                ],
                timeout: 10
            )
        )
    }
}
