import Foundation

/// Reads which account is signed in at a family's DEFAULT home — the proven identity slice of the
/// account-first model, with no candidate scanning. An account that can't name itself is reported
/// `unresolved`, never guessed: identity keys only ever come from the provider's own account
/// metadata, so a wrong-account attribution is structurally impossible.
struct DefaultAccountObserver: Sendable {
    /// One family's default-home read this launch.
    enum Outcome: Equatable, Sendable {
        /// The default home named its account.
        case resolved(identityKey: String, label: String?, anchor: String)
        /// A credential footprint exists but nothing names the account (keyring-mode Codex, a
        /// comma-list `CLAUDE_CONFIG_DIR`, a legacy auth file without an account id).
        case unresolved(reason: String)
        /// No sign of a login at the default home.
        case absent
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainReading
    var codexIdentityCache: (any CodexHomeIdentityCaching)?
    var homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor(),
        codexIdentityCache: (any CodexHomeIdentityCaching)? = nil,
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.codexIdentityCache = codexIdentityCache
        self.homeDirectory = homeDirectory
    }

    /// Expand a leading `~` against the injected home so tests never touch the real one.
    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    // MARK: - Claude

    /// Claude Code's per-install state file, which names the signed-in account (`oauthAccount`).
    struct ClaudeStateFile: Codable {
        struct OAuthAccount: Codable {
            var accountUuid: String?
            var emailAddress: String?
            var organizationUuid: String?
            var organizationName: String?
            /// Current plan family and tier, refetched with the rest of the profile while Claude Code
            /// runs — unlike the credential blob's copies, which are written at login and go stale on
            /// a plan change. `organizationType` is plan-shaped: `claude_pro`, `claude_max`, ….
            var organizationType: String?
            var organizationRateLimitTier: String?
            var userRateLimitTier: String?
        }

        var oauthAccount: OAuthAccount?
    }

    /// Claude identity key: account UUID plus the org UUID when present. Plans are org-scoped — one
    /// human commonly has a personal Max org and a company Team org under the SAME account, and those
    /// are different usage pools that must stay different accounts, never merge.
    static func claudeIdentityKey(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        guard let uuid = account.accountUuid?.nilIfEmpty?.lowercased() else { return nil }
        guard let org = account.organizationUuid?.nilIfEmpty?.lowercased() else { return uuid }
        return "\(uuid)|\(org)"
    }

    /// "email (Org Name)" when both are known — the org is what tells two same-email logins apart.
    static func claudeIdentityLabel(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        let email = account.emailAddress?.nilIfEmpty
        guard let org = account.organizationName?.nilIfEmpty else { return email }
        return email.map { "\($0) (\(org))" } ?? org
    }

    /// An ambient inference token has no account metadata, so it cannot participate in identity
    /// reconciliation. It still keeps the standard Claude runtime useful for default-home spend logs.
    var hasAmbientClaudeToken: Bool {
        environment.value(for: "CLAUDE_CODE_OAUTH_TOKEN")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
    }

    /// The default Claude home, mirroring `ClaudeAuthStore`'s resolution exactly (the observer must
    /// name the account whose credentials the provider actually refreshes with): `CLAUDE_CONFIG_DIR`
    /// when exported, else `~/.claude`. A comma-separated list can't be assigned one identity.
    func observeClaude() -> Outcome {
        var configDir = "~/.claude"
        let configDirOverride = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let raw = configDirOverride {
            guard !raw.contains(",") else {
                return .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list")
            }
            configDir = raw
        }
        let anchor = expandTilde(configDir)
        // The identity file sits inside a custom config dir, but next to (not inside) the default
        // `~/.claude` — Claude Code keeps the default's state at `~/.claude.json`.
        let identityPath = anchor == expandTilde("~/.claude")
            ? expandTilde("~/.claude.json")
            : anchor + "/.claude.json"
        // Attribute the state-file identity only when an account-bound credential footprint backs
        // it. An ambient token carries no identity and can outlive an old state file, so the state
        // file alone must never lend that token a stale account name.
        let credentialFileUsable: Bool?
        do {
            if let text = try files.readTextIfPresent(anchor + "/.credentials.json") {
                credentialFileUsable = ClaudeAuthStore.parseUsableCredentials(text) != nil
            } else {
                credentialFileUsable = false
            }
        } catch {
            credentialFileUsable = nil
        }
        let keychainUsability = ClaudeAuthStore.standardKeychainServiceCandidates(
            environment: environment,
            configDirOverride: configDirOverride
        ).flatMap { service in
            [
                keychain.readGenericPasswordForCurrentUserWithoutUserInteraction(service: service),
                keychain.readGenericPasswordWithoutUserInteraction(service: service),
            ].map(Self.claudeKeychainCredentialUsability)
        }
        let text: String?
        do {
            text = try files.readTextIfPresent(identityPath)
        } catch {
            return .unresolved(reason: "identity file unreadable: \(error.localizedDescription)")
        }
        guard let text else {
            // No state file. File or keychain credentials without it can't be attributed. Keychain
            // validation forbids UI, so this launch path never opens an authorization prompt.
            if credentialFileUsable == true || keychainUsability.contains(true) {
                return .unresolved(reason: "credentials present but no identity file")
            }
            if credentialFileUsable == nil || keychainUsability.contains(where: { $0 == nil }) {
                return .unresolved(reason: "credential presence unverifiable")
            }
            return .absent
        }
        guard let parsed = try? JSONDecoder().decode(ClaudeStateFile.self, from: Data(text.utf8)),
              let account = parsed.oauthAccount,
              let key = Self.claudeIdentityKey(account)
        else {
            return .unresolved(reason: "identity file present but names no account")
        }
        if hasAmbientClaudeToken, credentialFileUsable != true, !keychainUsability.contains(true) {
            if credentialFileUsable == nil || keychainUsability.contains(where: { $0 == nil }) {
                return .unresolved(reason: "credential presence unverifiable")
            }
            return .absent
        }
        return .resolved(identityKey: key, label: Self.claudeIdentityLabel(account), anchor: anchor)
    }

