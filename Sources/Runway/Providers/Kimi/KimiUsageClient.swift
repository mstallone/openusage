import Foundation

struct KimiRefreshResponse: Hashable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Double
    var scope: String
    var tokenType: String
}

struct KimiUsageClient: Sendable {
    private static let refreshRetryStatuses = Set([429, 500, 502, 503, 504])

    var http: any HTTPClient
    var sleep: @Sendable (Duration) async throws -> Void

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.http = http
        self.sleep = sleep
    }

    func fetchUsage(accessToken: String, url: URL) async throws -> HTTPResponse {
        do {
            return try await http.send(HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json",
                    "User-Agent": "Runway"
                ],
                timeout: 8
            ))
        } catch {
            throw KimiUsageError.connectionFailed
        }
    }

    /// Kimi Code's OAuth refresh-token grant. The service rotates both access and refresh tokens, so a
    /// response is accepted only when all three lifecycle fields are present and then atomically saved
    /// before the new access token is used.
    func refreshToken(_ refreshToken: String, url: URL) async throws -> KimiRefreshResponse {
        let body = [
            "client_id=\(KimiAuthStore.clientID.urlFormEncoded)",
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlFormEncoded)"
        ].joined(separator: "&")

        for attempt in 0..<3 {
            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(
                    method: "POST",
                    url: url,
                    headers: [
                        "Accept": "application/json",
                        "Content-Type": "application/x-www-form-urlencoded",
                        "User-Agent": "Runway"
                    ],
                    body: Data(body.utf8),
                    timeout: 30
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < 2 {
                    try await sleep(.seconds(1 << attempt))
                    continue
                }
                throw KimiUsageError.connectionFailed
            }

            if response.statusCode == 401 || response.statusCode == 403 {
                throw KimiAuthError.sessionExpired
            }
            if let root = ProviderParse.jsonObject(response.body),
               (root["error"] as? String) == "invalid_grant" {
                throw KimiAuthError.sessionExpired
            }
            guard (200..<300).contains(response.statusCode) else {
                if Self.refreshRetryStatuses.contains(response.statusCode), attempt < 2 {
                    try await sleep(.seconds(1 << attempt))
                    continue
                }
                throw KimiUsageError.requestFailed(response.statusCode)
            }
            guard let root = ProviderParse.jsonObject(response.body),
                  let accessToken = (root["access_token"] as? String)?.nilIfEmpty,
                  let rotatedRefreshToken = (root["refresh_token"] as? String)?.nilIfEmpty,
                  let expiresIn = ProviderParse.number(root["expires_in"]),
                  expiresIn > 0
            else {
                throw KimiUsageError.invalidResponse
            }

            return KimiRefreshResponse(
                accessToken: accessToken,
                refreshToken: rotatedRefreshToken,
                expiresIn: expiresIn,
                scope: root["scope"] as? String ?? "",
                tokenType: (root["token_type"] as? String)?.nilIfEmpty ?? "Bearer"
            )
        }
        throw KimiUsageError.connectionFailed
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .usageUnavailable:
            return "Kimi Code subscription usage is unavailable for this account."
        }
    }
}
