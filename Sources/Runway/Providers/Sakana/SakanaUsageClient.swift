import Foundation

struct SakanaUsageClient: Sendable {
    static let sessionURL = URL(string: "https://console.sakana.ai/api/auth/session")!
    static let billingURL = URL(string: "https://console.sakana.ai/billing")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchSession(token: String) async throws -> HTTPResponse {
        try await get(Self.sessionURL, token: token, accept: "application/json")
    }

    func fetchBilling(token: String) async throws -> HTTPResponse {
        try await get(Self.billingURL, token: token, accept: "text/html")
    }

    private func get(_ url: URL, token: String, accept: String) async throws -> HTTPResponse {
        do {
            return try await http.send(HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Cookie": "\(SakanaAuthStore.cookieName)=\(token)",
                    "Accept": accept,
                    "User-Agent": "Runway"
                ],
                timeout: 15
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SakanaUsageError.connectionFailed
        }
    }
}

enum SakanaUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return "Sakana Console returned an unsupported billing response. The private console format may have changed."
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
