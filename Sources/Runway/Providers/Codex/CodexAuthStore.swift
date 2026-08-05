import CryptoKit
import Foundation

/// Which Codex login a store may read. `.standard` preserves the historical environment/default
/// path walk and legacy service-level Keychain fallback. `.home` backs one account card and is pinned
/// to exactly that home's `auth.json` plus its Codex CLI account-scoped keyring item.
enum CodexCredentialScope: Hashable, Sendable {
    case standard
    case home(path: String)
}

struct CodexTokens: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

struct CodexAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file(path: String)
        case keychain
    }

    var auth: CodexAuth
    var source: Source
    /// Exact keychain account loaded for this state. `nil` only for the legacy service-level fallback.
    var keychainAccount: String?
    /// Canonical home behind either source. Used to reload one source and warm its identity binding.
    var credentialHome: String?

    init(
        auth: CodexAuth,
        source: Source,
        keychainAccount: String? = nil,
        credentialHome: String? = nil
    ) {
        self.auth = auth
        self.source = source
        self.keychainAccount = keychainAccount
        self.credentialHome = credentialHome
    }

    /// Whether this candidate carries a non-empty OAuth access token — the same bar `refresh()`'s
    /// probe requires before fetching usage (an API-key-only auth.json can't serve the usage API).
    /// `hasLocalCredentials()`'s first-run detection checks this, so the two can never drift.
    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.isEmpty == false
    }
}

enum CodexAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case loginRenewalRequired
    case usageAPIKey
    case invalidAuthPayload
    /// The Codex Keychain item exists but hasn't been loaded this process — the neutral connect
    /// prompt, not a warning.
    case keychainConnectRequired
    /// An attempted manual read of the Codex Keychain item was denied.
    case keychainPermissionRequired
    case credentialStoreUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `codex` to authenticate."
        case .loginRenewalRequired:
            return "Codex login needs renewal. Run `codex`, then refresh Runway."
        case .usageAPIKey:
            return "Usage not available for API key."
        case .invalidAuthPayload:
            return "Codex auth data is invalid."
        case .keychainConnectRequired:
            return "Codex login found in Keychain. Connect to load it; if macOS asks, choose Always Allow to avoid future dialogs."
        case .keychainPermissionRequired:
            return "Keychain access to the Codex login was declined. Refresh and choose Always Allow when macOS asks."
        case .credentialStoreUnreadable:
            return "Codex credentials couldn’t be read. Unlock your login keychain and refresh."
        }
    }

    var allowsAuthFallback: Bool {
        switch self {
        case .loginRenewalRequired:
            return true
        case .notLoggedIn, .usageAPIKey, .invalidAuthPayload, .keychainConnectRequired,
             .keychainPermissionRequired, .credentialStoreUnreadable:
            return false
        }
    }
}

/// Outcome of the keyring lookup. `connectRequired` means a Codex Keychain item exists but its
/// secret hasn't been loaded into this process yet — a real login footprint that only an explicit
/// user action may convert into access, and a neutral state (nothing was denied).
enum CodexKeychainLoad {
    case state(CodexAuthState)
    case connectRequired
    /// An attempted (user-attended) read of the item was denied — the ACL rejects Runway, or the
    /// user declined the dialog. Unlike `connectRequired`, this genuinely needs the user to act.
    case permissionRequired
    /// The item could not be read for a reason approval cannot fix — a locked login keychain, or
    /// securityd failing. Kept apart from `permissionRequired` so the card gives advice that works.
    case unreadable
    case none

    var state: CodexAuthState? {
        guard case .state(let state) = self else { return nil }
        return state
    }
}

struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    /// Refresh once the access token is within this window of its JWT `exp` — the same 5-minute slack
    /// the `codex` CLI itself uses, so Runway rotates on the same schedule rather than guessing.
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    private static let authFile = "auth.json"
    private static let defaultAuthHomes = ["~/.config/codex", "~/.codex"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainReading
    var identityCache: (any CodexHomeIdentityCaching)?
    var now: @Sendable () -> Date
    let scope: CodexCredentialScope

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor(),
        scope: CodexCredentialScope = .standard,
        identityCache: (any CodexHomeIdentityCaching)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.scope = scope
        self.identityCache = identityCache
        self.now = now
    }

    func loadAuthCandidates() -> [CodexAuthState] {
        authPaths().compactMap { loadAuth(at: $0) }
    }

    /// Codex CLI keyring account for one home: `cli|` plus the first 16 hex characters of the
    /// canonical home's SHA-256. This lets every read/write target one item without enumerating the
    /// shared service or borrowing another home's credential.
    static func keychainAccountName(forHome path: String) -> String {
        let canonical = canonicalHome(path)
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "cli|\(digest.prefix(16))"
    }

    /// Reads the credential from a single on-disk auth file — the targeted counterpart to
    /// `loadKeychainAuth()`, used when reloading the exact source we already loaded from so we don't
    /// re-scan every candidate path. Returns `nil` when the file is missing, unreadable, or doesn't
    /// carry token-like auth.
    func loadAuth(at path: String) -> CodexAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let auth = Self.parseAuth(text),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(
            auth: auth,
            source: .file(path: path),
            credentialHome: Self.canonicalHome(forAuthPath: path)
        )
    }

    /// Convenience for callers that only care about a successfully loaded credential (the identity
    /// warm task); the permission state collapses to nil there, keeping the home hidden.
    func loadKeychainAuth() -> CodexAuthState? {
        guard case .state(let state) = loadKeychainCredentials() else { return nil }
        return state
    }

    /// Keychain access stays in-process. Automatic refreshes inspect metadata and reuse a manually
    /// seeded cache; only a manual refresh (`allowKeychainInteraction`) may request secret data or
    /// raise the approval prompt.
    func loadKeychainCredentials(allowKeychainInteraction: Bool = false) -> CodexKeychainLoad {
        // Target each candidate home's computed account first. A scoped card has exactly one; a
        // standard unresolved card follows the same home order as its file candidates. Later homes
        // are still tried after a protected item — each read targets its own exact account, so
        // there is no cross-credential risk between them.
        var permissionDenied = false
        var connectRequired = false
        var unreadable = false
        for home in credentialHomes() {
            let canonicalHome = Self.canonicalHome(home)
            let account = Self.keychainAccountName(forHome: canonicalHome)
            switch readKeychainValue(account: account, allowInteraction: allowKeychainInteraction) {
            case .value(let value):
                guard let auth = Self.parseAuth(value), Self.hasTokenLikeAuth(auth) else { continue }
                _ = recordResolvedIdentity(auth, home: canonicalHome)
                return .state(CodexAuthState(
                    auth: auth,
                    source: .keychain,
                    keychainAccount: account,
                    credentialHome: canonicalHome
                ))
            case .unavailable:
                // Interactive mode: the user just saw (and declined, or failed) this exact item's
                // prompt. Stop the scan — continuing would raise one dialog per remaining home. The
                // same failure can also be a locked keychain, which approval cannot fix, so report
                // whichever the read's own status recorded.
                if allowKeychainInteraction {
                    // Only a recorded denial asks for approval. No verdict means the read never
                    // reached one — UI-gate contention leaves none by design — so an unexamined
                    // item must not be reported as denied.
                    switch keychain.lastReadFailure(service: Self.keychainService, account: account) {
                    case .permissionDenied?: return .permissionRequired
                    case .manualReadDeferred?: return .connectRequired
                    case .unreadable?, nil: return .unreadable
                    }
                }
                // Approval only helps when the ACL was the problem. The read's own status is
                // the evidence; a later probe cannot answer this, because the failed read tripped
                // the item's breaker and probes are then answered locally.
                switch keychain.lastReadFailure(service: Self.keychainService, account: account) {
                case .permissionDenied?:
                    permissionDenied = true
                case .manualReadDeferred?:
                    connectRequired = true
                case .unreadable?:
                    unreadable = true
                case nil:
                    // No category recorded — which is exactly what UI-gate contention leaves — so
                    // fall back to the prompt-free attributes probe. A confirmed-present item was
                    // simply never read (a deferral, not a denial); an indeterminate probe means
                    // the item was never examined, and a confirmed absence is no footprint at all.
                    switch keychain.genericPasswordExists(service: Self.keychainService, account: account) {
                    case true?: connectRequired = true
                    case nil: unreadable = true
                    case false?: break
                    }
                }
            case .missing:
                continue
            }
        }
        // A protected exact item forbids the broad service-only lookup — with several Codex items
        // it could silently select a different login. Broadening stays allowed only when every
        // scoped item provably does not exist. A denial outranks a pending connect, which outranks
        // "couldn't check".
        if permissionDenied {
            return .permissionRequired
        }
        if connectRequired {
            return .connectRequired
        }
        // Same containment rule, different advice: an unreadable exact item must not be replaced
        // by the broad service-only lookup either.
        if unreadable {
            return .unreadable
        }

        // Preserve the historical service-only fallback for the unresolved single card. A scoped
        // account card never reaches it, so an unrelated item can never cross into a verified card.
        guard scope == .standard else { return .none }
        switch readKeychainValue(account: nil, allowInteraction: allowKeychainInteraction) {
        case .value(let value):
            guard let auth = Self.parseAuth(value), Self.hasTokenLikeAuth(auth) else { return .none }
            return .state(CodexAuthState(auth: auth, source: .keychain))
        case .missing:
            return .none
        case .unavailable:
            // Same rule as the scoped path: the read's own status says whether approval is the fix.
            switch keychain.lastReadFailure(service: Self.keychainService) {
            case .permissionDenied?:
                return .permissionRequired
            case .manualReadDeferred?:
                return .connectRequired
            case .unreadable?:
                return .unreadable
            case nil:
                // `nil` from the probe means "cannot check" (locked keychain, or the same UI gate
                // that left no category), not "absent" — treating it as logged-out would silently
                // swallow an access problem, and treating it as denied would ask the user to
                // approve an item nothing examined. Only a confirmed-absent item reports none.
                switch keychain.genericPasswordExists(service: Self.keychainService) {
                case true?: return .connectRequired
                case nil: return .unreadable
                case false?: return .none
                }
            }
        }
    }

    private func readKeychainValue(account: String?, allowInteraction: Bool) -> NonInteractiveKeychainRead {
        guard allowInteraction else {
            if let account {
                return keychain.readGenericPasswordWithoutUserInteraction(service: Self.keychainService, account: account)
            }
            return keychain.readGenericPasswordWithoutUserInteraction(service: Self.keychainService)
        }
        do {
            let value: String?
            if let account {
                value = try keychain.readGenericPasswordAllowingUserInteraction(service: Self.keychainService, account: account)
            } else {
                value = try keychain.readGenericPasswordAllowingUserInteraction(service: Self.keychainService)
            }
            return value.map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    /// Reload exactly the source that produced a state. A standard store can know several homes, so
    /// repeating its normal precedence walk during token rotation could jump accounts.
    /// Re-reads the state's own credential store mid-refresh (e.g. before a rotation). Keychain
    /// reloads are prompt-free by construction: the item was already read to get here, so the
    /// non-interactive in-process read serves it from the coordinator without touching securityd's
    /// approval machinery again.
    func reload(_ state: CodexAuthState) -> CodexAuthState? {
        switch state.source {
        case .file(let path):
            return loadAuth(at: path)
        case .keychain:
            guard let account = state.keychainAccount,
                  let home = state.credentialHome,
                  case .value(let value) = keychain.readGenericPasswordWithoutUserInteraction(
                      service: Self.keychainService,
                      account: account
                  ),
                  let auth = Self.parseAuth(value),
                  Self.hasTokenLikeAuth(auth)
            else {
                // The service-level legacy state has no exact address.
                guard state.keychainAccount == nil else { return nil }
                return loadLegacyKeychainAuth()
            }
            _ = recordResolvedIdentity(auth, home: home)
            return CodexAuthState(
                auth: auth,
                source: .keychain,
                keychainAccount: account,
                credentialHome: home
            )
        }
    }

    /// Record the account that actually authenticated a usage request. File-backed cards don't need
    /// the cache; keyring states refresh the binding in case the item's metadata changed.
    @discardableResult
    func recordSelectedIdentity(_ state: CodexAuthState) -> DefaultAccountObserver.CodexIdentity? {
        guard let identity = DefaultAccountObserver.codexIdentity(state.auth) else { return nil }
        if state.source.isKeychain, let home = state.credentialHome {
            _ = recordResolvedIdentity(state.auth, home: home)
        }
        return identity
    }

    /// Stronger result for hidden-home preparation: identity parsing alone is not success. The next
    /// launch can place the card only after the identity and the item's current fingerprint were
    /// durably recorded together.
    func recordSelectedIdentityBinding(_ state: CodexAuthState) -> Bool {
        guard state.source.isKeychain, let home = state.credentialHome else { return false }
        return recordResolvedIdentity(state.auth, home: home)?.bindingRecorded == true
    }

    /// Whether the access token should be proactively refreshed.
    ///
    /// Prefers the access token's own JWT `exp` — refresh only when it is at (or within
    /// `accessTokenRefreshWindow` of) expiry, mirroring the `codex` CLI. The hardcoded 8-day
    /// wall-clock age is only a fallback for tokens whose `exp` we can't read; on its own it forced a
    /// refresh while the access token was still valid, tripping `refresh_token_reused` (issue #516).
    /// A brand-new login with no `last_refresh` and no readable `exp` does NOT need a refresh.
    /// Whether the credential is at (or within a slack window of) its expiry — the trigger for
    /// re-reading the live store, where the `codex` CLI may already have rotated a fresh token.
    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let accessToken = auth.tokens?.accessToken,
           let expiresAt = accessTokenExpiresAt(accessToken) {
            return expiresAt.timeIntervalSince(now()) <= Self.accessTokenRefreshWindow
        }
        guard let lastRefresh = auth.lastRefresh,
              let date = RunwayISO8601.date(from: lastRefresh)
        else {
            return false
        }
        return now().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    /// Whether the access token's own JWT `exp` has lapsed. Runway never refreshes a Codex token —
    /// the `codex` CLI owns rotation (and OpenAI's reuse detection punishes a second rotator) — so
    /// an expired candidate is reported for renewal, not renewed. Unknown expiry is not "expired":
    /// the usage call decides.
    func isExpired(_ auth: CodexAuth) -> Bool {
        guard let accessToken = auth.tokens?.accessToken,
              let expiresAt = accessTokenExpiresAt(accessToken)
        else {
            return false
        }
        return expiresAt <= now()
    }

    /// The access token's expiry from its JWT `exp` claim, or `nil` when the token isn't a decodable
    /// JWT or omits `exp`.
    func accessTokenExpiresAt(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func authPaths() -> [String] {
        credentialHomes().map { joinPath($0, Self.authFile) }
    }

    func codexHome() -> String? {
        guard let codexHome = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexHome.isEmpty
        else {
            return nil
        }
        return codexHome
    }

    /// Credential homes in probe order. Comma-separated `CODEX_HOME` values already drive the log
    /// scanner; treating each entry as a home keeps auth resolution aligned until the launch account
    /// pass pins every rendered card to one exact source.
    func credentialHomes() -> [String] {
        if case .home(let path) = scope { return [path] }
        if let raw = codexHome() {
            let homes = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !homes.isEmpty { return homes }
        }
        return Self.defaultAuthHomes
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        ProviderParse.decodeJSONWithHexFallback(text, as: CodexAuth.self)
    }

    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        if auth.tokens?.accessToken?.isEmpty == false { return true }
        if auth.apiKey?.isEmpty == false { return true }
        return false
    }

    private func joinPath(_ base: String, _ leaf: String) -> String {
        base.trimmingTrailingSlashes + "/" + leaf
    }

    private func loadLegacyKeychainAuth() -> CodexAuthState? {
        guard scope == .standard,
              case .value(let value) = keychain.readGenericPasswordWithoutUserInteraction(service: Self.keychainService),
              let auth = Self.parseAuth(value),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .keychain)
    }

    private static func canonicalHome(forAuthPath path: String) -> String {
        canonicalHome(URL(fileURLWithPath: expandHome(path)).deletingLastPathComponent().path)
    }

    private static func canonicalHome(_ path: String) -> String {
        URL(fileURLWithPath: expandHome(path))
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    @discardableResult
    private func recordResolvedIdentity(
        _ auth: CodexAuth,
        home: String
    ) -> (identity: DefaultAccountObserver.CodexIdentity, bindingRecorded: Bool)? {
        guard let identity = DefaultAccountObserver.codexIdentity(auth) else { return nil }
        guard let identityCache else { return (identity, false) }
        let account = Self.keychainAccountName(forHome: home)
        guard let fingerprint = keychain.genericPasswordAttributeFingerprint(
            service: Self.keychainService,
            account: account
        ) else {
            AppLog.warn(
                .keychain,
                "Codex identity cache skipped because account-scoped item attributes were unreadable"
            )
            return (identity, false)
        }
        let recorded = identityCache.record(
            identity: identity,
            forHome: home,
            keychainItemFingerprint: fingerprint
        )
        return (identity, recorded)
    }
}

private extension CodexAuthState.Source {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    var isKeychain: Bool {
        if case .keychain = self { return true }
        return false
    }
}
