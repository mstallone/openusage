import Foundation

/// A GitHub token already on the machine, usable against the Copilot usage endpoint.
struct CopilotToken: Hashable, Sendable {
    var value: String
}

enum CopilotAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenInvalid

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .tokenInvalid:
            return "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        }
    }
}

/// Reads a GitHub token that Copilot tooling already left on the machine — no login flow, no browser
/// cookies. Sources are tried prompt-free files first, Keychain last:
/// 1. Copilot editor config `~/.config/github-copilot/apps.json` (older `hosts.json`) — the OAuth token
///    the VS Code / JetBrains / Neovim Copilot plugins write. Universal and file-based.
/// 2. GitHub CLI `~/.config/gh/hosts.yml` `oauth_token` — present when `gh` stores the token in a file.
/// 3. GitHub CLI Keychain item (service `gh:github.com`) — go-keyring-wrapped, used when `gh` stores the
///    token in the system keyring instead of the file.
struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    var files: TextFileAccessing
    var keychain: KeychainReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// First non-empty source wins. Blocking (Keychain) — call off the main actor.
    /// `allowKeychainInteraction` is true only for a manual refresh: that read may raise the macOS
    /// approval prompt once, for Runway itself; automatic refreshes and launch detection never
    /// prompt.
    func loadToken(allowKeychainInteraction: Bool = false) -> CopilotToken? {
        loadFromEditorConfig()
            ?? loadFromGhConfig()
            ?? loadFromGhKeychain(allowKeychainInteraction: allowKeychainInteraction)
    }

    /// Tokens suitable for public GitHub billing APIs, with the GitHub CLI credential first.
    /// Editor OAuth tokens remain useful fallbacks, but commonly have only the private Copilot
    /// endpoint's permissions. Blocking (Keychain) — call off the main actor.
    func loadBillingTokenCandidates(
        usageToken: CopilotToken,
        allowKeychainInteraction: Bool = false
    ) -> [CopilotToken] {
        let ghToken = loadFromGhConfig()
            ?? loadFromGhKeychain(allowKeychainInteraction: allowKeychainInteraction)
        var seen: Set<CopilotToken> = []
        return [ghToken, usageToken].compactMap { token in
            guard let token, seen.insert(token).inserted else { return nil }
            return token
        }
    }

    // MARK: - Sources

    func loadFromEditorConfig() -> CopilotToken? {
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            guard files.exists(path),
                  let text = try? files.readText(path),
                  let token = Self.oauthToken(fromEditorJSON: text)
            else {
                continue
            }
            return CopilotToken(value: token)
        }
        return nil
    }

    func loadFromGhConfig() -> CopilotToken? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath),
              let token = Self.yamlValue(text, key: "oauth_token")
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    func loadFromGhKeychain(allowKeychainInteraction: Bool = false) -> CopilotToken? {
        guard let raw = readGhKeychainRaw(allowInteraction: allowKeychainInteraction),
              let token = ProviderParse.unwrapGoKeyring(raw)
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    /// `gh` stores its Keychain item under the GitHub username as the account. Read it scoped to that
    /// account when we can recover it from hosts.yml; otherwise fall back to a service-only lookup.
    /// Both reads are in-process — never the `/usr/bin/security` subprocess, whose prompts authorize
    /// the helper binary instead of Runway and fueled the 2026-08-03 prompt loop.
    private func readGhKeychainRaw(allowInteraction: Bool) -> String? {
        let account = ghUsername()
        guard allowInteraction else {
            if let account,
               case .value(let raw) = keychain.readGenericPasswordWithoutUserInteraction(
                   service: Self.ghKeychainService, account: account
               ) {
                return raw
            }
            if case .value(let raw) = keychain.readGenericPasswordWithoutUserInteraction(
                service: Self.ghKeychainService
            ) {
                return raw
            }
            return nil
        }
        if let account {
            do {
                if let raw = try keychain.readGenericPasswordAllowingUserInteraction(
                    service: Self.ghKeychainService, account: account
                ) {
                    return raw
                }
            } catch {
                // The user denied (or the read failed) on the exact item; a broader service-only
                // lookup would just repeat the same prompt.
                return nil
            }
        }
        return try? keychain.readGenericPasswordAllowingUserInteraction(service: Self.ghKeychainService)
    }

    private func ghUsername() -> String? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath)
        else {
            return nil
        }
        return Self.yamlValue(text, key: "user")
    }

    // MARK: - Parsing (pure)

    /// Pull a github.com `oauth_token` from the Copilot editor config. The file is a JSON object keyed by
    /// host — `"github.com"` (older `hosts.json`) or `"github.com:<appId>"` (newer `apps.json`) — each
    /// value an object carrying `oauth_token`. Only github.com entries are used: another host's token
    /// (e.g. GitHub Enterprise) must not be sent to api.github.com, and returning `nil` lets the chain
    /// fall through to gh config / keychain, which may hold a valid github.com token.
    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        func token(in value: Any?) -> String? {
            guard let dict = value as? [String: Any],
                  let token = (dict["oauth_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                return nil
            }
            return token
        }

        for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = token(in: value) { return token }
        }
        return nil
    }

    /// Read an indented `key: value` from within a specific host block of the `hosts.yml` GitHub CLI
    /// writes. `gh` keys each host block by a top-level (unindented) `<host>:` line; reading must be
    /// scoped to the `github.com` block, because a GitHub Enterprise block in the same file would
    /// otherwise let its `oauth_token` win and get sent to api.github.com (a guaranteed 401/403).
    /// `users:` (the nested map) doesn't match `user:` because the colon position differs.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            // An unindented line starts a new top-level block (a host header or other root key); only
            // the github.com block's children should be read.
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

}