    private static func claudeKeychainCredentialUsability(
        _ read: NonInteractiveKeychainRead
    ) -> Bool? {
        switch read {
        case .value(let text):
            ClaudeAuthStore.parseUsableCredentials(text) != nil
        case .missing:
            false
        case .unavailable:
            nil
        }
    }

    // MARK: - Codex

    struct CodexIdentity: Equatable, Sendable {
        var key: String
        var label: String?
    }

    /// The default Codex homes, mirroring `CodexAuthStore.authPaths()`: `CODEX_HOME` when exported,
    /// else `~/.config/codex` then `~/.codex`. The first home that names its account wins.
    ///
    /// Identity is strict — `tokens.account_id`, or the id_token's ChatGPT account claim (the value
    /// the CLI itself copies into `account_id`). No path-derived fallback: an auth file that can't
    /// name its account stays unresolved. A keyring-mode login resolves only through the
    /// fingerprint-bound identity cache populated by a prior exact-item read.
    func observeCodex() -> Outcome {
        let homes: [String]
        if let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            homes = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            homes = ["~/.config/codex", "~/.codex"]
        }

        var sawFootprint = false
        for home in homes {
            let anchor = expandTilde(home)
            let text: String?
            do {
                text = try files.readTextIfPresent(anchor + "/auth.json")
            } catch {
                // An unreadable auth file is still a login footprint — just one we can't attribute.
                sawFootprint = true
                continue
            }
            let fileIdentity: CodexIdentity? = if let text {
                Self.fileBackedCodexIdentity(text)
            } else {
                nil
            }
            if text != nil { sawFootprint = true }

            let account = CodexAuthStore.keychainAccountName(forHome: anchor)
            switch keychain.genericPasswordExists(
                service: CodexAuthStore.keychainService,
                account: account
            ) {
            case false:
                if let fileIdentity {
                    return .resolved(
                        identityKey: fileIdentity.key,
                        label: fileIdentity.label,
                        anchor: anchor
                    )
                }
            case true:
                sawFootprint = true
                guard let fingerprint = keychain.genericPasswordAttributeFingerprint(
                    service: CodexAuthStore.keychainService,
                    account: account
                ),
                    let keychainIdentity = codexIdentityCache?.identity(
                        forHome: anchor,
                        keychainItemFingerprint: fingerprint
                    )
                else {
                    return .unresolved(reason: "account-scoped keyring identity unverified")
                }
                if let fileIdentity, fileIdentity.key != keychainIdentity.key {
                    return .unresolved(reason: "auth file and keyring identities disagree")
                }
                let identity = fileIdentity ?? keychainIdentity
                return .resolved(
                    identityKey: identity.key,
                    label: identity.label,
                    anchor: anchor
                )
            case nil:
                // A failed exact-item probe cannot prove that a file fallback is account-safe.
                if text != nil {
                    return .unresolved(reason: "account-scoped keyring item unverifiable")
                }
            }
        }

        // A service-only item has no trustworthy home address and therefore contributes no identity
        // here. An unrelated account-scoped item elsewhere under the shared service cannot suppress
        // verified file-backed homes just because a service-only query happens to find it first.
        return sawFootprint
            ? .unresolved(reason: "credentials present but no account identity")
            : .absent
    }

    private static func fileBackedCodexIdentity(_ text: String) -> CodexIdentity? {
        guard let auth = CodexAuthStore.parseAuth(text),
              auth.tokens?.accessToken?.nilIfEmpty != nil
        else {
            return nil
        }
        return codexIdentity(auth)
    }

    /// Strict provider-owned identity extraction shared by default-home observation and extra-home
    /// discovery. A path is never an identity: without `account_id` or the equivalent id-token claim,
    /// the credential cannot safely own a card.
    static func codexIdentity(_ auth: CodexAuth) -> CodexIdentity? {
        let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
        let label = (payload?["email"] as? String)?.nilIfEmpty
        let rawKey = auth.tokens?.accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? chatGPTAccountID(inIDTokenPayload: payload)
        guard let rawKey else { return nil }
        return CodexIdentity(key: rawKey.lowercased(), label: label)
    }

    /// The account id inside a Codex id_token: `chatgpt_account_id` under the
    /// `https://api.openai.com/auth` claim (the CLI's source for `tokens.account_id`), with the
    /// bare top-level spelling accepted for older tokens.
    static func chatGPTAccountID(inIDTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let authClaim = payload["https://api.openai.com/auth"] as? [String: Any]
        let raw = (authClaim?["chatgpt_account_id"] ?? payload["chatgpt_account_id"]) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
