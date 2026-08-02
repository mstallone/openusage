import CryptoKit
import Foundation

/// OAuth token written by Kimi Code CLI under
/// `$KIMI_CODE_HOME/credentials/kimi-code.json` (default `~/.kimi-code`).
struct KimiOAuthToken: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double
    var scope: String
    var tokenType: String
    var expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

/// A loaded Kimi login plus the exact storage and service endpoints selected for this launch.
/// Keeping these together prevents a token loaded from one KIMI_CODE_HOME from being saved into
/// another if the surrounding shell environment changes while a refresh is in flight.
struct KimiAuth: Hashable, Sendable {
    var token: KimiOAuthToken
    var credentialPath: String
    var credentialName: String
    var homeDirectory: String
    var usageURL: URL
    var refreshURL: URL

    func replacing(token: KimiOAuthToken) -> KimiAuth {
        var copy = self
        copy.token = token
        return copy
    }
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable
    case invalidCredentials
    case sessionExpired
    case invalidEndpoint(String)
    case refreshLockFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to Kimi Code. Run `kimi`, then use `/login`."
        case .credentialsUnreadable:
            return "Kimi Code credentials couldn't be read."
        case .invalidCredentials:
            return "Kimi Code credentials are invalid. Run `/login` in Kimi Code again."
        case .sessionExpired:
            return "Kimi Code session expired. Run `/login` in Kimi Code again."
        case .invalidEndpoint(let variable):
            return "\(variable) is not a secure Kimi endpoint."
        case .refreshLockFailed:
            return "Couldn't safely refresh Kimi Code credentials. Try again after Kimi Code finishes refreshing."
        case .saveFailed:
            return "Couldn't save refreshed Kimi Code credentials."
        }
    }
}

