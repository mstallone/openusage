import Foundation

/// A GitHub token already on the machine, usable against the Copilot usage endpoint.
struct CopilotToken: Hashable, Sendable {
    var value: String
}

enum CopilotAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenInvalid
    case keychainPermissionRequired
    case credentialStoreUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .tokenInvalid:
            return "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        case .keychainPermissionRequired:
            return "GitHub login found in Keychain. Refresh manually and choose Always Allow to connect it."
        case .credentialStoreUnreadable:
            return "GitHub login couldn’t be read. Unlock your login keychain and refresh."
        }
    }
}

/// Billing candidates plus why the *preferred* GitHub CLI credential was unusable, when that is
/// a Keychain problem. Without it an org-managed card falls back to an editor token that usually
/// lacks billing scopes and reports "you need billing access", when the actionable truth is that
/// an existing credential can be approved — or that the keychain simply couldn't be read.
struct CopilotBillingCandidates: Sendable {
    var tokens: [CopilotToken]
    var keychainError: CopilotAuthError?
}

/// Outcome of a credential load. `keychainPermissionRequired` means a gh Keychain item exists but
/// Runway isn't authorized to read it prompt-free yet — a real login footprint that only an explicit
/// manual refresh may convert into access.
enum CopilotCredentialLoad: Equatable, Sendable {
    case token(CopilotToken)
    case keychainPermissionRequired
    /// The item could not be read for a reason approval cannot fix — a locked login keychain, or
    /// securityd failing. Kept apart from `keychainPermissionRequired` so the card gives advice
    /// that works.
    case unreadable
    case none

    var token: CopilotToken? {
        guard case .token(let token) = self else { return nil }
        return token
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
    func loadCredentials(allowKeychainInteraction: Bool = false) -> CopilotCredentialLoad {
        if let token = loadFromEditorConfig() ?? loadFromGhConfig() {
            return .token(token)
        }
        return loadFromGhKeychain(allowKeychainInteraction: allowKeychainInteraction)
    }

    /// Tokens suitable for public GitHub billing APIs, with the GitHub CLI credential first.
    /// Editor OAuth tokens remain useful fallbacks, but commonly have only the private Copilot
    /// endpoint's permissions. Blocking (Keychain) — call off the main actor.
    ///
    /// The Keychain lookup is prompt-free first: when the usage token itself just came from an
    /// approved manual Keychain read, the coordinator's cache serves the same value here without a
    /// second prompt. Only a manual refresh may then fall through to one interactive read — the
    /// editor-token-plus-protected-gh-item setup, where billing is the FIRST Keychain touch and
    /// would otherwise be impossible to approve at all.
    func loadBillingTokenCandidates(
        usageToken: CopilotToken,
        allowKeychainInteraction: Bool = false
    ) -> CopilotBillingCandidates {
        var ghToken = loadFromGhConfig()
        var keychainError: CopilotAuthError?
        if ghToken == nil {
            var load = loadFromGhKeychain()
            if load == .keychainPermissionRequired, allowKeychainInteraction {
                load = loadFromGhKeychain(allowKeychainInteraction: true)
            }
            switch load {
            case .keychainPermissionRequired: keychainError = .keychainPermissionRequired
            case .unreadable: keychainError = .credentialStoreUnreadable
            case .token, .none: keychainError = nil
            }
            ghToken = load.token
        }
        var seen: Set<CopilotToken> = []
        let tokens = [ghToken, usageToken].compactMap { (token: CopilotToken?) -> CopilotToken? in
            guard let token, seen.insert(token).inserted else { return nil }
            return token
        }
        return CopilotBillingCandidates(tokens: tokens, keychainError: keychainError)
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

    /// `gh` stores its Keychain item under the GitHub username as the account. Read it scoped to that
    /// account when we can recover it from hosts.yml; otherwise fall back to a service-only lookup.
    /// Both reads are in-process — never the `/usr/bin/security` subprocess, whose prompts authorize
    /// the helper binary instead of Runway and fueled the 2026-08-03 prompt loop.
    func loadFromGhKeychain(allowKeychainInteraction: Bool = false) -> CopilotCredentialLoad {
        let account = ghUsername()
        guard allowKeychainInteraction else {
            if let account {
                switch keychain.readGenericPasswordWithoutUserInteraction(service: Self.ghKeychainService, account: account) {
                case .value(let raw):
                    return credentialLoad(fromKeychainRaw: raw)
                case .unavailable:
                    // The intended account's item is protected (or the keychain can't be checked).
                    // Never broaden to the account-less query from here — with several
                    // `gh:github.com` items it could silently select another account's token.
                    // Broadening is allowed only when the scoped item provably does not exist.
                    switch keychain.lastReadWasPermissionDenied(service: Self.ghKeychainService, account: account) {
                    case true?:
                        return .keychainPermissionRequired
                    case false?:
                        return .unreadable
                    case nil:
                        if keychain.genericPasswordExists(service: Self.ghKeychainService, account: account) != false {
                            return .keychainPermissionRequired
                        }
                    }
                case .missing:
                    break
                }
            }
            switch keychain.readGenericPasswordWithoutUserInteraction(service: Self.ghKeychainService) {
            case .value(let raw):
                return credentialLoad(fromKeychainRaw: raw)
            case .missing:
                return .none
            case .unavailable:
                // An existing-but-unreadable item is a real login footprint (`hasLocalCredentials`
                // must see it); only a manual refresh may convert it into access. The existence
                // probe is attributes-only and prompt-free, and `nil` from it means "cannot check"
                // (locked keychain, suppressed UI, stuck flight) — never "absent", which would
                // report a real login as logged-out.
                switch keychain.lastReadWasPermissionDenied(service: Self.ghKeychainService) {
                case true?:
                    return .keychainPermissionRequired
                case false?:
                    return .unreadable
                case nil:
                    return keychain.genericPasswordExists(service: Self.ghKeychainService) != false
                        ? .keychainPermissionRequired
                        : .none
                }
            }
        }
        // Manual refresh: may raise the approval prompt, once, for Runway itself. A denial is
        // reported as still-needing-permission and deliberately NOT retried through the broader
        // service-only lookup — that would just repeat the same prompt.
        if let account {
            do {
                if let raw = try keychain.readGenericPasswordAllowingUserInteraction(
                    service: Self.ghKeychainService, account: account
                ) {
                    return credentialLoad(fromKeychainRaw: raw)
                }
            } catch {
                return .keychainPermissionRequired
            }
        }
        do {
            guard let raw = try keychain.readGenericPasswordAllowingUserInteraction(service: Self.ghKeychainService) else {
                return .none
            }
            return credentialLoad(fromKeychainRaw: raw)
        } catch {
            return .keychainPermissionRequired
        }
    }

    private func credentialLoad(fromKeychainRaw raw: String) -> CopilotCredentialLoad {
        guard let token = ProviderParse.unwrapGoKeyring(raw) else { return .none }
        return .token(CopilotToken(value: token))
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