/// Reads and updates the OAuth credential managed by the current Kimi Code CLI.
///
/// Kimi relocates its entire data root with `KIMI_CODE_HOME`; Runway honors the same override and
/// otherwise reads `~/.kimi-code/credentials/kimi-code.json`. Endpoint overrides are also mirrored so
/// a self-hosted/test Kimi login never has its token sent to the production service by mistake.
struct KimiAuthStore: Sendable {
    static let defaultHome = "~/.kimi-code"
    static let defaultAPIBaseURL = "https://api.kimi.com/coding/v1"
    static let defaultOAuthHost = "https://auth.kimi.com"
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    /// The official CLI refreshes within half the token lifetime, but never less than five minutes
    /// before expiry.
    static let minimumRefreshWindow: TimeInterval = 5 * 60

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.now = now
    }

    func loadAuth() throws -> KimiAuth {
        let home = homeDirectory()
        let apiBaseURL = selectedAPIBaseURL()
        let oauthHost = selectedOAuthHost()
        let usageURL = try endpoint(
            base: apiBaseURL,
            appending: "usages",
            variable: "KIMI_CODE_BASE_URL"
        )
        let refreshURL = try endpoint(
            base: oauthHost,
            appending: "api/oauth/token",
            variable: "KIMI_CODE_OAUTH_HOST"
        )
        let name = Self.credentialName(apiBaseURL: apiBaseURL, oauthHost: oauthHost)
        let path = credentialPath(homeDirectory: home, credentialName: name)
        let token = try loadToken(at: path)
        return KimiAuth(
            token: token,
            credentialPath: path,
            credentialName: name,
            homeDirectory: home,
            usageURL: usageURL,
            refreshURL: refreshURL
        )
    }

    /// Reload the exact credential file that produced `auth`; used immediately before refresh and
    /// after a 401 so a token rotated by Kimi Code in another process wins instead of being overwritten.
    func reload(_ auth: KimiAuth) throws -> KimiAuth {
        auth.replacing(token: try loadToken(at: auth.credentialPath))
    }

    func hasUsableCredentials() -> Bool {
        (try? loadAuth()) != nil
    }

    func needsRefresh(_ token: KimiOAuthToken) -> Bool {
        guard token.expiresAt > 0 else { return false }
        let dynamicWindow = token.expiresIn > 0 ? token.expiresIn * 0.5 : 0
        let window = max(Self.minimumRefreshWindow, dynamicWindow)
        return token.expiresAt - now().timeIntervalSince1970 < window
    }

    func refreshedToken(from response: KimiRefreshResponse) -> KimiOAuthToken {
        KimiOAuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: now().timeIntervalSince1970 + response.expiresIn,
            scope: response.scope,
            tokenType: response.tokenType,
            expiresIn: response.expiresIn
        )
    }

    func save(_ auth: KimiAuth) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(auth.token)
            guard let text = String(data: data, encoding: .utf8) else {
                throw KimiAuthError.saveFailed
            }
            // LocalTextFileAccessor writes through a private 0600 temporary file and atomically
            // renames it over the credential, matching Kimi Code's own storage guarantees.
            try files.writeText(auth.credentialPath, text + "\n")
        } catch let error as KimiAuthError {
            throw error
        } catch {
            throw KimiAuthError.saveFailed
        }
    }

    func homeDirectory() -> String {
        let override = environment.value(for: "KIMI_CODE_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return override?.nilIfEmpty ?? Self.defaultHome
    }

    func credentialPath(
        homeDirectory: String? = nil,
        credentialName: String = "kimi-code"
    ) -> String {
        let home = (homeDirectory ?? self.homeDirectory()).trimmingTrailingSlashes
        return "\(home)/credentials/\(credentialName).json"
    }

    private func loadToken(at path: String) throws -> KimiOAuthToken {
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(path) else {
                throw KimiAuthError.notLoggedIn
            }
            text = stored
        } catch let error as KimiAuthError {
            throw error
        } catch {
            throw KimiAuthError.credentialsUnreadable
        }

        guard let data = text.data(using: .utf8),
              let token = try? JSONDecoder().decode(KimiOAuthToken.self, from: data)
        else {
            throw KimiAuthError.invalidCredentials
        }
        // Kimi writes an empty access token as a revoked-session tombstone.
        guard !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiAuthError.sessionExpired
        }
        guard token.expiresAt.isFinite, token.expiresIn.isFinite else {
            throw KimiAuthError.invalidCredentials
        }
        return token
    }

    private func selectedAPIBaseURL() -> String {
        (environment.value(for: "KIMI_CODE_BASE_URL") ?? Self.defaultAPIBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlashes
    }

    private func selectedOAuthHost() -> String {
        (environment.value(for: "KIMI_CODE_OAUTH_HOST")
            ?? environment.value(for: "KIMI_OAUTH_HOST")
            ?? Self.defaultOAuthHost)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlashes
    }

    /// Kimi Code isolates non-default endpoint logins in a deterministic credential slot so an
    /// environment override can never send the production account's token to another service.
    /// Mirror its exact SHA-256 naming contract.
    static func credentialName(apiBaseURL: String, oauthHost: String) -> String {
        guard apiBaseURL != defaultAPIBaseURL || oauthHost != defaultOAuthHost else {
            return "kimi-code"
        }
        let identity = #"{"oauthHost":\#(jsonQuoted(oauthHost)),"baseUrl":\#(jsonQuoted(apiBaseURL))}"#
        let digest = SHA256.hash(data: Data(identity.utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "kimi-code-env-\(prefix)"
    }

    private static func jsonQuoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        )
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// OAuth credentials must only travel over HTTPS. Loopback HTTP remains available for the
    /// self-hosted/test setup Kimi documents, without allowing a typo to expose a bearer token to an
    /// arbitrary clear-text host.
    private func endpoint(base: String, appending path: String, variable: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLoopback(host))
        else {
            throw KimiAuthError.invalidEndpoint(variable)
        }
        components.path = components.path.trimmingTrailingSlashes + "/" + path
        guard let url = components.url else {
            throw KimiAuthError.invalidEndpoint(variable)
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
